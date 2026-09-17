//
//  MediaInfo.swift
//  Dropload
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

    enum CodingKeys: String, CodingKey {
        case id, title, duration, thumbnail, formats
        case extractorKey = "extractor_key"
        case webpageURL = "webpage_url"
    }

    public init(
        id: String,
        title: String,
        extractorKey: String?,
        webpageURL: String? = nil,
        duration: Double? = nil,
        thumbnail: String? = nil,
        formats: [MediaFormat]?
    ) {
        self.id = id
        self.title = title
        self.extractorKey = extractorKey
        self.webpageURL = webpageURL
        self.duration = duration
        self.thumbnail = thumbnail
        self.formats = formats
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
    /// TODO(T2): implement. Rules to follow:
    /// - A height preset is available when some video format reaches at least
    ///   that height; `best` whenever any video exists; `audioOnly` whenever
    ///   any audio exists.
    /// - Containers stay available (ffmpeg remuxes), audio formats stay
    ///   available (ffmpeg converts); only qualities are really restricted.
    /// - No formats at all -> `.unrestricted`.
    public init(info: MediaInfo) {
        self = .unrestricted
    }
}
