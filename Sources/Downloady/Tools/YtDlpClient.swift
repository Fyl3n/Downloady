//
//  YtDlpClient.swift
//  Downloady
//
//  Runs yt-dlp as a child process. Never blocks the main actor: the droplet
//  runs inside Droppy's process, on Droppy's main thread.
//

import Darwin
import Foundation

/// What a running download reports.
public enum DownloadEvent: Equatable, Sendable {
    /// 0...1, with speed and ETA as yt-dlp formats them.
    case progress(fraction: Double, speed: String?, eta: String?)
    /// A file yt-dlp is about to write. Cancelling leaves a `.part` beside
    /// it, which is what makes the cleanup possible.
    case destination(URL)
    /// yt-dlp moved on to merging, extracting or remuxing.
    case postProcessing
    /// The final file.
    case finished(URL)
}

public enum YtDlpError: Error, Equatable, Sendable, LocalizedError {
    case toolsNotReady
    case unsupportedURL
    case processFailed(exitCode: Int32, message: String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .toolsNotReady: "yt-dlp is not installed yet"
        case .unsupportedURL: "This page has nothing yt-dlp can download"
        case .processFailed(let code, let message):
            message.isEmpty ? "yt-dlp stopped with exit code \(code)" : message
        case .cancelled: "Cancelled"
        }
    }
}

@MainActor
public protocol YtDlpRunning: AnyObject {
    /// `yt-dlp -J --no-playlist --skip-download <url>`, decoded.
    func fetchInfo(for url: URL) async throws -> MediaInfo

    /// Whether one of yt-dlp's dedicated extractors claims `url`, without
    /// touching the network (`YtDlpCommand.supportProbe`). About half a
    /// second. `false` when yt-dlp is not ready or the task is cancelled.
    func isSupported(_ url: URL) async -> Bool

    /// `yt-dlp --list-extractors`, offline. `nil` when yt-dlp is not ready
    /// or fails.
    func listExtractors() async -> String?

    /// Downloads `url` into `folder`. `subtitleLanguage` is the track
    /// yt-dlp is asked for when the options want subtitles. Cancelling the
    /// consuming task terminates the process.
    func download(
        _ url: URL,
        options: DownloadOptions,
        into folder: URL,
        subtitleLanguage: String
    ) -> AsyncThrowingStream<DownloadEvent, Error>

    /// Terminates every child process. Called from `deactivate()`.
    func cancelAll()
}

public extension YtDlpRunning {
    /// A download with no subtitles to pick a language for.
    func download(
        _ url: URL,
        options: DownloadOptions,
        into folder: URL
    ) -> AsyncThrowingStream<DownloadEvent, Error> {
        download(url, options: options, into: folder, subtitleLanguage: "en")
    }
}

// MARK: - Arguments and output lines

/// The command lines, and what a line of download output means. Pure, so the
/// tests pin it.
public enum YtDlpCommand {
    public static let progressTemplate =
        "download:downloady %(progress._percent_str)s|%(progress._speed_str)s|%(progress._eta_str)s"
    public static let outputTemplate = "%(title).200B [%(id)s].%(ext)s"

    /// The line yt-dlp prints before it writes a stream.
    static let destinationPrefix = "[download] Destination: "

    /// Lines yt-dlp prints when a post-processor starts.
    static let postProcessorPrefixes = ["[Merger]", "[ExtractAudio]", "[VideoRemuxer]"]

    /// Where each post-processor says it writes, after these markers.
    static let postProcessorOutputMarkers = [
        "[Merger] Merging formats into ",
        "[ExtractAudio] Destination: ",
        "; Destination: ",
    ]

    /// The subtitle file yt-dlp is about to write.
    static let subtitlePrefix = "[info] Writing video subtitles to: "

    /// `--ignore-config`: a yt-dlp config file of the user's own (`--quiet`,
    /// `-o`, `--print`…) would change the output this runner reads.
    static func common(ffmpeg: URL?) -> [String] {
        var args = ["--ignore-config", "--no-playlist", "--newline", "--no-colors"]
        if let ffmpeg {
            args += ["--ffmpeg-location", ffmpeg.path]
        }
        return args
    }

