import Foundation
import Testing
@testable import Downloady

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
        let availability = FormatAvailability(qualities: [.best, .p720, .p480, .audioOnly])
        #expect(availability.fallback(for: .p1080) == .p720)
        #expect(availability.fallback(for: .p2160) == .p720)
        #expect(availability.fallback(for: .p480) == .p480)
        #expect(availability.fallback(for: .best) == .best)

        let audio = FormatAvailability(qualities: [.audioOnly])
        #expect(audio.fallback(for: .p1080) == .audioOnly)
        #expect(audio.fallback(for: .best) == .audioOnly)

        let low = FormatAvailability(qualities: [.best, .audioOnly])
        #expect(low.fallback(for: .p480) == .best)
    }
}

@Suite struct OptionsSummaryTests {
    @Test func describesTheResult() {
        #expect(DownloadOptions(quality: .p1080, container: .mp4, audio: .m4a).summary == "1080p mp4, m4a audio")
        #expect(DownloadOptions().summary == "Best video, original audio")
        #expect(DownloadOptions(quality: .best, container: .mkv, audioQuality: .k128).summary == "Best mkv, original audio up to 128 kbps")
        #expect(DownloadOptions(quality: .audioOnly, audio: .mp3, audioQuality: .k192).summary == "mp3 audio only, 192 kbps")
        #expect(DownloadOptions(quality: .audioOnly, audioQuality: .k128).summary == "Original audio only, up to 128 kbps")
        #expect(DownloadOptions(quality: .audioOnly, audio: .flac, audioQuality: .k128).summary == "flac audio only")
        // mp3 cannot go into mp4 with video: normalized to original.
        #expect(DownloadOptions(quality: .p720, container: .mp4, audio: .mp3).summary == "720p mp4, original audio")
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
        #expect(model.options.audio == .original)
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

@Suite struct PlaylistLookupTests {
    /// Trimmed from a real `yt-dlp --flat-playlist -J` of a 54-entry YouTube
    /// playlist, with the second entry hand-edited into a private one.
    static let playlistJSON = """
    {
      "id": "PLFs4vir_WsTwEd-nJgVJCZPNL3HALHHpF", "title": "The Universe and Space stuff",
      "availability": "public", "playlist_count": 54, "_type": "playlist",
      "extractor_key": "YoutubeTab", "extractor": "youtube:tab",
      "webpage_url": "https://www.youtube.com/playlist?list=PLFs4vir_WsTwEd-nJgVJCZPNL3HALHHpF",
      "entries": [
        {"title": "Three Ways to Destroy the Universe", "duration": 377, "live_status": null, "availability": null,
         "ie_key": "Youtube", "id": "4_aOIA-vyBo", "_type": "url", "url": "https://www.youtube.com/watch?v=4_aOIA-vyBo"},
        {"title": "[Private video]", "duration": null, "live_status": null, "availability": "private",
         "ie_key": "Youtube", "id": "e-P5IFTqB98", "_type": "url", "url": "https://www.youtube.com/watch?v=e-P5IFTqB98"},
        {"title": "Space Elevator – Science Fiction or the Future of Mankind?", "duration": 326, "live_status": null,
         "availability": null, "ie_key": "Youtube", "id": "qPQQwqGWktE", "_type": "url",
         "url": "https://www.youtube.com/watch?v=qPQQwqGWktE"}
      ]
    }
    """

    @Test func decodesAFlatPlaylist() throws {
        let info = try FormatAvailabilityTests.decode(Self.playlistJSON)
        #expect(info.isPlaylist)
        #expect(info.playlistCount == 54)
        #expect(info.title == "The Universe and Space stuff")
        #expect(info.formats == nil)
        #expect(info.entries?.count == 3)
        #expect(info.entries?.first == PlaylistEntry(
            url: "https://www.youtube.com/watch?v=4_aOIA-vyBo",
            title: "Three Ways to Destroy the Universe",
            duration: 377,
            type: "url"
        ))
        #expect(info.downloadableCount == 2)
        #expect(FormatAvailability(info: info) == .unrestricted)
    }

