import Foundation
import Testing
@testable import Downloady

@Suite struct DownloadOptionsTests {
    @Test func bestVideoMergesIntoContainer() {
        let args = DownloadOptions(quality: .best, container: .mkv).ytDlpArguments
        #expect(args == ["-f", "bv*+ba/b", "--merge-output-format", "mkv", "--remux-video", "mkv"])
    }

    @Test func heightCeilingFiltersAndSorts() {
        let options = DownloadOptions(quality: .p1080, container: .mp4, audio: .m4a)
        #expect(options.formatSelector == "bv*[height<=1080]+ba/b[height<=1080]/bv*+ba/b")
        #expect(options.formatSort == "res:1080,vext:mp4,aext:m4a")
    }

    @Test func audioOnlyExtracts() {
        let args = DownloadOptions(quality: .audioOnly, container: .mp4, audio: .mp3).ytDlpArguments
        #expect(args == ["-f", "ba/b", "-S", "aext:mp3", "-x", "--audio-format", "mp3"])
    }

    @Test func originalContainerIsNotRemuxed() {
        let args = DownloadOptions(quality: .p720).ytDlpArguments
        #expect(!args.contains("--merge-output-format"))
        #expect(!args.contains("--remux-video"))
    }

    @Test func bitrateCapsTheStreamWithoutReencoding() {
        let video = DownloadOptions(quality: .p1080, container: .mp4, audioQuality: .k128)
        #expect(video.formatSelector == "bv*[height<=1080]+ba[abr<=128]/bv*[height<=1080]+ba/b[height<=1080]/bv*+ba/b")
        #expect(!video.ytDlpArguments.contains("--audio-quality"))

        let original = DownloadOptions(quality: .audioOnly, audioQuality: .k192)
        #expect(original.ytDlpArguments == ["-f", "ba[abr<=192]/ba/b", "-x", "--audio-format", "best"])
    }

    @Test func bitrateIsTheEncodingRateWhenConverting() {
        let args = DownloadOptions(quality: .audioOnly, audio: .mp3, audioQuality: .k192).ytDlpArguments
        #expect(args == ["-f", "ba/b", "-S", "aext:mp3", "-x", "--audio-format", "mp3", "--audio-quality", "192K"])
    }

    @Test func losslessIgnoresTheBitrate() {
        let options = DownloadOptions(quality: .audioOnly, audio: .flac, audioQuality: .k128)
        #expect(!options.usesAudioQuality)
        #expect(!options.ytDlpArguments.contains("--audio-quality"))
    }

    @Test func readsOptionsStoredBeforeBitrateAndOriginal() throws {
        let stored = #"{"quality":"p720","container":"mp4","audio":"best"}"#.data(using: .utf8)!
        let options = try JSONDecoder().decode(DownloadOptions.self, from: stored)
        #expect(options == DownloadOptions(quality: .p720, container: .mp4, audio: .original, audioQuality: .best))
    }

    @Test func audioTheContainerCannotHoldFallsBackToOriginal() {
        let options = DownloadOptions(quality: .p720, container: .mp4, audio: .flac)
        #expect(options.normalized.audio == .original)
        #expect(!options.ytDlpArguments.contains("flac"))
    }

    @Test func everyAudioFormatIsAvailableForAudioOnly() {
        for format in AudioFormat.allCases {
            #expect(format.isAvailable(with: .audioOnly, container: .webm))
        }
    }

    @Test func browserTableMatchesByBundleID() {
        #expect(SupportedBrowser.matching(bundleID: "com.apple.Safari")?.family == .safari)
        #expect(SupportedBrowser.matching(bundleID: "company.thebrowser.Browser")?.family == .chromium)
        #expect(SupportedBrowser.matching(bundleID: "org.mozilla.firefox") == nil)
    }
}
