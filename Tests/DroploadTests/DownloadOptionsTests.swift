import Testing
@testable import Dropload

@Suite struct DownloadOptionsTests {
    @Test func bestVideoMergesIntoContainer() {
        let args = DownloadOptions(quality: .best, container: .mkv, audio: .best).ytDlpArguments
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

    @Test func audioTheContainerCannotHoldFallsBackToBest() {
        let options = DownloadOptions(quality: .p720, container: .mp4, audio: .flac)
        #expect(options.normalized.audio == .best)
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
