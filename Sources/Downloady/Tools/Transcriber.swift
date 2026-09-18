//
//  Transcriber.swift
//  Downloady
//
//  Local transcription, for media a site has no subtitles for. macOS 26's
//  `SpeechAnalyzer` does the work on this Mac; ffmpeg turns the downloaded
//  file into the audio it wants. Nothing leaves the machine, and nothing runs
//  on the main actor.
//

import AVFoundation
import Foundation
import Speech

public enum TranscriptionError: Error, Equatable, Sendable, LocalizedError {
    /// macOS is older than 26, where `SpeechAnalyzer` arrived.
    case unsupportedSystem
    /// The user has not allowed speech recognition for Droppy.
    case notAuthorized
    /// Extracting the audio needs ffmpeg, and there is none.
    case needsFFmpeg
    /// ffmpeg could not read the media.
    case audioExtractionFailed(String)
    /// Apple has no speech model for any language this Mac can use.
    case noSpeechModel
    case speechFailed(String)
    case emptyTranscript
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .unsupportedSystem: "Transcribing needs macOS 26 or later"
        case .notAuthorized: "Allow speech recognition for Droppy to transcribe"
        case .needsFFmpeg: "Transcribing needs ffmpeg"
        case .audioExtractionFailed(let message):
            message.isEmpty ? "The audio could not be read" : message
        case .noSpeechModel: "macOS has no speech model for this language"
        case .speechFailed(let message):
            message.isEmpty ? "Transcribing failed" : message
        case .emptyTranscript: "No speech was found in this media"
        case .cancelled: "Cancelled"
        }
    }
}

/// What a running transcription reports.
public enum TranscriptionEvent: Equatable, Sendable {
    /// macOS is fetching the speech model for the language. Once per language.
    case preparing
    /// 0...1, measured against the media's duration.
    case progress(Double)
}

@MainActor
public protocol Transcribing: AnyObject {
    /// Whether this Mac can transcribe at all (macOS 26 or later).
    nonisolated var isSupported: Bool { get }

    /// Transcribes `media` and writes a `.srt` beside it. `duration` is the
    /// media's length in seconds, used for progress. Cancelling the consuming
    /// task stops ffmpeg and the analyzer.
    func transcribe(
        media: URL,
        duration: Double?,
        ffmpeg: URL?,
        onEvent: @escaping @MainActor (TranscriptionEvent) -> Void
    ) async throws -> URL

    /// Stops everything. Called from `deactivate()`.
    func cancelAll()
}

/// The real implementation.
@MainActor
public final class SpeechTranscriptionService: Transcribing {
    private let log: @MainActor (String) -> Void
    private var running: [ObjectIdentifier: ChildProcess] = [:]

    public init(log: @escaping @MainActor (String) -> Void) {
        self.log = log
    }

    public nonisolated var isSupported: Bool {
        if #available(macOS 26, *) { true } else { false }
    }

    public func transcribe(
        media: URL,
        duration: Double?,
        ffmpeg: URL?,
        onEvent: @escaping @MainActor (TranscriptionEvent) -> Void
    ) async throws -> URL {
        guard #available(macOS 26, *) else { throw TranscriptionError.unsupportedSystem }
        guard let ffmpeg else { throw TranscriptionError.needsFFmpeg }

        let audio = FileManager.default.temporaryDirectory
            .appendingPathComponent("downloady-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: audio) }

        try await extractAudio(from: media, to: audio, ffmpeg: ffmpeg)
        if Task.isCancelled { throw TranscriptionError.cancelled }

        log("Transcribing \(media.lastPathComponent) on this Mac")
        let cues = try await SpeechRun.run(
            audio: audio,
            duration: duration,
            onEvent: { event in Task { @MainActor in onEvent(event) } }
        )
        if Task.isCancelled { throw TranscriptionError.cancelled }
        guard !cues.isEmpty else { throw TranscriptionError.emptyTranscript }

        let destination = Self.transcriptURL(for: media)
        try SubRip.text(for: cues).write(to: destination, atomically: true, encoding: .utf8)
        return destination
    }

    public func cancelAll() {
        for child in running.values { child.terminate() }
        running.removeAll()
    }

    /// Where the `.srt` goes: beside the media, same name.
    public nonisolated static func transcriptURL(for media: URL) -> URL {
        media.deletingPathExtension().appendingPathExtension("srt")
    }

    // MARK: ffmpeg

    /// 16 kHz mono PCM, which is what the speech models want and what keeps
    /// the temporary file small.
    nonisolated static func audioArguments(input: URL, output: URL) -> [String] {
        [
            "-nostdin", "-y", "-loglevel", "error",
            "-i", input.path,
            "-vn", "-ac", "1", "-ar", "16000",
            "-c:a", "pcm_s16le",
            output.path,
        ]
    }

    private func extractAudio(from media: URL, to audio: URL, ffmpeg: URL) async throws {
        let child = ChildProcess(executable: ffmpeg, arguments: Self.audioArguments(input: media, output: audio))
        let key = ObjectIdentifier(child)
        running[key] = child
        defer { running[key] = nil }

        let exit: ChildProcess.Exit = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                child.start(collectStdout: true, onLine: { _ in }) { result in
                    continuation.resume(with: result.map(\.0))
                }
            }
        } onCancel: {
            child.terminate()
        }

