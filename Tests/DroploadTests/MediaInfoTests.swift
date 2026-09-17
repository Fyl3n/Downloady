import Foundation
import Testing
@testable import Dropload

@Suite struct FormatAvailabilityTests {
    /// Trimmed from a real `yt-dlp -J` of a YouTube video that tops out at 720p,
    /// with the keys the droplet does not read left in.
    static let youtubeJSON = """
    {
      "id": "abc", "title": "A video", "extractor_key": "Youtube", "extractor": "youtube",
      "webpage_url": "https://www.youtube.com/watch?v=abc", "duration": 212.0,
      "thumbnail": "https://i.ytimg.com/vi/abc/hq.jpg", "view_count": 12,
      "formats": [
        {"format_id": "sb0", "ext": "mhtml", "vcodec": "none", "acodec": "none", "height": 90, "protocol": "mhtml"},
        {"format_id": "233", "ext": "mp4", "vcodec": "none", "acodec": null},
        {"format_id": "140", "ext": "m4a", "vcodec": "none", "acodec": "mp4a.40.2", "height": null, "abr": 129.5},
        {"format_id": "251", "ext": "webm", "vcodec": "none", "acodec": "opus"},
        {"format_id": "160", "ext": "mp4", "vcodec": "avc1.4d400c", "acodec": "none", "height": 144},
        {"format_id": "134", "ext": "mp4", "vcodec": "avc1.4d401e", "acodec": "none", "height": 360},
        {"format_id": "247", "ext": "webm", "vcodec": "vp9", "acodec": "none", "height": 720},
        {"format_id": "18", "ext": "mp4", "vcodec": "avc1.42001E", "acodec": "mp4a.40.2", "height": 360}
      ]
    }
    """

    static let audioOnlyJSON = """
    {
      "id": "123", "title": "A track", "extractor_key": "Soundcloud", "duration": 30,
      "formats": [
        {"format_id": "hls_mp3", "ext": "mp3", "vcodec": "none", "acodec": "mp3"},
        {"format_id": "hls_opus", "ext": "opus", "vcodec": "none", "acodec": "opus"}
      ]
    }
    """

    static let noFormatsJSON = """
    {"id": "x", "title": "A playlist", "extractor_key": "YoutubeTab", "_type": "playlist"}
    """

    static func decode(_ json: String) throws -> MediaInfo {
        try JSONDecoder().decode(MediaInfo.self, from: Data(json.utf8))
    }

    @Test func youtubeGreysOutQualitiesAboveTheMaximum() throws {
        let info = try Self.decode(Self.youtubeJSON)
        #expect(info.title == "A video")
        #expect(info.duration == 212)
        #expect(info.isDedicatedExtractor)
        #expect(info.formats?.count == 8)
        let availability = FormatAvailability(info: info)
        #expect(availability.qualities == [.best, .p720, .p480, .audioOnly])
        #expect(availability.containers == Set(VideoContainer.allCases))
        #expect(availability.audioFormats == Set(AudioFormat.allCases))
    }

    @Test func audioOnlySourcesOfferOnlyAudio() throws {
        let availability = FormatAvailability(info: try Self.decode(Self.audioOnlyJSON))
        #expect(availability.qualities == [.audioOnly])
    }

    @Test func noFormatsIsUnrestricted() throws {
        #expect(FormatAvailability(info: try Self.decode(Self.noFormatsJSON)) == .unrestricted)
        let empty = MediaInfo(id: "x", title: "x", extractorKey: "Vimeo", formats: [])
        #expect(FormatAvailability(info: empty) == .unrestricted)
    }

    @Test func formatsWithoutCodecInfoKeepEverything() {
        let info = MediaInfo(id: "x", title: "x", extractorKey: "Generic", formats: [
            MediaFormat(formatID: "mp4", ext: "mp4", vcodec: nil, acodec: nil, height: nil),
        ])
        #expect(FormatAvailability(info: info) == .unrestricted)
    }

