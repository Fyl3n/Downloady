//
//  ToolManager.swift
//  Dropload
//
//  Where yt-dlp and ffmpeg come from.
//
//  yt-dlp: the user's custom path, or the droplet's own copy, downloaded on
//  first run into `host.environment.containerDirectory/tools/`, never into
//  the bundle (Droppy refuses a bundle whose files changed after approval).
//  ffmpeg: a custom path, a system copy when there is one, otherwise a
//  downloaded static build in the same folder.
//

import CryptoKit
import Foundation

/// A located executable and where it came from.
public struct ToolLocation: Equatable, Sendable {
    public enum Source: String, Sendable {
        /// Downloaded by the droplet into its container.
        case managed
        /// Found on the system (Homebrew, /usr/local, PATH).
        case system
        /// A path the user set in Settings.
        case custom

        /// How Settings names it.
        public var title: String {
            switch self {
            case .managed: "Downloaded"
            case .system: "System"
            case .custom: "Custom"
            }
        }
    }

    public let url: URL
    public let source: Source
    public let version: String?

    public init(url: URL, source: Source, version: String?) {
        self.url = url
        self.source = source
        self.version = version
    }
}

/// What the widget needs to know before it can offer a download.
public enum ToolStatus: Equatable, Sendable {
    case unknown
    case missing
    case installing(progress: Double)
    case ready(ytDlp: ToolLocation, ffmpeg: ToolLocation?)
    case failed(String)

    public var isReady: Bool {
        if case .ready = self { return true }
        return false
    }

    public var ytDlp: ToolLocation? {
        if case .ready(let ytDlp, _) = self { return ytDlp }
        return nil
    }

    public var ffmpeg: ToolLocation? {
        if case .ready(_, let ffmpeg) = self { return ffmpeg }
        return nil
    }
}

public enum ToolError: Error, Equatable, LocalizedError {
    case notPermitted
    case insecureURL(String)
    case httpStatus(Int, String)
    case checksumMissing(String)
    case checksumMismatch(String)
    case unpackFailed(String)
    case releaseUnknown

    public var errorDescription: String? {
        switch self {
        case .notPermitted: "Network access is turned off for Dropload"
        case .insecureURL(let url): "Refused a download that is not HTTPS: \(url)"
        case .httpStatus(let code, let name): "Download of \(name) failed (HTTP \(code))"
        case .checksumMissing(let name): "No checksum published for \(name)"
        case .checksumMismatch(let name): "Checksum mismatch for \(name)"
        case .unpackFailed(let name): "Could not unpack \(name)"
        case .releaseUnknown: "Could not find the latest yt-dlp release"
        }
    }
}

/// Finds, installs and updates the external tools.
@MainActor
public protocol ToolManaging: AnyObject {
    /// Current state, without touching the network.
    func resolve() async -> ToolStatus

    /// Where ffmpeg would come from, even while yt-dlp is missing. No version.
    func locateFFmpeg() -> ToolLocation?

    /// Downloads whatever is missing (yt-dlp, and ffmpeg when the system has
    /// none), verifying checksums, and reports progress through `progress`.
    func installMissing(progress: @escaping @MainActor (Double) -> Void) async throws -> ToolStatus

    /// Re-downloads the managed yt-dlp when a newer release exists.
    func updateYtDlp() async throws -> ToolStatus
}

// MARK: - Pure logic

/// Parses `SHA2-256SUMS` style files: `<hex digest>  <file name>` per line,
/// optionally with a `*` binary marker before the name.
public enum ChecksumList {
    public static func parse(_ text: String) -> [String: String] {
        var sums: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(maxSplits: 1, whereSeparator: \.isWhitespace)
            guard parts.count == 2 else { continue }
            let digest = parts[0].lowercased()
            guard digest.count == 64, digest.allSatisfy(\.isHexDigit) else { continue }
            var name = parts[1].trimmingCharacters(in: .whitespaces)
            if name.hasPrefix("*") { name.removeFirst() }
            guard !name.isEmpty else { continue }
            sums[name] = digest
        }
        return sums
    }

    /// SHA-256 of a file, streamed, as lowercase hex.
    public static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// The order tools are looked up in.
