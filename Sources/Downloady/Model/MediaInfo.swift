//
//  MediaInfo.swift
//  Downloady
//
//  The slice of `yt-dlp -J` the droplet reads, and what it says about which
//  picker entries the URL can actually satisfy.
//

import Foundation

/// One entry of `formats` in `yt-dlp -J` output.
public struct MediaFormat: Codable, Equatable, Sendable {
    public let formatID: String
    public let ext: String?
    public let vcodec: String?
    public let acodec: String?
    public let height: Int?

    enum CodingKeys: String, CodingKey {
        case formatID = "format_id"
        case ext, vcodec, acodec, height
    }

    public init(formatID: String, ext: String?, vcodec: String?, acodec: String?, height: Int?) {
        self.formatID = formatID
        self.ext = ext
        self.vcodec = vcodec
        self.acodec = acodec
        self.height = height
    }

    /// yt-dlp writes `"none"` for a missing stream.
    public var hasVideo: Bool { vcodec.map { $0 != "none" } ?? false }
    public var hasAudio: Bool { acodec.map { $0 != "none" } ?? false }
}

/// One entry of `subtitles` or `automatic_captions` in `yt-dlp -J` output.
/// Only the shape matters here: the droplet asks yt-dlp for a language, it
/// never fetches a track itself.
public struct SubtitleTrack: Codable, Equatable, Sendable {
    public let ext: String?
    public let name: String?

    public init(ext: String? = nil, name: String? = nil) {
        self.ext = ext
        self.name = name
    }
}

/// The metadata the droplet needs about one URL.
public struct MediaInfo: Codable, Equatable, Sendable {
    public let id: String
    public let title: String
    /// yt-dlp's extractor, e.g. `"Youtube"`. `"Generic"` means no dedicated
    /// extractor matched, which is the signal for "not a supported site".
    public let extractorKey: String?
    public let webpageURL: String?
    public let duration: Double?
    public let thumbnail: String?
    public let formats: [MediaFormat]?
    /// `subtitles` in `yt-dlp -J`: language code to tracks, written by people.
    public let subtitles: [String: [SubtitleTrack]]?
    /// `automatic_captions`: the same shape, machine-written (YouTube's).
    public let automaticCaptions: [String: [SubtitleTrack]]?
    /// `language`: the media's own language, when the extractor knows it.
    public let language: String?

    enum CodingKeys: String, CodingKey {
        case id, title, duration, thumbnail, formats, subtitles, language
        case extractorKey = "extractor_key"
        case webpageURL = "webpage_url"
        case automaticCaptions = "automatic_captions"
    }

    public init(
        id: String,
        title: String,
        extractorKey: String?,
        webpageURL: String? = nil,
        duration: Double? = nil,
        thumbnail: String? = nil,
        formats: [MediaFormat]?,
        subtitles: [String: [SubtitleTrack]]? = nil,
        automaticCaptions: [String: [SubtitleTrack]]? = nil,
        language: String? = nil
    ) {
        self.id = id
        self.title = title
        self.extractorKey = extractorKey
        self.webpageURL = webpageURL
        self.duration = duration
        self.thumbnail = thumbnail
        self.formats = formats
        self.subtitles = subtitles
        self.automaticCaptions = automaticCaptions
        self.language = language
    }

    /// Every language code with a subtitle track, written or automatic,
    /// without yt-dlp's live chat pseudo-track.
    public var subtitleLanguages: Set<String> {
        let keys = Array((subtitles ?? [:]).keys) + Array((automaticCaptions ?? [:]).keys)
        return Set(keys.filter { $0 != "live_chat" })
    }

    /// Whether `yt-dlp` has any subtitles to write for this URL.
    public var hasSubtitles: Bool { !subtitleLanguages.isEmpty }

