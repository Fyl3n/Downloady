//
//  ToolManager.swift
//  Downloady
//
//  Where yt-dlp, ffmpeg and Deno come from.
//
//  Each tool comes from one source the user picks in Settings: the copy
//  Downloady downloads into `host.environment.containerDirectory/tools/`
//  (never into the bundle: Droppy refuses a bundle whose files changed after
//  approval), the one installed on the Mac, or a custom path.
//  yt-dlp defaults to Downloady's copy, installed on first run and kept
//  current: YouTube breaks older releases within weeks. ffmpeg and Deno are
//  stable and any recent copy works, so they default to the Mac's copy, and
//  to Downloady's when the Mac has none.
//

import CryptoKit
import Foundation
import os

/// A located executable and where it came from.
public struct ToolLocation: Equatable, Sendable {
    public enum Source: String, Sendable, CaseIterable {
        /// Downloaded by the droplet into its container.
        case managed
        /// Found on the system (Homebrew, /usr/local, PATH).
        case system
        /// A path the user set in Settings.
        case custom

        /// The segment in Settings' source picker.
        public var title: String {
            switch self {
            case .managed: "Downloady"
            case .system: "This Mac"
            case .custom: "Custom"
            }
        }
    }

    /// The external tools. yt-dlp is required; ffmpeg merges and converts,
    /// and Deno runs YouTube's JavaScript challenges for yt-dlp.
    public enum Tool: String, Sendable, CaseIterable {
        case ytDlp = "yt-dlp"
        case ffmpeg
        case deno

        /// The name Settings shows.
        public var name: String { self == .deno ? "Deno" : rawValue }
        /// The source the default tries first: yt-dlp is Downloady's copy,
        /// kept current; the stable helpers reuse the Mac's.
        public var preferredSource: Source { self == .ytDlp ? .managed : .system }
        /// The executable's file name on the Mac.
        public var executableName: String { rawValue }
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

/// Where the user wants each tool to come from. A `nil` source is the
/// default: the tool's preferred source, falling back to the other one (see
/// `ToolLookup.effectiveSource`). A source the user picked never falls back.
public struct ToolChoices: Equatable, Sendable {
    public var sources: [ToolLocation.Tool: ToolLocation.Source]
    public var paths: [ToolLocation.Tool: String]
    /// Tools whose Downloady copy failed to install this session.
    public var failedInstalls: Set<ToolLocation.Tool>

    public init(
        sources: [ToolLocation.Tool: ToolLocation.Source] = [:],
        paths: [ToolLocation.Tool: String] = [:],
        failedInstalls: Set<ToolLocation.Tool> = []
    ) {
        self.sources = sources
        self.paths = paths
        self.failedInstalls = failedInstalls
    }

    /// The stored choice for `tool`; `nil` is the default.
    public func source(for tool: ToolLocation.Tool) -> ToolLocation.Source? { sources[tool] }

    public func path(for tool: ToolLocation.Tool) -> String? { paths[tool] }
}

/// What the widget needs to know before it can offer a download.
public enum ToolStatus: Equatable, Sendable {
    case unknown
    case missing
    case installing(progress: Double)
    case ready(ytDlp: ToolLocation, ffmpeg: ToolLocation?, deno: ToolLocation? = nil)
    case failed(String)

    public var isReady: Bool {
        if case .ready = self { return true }
        return false
    }

    public var ytDlp: ToolLocation? {
        if case .ready(let ytDlp, _, _) = self { return ytDlp }
        return nil
    }

    public var ffmpeg: ToolLocation? {
        if case .ready(_, let ffmpeg, _) = self { return ffmpeg }
        return nil
    }

    public var deno: ToolLocation? {
        if case .ready(_, _, let deno) = self { return deno }
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
    case nothingToCompare(String)

    public var errorDescription: String? {
        switch self {
        case .notPermitted: "Network access is turned off for Downloady"
        case .insecureURL(let url): "Refused a download that is not HTTPS: \(url)"
        case .httpStatus(let code, let name): "Download of \(name) failed (HTTP \(code))"
        case .checksumMissing(let name): "No checksum published for \(name)"
        case .checksumMismatch(let name): "Checksum mismatch for \(name)"
        case .unpackFailed(let name): "Could not unpack \(name)"
        case .releaseUnknown: "Could not find the latest release"
        case .nothingToCompare(let name): "Nothing says which \(name) is current"
        }
    }
}

/// Finds, installs and updates the external tools.
/// A newer release of a tool, and how to get it.
public struct ToolUpdate: Equatable, Sendable {
    public let version: String
    /// What updates a copy Downloady does not own, when its origin is known.
    /// `nil` for Downloady's copy, which updates itself.
    public let command: String?