public enum ToolLookup {
    public static let systemFFmpegPaths = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"]

    /// yt-dlp: the custom path, then the managed onedir copy.
    public static func ytDlp(
        custom: String?,
        managed: URL,
        isExecutable: (String) -> Bool
    ) -> (url: URL, source: ToolLocation.Source)? {
        if let custom = normalized(custom), isExecutable(custom) {
            return (URL(fileURLWithPath: custom), .custom)
        }
        if isExecutable(managed.path) { return (managed, .managed) }
        return nil
    }

    /// ffmpeg: the custom path, Homebrew, /usr/local, `PATH`, then the managed copy.
    public static func ffmpeg(
        custom: String?,
        pathVariable: String?,
        managed: URL,
        isExecutable: (String) -> Bool
    ) -> (url: URL, source: ToolLocation.Source)? {
        if let custom = normalized(custom), isExecutable(custom) {
            return (URL(fileURLWithPath: custom), .custom)
        }
        var candidates = systemFFmpegPaths
        for directory in (pathVariable ?? "").split(separator: ":") where !directory.isEmpty {
            let path = URL(fileURLWithPath: String(directory)).appendingPathComponent("ffmpeg").path
            if !candidates.contains(path) { candidates.append(path) }
        }
        for path in candidates where path != managed.path && isExecutable(path) {
            return (URL(fileURLWithPath: path), .system)
        }
        if isExecutable(managed.path) { return (managed, .managed) }
        return nil
    }

    static func normalized(_ path: String?) -> String? {
        guard let trimmed = path?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return (trimmed as NSString).expandingTildeInPath
    }
}

public enum ToolVersion {
    /// `ffmpeg version 7.1.1 Copyright (c) …` -> `7.1.1`.
    public static func ffmpeg(fromFirstLine output: String) -> String? {
        guard let line = output.split(whereSeparator: \.isNewline).first else { return nil }
        let words = line.split(separator: " ")
        if words.count >= 3, words[0] == "ffmpeg", words[1] == "version" {
            // Some static builds append their site: `8.0.git-https://…`.
            let version = String(words[2])
            return version.components(separatedBy: "-http").first ?? version
        }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// `2026.08.19\n` -> `2026.08.19`.
    public static func ytDlp(from output: String) -> String? {
        let line = output.split(whereSeparator: \.isNewline).first.map(String.init)?
            .trimmingCharacters(in: .whitespaces)
        return line?.isEmpty == false ? line : nil
    }

    /// Compares yt-dlp versions (`2026.08.19`, `2026.08.19.1`) numerically.
    public static func isNewer(_ candidate: String, than current: String?) -> Bool {
        guard let current else { return true }
        let lhs = components(candidate), rhs = components(current)
        guard !lhs.isEmpty else { return false }
        for index in 0..<max(lhs.count, rhs.count) {
            let a = index < lhs.count ? lhs[index] : 0
            let b = index < rhs.count ? rhs[index] : 0
            if a != b { return a > b }
        }
        return false
    }

    private static func components(_ version: String) -> [Int] {
        version.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
    }
}

// MARK: - Downloads

/// A file fetched to a temporary location, and the URL it finally came from
/// after redirects.
public struct FetchedFile: Sendable {
    public let file: URL
    public let finalURL: URL

    public init(file: URL, finalURL: URL) {
        self.file = file
        self.finalURL = finalURL
    }
}

/// The network under the tool manager, so tests can replace it.
public protocol ToolFetching: Sendable {
    /// Downloads `url` into `directory`, reporting 0...1.
    func fetch(_ url: URL, into directory: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> FetchedFile
    /// Where `url` ends up after redirects, without downloading the body.
    func resolveRedirect(_ url: URL) async throws -> URL
}

/// `URLSession` with a delegate, so progress is reported and a cancelled
/// task cancels the transfer.
public final class URLSessionToolFetcher: NSObject, ToolFetching, URLSessionDownloadDelegate, @unchecked Sendable {
    private struct Pending {
        let directory: URL
        let progress: @Sendable (Double) -> Void
        let continuation: CheckedContinuation<FetchedFile, Error>
    }