    /// The language to ask yt-dlp for: the first of `preferred` the media
    /// has, else its own language, else English, else any of them.
    ///
    /// The result is a yt-dlp `--sub-langs` selector, so a bare `"fr"` also
    /// matches `fr-FR` through yt-dlp's own prefix matching.
    public func subtitleLanguage(preferring preferred: [String]) -> String {
        let available = subtitleLanguages
        let codes = available.map { ($0, $0.prefix(while: { $0 != "-" }).lowercased()) }
        for wanted in preferred.map({ $0.prefix(while: { $0 != "-" }).lowercased() }) {
            if let match = codes.first(where: { $0.1 == wanted }) { return match.0 }
        }
        if let own = language, let match = codes.first(where: { $0.1 == own.prefix(while: { $0 != "-" }).lowercased() }) {
            return match.0
        }
        if let english = codes.first(where: { $0.1 == "en" }) { return english.0 }
        return available.sorted().first ?? "en"
    }

    /// Whether a dedicated extractor handled the URL.
    public var isDedicatedExtractor: Bool {
        guard let extractorKey else { return false }
        return extractorKey != "Generic"
    }
}

/// Which picker entries a fetched URL can satisfy. `nil` (no metadata yet)
/// means everything is offered, and yt-dlp falls back on its own.
public struct FormatAvailability: Equatable, Sendable {
    public var qualities: Set<DownloadQuality>
    public var containers: Set<VideoContainer>
    public var audioFormats: Set<AudioFormat>

    public static let unrestricted = FormatAvailability(
        qualities: Set(DownloadQuality.allCases),
        containers: Set(VideoContainer.allCases),
        audioFormats: Set(AudioFormat.allCases)
    )

    public init(qualities: Set<DownloadQuality>, containers: Set<VideoContainer>, audioFormats: Set<AudioFormat>) {
        self.qualities = qualities
        self.containers = containers
        self.audioFormats = audioFormats
    }

    /// Derives availability from the formats yt-dlp reported.
    ///
    /// - A height preset is available when some video format reaches at least
    ///   that height; `best` whenever any video exists; `audioOnly` whenever
    ///   any audio exists. When no video format reports a height, the height
    ///   presets stay available (yt-dlp falls back on its own).
    /// - Containers stay available (ffmpeg remuxes), audio formats stay
    ///   available (ffmpeg converts); only qualities are really restricted.
    /// - No formats at all -> `.unrestricted`.
    public init(info: MediaInfo) {
        let formats = (info.formats ?? []).filter { !$0.isStoryboard }
        guard !formats.isEmpty else {
            self = .unrestricted
            return
        }
        let video = formats.filter(\.mayHaveVideo)
        let hasAudio = formats.contains(where: \.mayHaveAudio)
        let maxHeight = video.compactMap(\.height).max()

        var qualities = Set<DownloadQuality>()
        if !video.isEmpty {
            qualities.insert(.best)
            for quality in DownloadQuality.allCases {
                guard let height = quality.maxHeight else { continue }
                if maxHeight.map({ $0 >= height }) ?? true {
                    qualities.insert(quality)
                }
            }
        }
        if hasAudio { qualities.insert(.audioOnly) }
        if qualities.isEmpty {
            // Nothing recognisable: let yt-dlp decide rather than block everything.
            qualities = Set(DownloadQuality.allCases)
        }
        self.init(
            qualities: qualities,
            containers: Set(VideoContainer.allCases),
            audioFormats: Set(AudioFormat.allCases)
        )
    }

    /// The quality to use when `quality` is not available: the next lower
    /// available one, else the highest available one.
    public func fallback(for quality: DownloadQuality) -> DownloadQuality {
        guard !qualities.contains(quality) else { return quality }
        let order = DownloadQuality.allCases
        let index = order.firstIndex(of: quality) ?? order.startIndex
        if let lower = order[index...].first(where: { $0.includesVideo && qualities.contains($0) }) {
            return lower
        }
        return order.first(where: qualities.contains) ?? quality
    }
}

extension MediaFormat {
    /// yt-dlp lists storyboard images as formats; they are neither.
    var isStoryboard: Bool {
        ext == "mhtml"
    }

    /// An unknown codec (`nil`) may still be video; only `"none"` rules it out.
    var mayHaveVideo: Bool {
        guard vcodec != "none" else { return false }
        // A format with no codec info at all and an audio codec is audio.
        return vcodec != nil || height != nil || acodec == nil
    }

    var mayHaveAudio: Bool {
        acodec != "none"
    }
}
