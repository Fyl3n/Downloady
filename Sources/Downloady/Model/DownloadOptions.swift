//
//  DownloadOptions.swift
//  Downloady
//
//  The four pickers, and how a choice turns into yt-dlp arguments.
//  Pure value types, no host and no process: this is the part the tests pin.
//

import Foundation

/// The quality picker: a height ceiling, or audio only.
public enum DownloadQuality: String, CaseIterable, Codable, Identifiable, Sendable {
    case best
    case p2160
    case p1440
    case p1080
    case p720
    case p480
    case audioOnly

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .best: "Best"
        case .p2160: "2160p"
        case .p1440: "1440p"
        case .p1080: "1080p"
        case .p720: "720p"
        case .p480: "480p"
        case .audioOnly: "Audio only"
        }
    }

    /// The height ceiling, or `nil` for no ceiling (best) and for audio only.
    public var maxHeight: Int? {
        switch self {
        case .p2160: 2160
        case .p1440: 1440
        case .p1080: 1080
        case .p720: 720
        case .p480: 480
        case .best, .audioOnly: nil
        }
    }

    public var includesVideo: Bool { self != .audioOnly }
}

/// The video format picker: the container the result is merged or remuxed
/// into, or the site's own.
public enum VideoContainer: String, CaseIterable, Codable, Identifiable, Sendable {
    /// No remux: whatever container yt-dlp downloads or merges into.
    case original
    case mp4
    case mkv
    case webm

    public var id: String { rawValue }
    public var title: String { self == .original ? "Original" : rawValue }
}

/// The audio format picker.
///
/// With audio only, this is the format the audio is extracted to (`-x`);
/// `original` keeps the stream as the site serves it. With video, it is a
/// preference for the audio stream that gets merged, so only formats the
/// container can hold without re-encoding are offered
/// (see ``isAvailable(with:container:)``).
public enum AudioFormat: String, CaseIterable, Codable, Identifiable, Sendable {
    case original
    case m4a
    case mp3
    case opus
    case flac
    case wav

    public var id: String { rawValue }

    public var title: String {
        self == .original ? "Original" : rawValue
    }

    /// Lossless formats have no bitrate to pick.
    public var isLossless: Bool { self == .flac || self == .wav }

    /// Reads the pre-1.1 `"best"`, which meant the same thing.
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = raw == "best" ? .original : (AudioFormat(rawValue: raw) ?? .original)
    }

    /// Whether this choice makes sense for the given quality and container.
    public func isAvailable(with quality: DownloadQuality, container: VideoContainer) -> Bool {
        guard quality.includesVideo else { return true }
        switch container {
        case .mp4: return [.original, .m4a].contains(self)
        case .webm: return [.original, .opus].contains(self)
        case .mkv, .original: return [.original, .m4a, .opus].contains(self)
        }
    }
}

/// The audio quality picker: a bitrate ceiling.
///
/// Converting to a lossy format, it is the encoding bitrate. Otherwise it caps
/// the audio stream yt-dlp picks, with no re-encoding. Lossless formats
/// ignore it.
public enum AudioQuality: String, CaseIterable, Codable, Identifiable, Sendable {
    case best
    case k320
    case k256
    case k192
    case k128

    public var id: String { rawValue }

    public var kbps: Int? {
        switch self {
        case .best: nil
        case .k320: 320
        case .k256: 256
        case .k192: 192
        case .k128: 128
        }
    }

    public var title: String { kbps.map { "\($0) kbps" } ?? "Best" }
}

/// The text picker: whether a download also produces a `.srt` beside the
/// media, and where its text comes from.
public enum TranscriptMode: String, CaseIterable, Codable, Identifiable, Sendable {
    /// No text file. The default.
    case off
    /// The subtitles the site already has, written by yt-dlp.
    case subtitles
    /// Transcribed on this Mac, for media with no subtitles. macOS 26 or later.
    case transcribe

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .off: "Off"
        case .subtitles: "Subtitles"
        case .transcribe: "Transcribe"
        }
    }

    /// What the picker row says under the pickers, and the queue row shows.
    public var shortTitle: String {
        switch self {
        case .off: "No text"
        case .subtitles: "subtitles"
        case .transcribe: "transcript"
        }
    }

    public var writesSubtitles: Bool { self == .subtitles }
    public var transcribesLocally: Bool { self == .transcribe }
}

/// Everything the pickers say, together.
public struct DownloadOptions: Codable, Equatable, Sendable {
    public var quality: DownloadQuality
    public var container: VideoContainer
    public var audio: AudioFormat
    public var audioQuality: AudioQuality
    /// Whether the download also writes a `.srt`, and from where.
    public var transcript: TranscriptMode

    public init(
        quality: DownloadQuality = .best,
        container: VideoContainer = .original,
        audio: AudioFormat = .original,
        audioQuality: AudioQuality = .best,
        transcript: TranscriptMode = .off
    ) {
        self.quality = quality
        self.container = container
        self.audio = audio
        self.audioQuality = audioQuality
        self.transcript = transcript
    }

    enum CodingKeys: String, CodingKey {
        case quality, container, audio, audioQuality, transcript
    }

