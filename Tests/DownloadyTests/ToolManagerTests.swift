import Foundation
import Testing
@testable import Downloady

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

    @Test func systemCandidatesAreHomebrewThenPipxThenPath() {
        let candidates = ToolLookup.systemCandidates(named: "yt-dlp", pathVariable: "/x:/usr/local/bin:", home: "/Users/me")
        #expect(candidates == [
            "/opt/homebrew/bin/yt-dlp", "/usr/local/bin/yt-dlp", "/Users/me/.local/bin/yt-dlp", "/x/yt-dlp",
        ])
    }

    @Test func denoAlsoLooksInItsInstallersFolder() {
        let candidates = ToolLookup.systemCandidates(named: "deno", pathVariable: nil, home: "/Users/me")
        #expect(candidates.contains("/Users/me/.deno/bin/deno"))
        #expect(!ToolLookup.systemCandidates(named: "ffmpeg", pathVariable: nil, home: "/Users/me").contains { $0.contains(".deno") })
    }

    @Test func eachSourceIsStrict() {
        let candidates = ToolLookup.systemCandidates(named: "ffmpeg", pathVariable: "/p/bin", home: "/h")
        var present: Set<String> = ["/custom/ffmpeg", "/usr/local/bin/ffmpeg", managed.path]
        func locate(_ source: ToolLocation.Source, custom: String? = "/custom/ffmpeg") -> String? {
            ToolLookup.locate(source: source, custom: custom, systemCandidates: candidates, managed: managed) {
                present.contains($0)
            }?.path
        }
        #expect(locate(.custom) == "/custom/ffmpeg")
        #expect(locate(.system) == "/usr/local/bin/ffmpeg")
        #expect(locate(.managed) == managed.path)
        #expect(locate(.custom, custom: "  ") == nil)
        present = []
        // Nothing falls through to another source.
        #expect(locate(.custom) == nil)
        #expect(locate(.system) == nil)
        #expect(locate(.managed) == nil)
    }

    @Test func systemCopyPrefersHomebrewAndSkipsTheManagedCopy() {
        let candidates = [managed.path, "/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"]
        let found = ToolLookup.systemCopy(in: candidates, excluding: managed) { _ in true }
        #expect(found?.path == "/opt/homebrew/bin/ffmpeg")
    }

    @Test func aPickedSourceNeverFallsBack() {
        #expect(ToolLookup.effectiveSource(.system, preferred: .managed, systemAvailable: false, managedAvailable: true, installFailed: false) == .system)
        #expect(ToolLookup.effectiveSource(.managed, preferred: .managed, systemAvailable: true, managedAvailable: false, installFailed: true) == .managed)
    }

    @Test func helpersPreferTheMacsThenDownloadys() {
        func source(system: Bool, managed: Bool) -> ToolLocation.Source {
            ToolLookup.effectiveSource(nil, preferred: .system, systemAvailable: system, managedAvailable: managed, installFailed: false)
        }
        #expect(source(system: true, managed: true) == .system)
        #expect(source(system: false, managed: false) == .managed)
    }

    @Test func ytDlpFallsBackToTheMacsOnlyAfterItsInstallFailed() {
        func source(system: Bool, managed: Bool, failed: Bool) -> ToolLocation.Source {
            ToolLookup.effectiveSource(nil, preferred: .managed, systemAvailable: system, managedAvailable: managed, installFailed: failed)
        }
        // Not tried yet: install Downloady's even with a Homebrew copy around.
        #expect(source(system: true, managed: false, failed: false) == .managed)
        #expect(source(system: true, managed: false, failed: true) == .system)
        // Both failed: the source to retry.
        #expect(source(system: false, managed: false, failed: true) == .managed)
        #expect(source(system: true, managed: true, failed: true) == .managed)
    }
}

@Suite struct ToolVersionTests {
    @Test func parsesVersions() {
        #expect(ToolVersion.ffmpeg(fromFirstLine: "ffmpeg version 7.1.1 Copyright (c) 2000-2025\nbuilt with") == "7.1.1")
        #expect(ToolVersion.ffmpeg(fromFirstLine: "ffmpeg version 8.0.git-https://www.martin-riedl.de Copyright") == "8.0.git")
        #expect(ToolVersion.ytDlp(from: "2026.08.19\n") == "2026.08.19")
        #expect(ToolVersion.ytDlp(from: "") == nil)
        #expect(ToolVersion.deno(fromFirstLine: "deno 2.9.6 (stable, release, aarch64-apple-darwin)\nv8 14.0") == "2.9.6")
        #expect(ToolVersion.deno(fromFirstLine: "something else") == nil)
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
        let container = FileManager.default.temporaryDirectory.appendingPathComponent("downloady-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: container) }
        let fetcher = FakeFetcher(files: [
            "yt-dlp_macos.zip": Data("not the real archive".utf8),
            "SHA2-256SUMS": Data((String(repeating: "0", count: 64) + "  yt-dlp_macos.zip\n").utf8),
        ])
        let manager = ToolManager(
            containerDirectory: container,
            fetcher: fetcher,
            choices: { ToolChoices(sources: [.ffmpeg: .custom, .deno: .custom], paths: [.ffmpeg: "/usr/bin/true"]) },
            log: { _ in }
        )
        await #expect(throws: ToolError.checksumMismatch("yt-dlp_macos.zip")) {
            _ = try await manager.installMissing { _ in }
        }
        #expect(await manager.resolve() == .missing)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: manager.toolsDirectory.path)
        #expect(leftovers.isEmpty)
    }