        if Task.isCancelled || child.wasTerminated { throw TranscriptionError.cancelled }
        guard exit.status == 0 else {
            let message = YtDlpCommand.errorMessage(fromStderr: exit.stderr)
            log("ffmpeg could not extract the audio (\(exit.status)): \(message)")
            throw TranscriptionError.audioExtractionFailed(message)
        }
    }
}

// MARK: - Speech

/// One line of the written transcript.
public struct TranscriptCue: Equatable, Sendable {
    public let start: Double
    public let end: Double
    public let text: String

    public init(start: Double, end: Double, text: String) {
        self.start = start
        self.end = end
        self.text = text
    }
}

/// The macOS 26 speech pass, kept behind its availability so nothing else in
/// the droplet has to care which macOS it is running on.
@available(macOS 26, *)
enum SpeechRun {
    static func run(
        audio: URL,
        duration: Double?,
        onEvent: @escaping @Sendable (TranscriptionEvent) -> Void
    ) async throws -> [TranscriptCue] {
        let locale = try await bestLocale()
        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: []
        )
        try await install(transcriber, onEvent: onEvent)

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let collector = Task { () -> [TranscriptCue] in
            var cues: [TranscriptCue] = []
            for try await result in transcriber.results {
                let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                let start = result.range.start.seconds
                let end = (result.range.start + result.range.duration).seconds
                guard !text.isEmpty, start.isFinite, end.isFinite else { continue }
                cues.append(TranscriptCue(start: start, end: max(end, start + 0.5), text: text))
                if let duration, duration > 0 {
                    onEvent(.progress(min(max(end / duration, 0), 1)))
                }
            }
            return cues
        }

        do {
            let file = try AVAudioFile(forReading: audio)
            _ = try await analyzer.analyzeSequence(from: file)
            try await analyzer.finalizeAndFinishThroughEndOfInput()
        } catch {
            collector.cancel()
            await analyzer.cancelAndFinishNow()
            throw wrap(error)
        }

        do {
            return try await collector.value
        } catch {
            throw wrap(error)
        }
    }

    /// The language the transcript is in: the Mac's own language when a model
    /// supports it, else English, else whatever is supported.
    private static func bestLocale() async throws -> Locale {
        let supported = await SpeechTranscriber.supportedLocales
        guard !supported.isEmpty else { throw TranscriptionError.noSpeechModel }
        let wanted = Locale.preferredLanguages.map { Locale(identifier: $0) } + [Locale.current]
        for locale in wanted {
            if let match = await SpeechTranscriber.supportedLocale(equivalentTo: locale) { return match }
        }
        if let english = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en-US")) {
            return english
        }
        return supported[0]
    }

    /// macOS keeps the speech models outside the app. The first run for a
    /// language fetches one.
    private static func install(
        _ transcriber: SpeechTranscriber,
        onEvent: @escaping @Sendable (TranscriptionEvent) -> Void
    ) async throws {
        do {
            guard let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) else {
                return
            }
            onEvent(.preparing)
            try await request.downloadAndInstall()
        } catch {
            throw wrap(error)
        }
    }

    private static func wrap(_ error: Error) -> Error {
        if error is CancellationError { return TranscriptionError.cancelled }
        if let known = error as? TranscriptionError { return known }
        return TranscriptionError.speechFailed(error.localizedDescription)
    }
}

// MARK: - SubRip

/// Writes the cues as a `.srt`, the subtitle format every player and every
/// text editor already reads, and the one `--convert-subs srt` produces for
/// the subtitles path, so both paths leave the same kind of file.
public enum SubRip {
    public static func text(for cues: [TranscriptCue]) -> String {
        cues.enumerated().map { index, cue in
            "\(index + 1)\n\(timecode(cue.start)) --> \(timecode(cue.end))\n\(cue.text)\n"
        }
        .joined(separator: "\n")
    }

    /// `HH:MM:SS,mmm`.
    public static func timecode(_ seconds: Double) -> String {
        let clamped = max(seconds, 0)
        let total = Int(clamped)
        let milliseconds = Int(((clamped - Double(total)) * 1000).rounded())
        return String(
            format: "%02d:%02d:%02d,%03d",
            total / 3600, (total % 3600) / 60, total % 60, min(milliseconds, 999)
        )
    }
}