    @Test func aSingleVideoIsNotAPlaylist() throws {
        let info = try FormatAvailabilityTests.decode(FormatAvailabilityTests.youtubeJSON)
        #expect(!info.isPlaylist)
        #expect(info.entries == nil)
        #expect(info.formats?.count == 8)
    }

    @Test func unavailableEntriesSayWhy() {
        func reason(title: String = "A video", availability: String? = nil, live: String? = nil) -> String? {
            PlaylistEntry(url: "https://youtu.be/a", title: title, availability: availability, liveStatus: live).unavailableReason
        }
        #expect(reason() == nil)
        #expect(reason(availability: "public") == nil)
        #expect(reason(availability: "unlisted") == nil)
        #expect(reason(availability: "private") == "Private video")
        #expect(reason(availability: "premium_only") != nil)
        #expect(reason(availability: "subscriber_only") != nil)
        #expect(reason(availability: "needs_auth") != nil)
        #expect(reason(title: "[Private video]") == "Private video")
        #expect(reason(title: "[Deleted video]") == "Deleted video")
        #expect(reason(live: "is_live") == "Live stream: open it on its own to record it")
        #expect(reason(live: "is_upcoming") == "Live stream: open it on its own to record it")
        #expect(reason(live: "was_live") == nil)
    }
}

@Suite struct LiveLookupTests {
    /// Trimmed from real `yt-dlp -J` output: a 24/7 stream on now, one that
    /// begins in 10 hours (with `--ignore-no-formats-error`), and one over.
    static let liveJSON = """
    {"id": "wBhxknOJibc", "title": "Sky News live", "extractor_key": "Youtube", "is_live": true,
     "live_status": "is_live", "release_timestamp": 1790579361, "duration": null,
     "formats": [{"format_id": "230", "ext": "mp4", "vcodec": "avc1.4D401E", "acodec": "none", "height": 360}]}
    """
    static let upcomingJSON = """
    {"id": "j9epFget1W8", "title": "Space Station Operations Update", "extractor_key": "Youtube", "is_live": false,
     "live_status": "is_upcoming", "release_timestamp": 1790622000, "duration": null, "formats": []}
    """
    static let postLiveJSON = """
    {"id": "abc", "title": "Yesterday's stream", "extractor_key": "Youtube", "was_live": true,
     "live_status": "post_live", "release_timestamp": 1790500000, "duration": 3600,
     "formats": [{"format_id": "18", "ext": "mp4", "vcodec": "avc1", "acodec": "mp4a", "height": 360}]}
    """

    @Test func aLiveStreamIsRecordedAtOnce() throws {
        let info = try FormatAvailabilityTests.decode(Self.liveJSON)
        #expect(info.liveStatus == "is_live")
        #expect(info.releaseTimestamp == 1_790_579_361)
        #expect(info.isLiveStream)
        // It began in the past: no Scheduled recording.
        #expect(info.scheduledStart == nil)
    }

    @Test func anUpcomingStreamIsScheduled() throws {
        let info = try FormatAvailabilityTests.decode(Self.upcomingJSON)
        #expect(info.isLiveStream)
        #expect(info.scheduledStart == Date(timeIntervalSince1970: 1_790_622_000))
        #expect(FormatAvailability(info: info) == .unrestricted)
    }

    @Test func aStreamThatEndedIsAnOrdinaryVideo() throws {
        let info = try FormatAvailabilityTests.decode(Self.postLiveJSON)
        #expect(info.liveStatus == "post_live")
        #expect(!info.isLiveStream)
        #expect(info.scheduledStart == nil)
        #expect(!MediaInfo(id: "a", title: "A", extractorKey: "Youtube", formats: nil, liveStatus: "was_live").isLiveStream)
    }
}