    private let lock = NSLock()
    private var pending: [Int: Pending] = [:]
    private var session: URLSession!

    public override init() {
        super.init()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }

    /// Breaks the session's strong reference to its delegate.
    public func invalidate() {
        session.invalidateAndCancel()
    }

    public func fetch(_ url: URL, into directory: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> FetchedFile {
        guard url.scheme == "https" else { throw ToolError.insecureURL(url.absoluteString) }
        let task = session.downloadTask(with: url)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.withLock {
                    pending[task.taskIdentifier] = Pending(directory: directory, progress: progress, continuation: continuation)
                }
                if Task.isCancelled { task.cancel() }
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    public func resolveRedirect(_ url: URL) async throws -> URL {
        guard url.scheme == "https" else { throw ToolError.insecureURL(url.absoluteString) }
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        let (_, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ToolError.httpStatus(http.statusCode, url.lastPathComponent)
        }
        guard let final = response.url, final.scheme == "https" else {
            throw ToolError.insecureURL(response.url?.absoluteString ?? url.absoluteString)
        }
        return final
    }

    private func take(_ task: URLSessionTask) -> Pending? {
        lock.withLock { pending.removeValue(forKey: task.taskIdentifier) }
    }

    public func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let entry = lock.withLock { pending[downloadTask.taskIdentifier] }
        entry?.progress(min(1, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)))
    }

    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let entry = take(downloadTask) else { return }
        let finalURL = downloadTask.response?.url ?? downloadTask.originalRequest?.url
        let name = downloadTask.originalRequest?.url?.lastPathComponent ?? "file"
        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            entry.continuation.resume(throwing: ToolError.httpStatus(http.statusCode, name))
            return
        }
        guard let finalURL, finalURL.scheme == "https" else {
            entry.continuation.resume(throwing: ToolError.insecureURL(finalURL?.absoluteString ?? name))
            return
        }
        // The system deletes `location` when this method returns.
        let destination = entry.directory.appendingPathComponent(UUID().uuidString + "-" + finalURL.lastPathComponent)
        do {
            try FileManager.default.moveItem(at: location, to: destination)
            entry.progress(1)
            entry.continuation.resume(returning: FetchedFile(file: destination, finalURL: finalURL))
        } catch {
            entry.continuation.resume(throwing: error)
        }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let entry = take(task) else { return }
        if let error, (error as? URLError)?.code == .cancelled {
            entry.continuation.resume(throwing: CancellationError())
        } else {
            entry.continuation.resume(throwing: error ?? URLError(.unknown))
        }
    }
}

// MARK: - Processes

/// Runs a short-lived tool off the main actor, with a timeout.
enum ToolProcess {
    private final class Box: @unchecked Sendable {
        let process = Process()
    }

    struct Result: Sendable {
        let status: Int32
        let output: String
    }

    static func run(_ executable: URL, _ arguments: [String], timeout: TimeInterval) async -> Result? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let box = Box()
                let process = box.process
                let pipe = Pipe()
                process.executableURL = executable
                process.arguments = arguments
                process.standardOutput = pipe
                process.standardError = FileHandle.nullDevice
                process.standardInput = FileHandle.nullDevice
                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: nil)
                    return
                }
                let watchdog = DispatchWorkItem {
                    if box.process.isRunning { box.process.terminate() }
                }
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: watchdog)
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                watchdog.cancel()
                continuation.resume(returning: Result(status: process.terminationStatus, output: String(decoding: data, as: UTF8.self)))
            }
        }
    }
}

// MARK: - Tool manager

