//
//  TranscriptTests.swift
//  DownloadyTests
//
//  The text picker: what it puts on the yt-dlp command line, which language
//  it asks for, and what the local transcript writes.
//

import Foundation
import Testing

@testable import Downloady

@Suite struct TranscriptOptionTests {
    @Test func offWritesNoSubtitleArguments() {
        #expect(DownloadOptions().subtitleArguments(language: "en").isEmpty)
        #expect(DownloadOptions(transcript: .transcribe).subtitleArguments(language: "en").isEmpty)
    }

    @Test func subtitlesAskForOneLanguageAndSrt() {
        let args = DownloadOptions(transcript: .subtitles).subtitleArguments(language: "fr")
        #expect(args.contains("--write-subs"))
        // YouTube's captions are usually automatic; without this most videos
        // would write nothing.
        #expect(args.contains("--write-auto-subs"))
        #expect(args.contains("fr,-live_chat"))
        #expect(args.contains("srt"))
    }

    @Test func downloadArgumentsCarryTheSubtitleRequest() {
        let args = YtDlpCommand.download(
            URL(string: "https://youtu.be/a")!,
            options: DownloadOptions(transcript: .subtitles),
            folder: URL(fileURLWithPath: "/tmp"),
            ffmpeg: nil,
            subtitleLanguage: "de"
        )
        #expect(args.contains("--write-subs"))
        #expect(args.contains("de,-live_chat"))
    }

    @Test func summarySaysWhatTextTheDownloadWrites() {
        #expect(DownloadOptions(transcript: .subtitles).summary.hasSuffix("with subtitles"))
        #expect(DownloadOptions(transcript: .transcribe).summary.hasSuffix("with a transcript"))
        #expect(!DownloadOptions().summary.contains("with"))
    }

    @Test func storedOptionsFromBeforeTheTextPickerAreOff() throws {
        let json = #"{"quality":"p720","container":"mp4","audio":"m4a","audioQuality":"k192"}"#
        let options = try JSONDecoder().decode(DownloadOptions.self, from: Data(json.utf8))
        #expect(options.transcript == .off)
    }
}

@Suite struct SubtitleLanguageTests {
    private func info(subtitles: [String], automatic: [String] = [], language: String? = nil) -> MediaInfo {
        MediaInfo(
            id: "a",
            title: "A",
            extractorKey: "Youtube",
            formats: nil,
            subtitles: Dictionary(uniqueKeysWithValues: subtitles.map { ($0, [SubtitleTrack(ext: "vtt")]) }),
            automaticCaptions: Dictionary(uniqueKeysWithValues: automatic.map { ($0, [SubtitleTrack(ext: "vtt")]) }),
            language: language
        )
    }

    @Test func liveChatIsNotASubtitleTrack() {
        #expect(!info(subtitles: ["live_chat"]).hasSubtitles)
        #expect(info(subtitles: ["live_chat", "en"]).hasSubtitles)
    }

    @Test func automaticCaptionsCount() {
        #expect(info(subtitles: [], automatic: ["en"]).hasSubtitles)
    }

    @Test func picksTheFirstLanguageTheUserReads() {
        let media = info(subtitles: ["en", "fr", "de"])
        #expect(media.subtitleLanguage(preferring: ["fr", "en"]) == "fr")
        #expect(media.subtitleLanguage(preferring: ["es", "de"]) == "de")
    }

    @Test func regionalTracksMatchTheBareCode() {
        #expect(info(subtitles: ["fr-FR"]).subtitleLanguage(preferring: ["fr"]) == "fr-FR")
        #expect(info(subtitles: ["en-US"]).subtitleLanguage(preferring: ["en-GB"]) == "en-US")
    }

    @Test func fallsBackToTheMediasOwnLanguageThenEnglish() {
        #expect(info(subtitles: ["it", "en"], language: "it").subtitleLanguage(preferring: ["ja"]) == "it")
        #expect(info(subtitles: ["it", "en"]).subtitleLanguage(preferring: ["ja"]) == "en")
        #expect(info(subtitles: ["it"]).subtitleLanguage(preferring: ["ja"]) == "it")
    }

    @Test func withoutAnySubtitlesItStillAnswers() {
        #expect(info(subtitles: []).subtitleLanguage(preferring: ["fr"]) == "en")
    }
}

@Suite struct SubRipTests {
    @Test func timecodesAreSubRip() {
        #expect(SubRip.timecode(0) == "00:00:00,000")
        #expect(SubRip.timecode(3661.5) == "01:01:01,500")
        // A negative start is a clock that never goes backwards.
        #expect(SubRip.timecode(-1) == "00:00:00,000")
    }

    @Test func cuesAreNumberedFromOne() {
        let text = SubRip.text(for: [
            TranscriptCue(start: 0, end: 1.5, text: "Hello"),
            TranscriptCue(start: 1.5, end: 3, text: "there"),
        ])
        #expect(text.hasPrefix("1\n00:00:00,000 --> 00:00:01,500\nHello\n"))
        #expect(text.contains("2\n00:00:01,500 --> 00:00:03,000\nthere\n"))
    }

    @Test func theTranscriptSitsBesideTheMedia() {
        let media = URL(fileURLWithPath: "/tmp/Some video [abc].mp4")
        #expect(SpeechTranscriptionService.transcriptURL(for: media).lastPathComponent == "Some video [abc].srt")
    }

    @Test func audioIsExtractedAsSixteenKilohertzMono() {
        let args = SpeechTranscriptionService.audioArguments(
            input: URL(fileURLWithPath: "/tmp/a.mkv"),
            output: URL(fileURLWithPath: "/tmp/a.wav")
        )
        #expect(args.contains("-vn"))
        #expect(args.contains("16000"))
        #expect(args.contains("pcm_s16le"))
    }
}