    public init(version: String, command: String?) {
        self.version = version
        self.command = command
    }
}

/// How a copy on the Mac was installed: where its newer release is
/// announced, and the command that fetches it.
public enum ToolOrigin: Equatable, Sendable {
    /// A symlink into Homebrew's Cellar.
    case homebrew
    /// Deno's own installer, in `~/.deno/bin`.
    case denoInstaller
    /// A pipx virtual environment.
    case pipx
    /// Anything else: a download, a pip install, a build of the user's own.
    case unknown

    /// `resolved` is `path` with its symlinks resolved.
    public static func detect(path: String, resolved: String, home: String = NSHomeDirectory()) -> ToolOrigin {
        if resolved.contains("/Cellar/") { return .homebrew }
        if path == "\(home)/.deno/bin/deno" { return .denoInstaller }
        if resolved.contains("/pipx/venvs/") { return .pipx }
        return .unknown
    }

    public func upgradeCommand(for tool: ToolLocation.Tool) -> String? {
        switch self {
        case .homebrew: "brew upgrade \(tool.executableName)"
        case .denoInstaller: "~/.deno/bin/deno upgrade"
        case .pipx: "pipx upgrade \(tool.executableName)"
        case .unknown: nil
        }
    }
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

/// Where each source looks. Every lookup is strict: a tool set to one
/// source never quietly comes from another.
public enum ToolLookup {
    /// Homebrew (Apple silicon, then Intel), pipx, Deno's own installer,
    /// then each `PATH` entry. Droppy started from Finder has a short `PATH`,
    /// hence the fixed ones.
    public static func systemCandidates(
        named name: String,
        pathVariable: String?,
        home: String = NSHomeDirectory()
    ) -> [String] {
        var candidates = ["/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)", "\(home)/.local/bin/\(name)"]
        if name == "deno" { candidates.append("\(home)/.deno/bin/deno") }
        for directory in (pathVariable ?? "").split(separator: ":") where !directory.isEmpty {
            let path = URL(fileURLWithPath: String(directory)).appendingPathComponent(name).path
            if !candidates.contains(path) { candidates.append(path) }
        }
        return candidates
    }

    /// The first system candidate that is an executable, skipping the
    /// managed copy should `PATH` ever point into the container.
    public static func systemCopy(
        in candidates: [String],
        excluding managed: URL,
        isExecutable: (String) -> Bool
    ) -> URL? {
        candidates.first { $0 != managed.path && isExecutable($0) }.map { URL(fileURLWithPath: $0) }
    }

    /// The tool as `source` provides it, or `nil` when that source has none.
    public static func locate(
        source: ToolLocation.Source,
        custom: String?,
        systemCandidates: [String],
        managed: URL,
        isExecutable: (String) -> Bool
    ) -> URL? {
        switch source {
        case .custom:
            guard let custom = normalized(custom), isExecutable(custom) else { return nil }
            return URL(fileURLWithPath: custom)
        case .system:
            return systemCopy(in: systemCandidates, excluding: managed, isExecutable: isExecutable)
        case .managed:
            return isExecutable(managed.path) ? managed : nil
        }
    }