/// The real implementation.
///
/// - yt-dlp: `yt-dlp_macos.zip` (onedir build, starts much faster than the
///   onefile `yt-dlp_macos`) from a GitHub release, verified against that
///   release's `SHA2-256SUMS`, unpacked into `<container>/tools/yt-dlp/`.
/// - ffmpeg: custom path, /opt/homebrew/bin, /usr/local/bin, PATH; else a
///   static build for the running architecture from ffmpeg.martin-riedl.de,
///   verified against its published `.sha256`, at `<container>/tools/ffmpeg`.
@MainActor
public final class ToolManager: ToolManaging {
    public struct Configuration: Sendable {
        /// `/latest` redirects to `/tag/<version>`.
        public var ytDlpLatestRelease = URL(string: "https://github.com/yt-dlp/yt-dlp/releases/latest")!
        public var ytDlpDownloadBase = URL(string: "https://github.com/yt-dlp/yt-dlp/releases/download/")!
        public var ffmpegArchive: URL
        public var versionTimeout: TimeInterval = 30

        public init() {
            #if arch(arm64)
            let arch = "arm64"
            #else
            let arch = "amd64"
            #endif
            ffmpegArchive = URL(string: "https://ffmpeg.martin-riedl.de/redirect/latest/macos/\(arch)/snapshot/ffmpeg.zip")!
        }
    }

    static let ytDlpArchiveName = "yt-dlp_macos.zip"
    static let ytDlpExecutableName = "yt-dlp_macos"
    static let ytDlpSumsName = "SHA2-256SUMS"
    /// yt-dlp's share of the install progress bar; ffmpeg gets the rest.
    static let ytDlpProgressShare = 0.7

    private let containerDirectory: URL
    private let configuration: Configuration
    private let fetcher: ToolFetching
    private let customPaths: @MainActor () -> (ytDlp: String?, ffmpeg: String?)
    private let networkGranted: @MainActor () -> Bool
    private let log: @MainActor (String) -> Void
    private let fileManager = FileManager.default

    public init(
        containerDirectory: URL,
        configuration: Configuration = Configuration(),
        fetcher: ToolFetching? = nil,
        customPaths: @escaping @MainActor () -> (ytDlp: String?, ffmpeg: String?) = { (nil, nil) },
        networkGranted: @escaping @MainActor () -> Bool = { true },
        log: @escaping @MainActor (String) -> Void
    ) {
        self.containerDirectory = containerDirectory
        self.configuration = configuration
        self.fetcher = fetcher ?? URLSessionToolFetcher()
        self.customPaths = customPaths
        self.networkGranted = networkGranted
        self.log = log
    }

    deinit {
        (fetcher as? URLSessionToolFetcher)?.invalidate()
    }

    /// `<container>/tools`
    public var toolsDirectory: URL {
        containerDirectory.appendingPathComponent("tools", isDirectory: true)
    }

    /// `<container>/tools/yt-dlp`
    var ytDlpDirectory: URL { toolsDirectory.appendingPathComponent("yt-dlp", isDirectory: true) }
    var managedYtDlp: URL { ytDlpDirectory.appendingPathComponent(Self.ytDlpExecutableName) }
    var managedFFmpeg: URL { toolsDirectory.appendingPathComponent("ffmpeg") }

    // MARK: Resolve

    public func resolve() async -> ToolStatus {
        let paths = customPaths()
        let isExecutable = Self.isExecutableFile
        guard let ytDlp = ToolLookup.ytDlp(custom: paths.ytDlp, managed: managedYtDlp, isExecutable: isExecutable) else {
            return .missing
        }
        let ffmpeg = ToolLookup.ffmpeg(
            custom: paths.ffmpeg,
            pathVariable: ProcessInfo.processInfo.environment["PATH"],
            managed: managedFFmpeg,
            isExecutable: isExecutable
        )

        let timeout = configuration.versionTimeout
        let ffmpegURL = ffmpeg?.url
        async let ytDlpOutput = ToolProcess.run(ytDlp.url, ["--version"], timeout: timeout)
        async let ffmpegOutput = Self.runIfPresent(ffmpegURL, ["-version"], timeout: timeout)
        let ytDlpResult = await ytDlpOutput
        let ffmpegResult = await ffmpegOutput

        let ytDlpVersion = ytDlpResult.flatMap { $0.status == 0 ? ToolVersion.ytDlp(from: $0.output) : nil }
        if ytDlpVersion == nil { log("yt-dlp at \(ytDlp.url.path) did not report a version") }
        let ffmpegVersion = ffmpegResult.flatMap { ToolVersion.ffmpeg(fromFirstLine: $0.output) }

        return .ready(
            ytDlp: ToolLocation(url: ytDlp.url, source: ytDlp.source, version: ytDlpVersion),
            ffmpeg: ffmpeg.map { ToolLocation(url: $0.url, source: $0.source, version: ffmpegVersion) }
        )
    }