    /// Stored options from before a field existed fall back to its default.
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            quality: try values.decodeIfPresent(DownloadQuality.self, forKey: .quality) ?? .best,
            container: try values.decodeIfPresent(VideoContainer.self, forKey: .container) ?? .original,
            audio: try values.decodeIfPresent(AudioFormat.self, forKey: .audio) ?? .original,
            audioQuality: try values.decodeIfPresent(AudioQuality.self, forKey: .audioQuality) ?? .best,
            transcript: try values.decodeIfPresent(TranscriptMode.self, forKey: .transcript) ?? .off
        )
    }

    /// The same options with any combination the pickers cannot express
    /// folded back to a valid one (an audio format the container cannot hold
    /// becomes `.original`).
    public var normalized: DownloadOptions {
        var copy = self
        if !copy.audio.isAvailable(with: copy.quality, container: copy.container) {
            copy.audio = .original
        }
        return copy
    }

    /// Whether the audio is re-encoded: audio only, into a format other than
    /// the original.
    public var convertsAudio: Bool {
        !quality.includesVideo && audio != .original
    }

    /// Whether the bitrate picker means anything: not for lossless output.
    public var usesAudioQuality: Bool {
        !(convertsAudio && audio.isLossless)
    }

    /// The bitrate that caps which audio stream is picked, when the audio is
    /// not re-encoded.
    var audioStreamCap: Int? {
        usesAudioQuality && !convertsAudio ? audioQuality.kbps : nil
    }

    /// What the pickers will produce, in plain words, e.g.
    /// "1080p mp4, m4a audio up to 128 kbps" or "mp3 audio only, 192 kbps".
    public var summary: String {
        let options = normalized
        let bitrate = options.usesAudioQuality ? options.audioQuality.kbps : nil
        let audioName = options.audio == .original ? "original" : options.audio.rawValue
        let text: String
        if options.quality.includesVideo {
            let quality = options.quality == .best ? "best" : options.quality.title
            let video = options.container == .original ? "\(quality) video" : "\(quality) \(options.container.rawValue)"
            text = "\(video), \(audioName) audio" + (bitrate.map { " up to \($0) kbps" } ?? "")
        } else if let bitrate {
            text = options.convertsAudio
                ? "\(audioName) audio only, \(bitrate) kbps"
                : "\(audioName) audio only, up to \(bitrate) kbps"
        } else {
            text = "\(audioName) audio only"
        }
        let withText = text + transcriptSuffix
        // Sentence case, but a format name keeps its own spelling ("mp3").
        guard withText.hasPrefix("best") || withText.hasPrefix("original") else { return withText }
        return withText.prefix(1).uppercased() + withText.dropFirst()
    }

    private var transcriptSuffix: String {
        switch transcript {
        case .off: ""
        case .subtitles: ", with subtitles"
        case .transcribe: ", with a transcript"
        }
    }

    /// The subtitle arguments, for the language the runner picked.
    ///
    /// `--write-auto-subs` is what makes this work on YouTube, where most
    /// videos only have machine-written captions; `--convert-subs srt` gives
    /// one format whatever the site serves. The live chat "subtitle" track is
    /// never what the user asked for.
    public func subtitleArguments(language: String) -> [String] {
        guard transcript.writesSubtitles else { return [] }
        return [
            "--write-subs", "--write-auto-subs",
            "--sub-langs", "\(language),-live_chat",
            "--convert-subs", "srt",
        ]
    }

    /// The `-f` format selector.
    public var formatSelector: String {
        let options = normalized
        let audio = options.audioStreamCap.map { "ba[abr<=\($0)]" } ?? "ba"
        var choices: [String]
        if options.quality.includesVideo {
            let height = options.quality.maxHeight
            let video = height.map { "bv*[height<=\($0)]" } ?? "bv*"
            choices = ["\(video)+\(audio)", "\(video)+ba"]
            if let height { choices.append("b[height<=\(height)]") }
            choices += ["bv*+ba", "b"]
        } else {
            choices = [audio, "ba", "b"]
        }
        var seen = Set<String>()
        return choices.filter { seen.insert($0).inserted }.joined(separator: "/")
    }

    /// The `-S` sort, which steers the pick toward what the container and the
    /// audio picker asked for without making it a hard filter.
    public var formatSort: String? {
        let options = normalized
        var fields: [String] = []
        if options.quality.includesVideo {
            if let height = options.quality.maxHeight { fields.append("res:\(height)") }
            switch options.container {
            case .mp4: fields.append("vext:mp4")
            case .webm: fields.append("vext:webm")
            case .mkv, .original: break
            }
        }
        switch options.audio {
        case .m4a: fields.append("aext:m4a")
        case .opus: fields.append("aext:opus")
        case .mp3: fields.append("aext:mp3")
        case .original, .flac, .wav: break
        }
        return fields.isEmpty ? nil : fields.joined(separator: ",")
    }

    /// The format and post-processing arguments, without the URL, the output
    /// template, or the tool locations. The runner adds those.
    public var ytDlpArguments: [String] {
        let options = normalized
        var args = ["-f", options.formatSelector]
        if let sort = options.formatSort {
            args += ["-S", sort]
        }
        if options.quality.includesVideo {
            if options.container != .original {
                args += ["--merge-output-format", options.container.rawValue,
                         "--remux-video", options.container.rawValue]
            }
        } else {
            // `best` keeps the codec and only unwraps the audio.
            args += ["-x", "--audio-format", options.audio == .original ? "best" : options.audio.rawValue]
            if options.convertsAudio, options.usesAudioQuality, let kbps = options.audioQuality.kbps {
                args += ["--audio-quality", "\(kbps)K"]
            }
        }
        return args
    }
}