    public static func fetchInfo(_ url: URL, ffmpeg: URL?) -> [String] {
        common(ffmpeg: ffmpeg) + ["-J", "--skip-download", "--", url.absoluteString]
    }

    /// The compatibility probe: every extractor except the generic one, and
    /// every request sent to a local port that refuses it. A URL that an
    /// extractor claims fails on its first request (`ERROR: [youtube] …`); a
    /// URL none claims fails before any ("No suitable extractor"). Either way
    /// nothing leaves the Mac.
    public static func supportProbe(_ url: URL) -> [String] {
        [
            "--ignore-config", "--no-playlist", "--no-colors", "--no-cache-dir",
            "--ies", "default,-generic",
            "--proxy", "http://127.0.0.1:9",
            "--socket-timeout", "2", "--retries", "0", "--extractor-retries", "0",
            "-J", "--skip-download",
            "--", url.absoluteString,
        ]
    }

    /// What the probe's exit says. Only an explicit "no extractor" is a no:
    /// a yt-dlp too old for `--ies` falls back to the full lookup.
    static func probeSaysSupported(status: Int32, stderr: String) -> Bool {
        guard status != 0 else { return true }
        return !stderr.contains("No suitable extractor") && !isUnsupported(stderr: stderr)
    }

    public static func download(
        _ url: URL,
        options: DownloadOptions,
        folder: URL,
        ffmpeg: URL?,
        subtitleLanguage: String = "en"
    ) -> [String] {
        common(ffmpeg: ffmpeg)
            + options.ytDlpArguments
            + options.subtitleArguments(language: subtitleLanguage)
            + [
                "-o", folder.appendingPathComponent(outputTemplate).path,
                "--progress-template", progressTemplate,
                "--print", "after_move:filepath",
                // `--print` implies `--quiet`, which would hide the progress
                // lines and the post-processor lines this runner reads.
                "--no-quiet",
                "--", url.absoluteString,
            ]
    }

    /// What one stdout line of a download says, if anything. A bare absolute
    /// path is the `--print after_move:filepath` line.
    public static func event(forLine line: String) -> DownloadEvent? {
        if let progress = ProgressParser.parse(line) { return progress }
        if line.hasPrefix(destinationPrefix) {
            let path = line.dropFirst(destinationPrefix.count).trimmingCharacters(in: .whitespaces)
            return path.hasPrefix("/") ? .destination(URL(fileURLWithPath: path)) : nil
        }
        if postProcessorPrefixes.contains(where: line.hasPrefix) { return .postProcessing }
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("/") {
            return .finished(URL(fileURLWithPath: trimmed))
        }
        return nil
    }

    /// The file a line says yt-dlp is about to write, for the cleanup of a
    /// stopped download: a stream, a subtitle, or a post-processor's output.
    /// `nil` for any other line, and for a path that is not absolute.
    static func writtenFile(forLine line: String) -> URL? {
        var rest: Substring?
        if line.hasPrefix(destinationPrefix) {
            rest = line.dropFirst(destinationPrefix.count)
        } else if line.hasPrefix(subtitlePrefix) {
            rest = line.dropFirst(subtitlePrefix.count)
        } else if line.hasPrefix("[") {
            for marker in postProcessorOutputMarkers {
                if let range = line.range(of: marker) {
                    rest = line[range.upperBound...]
                    break
                }
            }
        }
        guard var path = rest?.trimmingCharacters(in: .whitespaces) else { return nil }
        if path.count >= 2, path.hasPrefix("\""), path.hasSuffix("\"") {
            path = String(path.dropFirst().dropLast())
        }
        return path.hasPrefix("/") ? URL(fileURLWithPath: path) : nil
    }

    /// What a download that stopped before the end leaves behind: every file
    /// yt-dlp announced (its complete streams too, which only a merge that
    /// never happened would have consumed), their `.part` and resume index,
    /// and the `.temp` file ffmpeg writes a merge or remux into.
    ///
    /// Only paths yt-dlp announced in this run, never a guess: yt-dlp skips
    /// a file already on disk without announcing it, so nothing the user had
    /// before can be on this list.
    public static func leftovers(of announced: [URL]) -> [URL] {
        var files: [URL] = []
        for file in announced {
            files += [file, file.appendingPathExtension("part"), file.appendingPathExtension("ytdl")]
            let ext = file.pathExtension
            if !ext.isEmpty {
                files.append(file.deletingPathExtension().appendingPathExtension("temp").appendingPathExtension(ext))
            }
        }
        var seen = Set<URL>()
        return files.filter { seen.insert($0).inserted }
    }