    public func locateFFmpeg() -> ToolLocation? {
        ToolLookup.ffmpeg(
            custom: customPaths().ffmpeg,
            pathVariable: ProcessInfo.processInfo.environment["PATH"],
            managed: managedFFmpeg,
            isExecutable: Self.isExecutableFile
        ).map { ToolLocation(url: $0.url, source: $0.source, version: nil) }
    }

    nonisolated private static func runIfPresent(_ url: URL?, _ arguments: [String], timeout: TimeInterval) async -> ToolProcess.Result? {
        guard let url else { return nil }
        return await ToolProcess.run(url, arguments, timeout: timeout)
    }

    nonisolated static func isExecutableFile(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            return false
        }
        return FileManager.default.isExecutableFile(atPath: path)
    }

    // MARK: Install

    public func installMissing(progress: @escaping @MainActor (Double) -> Void) async throws -> ToolStatus {
        guard networkGranted() else { throw ToolError.notPermitted }
        let paths = customPaths()
        let needsYtDlp = ToolLookup.ytDlp(custom: paths.ytDlp, managed: managedYtDlp, isExecutable: Self.isExecutableFile) == nil
        let needsFFmpeg = ToolLookup.ffmpeg(
            custom: paths.ffmpeg,
            pathVariable: ProcessInfo.processInfo.environment["PATH"],
            managed: managedFFmpeg,
            isExecutable: Self.isExecutableFile
        ) == nil

        let share = needsFFmpeg ? Self.ytDlpProgressShare : 1
        progress(0)
        if needsYtDlp {
            let tag = try await latestYtDlpTag()
            try await installYtDlp(tag: tag) { progress($0 * share) }
        }
        progress(share)
        try Task.checkCancellation()

        if needsFFmpeg {
            do {
                try await installFFmpeg { progress(share + $0 * (1 - share)) }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // ffmpeg only matters for merging and converting; yt-dlp still works.
                log("ffmpeg install failed: \(error.localizedDescription)")
            }
        }
        progress(1)
        return await resolve()
    }

    public func updateYtDlp() async throws -> ToolStatus {
        guard networkGranted() else { throw ToolError.notPermitted }
        let current = await resolve()
        if let location = current.ytDlp, location.source == .custom {
            log("yt-dlp comes from a custom path; not updating it")
            return current
        }
        let tag = try await latestYtDlpTag()
        let installed = current.ytDlp?.version
        guard ToolVersion.isNewer(tag, than: installed) else {
            log("yt-dlp \(installed ?? "?") is up to date")
            return current
        }
        log("updating yt-dlp \(installed ?? "none") -> \(tag)")
        try await installYtDlp(tag: tag) { _ in }
        return await resolve()
    }

    /// The tag `/releases/latest` redirects to.
    func latestYtDlpTag() async throws -> String {
        let final = try await fetcher.resolveRedirect(configuration.ytDlpLatestRelease)
        let tag = final.lastPathComponent
        guard final.pathComponents.contains("tag"), !tag.isEmpty else { throw ToolError.releaseUnknown }
        return tag
    }

    /// Downloads, verifies and swaps in the onedir build of `tag`.
    func installYtDlp(tag: String, progress: @escaping @MainActor (Double) -> Void) async throws {
        let release = configuration.ytDlpDownloadBase.appendingPathComponent(tag, isDirectory: true)
        let staging = try makeStaging()
        defer { try? fileManager.removeItem(at: staging) }

        let report = Self.sendable(progress, scale: 0.95)
        let archive = try await fetcher.fetch(release.appendingPathComponent(Self.ytDlpArchiveName), into: staging, progress: report)
        let sums = try await fetcher.fetch(release.appendingPathComponent(Self.ytDlpSumsName), into: staging) { _ in }
        try Task.checkCancellation()

        try await Self.verify(archive.file, named: Self.ytDlpArchiveName, against: sums.file)
        let unpacked = staging.appendingPathComponent("unpacked", isDirectory: true)
        try await Self.unzip(archive.file, into: unpacked, name: Self.ytDlpArchiveName)
        let executable = unpacked.appendingPathComponent(Self.ytDlpExecutableName)
        guard fileManager.fileExists(atPath: executable.path) else { throw ToolError.unpackFailed(Self.ytDlpArchiveName) }
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        try Task.checkCancellation()

        try swapIn(unpacked, at: ytDlpDirectory)
        await Self.clearQuarantine(ytDlpDirectory)
        progress(1)
        log("installed yt-dlp \(tag)")
    }

    /// Downloads, verifies and installs a static ffmpeg.
    func installFFmpeg(progress: @escaping @MainActor (Double) -> Void) async throws {
        let staging = try makeStaging()
        defer { try? fileManager.removeItem(at: staging) }

        let report = Self.sendable(progress, scale: 0.95)
        let archive = try await fetcher.fetch(configuration.ffmpegArchive, into: staging, progress: report)
        // Checksum of the exact build the redirect landed on.
        let sumsURL = URL(string: archive.finalURL.absoluteString + ".sha256")!
        let sums = try await fetcher.fetch(sumsURL, into: staging) { _ in }
        try Task.checkCancellation()

        let name = archive.finalURL.lastPathComponent
        try await Self.verify(archive.file, named: name, against: sums.file)
        let unpacked = staging.appendingPathComponent("unpacked", isDirectory: true)
        try await Self.unzip(archive.file, into: unpacked, name: name)
        let binary = unpacked.appendingPathComponent("ffmpeg")
        guard fileManager.fileExists(atPath: binary.path) else { throw ToolError.unpackFailed(name) }
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        try Task.checkCancellation()

        try swapIn(binary, at: managedFFmpeg)
        await Self.clearQuarantine(managedFFmpeg)
        progress(1)
        log("installed ffmpeg")
    }

    // MARK: Helpers

    /// A scratch folder inside `tools/`, so the final move is a same-volume rename.
    private func makeStaging() throws -> URL {
        let staging = toolsDirectory.appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        return staging
    }

    /// Replaces `destination` with `item` in one step.
    private func swapIn(_ item: URL, at destination: URL) throws {
        if fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(destination, withItemAt: item)
        } else {
            try fileManager.moveItem(at: item, to: destination)
        }
    }

    private static func sendable(_ progress: @escaping @MainActor (Double) -> Void, scale: Double) -> @Sendable (Double) -> Void {
        { value in Task { @MainActor in progress(value * scale) } }
    }

    nonisolated static func verify(_ file: URL, named name: String, against sumsFile: URL) async throws {
        try await Task.detached(priority: .utility) {
            let text = try String(contentsOf: sumsFile, encoding: .utf8)
            guard let expected = ChecksumList.parse(text)[name] else { throw ToolError.checksumMissing(name) }
            guard try ChecksumList.sha256(of: file) == expected else { throw ToolError.checksumMismatch(name) }
        }.value
    }

    nonisolated static func unzip(_ archive: URL, into directory: URL, name: String) async throws {
        let result = await ToolProcess.run(
            URL(fileURLWithPath: "/usr/bin/ditto"),
            ["-x", "-k", archive.path, directory.path],
            timeout: 300
        )
        guard result?.status == 0 else { throw ToolError.unpackFailed(name) }
    }

    /// Files fetched with URLSession carry no quarantine flag today; strip it
    /// anyway in case a host ever adds one.
    nonisolated static func clearQuarantine(_ url: URL) async {
        _ = await ToolProcess.run(
            URL(fileURLWithPath: "/usr/bin/xattr"),
            ["-dr", "com.apple.quarantine", url.path],
            timeout: 60
        )
    }
}
