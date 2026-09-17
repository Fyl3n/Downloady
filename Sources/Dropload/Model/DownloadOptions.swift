//
//  DownloadOptions.swift
//  Dropload
//
//  The three pickers, and how a choice turns into yt-dlp arguments.
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

/// The video picker: the container the result is merged or remuxed into.
public enum VideoContainer: String, CaseIterable, Codable, Identifiable, Sendable {
    case mp4
    case mkv
    case webm

    public var id: String { rawValue }
    public var title: String { rawValue }
}

/// The audio picker.
///
/// With audio only, this is the format the audio is extracted to (`-x`).
/// With video, it is a preference for the audio stream that gets merged, so
/// only formats the container can hold without re-encoding are offered
/// (see ``isAvailable(with:)``).
public enum AudioFormat: String, CaseIterable, Codable, Identifiable, Sendable {
    case best
    case m4a
    case mp3
    case opus
    case flac
    case wav

    public var id: String { rawValue }

    public var title: String {
        self == .best ? "Best" : rawValue
    }

    /// Whether this choice makes sense for the given quality and container.
    public func isAvailable(with quality: DownloadQuality, container: VideoContainer) -> Bool {
        guard quality.includesVideo else { return true }
        switch container {
        case .mp4: return [.best, .m4a].contains(self)
        case .webm: return [.best, .opus].contains(self)
        case .mkv: return [.best, .m4a, .opus].contains(self)
        }
    }
}

/// Everything the three pickers say, together.
public struct DownloadOptions: Codable, Equatable, Sendable {
    public var quality: DownloadQuality
    public var container: VideoContainer
    public var audio: AudioFormat

    public init(quality: DownloadQuality = .best, container: VideoContainer = .mp4, audio: AudioFormat = .best) {
        self.quality = quality
        self.container = container
        self.audio = audio
    }

    /// The same options with any combination the pickers cannot express
    /// folded back to a valid one (an audio format the container cannot hold
    /// becomes `.best`).
    public var normalized: DownloadOptions {
        var copy = self
        if !copy.audio.isAvailable(with: copy.quality, container: copy.container) {
            copy.audio = .best
        }
        return copy
    }

    /// What the pickers will produce, in plain words, e.g.
    /// "1080p mp4 with m4a audio" or "mp3 audio only".
    public var summary: String {
        let options = normalized
        let audio = options.audio == .best ? "the best" : options.audio.rawValue
        switch options.quality {
        case .audioOnly:
            return options.audio == .best ? "Best audio only" : "\(options.audio.rawValue) audio only"
        case .best:
            return "Best quality \(options.container.rawValue) with \(audio) audio"
        default:
            return "\(options.quality.title) \(options.container.rawValue) with \(audio) audio"
        }
    }

    /// The `-f` format selector.
    public var formatSelector: String {
        let options = normalized
        switch options.quality {
        case .audioOnly:
            return "ba/b"
        default:
            if let height = options.quality.maxHeight {
                return "bv*[height<=\(height)]+ba/b[height<=\(height)]/bv*+ba/b"
            }
            return "bv*+ba/b"
        }
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
            case .mkv: break
            }
        }
        switch options.audio {
        case .m4a: fields.append("aext:m4a")
        case .opus: fields.append("aext:opus")
        case .mp3: fields.append("aext:mp3")
        case .best, .flac, .wav: break
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
            args += ["--merge-output-format", options.container.rawValue,
                     "--remux-video", options.container.rawValue]
        } else {
            args += ["-x", "--audio-format", options.audio.rawValue]
        }
        return args
    }
}