    /// The line worth showing from yt-dlp's stderr: the last `ERROR:` line,
    /// else the last non-empty one.
    public static func errorMessage(fromStderr text: String) -> String {
        let lines = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let line = lines.last(where: { $0.hasPrefix("ERROR:") }) ?? lines.last ?? ""
        if line.hasPrefix("ERROR:") {
            return line.dropFirst("ERROR:".count).trimmingCharacters(in: .whitespaces)
        }
        return line
    }

    static func isUnsupported(stderr: String) -> Bool {
        stderr.contains("Unsupported URL")
    }
}

// MARK: - Child process

/// One running tool, yt-dlp or ffmpeg. Its pipes are read on background
/// threads; it can be terminated from any thread. Never started on the main
/// actor: the droplet runs on Droppy's main thread.
final class ChildProcess: @unchecked Sendable {
    struct Exit: Sendable {
        let status: Int32
        let reason: Process.TerminationReason
        let stderr: String
    }

    private let process = Process()
    private let lock = NSLock()
    private var terminationRequested = false

    init(executable: URL, arguments: [String]) {
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        var environment = ProcessInfo.processInfo.environment
        environment["PYTHONUNBUFFERED"] = "1"
        environment["PYTHONIOENCODING"] = "utf-8"
        process.environment = environment
    }

    var wasTerminated: Bool {
        lock.lock()
        defer { lock.unlock() }
        return terminationRequested
    }

    /// Starts the process on a background thread. `onLine` receives each
    /// stdout line (without its newline) when `collectStdout` is false;
    /// otherwise stdout is returned whole in `completion`.
    func start(
        collectStdout: Bool,
        onLine: @escaping @Sendable (String) -> Void,
        completion: @escaping @Sendable (Result<(Exit, Data), Error>) -> Void
    ) {
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            do {
                try process.run()
            } catch {
                completion(.failure(error))
                return
            }
            if wasTerminated { signalTree(SIGKILL) }

            let group = DispatchGroup()
            let errorBox = DataBox()
            group.enter()
            DispatchQueue.global(qos: .utility).async {
                errorBox.data = stderr.fileHandleForReading.readDataToEndOfFile()
                group.leave()
            }

            var collected = Data()
            if collectStdout {
                collected = stdout.fileHandleForReading.readDataToEndOfFile()
            } else {
                var buffer = Data()
                let handle = stdout.fileHandleForReading
                while true {
                    let chunk = handle.availableData
                    if chunk.isEmpty { break }
                    buffer.append(chunk)
                    while let index = buffer.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
                        let line = String(decoding: buffer[buffer.startIndex..<index], as: UTF8.self)
                        buffer.removeSubrange(buffer.startIndex...index)
                        if !line.isEmpty { onLine(line) }
                    }
                }
                if !buffer.isEmpty { onLine(String(decoding: buffer, as: UTF8.self)) }
            }
            process.waitUntilExit()
            group.wait()
            let exit = Exit(
                status: process.terminationStatus,
                reason: process.terminationReason,
                stderr: String(decoding: errorBox.data, as: UTF8.self)
            )
            completion(.success((exit, collected)))
        }
    }

    /// SIGTERM to yt-dlp and whatever it spawned (ffmpeg), then SIGKILL two
    /// seconds later for anything still alive.
    func terminate() {
        lock.lock()
        let first = !terminationRequested
        terminationRequested = true
        lock.unlock()
        guard first, process.processIdentifier > 0 else { return }
        signalTree(SIGTERM)
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) { [self] in
            if process.isRunning { signalTree(SIGKILL) }
        }
    }

    private func signalTree(_ signal: Int32) {
        let root = process.processIdentifier
        guard root > 0 else { return }
        // Children first, so ffmpeg does not outlive yt-dlp as an orphan.
        for pid in Self.descendants(of: root).reversed() {
            kill(pid, signal)
        }
        kill(root, signal)
    }

    static func descendants(of pid: pid_t) -> [pid_t] {
        var result: [pid_t] = []
        var queue = [pid]
        while let current = queue.popLast() {
            let count = proc_listchildpids(current, nil, 0)
            guard count > 0 else { continue }
            var children = [pid_t](repeating: 0, count: Int(count) * 2)
            let filled = children.withUnsafeMutableBufferPointer { buffer in
                proc_listchildpids(current, buffer.baseAddress, Int32(buffer.count * MemoryLayout<pid_t>.size))
            }
            let found = children.prefix(Int(max(filled, 0))).filter { $0 > 0 }
            result += found
            queue += found
        }
        return result
    }

    private final class DataBox: @unchecked Sendable {
        var data = Data()
    }
}

