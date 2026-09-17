import Foundation
import Testing
@testable import Dropload

@Suite struct ProgressParserTests {
    @Test func parsesAPaddedLine() {
        #expect(ProgressParser.parse("dropload  42.3%|  3.10MiB/s|00:12")
            == .progress(fraction: 0.423, speed: "3.10MiB/s", eta: "00:12"))
    }

    @Test func turnsUnknownFieldsIntoNil() {
        #expect(ProgressParser.parse("dropload 100.0%|1.18MiB/s|NA")
            == .progress(fraction: 1, speed: "1.18MiB/s", eta: nil))
        #expect(ProgressParser.parse("dropload   0.0%|Unknown|Unknown")
            == .progress(fraction: 0, speed: nil, eta: nil))
        #expect(ProgressParser.parse("dropload NA|NA|NA") == nil)
    }

    @Test func ignoresOtherLines() {
        #expect(ProgressParser.parse("[download] Destination: /tmp/a.webm") == nil)
        #expect(ProgressParser.parse("dropload") == nil)
        #expect(ProgressParser.parse("dropload 12%|x") == nil)
        #expect(ProgressParser.parse("") == nil)
    }
}

@Suite struct YtDlpCommandTests {
    @Test func downloadArguments() {
        let url = URL(string: "https://www.youtube.com/watch?v=abc")!
        let args = YtDlpCommand.download(
            url,
            options: DownloadOptions(quality: .audioOnly, audio: .mp3),
            folder: URL(fileURLWithPath: "/tmp/out", isDirectory: true),
            ffmpeg: URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg")
        )
        #expect(Array(args.prefix(5)) == ["--no-playlist", "--newline", "--no-colors", "--ffmpeg-location", "/opt/homebrew/bin/ffmpeg"])
        #expect(args.contains("-x"))
        #expect(args.last == url.absoluteString)
        let output = try? #require(args.firstIndex(of: "-o"))
        #expect(output.map { args[$0 + 1] } == "/tmp/out/%(title).200B [%(id)s].%(ext)s")
        #expect(args.contains(YtDlpCommand.progressTemplate))
        #expect(args.contains("after_move:filepath"))
    }

    @Test func fetchArgumentsWithoutFFmpeg() {
        let args = YtDlpCommand.fetchInfo(URL(string: "https://example.com")!, ffmpeg: nil)
        #expect(args == ["--no-playlist", "--newline", "--no-colors", "-J", "--skip-download", "--", "https://example.com"])
    }

    @Test func classifiesLines() {
        #expect(YtDlpCommand.event(forLine: "dropload  50.0%|1MiB/s|00:01") == .progress(fraction: 0.5, speed: "1MiB/s", eta: "00:01"))
        #expect(YtDlpCommand.event(forLine: "[Merger] Merging formats into \"/tmp/a.mp4\"") == .postProcessing)
        #expect(YtDlpCommand.event(forLine: "[ExtractAudio] Destination: /tmp/a.mp3") == .postProcessing)
        #expect(YtDlpCommand.event(forLine: "[VideoRemuxer] Not remuxing") == .postProcessing)
        #expect(YtDlpCommand.event(forLine: "/tmp/Me at the zoo [id].mp3") == .finished(URL(fileURLWithPath: "/tmp/Me at the zoo [id].mp3")))
        #expect(YtDlpCommand.event(forLine: "[youtube] abc: Downloading webpage") == nil)
        #expect(YtDlpCommand.event(forLine: "Deleting original file /tmp/a.webm") == nil)
    }

    @Test func picksTheErrorLine() {
        let stderr = "WARNING: [generic] Falling back\nERROR: Unsupported URL: https://example.com/\n"
        #expect(YtDlpCommand.errorMessage(fromStderr: stderr) == "Unsupported URL: https://example.com/")
        #expect(YtDlpCommand.isUnsupported(stderr: stderr))
        #expect(YtDlpCommand.errorMessage(fromStderr: "one\ntwo\n\n") == "two")
        #expect(YtDlpCommand.errorMessage(fromStderr: "") == "")
    }
}

