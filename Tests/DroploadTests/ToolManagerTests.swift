import Foundation
import Testing
@testable import Dropload

@Suite struct ChecksumListTests {
    @Test func parsesSha2SumsLines() {
        let text = """
        1fa6733c37ea6fb51c99ad8fe785e7b7e5f3246c9b980230329d4fb72ed8d4d6  yt-dlp
        07E54B0865303C864006925913BCE2604F8EE8CC6F18699BAC9C309F9328A6D8  yt-dlp_macos.zip
        0f192b7ec147ab6288885d6351d9ab67367640029b4377576ef46dd79cf7b202 *yt-dlp_macos

        not-a-digest  junk
        abc  short
        """
        let sums = ChecksumList.parse(text)
        #expect(sums.count == 3)
        #expect(sums["yt-dlp_macos.zip"] == "07e54b0865303c864006925913bce2604f8ee8cc6f18699bac9c309f9328a6d8")
        #expect(sums["yt-dlp_macos"] == "0f192b7ec147ab6288885d6351d9ab67367640029b4377576ef46dd79cf7b202")
        #expect(sums["junk"] == nil)
    }

    @Test func hashesAFile() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("abc".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(try ChecksumList.sha256(of: file) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }
}

@Suite struct ToolLookupTests {
    let managed = URL(fileURLWithPath: "/c/tools/ffmpeg")

    @Test func ffmpegPrefersCustomThenHomebrewThenLocalThenPathThenManaged() {
        var present: Set<String> = ["/custom/ffmpeg", "/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/p/bin/ffmpeg", managed.path]
        func locate() -> (URL, ToolLocation.Source)? {
            ToolLookup.ffmpeg(custom: "/custom/ffmpeg", pathVariable: "/x:/p/bin", managed: managed) { present.contains($0) }
                .map { ($0.url, $0.source) }
        }
        #expect(locate()?.0.path == "/custom/ffmpeg")
        #expect(locate()?.1 == .custom)
        present.remove("/custom/ffmpeg")
        #expect(locate()?.0.path == "/opt/homebrew/bin/ffmpeg")
        #expect(locate()?.1 == .system)
        present.remove("/opt/homebrew/bin/ffmpeg")
        #expect(locate()?.0.path == "/usr/local/bin/ffmpeg")
        present.remove("/usr/local/bin/ffmpeg")
        #expect(locate()?.0.path == "/p/bin/ffmpeg")
        #expect(locate()?.1 == .system)
        present.remove("/p/bin/ffmpeg")
        #expect(locate()?.0 == managed)
        #expect(locate()?.1 == .managed)
        present.remove(managed.path)
        #expect(locate() == nil)
    }

    @Test func ffmpegIgnoresBlankCustomPath() {
        let found = ToolLookup.ffmpeg(custom: "  ", pathVariable: nil, managed: managed) { $0 == "/usr/local/bin/ffmpeg" }
        #expect(found?.url.path == "/usr/local/bin/ffmpeg")
    }

    @Test func ytDlpUsesCustomThenManaged() {
        let managed = URL(fileURLWithPath: "/c/tools/yt-dlp/yt-dlp_macos")
        #expect(ToolLookup.ytDlp(custom: "/bin/yt", managed: managed) { _ in true }?.source == .custom)
        #expect(ToolLookup.ytDlp(custom: "/bin/yt", managed: managed) { $0 == managed.path }?.source == .managed)
        #expect(ToolLookup.ytDlp(custom: nil, managed: managed) { _ in false } == nil)
    }
}

@Suite struct ToolVersionTests {
    @Test func parsesVersions() {
        #expect(ToolVersion.ffmpeg(fromFirstLine: "ffmpeg version 7.1.1 Copyright (c) 2000-2025\nbuilt with") == "7.1.1")
        #expect(ToolVersion.ffmpeg(fromFirstLine: "ffmpeg version 8.0.git-https://www.martin-riedl.de Copyright") == "8.0.git")
        #expect(ToolVersion.ytDlp(from: "2026.08.19\n") == "2026.08.19")
        #expect(ToolVersion.ytDlp(from: "") == nil)
    }

