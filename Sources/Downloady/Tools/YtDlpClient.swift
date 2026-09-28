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

// MARK: - Arguments and output lines

/// The command lines, and what a line of download output means. Pure, so the
/// tests pin it.
public enum YtDlpCommand {
    public static let progressTemplate =
        "download:downloady %(progress._percent_str)s|%(progress._speed_str)s|%(progress._eta_str)s"
            + "|%(progress.fragment_index)s|%(progress.fragment_count)s"
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
    /// `--js-runtimes`: yt-dlp only looks for Deno on `PATH`, which is short
    /// when Droppy starts from Finder; without it YouTube loses formats.
    static func common(ffmpeg: URL?, deno: URL? = nil) -> [String] {
        var args = ["--ignore-config", "--no-playlist", "--newline", "--no-colors"]
        if let ffmpeg {
            args += ["--ffmpeg-location", ffmpeg.path]
        }
        if let deno {
            args += ["--js-runtimes", "deno:\(deno.path)"]
        }
        return args
    }

    /// `--flat-playlist`: a Playlist lists its entries without a Lookup of
    /// each, seconds instead of a minute. A single video is unaffected, and
    /// `--no-playlist` keeps `watch?v=X&list=Y` on video X.
    /// `--ignore-no-formats-error`: a broadcast that has not begun has no
    /// formats yet, and yt-dlp refuses it ("This live event will begin in
    /// 10 hours") instead of describing it.
    public static func fetchInfo(_ url: URL, ffmpeg: URL?, deno: URL? = nil) -> [String] {
        common(ffmpeg: ffmpeg, deno: deno)
            + ["-J", "--flat-playlist", "--skip-download", "--ignore-no-formats-error", "--", url.absoluteString]
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
        deno: URL? = nil,
        subtitleLanguage: String = "en",
        recording: Bool = false
    ) -> [String] {
        common(ffmpeg: ffmpeg, deno: deno)
            + options.ytDlpArguments
            + options.subtitleArguments(language: subtitleLanguage)
            + (recording ? recordingArguments : [])
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

    /// A Recording's extra arguments. `--wait-for-video`: a broadcast that is
    /// late is retried every 15 to 60 seconds instead of failing.
    /// `--no-hls-use-mpegts`: yt-dlp has ffmpeg write a live stream as
    /// MPEG-TS, and skips its MP4 fix-up when it merged video and audio, so
    /// the `.mp4` it leaves is one QuickTime refuses. As MP4, ffmpeg writes the
    /// index when Stop tells it to quit.
    static let recordingArguments = ["--wait-for-video", "15-60", "--no-hls-use-mpegts"]

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

    /// Whether a name in `folder` is a fragment of an announced file:
    /// `<announced>.part-Frag<n>`, with or without its own `.part`.
    static func isFragment(of announced: [URL], in folder: URL) -> (String) -> Bool {
        let prefixes = announced
            .filter { $0.deletingLastPathComponent().path == folder.path }
            .map { $0.lastPathComponent + ".part-Frag" }
        return { name in prefixes.contains(where: name.hasPrefix) }
    }

    /// The line worth showing from yt-dlp's stderr: the last `ERROR:` line,
    /// else the last non-empty one, without its `ERROR:` or `WARNING:`.
    public static func errorMessage(fromStderr text: String) -> String {
        let lines = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let line = lines.last(where: { $0.hasPrefix("ERROR:") }) ?? lines.last ?? ""
        for prefix in ["ERROR:", "WARNING:"] where line.hasPrefix(prefix) {
            return line.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
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
    private var interruptRequested = false

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

    /// Whether `interrupt()` stopped it: what it wrote is kept.
    var wasInterrupted: Bool {
        lock.lock()
        defer { lock.unlock() }
        return interruptRequested
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
            // Stopped or cancelled before it ran: it has written nothing.
            if wasTerminated || wasInterrupted { signalTree(SIGKILL) }

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
    /// Does nothing after `interrupt()`: a Recording that is being stopped
    /// is let finish its file.
    func terminate() {
        lock.lock()
        let first = !terminationRequested && !interruptRequested
        if !interruptRequested { terminationRequested = true }
        lock.unlock()
        // Not started yet: `start` kills it once `run()` returns. Exited: its
        // PID may belong to another process by now.
        guard first, process.isRunning else { return }
        signalTree(SIGTERM)
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) { [self] in
            if process.isRunning { signalTree(SIGKILL) }
        }
    }

    /// SIGINT to yt-dlp alone, which is how a Recording is Stopped: yt-dlp
    /// sends ffmpeg `q`, ffmpeg finishes the file, and yt-dlp renames it and
    /// exits 0. SIGTERM to ffmpeg would leave a `.part` instead. SIGKILL to
    /// the tree follows only if it is still running `timeout` later.
    func interrupt(timeout: TimeInterval = 30) {
        lock.lock()
        let first = !terminationRequested && !interruptRequested
        if first { interruptRequested = true }
        lock.unlock()
        guard first, process.isRunning else { return }
        kill(process.processIdentifier, SIGINT)
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) { [self] in
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

/// Every process is kept in `running` so `cancelAll()` can terminate it. Pipes
/// are read off the main actor; events are delivered through the stream,
/// which the model consumes on the main actor.
@MainActor
public final class YtDlpClient {
    private let tools: @MainActor () -> ToolStatus
    private let log: @MainActor (String) -> Void
    private var running: [ObjectIdentifier: ChildProcess] = [:]
    /// The Recordings among them, which Stop interrupts instead.
    private var recordings: Set<ObjectIdentifier> = []

    public init(tools: @escaping @MainActor () -> ToolStatus, log: @escaping @MainActor (String) -> Void) {
        self.tools = tools
        self.log = log
    }

    /// `yt-dlp -J --no-playlist --flat-playlist --skip-download <url>`, decoded.
    public func fetchInfo(for url: URL) async throws -> MediaInfo {
        let (exit, data) = try await runToEnd(YtDlpCommand.fetchInfo(url, ffmpeg: tools().ffmpeg?.url, deno: tools().deno?.url))
        guard exit.status == 0 else {
            if YtDlpCommand.isUnsupported(stderr: exit.stderr) { throw YtDlpError.unsupportedURL }
            let message = YtDlpCommand.errorMessage(fromStderr: exit.stderr)
            log("yt-dlp -J failed (\(exit.status)): \(message)")
            throw YtDlpError.processFailed(exitCode: exit.status, message: message)
        }
        let info = try await Self.decode(data)
        if let reason = info.nestedPlaylistReason {
            throw YtDlpError.processFailed(exitCode: 0, message: reason)
        }
        // A Playlist has no formats of its own; its entries have them. Nor
        // has a broadcast that has not begun.
        if !info.isPlaylist, info.liveStatus != "is_upcoming", info.formats?.isEmpty ?? true {
            guard info.isDedicatedExtractor else { throw YtDlpError.unsupportedURL }
            // `--ignore-no-formats-error` made yt-dlp's reason a warning.
            let message = YtDlpCommand.errorMessage(fromStderr: exit.stderr)
            log("yt-dlp -J found no formats: \(message)")
            throw YtDlpError.processFailed(exitCode: 0, message: message)
        }
        return info
    }

    /// Whether one of yt-dlp's dedicated extractors claims `url`, without
    /// touching the network (`YtDlpCommand.supportProbe`). About half a
    /// second. `false` when yt-dlp is not ready or the task is cancelled.
    public func isSupported(_ url: URL) async -> Bool {
        guard let exit = try? await runToEnd(YtDlpCommand.supportProbe(url)).0 else { return false }
        let supported = YtDlpCommand.probeSaysSupported(status: exit.status, stderr: exit.stderr)
        log("\(url.host() ?? url.absoluteString) is \(supported ? "" : "not ")supported by yt-dlp")
        return supported
    }

    /// `yt-dlp --list-extractors`, offline. `nil` when yt-dlp is not ready
    /// or fails.
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

    /// Downloads `url` into `folder`. `subtitleLanguage` is the track
    /// yt-dlp is asked for when the options want subtitles. Cancelling the
    /// consuming task terminates the process. A `recording` is ended by
    /// `stopRecordings()` instead, which keeps its file.
    public func download(
        _ url: URL,
        options: DownloadOptions,
        into folder: URL,
        subtitleLanguage: String = "en",
        recording: Bool = false
    ) -> AsyncThrowingStream<DownloadEvent, Error> {
        guard let ytDlp = tools().ytDlp else {
            return AsyncThrowingStream { $0.finish(throwing: YtDlpError.toolsNotReady) }
        }
        let arguments = YtDlpCommand.download(
            url,
            options: options,
            folder: folder,
            ffmpeg: tools().ffmpeg?.url,
            deno: tools().deno?.url,
            subtitleLanguage: subtitleLanguage,
            recording: recording
        )
        let child = ChildProcess(executable: ytDlp.url, arguments: arguments)
        let key = track(child)
        if recording { recordings.insert(key) }
        let log = self.log

        return AsyncThrowingStream { continuation in
            let lastFile = FileBox()
            let announced = AnnouncedFiles()
            continuation.onTermination = { [weak self] termination in
                if case .cancelled = termination { child.terminate() }
                Task { @MainActor in
                    self?.running[key] = nil
                    self?.recordings.remove(key)
                }
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
                } else if child.wasInterrupted {
                    // Stopped: what was recorded is kept, even half-written.
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
    /// A fragmented stream also leaves the fragment it was writing,
    /// `<name>.part-Frag<n>.part`, whose number no line announces.
    nonisolated static func removeLeftovers(of announced: [URL]) {
        let fm = FileManager.default
        var files = YtDlpCommand.leftovers(of: announced)
        for folder in Set(announced.map { $0.deletingLastPathComponent() }) {
            let names = (try? fm.contentsOfDirectory(atPath: folder.path)) ?? []
            files += names.filter(YtDlpCommand.isFragment(of: announced, in: folder)).map { folder.appendingPathComponent($0) }
        }
        for file in files {
            try? fm.removeItem(at: file)
        }
    }

    /// Stops every running Recording: see `ChildProcess.interrupt()`. Each
    /// one's stream then ends with its file, the way a finished download's
    /// does. The Recording Lane runs one at a time, so this is Stop.
    public func stopRecordings() {
        for key in recordings { running[key]?.interrupt() }
    }

    /// Terminates every child process but the Recordings being stopped.
    /// Called from `deactivate()`, after `stopRecordings()`.
    public func cancelAll() {
        for child in running.values { child.terminate() }
        running.removeAll()
        recordings.removeAll()
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
/// Input looks like `downloady  42.3%|  3.10MiB/s|00:12|NA|NA`; any other line
/// gives `nil`. yt-dlp writes `NA` (or `Unknown`) for a field it does not know.
///
/// A fragmented stream (HLS, DASH) reports its fragment index and count, and
/// the fraction comes from those: yt-dlp's percentage there is bytes over a
/// total it re-estimates from each fragment's size, so it steps backwards.
public enum ProgressParser {
    public static let prefix = "downloady "

    public static func parse(_ line: String) -> DownloadEvent? {
        guard line.hasPrefix(prefix) else { return nil }
        let fields = line.dropFirst(prefix.count)
            .split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard fields.count == 3 || fields.count == 5 else { return nil }
        let fraction: Double
        if fields.count == 5, let index = Double(fields[3]), let count = Double(fields[4]), count > 0 {
            fraction = index / count
        } else {
            let percentText = fields[0].hasSuffix("%") ? String(fields[0].dropLast()) : fields[0]
            guard let percent = Double(percentText.trimmingCharacters(in: .whitespaces)) else { return nil }
            fraction = percent / 100
        }
        return .progress(
            fraction: min(max(fraction, 0), 1),
            speed: known(fields[1]),
            eta: known(fields[2])
        )
    }

    private static func known(_ field: String) -> String? {
        let unknown: Set<String> = ["", "NA", "N/A", "Unknown", "Unknown speed", "Unknown B/s", "Unknown ETA"]
        return unknown.contains(field) ? nil : field
    }
}