    @Test func fallbackStepsDown() {
        let availability = FormatAvailability(
            qualities: [.best, .p720, .p480, .audioOnly],
            containers: Set(VideoContainer.allCases),
            audioFormats: Set(AudioFormat.allCases)
        )
        #expect(availability.fallback(for: .p1080) == .p720)
        #expect(availability.fallback(for: .p2160) == .p720)
        #expect(availability.fallback(for: .p480) == .p480)
        #expect(availability.fallback(for: .best) == .best)

        let audio = FormatAvailability(qualities: [.audioOnly], containers: [], audioFormats: [])
        #expect(audio.fallback(for: .p1080) == .audioOnly)
        #expect(audio.fallback(for: .best) == .audioOnly)

        let low = FormatAvailability(qualities: [.best, .audioOnly], containers: [], audioFormats: [])
        #expect(low.fallback(for: .p480) == .best)
    }
}

@Suite struct OptionsSummaryTests {
    @Test func describesTheResult() {
        #expect(DownloadOptions(quality: .p1080, container: .mp4, audio: .m4a).summary == "1080p mp4 with m4a audio")
        #expect(DownloadOptions(quality: .best, container: .mkv, audio: .best).summary == "Best quality mkv with the best audio")
        #expect(DownloadOptions(quality: .audioOnly, audio: .mp3).summary == "mp3 audio only")
        #expect(DownloadOptions(quality: .audioOnly, audio: .best).summary == "Best audio only")
        // mp3 cannot go into mp4 with video: normalized to best.
        #expect(DownloadOptions(quality: .p720, container: .mp4, audio: .mp3).summary == "720p mp4 with the best audio")
    }
}

@MainActor
@Suite struct DownloadModelInfoTests {
    @Test func readyInfoNarrowsAndStepsQualityDown() throws {
        let model = DownloadModel()
        model.options = DownloadOptions(quality: .p1080, container: .mp4, audio: .m4a)
        let info = try FormatAvailabilityTests.decode(FormatAvailabilityTests.youtubeJSON)
        model.applyInfo(.success(info))
        #expect(model.phase == .ready(info))
        #expect(model.info == info)
        #expect(model.options.quality == .p720)
        #expect(!model.availability.qualities.contains(.p1080))
    }

    @Test func unsupportedAndFailures() {
        let model = DownloadModel()
        model.applyInfo(.failure(YtDlpError.unsupportedURL))
        #expect(model.phase == .unsupported)
        #expect(model.info == nil)
        model.applyInfo(.failure(YtDlpError.processFailed(exitCode: 1, message: "HTTP Error 403")))
        #expect(model.phase == .failed("HTTP Error 403"))
        model.applyInfo(.failure(YtDlpError.cancelled))
        #expect(model.phase == .failed("HTTP Error 403"))
    }

    @Test func unsupportedPageCannotDownload() {
        let model = DownloadModel()
        model.urlText = "https://example.com"
        model.applyInfo(.failure(YtDlpError.unsupportedURL))
        #expect(!model.canDownload)
    }

    @Test func invalidOptionsAreNormalized() {
        let model = DownloadModel()
        model.options = DownloadOptions(quality: .p720, container: .webm, audio: .m4a)
        #expect(model.options.audio == .best)
    }

    @Test func webURLs() {
        #expect(DownloadModel.webURL(from: " https://youtu.be/x ") != nil)
        #expect(DownloadModel.webURL(from: "ftp://a.b/c") == nil)
        #expect(DownloadModel.webURL(from: "https://") == nil)
        #expect(DownloadModel.webURL(from: "hello") == nil)
    }

    @Test func refusesAFolderItCannotWriteTo() {
        #expect(DownloadModel.isWritableFolder(FileManager.default.temporaryDirectory))
        #expect(!DownloadModel.isWritableFolder(URL(fileURLWithPath: "/System")))
        #expect(!DownloadModel.isWritableFolder(URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)")))
        let model = DownloadModel()
        #expect(!model.setDownloadFolder(URL(fileURLWithPath: "/System")))
        #expect(model.downloadFolderMessage != nil)
    }
}