private let networkTestYtDlpPath = ProcessInfo.processInfo.environment["DROPLOAD_YTDLP"] ?? "/opt/homebrew/bin/yt-dlp"

/// Real yt-dlp against the network, opt-in: `DROPLOAD_NETWORK_TESTS=1 swift test`.
/// Uses Homebrew's yt-dlp (or `DROPLOAD_YTDLP`) and ffmpeg, and a 19-second video.
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["DROPLOAD_NETWORK_TESTS"] == "1"
    && FileManager.default.isExecutableFile(atPath: networkTestYtDlpPath)))
struct YtDlpClientNetworkTests {
    static let video = URL(string: "https://www.youtube.com/watch?v=jNQXAC9IVRw")!

    let client = YtDlpClient(tools: {
        .ready(
            ytDlp: ToolLocation(url: URL(fileURLWithPath: networkTestYtDlpPath), source: .custom, version: nil),
            ffmpeg: FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/ffmpeg")
                ? ToolLocation(url: URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg"), source: .system, version: nil)
                : nil
        )
    }, log: { print($0) })

    @Test func fetchesYouTubeInfo() async throws {
        let info = try await client.fetchInfo(for: Self.video)
        #expect(info.title == "Me at the zoo")
        #expect(info.extractorKey == "Youtube")
        let availability = FormatAvailability(info: info)
        #expect(availability.qualities.contains(.best))
        #expect(availability.qualities.contains(.audioOnly))
        #expect(!availability.qualities.contains(.p480))
        #expect(!availability.qualities.contains(.p1080))
    }

    @Test func rejectsANonVideoPage() async {
        await #expect(throws: YtDlpError.unsupportedURL) {
            _ = try await client.fetchInfo(for: URL(string: "https://example.com")!)
        }
    }

    @Test(arguments: [
        (DownloadOptions(quality: .p1080, container: .mp4, audio: .best), "mp4"),
        (DownloadOptions(quality: .audioOnly, container: .mp4, audio: .mp3), "mp3"),
        (DownloadOptions(quality: .best, container: .mkv, audio: .best), "mkv"),
    ])
    func downloadsTheRequestedFormat(options: DownloadOptions, ext: String) async throws {
        let folder = try Self.makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        var events: [DownloadEvent] = []
        for try await event in client.download(Self.video, options: options, into: folder) {
            events.append(event)
        }
        guard case .finished(let file) = events.last else {
            Issue.record("no finished event: \(events)")
            return
        }
        #expect(file.pathExtension == ext)
        #expect(file.deletingLastPathComponent().standardizedFileURL.path == folder.standardizedFileURL.path)
        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(events.contains { if case .progress = $0 { true } else { false } })
    }

    @Test func cancellingTerminatesTheProcess() async throws {
        let folder = try Self.makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        // A long video, cancelled once it is downloading.
        let long = URL(string: "https://www.youtube.com/watch?v=aqz-KE-bpKQ")!
        let stream = client.download(long, options: DownloadOptions(quality: .best, container: .mkv), into: folder)
        let started = AsyncStream<Void>.makeStream()
        let task = Task {
            for try await event in stream {
                if case .progress = event { started.continuation.yield() }
            }
        }
        for await _ in started.stream { break }
        #expect(Self.runningYtDlp() > 0)
        task.cancel()
        _ = try? await task.value
        try await Task.sleep(for: .seconds(3))
        #expect(Self.runningYtDlp() == 0)
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        print("left in folder after cancel:", leftovers)
    }

    @Test func cancelAllTerminatesAFetch() async throws {
        let long = URL(string: "https://www.youtube.com/watch?v=aqz-KE-bpKQ")!
        let task = Task { try await client.fetchInfo(for: long) }
        try await Task.sleep(for: .milliseconds(300))
        client.cancelAll()
        await #expect(throws: YtDlpError.cancelled) { _ = try await task.value }
        try await Task.sleep(for: .seconds(1))
        #expect(Self.runningYtDlp() == 0)
    }

    static func makeFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("dropload-dl-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// Child processes of this test process (yt-dlp and whatever it spawned).
    static func runningYtDlp() -> Int {
        YtDlpProcess.descendants(of: getpid()).count
    }
}