    @Test func comparesReleaseTags() {
        #expect(ToolVersion.isNewer("2026.08.19", than: "2026.07.30"))
        #expect(ToolVersion.isNewer("2026.08.19.1", than: "2026.08.19"))
        #expect(!ToolVersion.isNewer("2026.08.19", than: "2026.08.19"))
        #expect(!ToolVersion.isNewer("2026.01.01", than: "2026.08.19"))
        #expect(ToolVersion.isNewer("2026.01.01", than: nil))
    }
}

/// Serves files from memory instead of the network.
final class FakeFetcher: ToolFetching, @unchecked Sendable {
    let files: [String: Data]
    init(files: [String: Data]) { self.files = files }

    func fetch(_ url: URL, into directory: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> FetchedFile {
        guard let data = files[url.lastPathComponent] else { throw ToolError.httpStatus(404, url.lastPathComponent) }
        let file = directory.appendingPathComponent(UUID().uuidString)
        try data.write(to: file)
        progress(1)
        return FetchedFile(file: file, finalURL: url)
    }

    func resolveRedirect(_ url: URL) async throws -> URL {
        URL(string: "https://github.com/yt-dlp/yt-dlp/releases/tag/2026.08.19")!
    }
}

@MainActor
@Suite struct ToolManagerInstallTests {
    @Test func checksumMismatchInstallsNothing() async throws {
        let container = FileManager.default.temporaryDirectory.appendingPathComponent("dropload-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: container) }
        let fetcher = FakeFetcher(files: [
            "yt-dlp_macos.zip": Data("not the real archive".utf8),
            "SHA2-256SUMS": Data((String(repeating: "0", count: 64) + "  yt-dlp_macos.zip\n").utf8),
        ])
        let manager = ToolManager(
            containerDirectory: container,
            fetcher: fetcher,
            customPaths: { (nil, "/usr/bin/true") },
            log: { _ in }
        )
        await #expect(throws: ToolError.checksumMismatch("yt-dlp_macos.zip")) {
            _ = try await manager.installMissing { _ in }
        }
        #expect(await manager.resolve() == .missing)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: manager.toolsDirectory.path)
        #expect(leftovers.isEmpty)
    }

    @Test func refusedNetworkFails() async {
        let manager = ToolManager(
            containerDirectory: FileManager.default.temporaryDirectory,
            fetcher: FakeFetcher(files: [:]),
            networkGranted: { false },
            log: { _ in }
        )
        await #expect(throws: ToolError.notPermitted) {
            _ = try await manager.installMissing { _ in }
        }
    }

    /// Real download, opt-in: `DROPLOAD_NETWORK_TESTS=1 swift test`.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DROPLOAD_NETWORK_TESTS"] == "1"))
    func installsRealYtDlp() async throws {
        let container = FileManager.default.temporaryDirectory.appendingPathComponent("dropload-net-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: container) }
        let manager = ToolManager(containerDirectory: container, log: { print($0) })
        #expect(await manager.resolve() == .missing)
        var seen: [Double] = []
        let status = try await manager.installMissing { seen.append($0) }
        let ytDlp = try #require(status.ytDlp)
        #expect(ytDlp.source == .managed)
        #expect(ytDlp.version != nil)
        #expect(status.ffmpeg?.source == .system)
        #expect(seen.last == 1)
        #expect(seen.contains { $0 > 0 && $0 < 0.7 })
        print("installed", ytDlp, status.ffmpeg as Any, "progress samples", seen.count)
        let update = try await manager.updateYtDlp()
        #expect(update.ytDlp?.version == ytDlp.version)
    }

    /// Real static ffmpeg download, opt-in like the test above.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DROPLOAD_NETWORK_TESTS"] == "1"))
    func installsRealFFmpeg() async throws {
        let container = FileManager.default.temporaryDirectory.appendingPathComponent("dropload-net-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: container) }
        let manager = ToolManager(containerDirectory: container, log: { print($0) })
        try await manager.installFFmpeg { _ in }
        let result = await ToolProcess.run(manager.managedFFmpeg, ["-version"], timeout: 30)
        #expect(result?.status == 0)
        print("managed ffmpeg:", ToolVersion.ffmpeg(fromFirstLine: result?.output ?? "") ?? "?")
    }
}