    @Test func aFailedDenoAloneSaysWhy() async throws {
        let container = FileManager.default.temporaryDirectory.appendingPathComponent("downloady-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: container) }
        let archive = ToolManager.Configuration().denoArchiveName
        let fetcher = FakeFetcher(files: [
            archive: Data("not the real archive".utf8),
            archive + ".sha256sum": Data((String(repeating: "0", count: 64) + "  \(archive)\n").utf8),
        ])
        let manager = ToolManager(
            containerDirectory: container,
            fetcher: fetcher,
            choices: { ToolChoices(sources: [.ytDlp: .custom, .ffmpeg: .custom, .deno: .managed], paths: [.ytDlp: "/usr/bin/true"]) },
            log: { _ in }
        )
        #expect(manager.missingManagedTools() == [.deno])
        await #expect(throws: ToolError.checksumMismatch(archive)) {
            _ = try await manager.installMissing { _ in }
        }
    }

    @Test func aFailedYtDlpDoesNotStopTheHelpers() async throws {
        let container = FileManager.default.temporaryDirectory.appendingPathComponent("downloady-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: container) }
        let archive = ToolManager.Configuration().denoArchiveName
        let bad = { (name: String) in Data((String(repeating: "0", count: 64) + "  \(name)\n").utf8) }
        let manager = ToolManager(
            containerDirectory: container,
            fetcher: FakeFetcher(files: [
                "yt-dlp_macos.zip": Data("x".utf8), "SHA2-256SUMS": bad("yt-dlp_macos.zip"),
                archive: Data("x".utf8), archive + ".sha256sum": bad(archive),
            ]),
            choices: { ToolChoices(sources: [.ytDlp: .managed, .ffmpeg: .custom, .deno: .managed]) },
            log: { _ in }
        )
        await #expect(throws: ToolError.checksumMismatch("yt-dlp_macos.zip")) {
            _ = try await manager.installMissing { _ in }
        }
        // Deno was still tried, and both failures are on record.
        #expect(manager.installErrors[.ytDlp] != nil)
        #expect(manager.installErrors[.deno] == ToolError.checksumMismatch(archive).localizedDescription)
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

    /// Real download, opt-in: `DOWNLOADY_NETWORK_TESTS=1 swift test`.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DOWNLOADY_NETWORK_TESTS"] == "1"))
    func installsRealYtDlp() async throws {
        let container = FileManager.default.temporaryDirectory.appendingPathComponent("downloady-net-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: container) }
        let manager = ToolManager(containerDirectory: container, log: { print($0) })
        #expect(await manager.resolve() == .missing)
        #expect(manager.missingManagedTools().contains(.ytDlp))
        var seen: [Double] = []
        let status = try await manager.installMissing { seen.append($0) }
        let ytDlp = try #require(status.ytDlp)
        #expect(ytDlp.source == .managed)
        #expect(ytDlp.version != nil)
        #expect(status.ffmpeg?.source == .system)
        #expect(seen.last == 1)
        #expect(seen.contains { $0 > 0 && $0 < 1 })
        print("installed", ytDlp, status.ffmpeg as Any, "progress samples", seen.count)
        #expect(try await manager.availableUpdate(for: .ytDlp) == nil)
    }

    /// Real static ffmpeg download, opt-in like the test above.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DOWNLOADY_NETWORK_TESTS"] == "1"))
    func installsRealFFmpeg() async throws {
        let container = FileManager.default.temporaryDirectory.appendingPathComponent("downloady-net-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: container) }
        let manager = ToolManager(containerDirectory: container, log: { print($0) })
        try await manager.installFFmpeg { _ in }
        let result = await ToolProcess.run(manager.managedFFmpeg, ["-version"], timeout: 30)
        #expect(result?.status == 0)
        print("managed ffmpeg:", ToolVersion.ffmpeg(fromFirstLine: result?.output ?? "") ?? "?")
    }

    /// The Mac's own copies against Homebrew and GitHub, opt-in like the tests above.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DOWNLOADY_NETWORK_TESTS"] == "1"))
    func checksTheMacsCopiesForUpdates() async throws {
        let manager = ToolManager(
            containerDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("downloady-net-\(UUID().uuidString)"),
            choices: { ToolChoices(sources: [.ytDlp: .system, .ffmpeg: .system, .deno: .system]) },
            log: { print($0) }
        )
        for tool in ToolLocation.Tool.allCases {
            let location = tool == .ytDlp ? await manager.resolve().ytDlp : await manager.resolveHelper(tool)
            print(tool.name, location?.url.path ?? "none", location?.version ?? "?", "->", String(describing: try await manager.availableUpdate(for: tool)))
        }
    }

    /// Real Deno download, opt-in like the tests above.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DOWNLOADY_NETWORK_TESTS"] == "1"))
    func installsRealDeno() async throws {
        let container = FileManager.default.temporaryDirectory.appendingPathComponent("downloady-net-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: container) }
        let manager = ToolManager(containerDirectory: container, log: { print($0) })
        try await manager.installDeno { _ in }
        let result = await ToolProcess.run(manager.managedDeno, ["--version"], timeout: 30)
        #expect(result?.status == 0)
        #expect(ToolVersion.deno(fromFirstLine: result?.output ?? "") != nil)
    }
}

@MainActor
@Suite struct ToolManagerSourceTests {
    @Test func ffmpegIsResolvedWithoutYtDlp() async throws {
        let container = FileManager.default.temporaryDirectory.appendingPathComponent("downloady-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: container) }
        // `/bin/echo -version` prints "-version": a version line, with no yt-dlp anywhere.
        let manager = ToolManager(
            containerDirectory: container,
            fetcher: FakeFetcher(files: [:]),
            choices: { ToolChoices(sources: [.ffmpeg: .custom, .deno: .custom], paths: [.ffmpeg: "/bin/echo"]) },
            log: { _ in }
        )
        #expect(await manager.resolve() == .missing)
        let ffmpeg = try #require(await manager.resolveHelper(.ffmpeg))
        #expect(ffmpeg.source == .custom)
        #expect(ffmpeg.version == "-version")
        #expect(manager.missingManagedTools() == [.ytDlp])
    }

    @Test func aCustomYtDlpNeedsNoInstall() {
        let manager = ToolManager(
            containerDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
            fetcher: FakeFetcher(files: [:]),
            choices: { ToolChoices(sources: [.ytDlp: .custom, .ffmpeg: .custom, .deno: .custom]) },
            log: { _ in }
        )
        #expect(manager.missingManagedTools().isEmpty)
    }
}

@Suite struct ToolOriginTests {
    @Test func detectsHowACopyWasInstalled() {
        #expect(ToolOrigin.detect(path: "/opt/homebrew/bin/ffmpeg", resolved: "/opt/homebrew/Cellar/ffmpeg/8.1.2/bin/ffmpeg", home: "/h") == .homebrew)
        #expect(ToolOrigin.detect(path: "/h/.deno/bin/deno", resolved: "/h/.deno/bin/deno", home: "/h") == .denoInstaller)
        #expect(ToolOrigin.detect(path: "/h/.local/bin/yt-dlp", resolved: "/h/.local/share/pipx/venvs/yt-dlp/bin/yt-dlp", home: "/h") == .pipx)
        #expect(ToolOrigin.detect(path: "/usr/local/bin/yt-dlp", resolved: "/usr/local/bin/yt-dlp", home: "/h") == .unknown)
    }

    @Test func commandsMatchTheInstaller() {
        #expect(ToolOrigin.homebrew.upgradeCommand(for: .ytDlp) == "brew upgrade yt-dlp")
        #expect(ToolOrigin.homebrew.upgradeCommand(for: .deno) == "brew upgrade deno")
        #expect(ToolOrigin.denoInstaller.upgradeCommand(for: .deno) == "~/.deno/bin/deno upgrade")
        #expect(ToolOrigin.pipx.upgradeCommand(for: .ytDlp) == "pipx upgrade yt-dlp")
        #expect(ToolOrigin.unknown.upgradeCommand(for: .ffmpeg) == nil)
    }

    @Test func namesFFmpegSnapshots() {
        #expect(ToolVersion.ffmpegSnapshot("1789407207_N-126556-g639ee84952") == "N-126556")
    }

    @Test func homebrewVersionNumbersCompareWithGitHubs() {
        #expect(!ToolVersion.isNewer("2026.8.19", than: "2026.08.19"))
        #expect(ToolVersion.isNewer("9.0.2", than: "8.1.2"))
    }

    @MainActor
    @Test func readsHomebrewsStableVersion() async throws {
        let manager = ToolManager(
            containerDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("downloady-\(UUID().uuidString)"),
            fetcher: FakeFetcher(files: ["ffmpeg.json": Data(#"{"name":"ffmpeg","versions":{"stable":"9.0.2","head":"HEAD"}}"#.utf8)]),
            log: { _ in }
        )
        #expect(try await manager.homebrewVersion(of: .ffmpeg) == "9.0.2")
    }
}