// MARK: - Client

/// The real implementation.
///
/// Every process is kept in `running` so `cancelAll()` can terminate it. Pipes
/// are read off the main actor; events are delivered through the stream,
/// which the model consumes on the main actor.
@MainActor
public final class YtDlpClient: YtDlpRunning {
    private let tools: @MainActor () -> ToolStatus
    private let log: @MainActor (String) -> Void
    private var running: [ObjectIdentifier: ChildProcess] = [:]

    public init(tools: @escaping @MainActor () -> ToolStatus, log: @escaping @MainActor (String) -> Void) {
        self.tools = tools
        self.log = log
    }

    public func fetchInfo(for url: URL) async throws -> MediaInfo {
        let (exit, data) = try await runToEnd(YtDlpCommand.fetchInfo(url, ffmpeg: tools().ffmpeg?.url))
        guard exit.status == 0 else {
            if YtDlpCommand.isUnsupported(stderr: exit.stderr) { throw YtDlpError.unsupportedURL }
            let message = YtDlpCommand.errorMessage(fromStderr: exit.stderr)
            log("yt-dlp -J failed (\(exit.status)): \(message)")
            throw YtDlpError.processFailed(exitCode: exit.status, message: message)
        }
        let info = try await Self.decode(data)
        if !info.isDedicatedExtractor, info.formats?.isEmpty ?? true {
            throw YtDlpError.unsupportedURL
        }
        return info
    }

    public func isSupported(_ url: URL) async -> Bool {
        guard let exit = try? await runToEnd(YtDlpCommand.supportProbe(url)).0 else { return false }
        let supported = YtDlpCommand.probeSaysSupported(status: exit.status, stderr: exit.stderr)
        log("\(url.host() ?? url.absoluteString) is \(supported ? "" : "not ")supported by yt-dlp")
        return supported
    }

    public func listExtractors() async -> String? {
        guard let result = try? await runToEnd(["--ignore-config", "--list-extractors"]), result.0.status == 0 else { return nil }
        return String(decoding: result.1, as: UTF8.self)
    }