    /// The source a choice stands for. A picked source is kept as is. The
    /// default (`nil`) tries the preferred source, then the other one:
    /// - yt-dlp: Downloady's copy, installed when missing; the Mac's only
    ///   once that install failed.
    /// - ffmpeg, Deno: the Mac's copy; Downloady's when the Mac has none.
    /// Neither there: the source to install, so a retry knows what to fetch.
    public static func effectiveSource(
        _ chosen: ToolLocation.Source?,
        preferred: ToolLocation.Source,
        systemAvailable: Bool,
        managedAvailable: Bool,
        installFailed: Bool
    ) -> ToolLocation.Source {
        if let chosen { return chosen }
        if preferred == .system { return systemAvailable ? .system : .managed }
        return managedAvailable || !installFailed || !systemAvailable ? .managed : .system
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

    /// `deno 2.9.6 (stable, release, aarch64-apple-darwin)` -> `2.9.6`.
    public static func deno(fromFirstLine output: String) -> String? {
        guard let line = output.split(whereSeparator: \.isNewline).first else { return nil }
        let words = line.split(separator: " ")
        return words.count >= 2 && words[0] == "deno" ? String(words[1]) : nil
    }

    /// The build folder of a martin-riedl snapshot link,
    /// `1789407207_N-126556-g639ee84952` -> `N-126556`.
    public static func ffmpegSnapshot(_ build: String) -> String {
        let name = build.split(separator: "_", maxSplits: 1).last.map(String.init) ?? build
        return name.components(separatedBy: "-g").first ?? name
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

/// - yt-dlp: `yt-dlp_macos.zip` (onedir build, starts much faster than the
///   onefile `yt-dlp_macos`) from a GitHub release, verified against that
///   release's `SHA2-256SUMS`, unpacked into `<container>/tools/yt-dlp/`.
/// - ffmpeg: a static build for the running architecture from
///   ffmpeg.martin-riedl.de, when set to Downloady's copy,
///   verified against its published `.sha256`, at `<container>/tools/ffmpeg`.
/// - Deno: the release zip for the running architecture from GitHub, when set
///   to Downloady's copy, verified against its `.sha256sum`, at
///   `<container>/tools/deno`.
@MainActor
public final class ToolManager {
    public struct Configuration: Sendable {
        /// `/latest` redirects to `/tag/<version>`.
        public var ytDlpLatestRelease = URL(string: "https://github.com/yt-dlp/yt-dlp/releases/latest")!
        public var ytDlpDownloadBase = URL(string: "https://github.com/yt-dlp/yt-dlp/releases/download/")!
        public var ffmpegArchive: URL
        public var denoLatestRelease = URL(string: "https://github.com/denoland/deno/releases/latest")!
        public var denoDownloadBase = URL(string: "https://github.com/denoland/deno/releases/download/")!
        public var denoArchiveName: String
        /// `<base>/<formula>.json`, whose `versions.stable` is Homebrew's release.
        public var homebrewFormulaAPI = URL(string: "https://formulae.brew.sh/api/formula/")!
        public var versionTimeout: TimeInterval = 30

        public init() {
            #if arch(arm64)
            let arch = "arm64"
            denoArchiveName = "deno-aarch64-apple-darwin.zip"
            #else
            let arch = "amd64"
            denoArchiveName = "deno-x86_64-apple-darwin.zip"
            #endif
            ffmpegArchive = URL(string: "https://ffmpeg.martin-riedl.de/redirect/latest/macos/\(arch)/snapshot/ffmpeg.zip")!
        }
    }

    static let ytDlpArchiveName = "yt-dlp_macos.zip"
    static let ytDlpExecutableName = "yt-dlp_macos"
    static let ytDlpSumsName = "SHA2-256SUMS"

    private let containerDirectory: URL
    private let configuration: Configuration
    private let fetcher: ToolFetching
    private let choices: @MainActor () -> ToolChoices
    private let networkGranted: @MainActor () -> Bool
    private let log: @MainActor (String) -> Void
    private let fileManager = FileManager.default
    /// Why each tool the last `installMissing` tried failed. A tool it
    /// installed, or did not try, is absent.
    public private(set) var installErrors: [ToolLocation.Tool: String] = [:]

    public init(
        containerDirectory: URL,
        configuration: Configuration = Configuration(),
        fetcher: ToolFetching? = nil,
        choices: @escaping @MainActor () -> ToolChoices = { ToolChoices() },
        networkGranted: @escaping @MainActor () -> Bool = { true },
        log: @escaping @MainActor (String) -> Void
    ) {
        self.containerDirectory = containerDirectory
        self.configuration = configuration
        self.fetcher = fetcher ?? URLSessionToolFetcher()
        self.choices = choices
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
    var managedDeno: URL { toolsDirectory.appendingPathComponent("deno") }
    /// The snapshot build Downloady's ffmpeg came from: the binary reports
    /// only its branch (`8.0.git`), so updates compare this instead.
    var managedFFmpegBuild: URL { toolsDirectory.appendingPathComponent("ffmpeg.build") }

    // MARK: Resolve

    private func candidates(for tool: ToolLocation.Tool) -> [String] {
        ToolLookup.systemCandidates(
            named: tool.executableName,
            pathVariable: ProcessInfo.processInfo.environment["PATH"]
        )
    }

    private func managedURL(for tool: ToolLocation.Tool) -> URL {
        switch tool {
        case .ytDlp: managedYtDlp
        case .ffmpeg: managedFFmpeg
        case .deno: managedDeno
        }
    }

    /// The source `tool` comes from right now, the default resolved.
    func source(for tool: ToolLocation.Tool, in choices: ToolChoices) -> ToolLocation.Source {
        ToolLookup.effectiveSource(
            choices.source(for: tool),
            preferred: tool.preferredSource,
            systemAvailable: systemCopy(of: tool) != nil,
            managedAvailable: Self.isExecutableFile(managedURL(for: tool).path),
            installFailed: choices.failedInstalls.contains(tool)
        )
    }

    /// The source `tool` comes from with the current choices, the default
    /// and its fallback resolved. File checks only.
    public func effectiveSource(of tool: ToolLocation.Tool) -> ToolLocation.Source {
        source(for: tool, in: choices())
    }

    /// Where `tool` is, from the source the user picked, without a version.
    func locate(_ tool: ToolLocation.Tool, in choices: ToolChoices) -> ToolLocation? {
        let source = source(for: tool, in: choices)
        let url = ToolLookup.locate(
            source: source,
            custom: choices.path(for: tool),
            systemCandidates: candidates(for: tool),
            managed: managedURL(for: tool),
            isExecutable: Self.isExecutableFile
        )
        return url.map { ToolLocation(url: $0, source: source, version: nil) }
    }

    /// The copy of `tool` installed on the Mac, if any. File checks only.
    public func systemCopy(of tool: ToolLocation.Tool) -> URL? {
        ToolLookup.systemCopy(in: candidates(for: tool), excluding: managedURL(for: tool), isExecutable: Self.isExecutableFile)
    }

    /// The tools set to Downloady's copy whose copy is not there yet.
    public func missingManagedTools() -> Set<ToolLocation.Tool> {
        let choices = choices()
        return Set(ToolLocation.Tool.allCases.filter {
            source(for: $0, in: choices) == .managed && locate($0, in: choices) == nil
        })
    }

    /// Current state, without touching the network.
    public func resolve() async -> ToolStatus {
        let choices = choices()
        guard let ytDlp = locate(.ytDlp, in: choices) else { return .missing }

        async let ytDlpOutput = ToolProcess.run(ytDlp.url, ["--version"], timeout: configuration.versionTimeout)
        async let ffmpeg = resolveHelper(.ffmpeg)
        async let deno = resolveHelper(.deno)
        let ytDlpResult = await ytDlpOutput

        let ytDlpVersion = ytDlpResult.flatMap { $0.status == 0 ? ToolVersion.ytDlp(from: $0.output) : nil }
        if ytDlpVersion == nil { log("yt-dlp at \(ytDlp.url.path) did not report a version") }

        return await .ready(
            ytDlp: ToolLocation(url: ytDlp.url, source: ytDlp.source, version: ytDlpVersion),
            ffmpeg: ffmpeg,
            deno: deno
        )
    }

    /// ffmpeg or Deno with its version, looked up on its own so a missing
    /// yt-dlp does not hide it.
    public func resolveHelper(_ tool: ToolLocation.Tool) async -> ToolLocation? {
        guard let helper = locate(tool, in: choices()) else { return nil }
        let flag = tool == .ffmpeg ? "-version" : "--version"
        let result = await ToolProcess.run(helper.url, [flag], timeout: configuration.versionTimeout)
        let output = result?.output ?? ""
        let version = tool == .ffmpeg ? ToolVersion.ffmpeg(fromFirstLine: output) : ToolVersion.deno(fromFirstLine: output)
        return ToolLocation(url: helper.url, source: helper.source, version: version)
    }

    nonisolated static func isExecutableFile(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            return false
        }
        return FileManager.default.isExecutableFile(atPath: path)
    }

    // MARK: Install

    /// Downloads the tools set to Downloady's copy that are missing,
    /// verifying checksums, and reports progress through `progress`.
    public func installMissing(progress: @escaping @MainActor (Double) -> Void) async throws -> ToolStatus {
        guard networkGranted() else { throw ToolError.notPermitted }
        // Declaration order: yt-dlp first, it is the one downloads wait for.
        let missing = ToolLocation.Tool.allCases.filter(missingManagedTools().contains)
        // ponytail: equal progress shares; the three archives are all 30-40 MB.
        let share = 1 / Double(max(missing.count, 1))
        var failures: [ToolLocation.Tool: Error] = [:]
        installErrors = [:]
        progress(0)
        // Each tool on its own: one failing never stops the others.
        for (index, tool) in missing.enumerated() {
            let start = Double(index) * share
            let report: @MainActor (Double) -> Void = { progress(start + $0 * share) }
            do {
                switch tool {
                case .ytDlp: try await installYtDlp(tag: try await latestYtDlpTag(), progress: report)
                case .ffmpeg: try await installFFmpeg(progress: report)
                case .deno: try await installDeno(progress: report)
                }
            } catch let error where !(error is CancellationError) {
                log("\(tool.name) install failed: \(error.localizedDescription)")
                failures[tool] = error
                installErrors[tool] = error.localizedDescription
            }
            progress(start + share)
            try Task.checkCancellation()
        }
        // yt-dlp is what downloads need; otherwise, nothing installed at all
        // says why rather than a quiet "not found".
        if let error = failures[.ytDlp] { throw error }
        if let first = missing.first.flatMap({ failures[$0] }), failures.count == missing.count { throw first }
        progress(1)
        return await resolve()
    }

    /// A newer release of `tool` than the copy in use, wherever that copy
    /// comes from, or `nil` when it is current. Throws when it cannot tell
    /// (no copy, no version, nothing to compare with). Installs nothing.
    public func availableUpdate(for tool: ToolLocation.Tool) async throws -> ToolUpdate? {
        guard networkGranted() else { throw ToolError.notPermitted }
        let location = tool == .ytDlp ? await resolve().ytDlp : await resolveHelper(tool)
        guard let location else { throw ToolError.nothingToCompare(tool.name) }

        if location.source == .managed {
            if tool == .ffmpeg {
                let build = try await fetcher.resolveRedirect(configuration.ffmpegArchive)
                    .deletingLastPathComponent().lastPathComponent
                let installed = try? String(contentsOf: managedFFmpegBuild, encoding: .utf8)
                return build == installed ? nil : ToolUpdate(version: ToolVersion.ffmpegSnapshot(build), command: nil)
            }
            // No version (a broken copy) counts as out of date: reinstalling fixes it.
            let latest = try await latestRelease(of: tool)
            return ToolVersion.isNewer(latest, than: location.version) ? ToolUpdate(version: latest, command: nil) : nil
        }

        // A copy on the Mac, whatever the picker says: compare it with what
        // its installer would fetch.
        guard let installed = location.version else { throw ToolError.nothingToCompare(tool.name) }
        let origin = ToolOrigin.detect(path: location.url.path, resolved: location.url.resolvingSymlinksInPath().path)
        let latest: String
        if origin == .homebrew {
            latest = try await homebrewVersion(of: tool)
        } else if tool != .ffmpeg {
            latest = try await latestRelease(of: tool)
        } else {
            // ponytail: no numbered release to compare a non-Homebrew ffmpeg with; add ffmpeg.org's if asked.
            throw ToolError.nothingToCompare(tool.name)
        }
        guard ToolVersion.isNewer(latest, than: installed) else { return nil }
        return ToolUpdate(version: latest, command: origin.upgradeCommand(for: tool))
    }

    /// Re-downloads Downloady's copy of `tool`. Never touches a copy on the
    /// Mac: those update with the command `availableUpdate` gives.
    public func update(_ tool: ToolLocation.Tool) async throws -> ToolStatus {
        guard networkGranted() else { throw ToolError.notPermitted }
        guard source(for: tool, in: choices()) == .managed else {
            log("\(tool.name) is not Downloady's copy; not updating it")
            return await resolve()
        }
        switch tool {
        case .ytDlp: try await installYtDlp(tag: latestYtDlpTag()) { _ in }
        case .ffmpeg: try await installFFmpeg { _ in }
        case .deno: try await installDeno { _ in }
        }
        return await resolve()
    }

    /// The latest GitHub release of yt-dlp or Deno, `v` dropped.
    func latestRelease(of tool: ToolLocation.Tool) async throws -> String {
        let tag = try await latestTag(at: tool == .deno ? configuration.denoLatestRelease : configuration.ytDlpLatestRelease)
        return tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
    }

    /// Homebrew's current release of `tool`'s formula.
    func homebrewVersion(of tool: ToolLocation.Tool) async throws -> String {
        struct Formula: Decodable {
            struct Versions: Decodable { let stable: String }
            let versions: Versions
        }
        let staging = try makeStaging()
        defer { try? fileManager.removeItem(at: staging) }
        let url = configuration.homebrewFormulaAPI.appendingPathComponent("\(tool.executableName).json")
        let fetched = try await fetcher.fetch(url, into: staging) { _ in }
        return try JSONDecoder().decode(Formula.self, from: Data(contentsOf: fetched.file)).versions.stable
    }

    func latestYtDlpTag() async throws -> String {
        try await latestTag(at: configuration.ytDlpLatestRelease)
    }

    /// The tag a GitHub `/releases/latest` redirects to.
    func latestTag(at latest: URL) async throws -> String {
        let final = try await fetcher.resolveRedirect(latest)
        let tag = final.lastPathComponent
        guard final.pathComponents.contains("tag"), !tag.isEmpty else { throw ToolError.releaseUnknown }
        return tag
    }

    /// Downloads, verifies and swaps in the onedir build of `tag`.
    func installYtDlp(tag: String, progress: @escaping @MainActor (Double) -> Void) async throws {
        let release = configuration.ytDlpDownloadBase.appendingPathComponent(tag, isDirectory: true)
        try await install(
            release.appendingPathComponent(Self.ytDlpArchiveName),
            sums: { _ in release.appendingPathComponent(Self.ytDlpSumsName) },
            name: { _ in Self.ytDlpArchiveName },
            executable: Self.ytDlpExecutableName,
            swapsFolder: true,
            at: ytDlpDirectory,
            progress: progress
        )
        progress(1)
        log("installed yt-dlp \(tag)")
    }

    /// Downloads, verifies and installs a static ffmpeg.
    func installFFmpeg(progress: @escaping @MainActor (Double) -> Void) async throws {
        let archive = try await install(
            configuration.ffmpegArchive,
            // Checksum of the exact build the redirect landed on.
            sums: { URL(string: $0.finalURL.absoluteString + ".sha256")! },
            name: { $0.finalURL.lastPathComponent },
            executable: "ffmpeg",
            at: managedFFmpeg,
            progress: progress
        )
        try? archive.finalURL.deletingLastPathComponent().lastPathComponent
            .write(to: managedFFmpegBuild, atomically: true, encoding: .utf8)
        progress(1)
        log("installed ffmpeg")
    }

    /// Downloads, verifies and installs Deno's latest release.
    func installDeno(progress: @escaping @MainActor (Double) -> Void) async throws {
        let tag = try await latestTag(at: configuration.denoLatestRelease)
        let name = configuration.denoArchiveName
        let release = configuration.denoDownloadBase.appendingPathComponent(tag, isDirectory: true)
        try await install(
            release.appendingPathComponent(name),
            sums: { _ in release.appendingPathComponent(name + ".sha256sum") },
            name: { _ in name },
            executable: "deno",
            at: managedDeno,
            progress: progress
        )
        progress(1)
        log("installed Deno \(tag)")
    }

    /// Fetches `url` and the checksum list `sums` names for it, verifies the
    /// archive against its entry `name`, unzips it, and swaps the unpacked
    /// `executable` (or, with `swapsFolder`, the whole unpacked folder) in at
    /// `destination`. Returns the fetched archive.
    @discardableResult
    private func install(
        _ url: URL,
        sums: (FetchedFile) -> URL,
        name: (FetchedFile) -> String,
        executable: String,
        swapsFolder: Bool = false,
        at destination: URL,
        progress: @escaping @MainActor (Double) -> Void
    ) async throws -> FetchedFile {
        let staging = try makeStaging()
        defer { try? fileManager.removeItem(at: staging) }

        let report = Self.sendable(progress, scale: 0.95)
        let archive = try await fetcher.fetch(url, into: staging, progress: report)
        let sumsFile = try await fetcher.fetch(sums(archive), into: staging) { _ in }
        try Task.checkCancellation()

        let name = name(archive)
        try await Self.verify(archive.file, named: name, against: sumsFile.file)
        let unpacked = staging.appendingPathComponent("unpacked", isDirectory: true)
        try await Self.unzip(archive.file, into: unpacked, name: name)
        let binary = unpacked.appendingPathComponent(executable)
        guard fileManager.fileExists(atPath: binary.path) else { throw ToolError.unpackFailed(name) }
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        try Task.checkCancellation()

        try swapIn(swapsFolder ? unpacked : binary, at: destination)
        await Self.clearQuarantine(destination)
        return archive
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

    /// One main-actor hop per whole percent, not one per downloaded chunk:
    /// URLSession reports every write, thousands for a 40 MB archive.
    private static func sendable(_ progress: @escaping @MainActor (Double) -> Void, scale: Double) -> @Sendable (Double) -> Void {
        let lastPercent = OSAllocatedUnfairLock(initialState: -1)
        return { value in
            let percent = Int(value * scale * 100)
            let changed = lastPercent.withLock { last in
                defer { last = percent }
                return last != percent
            }
            guard changed else { return }
            Task { @MainActor in progress(value * scale) }
        }
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