    /// Runs yt-dlp with `arguments` and collects stdout. Cancelling the task
    /// terminates the process.
    private func runToEnd(_ arguments: [String]) async throws -> (ChildProcess.Exit, Data) {
        guard let ytDlp = tools().ytDlp else { throw YtDlpError.toolsNotReady }
        let child = ChildProcess(executable: ytDlp.url, arguments: arguments)
        let key = track(child)
        defer { running[key] = nil }

        let result: (ChildProcess.Exit, Data) = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                child.start(collectStdout: true, onLine: { _ in }) { continuation.resume(with: $0) }
            }
        } onCancel: {
            child.terminate()
        }
        if Task.isCancelled || child.wasTerminated { throw YtDlpError.cancelled }
        return result
    }

    /// Decoding a large `-J` document is not free; keep it off the main actor.
    nonisolated private static func decode(_ data: Data) async throws -> MediaInfo {
        try JSONDecoder().decode(MediaInfo.self, from: data)
    }

    public func download(
        _ url: URL,
        options: DownloadOptions,
        into folder: URL,
        subtitleLanguage: String
    ) -> AsyncThrowingStream<DownloadEvent, Error> {
        guard let ytDlp = tools().ytDlp else {
            return AsyncThrowingStream { $0.finish(throwing: YtDlpError.toolsNotReady) }
        }
        let arguments = YtDlpCommand.download(
            url,
            options: options,
            folder: folder,
            ffmpeg: tools().ffmpeg?.url,
            subtitleLanguage: subtitleLanguage
        )
        let child = ChildProcess(executable: ytDlp.url, arguments: arguments)
        let key = track(child)
        let log = self.log

        return AsyncThrowingStream { continuation in
            let lastFile = FileBox()
            let announced = AnnouncedFiles()
            continuation.onTermination = { [weak self] termination in
                if case .cancelled = termination { child.terminate() }
                Task { @MainActor in self?.running[key] = nil }
            }
            child.start(collectStdout: false, onLine: { line in
                if let file = YtDlpCommand.writtenFile(forLine: line) { announced.append(file) }
                guard let event = YtDlpCommand.event(forLine: line) else { return }
                if case .finished(let file) = event {
                    // Held back until the process exits cleanly.
                    lastFile.url = file
                } else {
                    continuation.yield(event)
                }
            }, completion: { result in
                // The process has exited (ffmpeg with it), so nothing can
                // write a file back after it is removed.
                if case .success(let (exit, _)) = result, !child.wasTerminated, exit.status == 0 {
                    // Finished: yt-dlp removed its own intermediates.
                } else {
                    Self.removeLeftovers(of: announced.files)
                }
                switch result {
                case .failure(let error):
                    continuation.finish(throwing: error)
                case .success((let exit, _)):
                    if child.wasTerminated {
                        continuation.finish(throwing: YtDlpError.cancelled)
                    } else if exit.status != 0 {
                        let message = YtDlpCommand.errorMessage(fromStderr: exit.stderr)
                        Task { @MainActor in log("yt-dlp download failed (\(exit.status)): \(message)") }
                        continuation.finish(throwing: YtDlpError.processFailed(exitCode: exit.status, message: message))
                    } else if let file = lastFile.url {
                        continuation.yield(.finished(file))
                        continuation.finish()
                    } else {
                        continuation.finish(throwing: YtDlpError.processFailed(
                            exitCode: 0,
                            message: "yt-dlp finished without reporting a file"
                        ))
                    }
                }
            })
        }
    }

    /// Deletes what a stopped or failed download left in the folder.
    nonisolated static func removeLeftovers(of announced: [URL]) {
        for file in YtDlpCommand.leftovers(of: announced) {
            try? FileManager.default.removeItem(at: file)
        }
    }

    public func cancelAll() {
        for child in running.values { child.terminate() }
        running.removeAll()
    }

    private func track(_ child: ChildProcess) -> ObjectIdentifier {
        let key = ObjectIdentifier(child)
        running[key] = child
        return key
    }

    private final class FileBox: @unchecked Sendable {
        var url: URL?
    }

    /// The files yt-dlp announced, appended from the pipe's reading thread.
    private final class AnnouncedFiles: @unchecked Sendable {
        private let lock = NSLock()
        private var urls: [URL] = []

        func append(_ url: URL) { lock.withLock { urls.append(url) } }
        var files: [URL] { lock.withLock { urls } }
    }
}

// MARK: - Progress

/// Turns one `--progress-template` line into an event.
///
/// Input looks like `downloady  42.3%|  3.10MiB/s|00:12`; any other line gives
/// `nil`. yt-dlp writes `NA` (or `Unknown`) for a field it does not know.
public enum ProgressParser {
    public static let prefix = "downloady "

    public static func parse(_ line: String) -> DownloadEvent? {
        guard line.hasPrefix(prefix) else { return nil }
        let fields = line.dropFirst(prefix.count)
            .split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard fields.count == 3 else { return nil }
        let percentText = fields[0].hasSuffix("%") ? String(fields[0].dropLast()) : fields[0]
        guard let percent = Double(percentText.trimmingCharacters(in: .whitespaces)) else { return nil }
        return .progress(
            fraction: min(max(percent / 100, 0), 1),
            speed: known(fields[1]),
            eta: known(fields[2])
        )
    }

    private static func known(_ field: String) -> String? {
        let unknown: Set<String> = ["", "NA", "N/A", "Unknown", "Unknown speed", "Unknown ETA"]
        return unknown.contains(field) ? nil : field
    }
}
