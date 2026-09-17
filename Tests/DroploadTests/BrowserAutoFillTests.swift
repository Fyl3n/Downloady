import Foundation
import Testing
@testable import Dropload

@Suite struct SupportedBrowserTests {
    @Test func matchesKnownBundleIDs() {
        #expect(SupportedBrowser.matching(bundleID: "com.apple.Safari")?.family == .safari)
        #expect(SupportedBrowser.matching(bundleID: "com.google.Chrome")?.name == "Chrome")
        #expect(SupportedBrowser.matching(bundleID: "company.thebrowser.Browser")?.name == "Arc")
        #expect(SupportedBrowser.matching(bundleID: "company.thebrowser.Browser")?.family == .chromium)
    }

    @Test func ignoresUnsupportedApps() {
        #expect(SupportedBrowser.matching(bundleID: "org.mozilla.firefox") == nil)
        #expect(SupportedBrowser.matching(bundleID: "com.apple.finder") == nil)
        #expect(SupportedBrowser.matching(bundleID: "com.apple.safari") == nil)
        #expect(SupportedBrowser.matching(bundleID: nil) == nil)
    }

    @Test func scriptsAddressTheBrowserByID() {
        let safari = SupportedBrowser.matching(bundleID: "com.apple.Safari")!
        #expect(safari.script == "tell application id \"com.apple.Safari\" to return URL of front document")
        let arc = SupportedBrowser.matching(bundleID: "company.thebrowser.Browser")!
        #expect(arc.script.hasSuffix("URL of active tab of front window"))
    }
}

@Suite struct BrowserURLFilterTests {
    @Test func acceptsHTTPAndHTTPS() {
        #expect(BrowserURLProvider.acceptedURL(from: "https://www.youtube.com/watch?v=jNQXAC9IVRw") != nil)
        #expect(BrowserURLProvider.acceptedURL(from: " http://example.com/a \n")?.absoluteString == "http://example.com/a")
        #expect(BrowserURLProvider.acceptedURL(from: "HTTPS://example.com") != nil)
    }

    @Test func rejectsEverythingElse() {
        for text in ["file:///Users/me/a.mp4", "about:blank", "favorites://", "chrome://newtab/",
                     "arc://start", "javascript:alert(1)", "", "missing value", "https://", "not a url"] {
            #expect(BrowserURLProvider.acceptedURL(from: text) == nil, "\(text)")
        }
        #expect(BrowserURLProvider.acceptedURL(from: nil) == nil)
    }

    @Test func mapsScriptResults() {
        let safari = SupportedBrowser.all[0]
        let url = URL(string: "https://example.com/v")!
        #expect(BrowserURLProvider.outcome(for: .string(url.absoluteString), browser: safari) == .url(url, safari))
        #expect(BrowserURLProvider.outcome(for: .string("file:///tmp/x"), browser: safari) == .nothing)
        #expect(BrowserURLProvider.outcome(for: .string(nil), browser: safari) == .nothing)
        #expect(BrowserURLProvider.outcome(for: .error(-1743), browser: safari) == .notAuthorized(safari))
        #expect(BrowserURLProvider.outcome(for: .error(-600), browser: safari) == .nothing)
        #expect(BrowserURLProvider.outcome(for: .error(-1728), browser: safari) == .nothing)
    }
}

@MainActor
@Suite struct AutoFillDecisionTests {
    let video = URL(string: "https://www.youtube.com/watch?v=abc")!

    private func decide(
        _ url: URL? = nil,
        text: String = "",
        typed: Bool = false,
        busy: Bool = false,
        ready: Bool = true,
        verdict: Bool? = nil
    ) -> DownloadModel.AutoFillDecision {
        DownloadModel.autoFillDecision(
            for: url ?? video, currentText: text, urlWasTyped: typed,
            isBusy: busy, toolsReady: ready, verdict: verdict
        )
    }

    @Test func fillsAnEmptyOrAutoFilledBar() {
        #expect(decide() == .fill)
        #expect(decide(text: "https://vimeo.com/1") == .fill)
        #expect(decide(verdict: true) == .fill)
    }

    @Test func neverReplacesATypedURL() {
        #expect(decide(text: "https://vimeo.com/1", typed: true) == .skip)
    }

    @Test func skipsTheSameURL() {
        #expect(decide(text: video.absoluteString) == .skip)
        #expect(decide(text: " \(video.absoluteString) ") == .skip)
    }

    @Test func skipsWhileBusyOrWithoutYtDlp() {
        #expect(decide(busy: true) == .skip)
        #expect(decide(ready: false) == .skip)
    }

    @Test func skipsKnownUnsupportedPages() {
        #expect(decide(URL(string: "https://example.com")!, verdict: false) == .skip)
    }

    @Test func skipsNonWebURLs() {
        #expect(decide(URL(string: "file:///tmp/a.mp4")!) == .skip)
    }

    @Test func clearingTheFieldResumesAutoFill() {
        let model = DownloadModel()
        model.userEditedURL("https://vimeo.com/1")
        #expect(model.urlWasTyped)
        model.userEditedURL("")
        #expect(!model.urlWasTyped)
        #expect(model.autoFilledBrowser == nil)
    }
}

@Suite struct VerdictCacheTests {
    @Test func keepsTheMostRecent() {
        var cache = VerdictCache(capacity: 50)
        for index in 0..<60 { cache["u\(index)"] = index.isMultiple(of: 2) }
        #expect(cache.count == 50)
        #expect(cache["u9"] == nil)
        #expect(cache["u10"] == true)
        #expect(cache["u59"] == false)
    }

    @Test func refreshingAKeyMovesItToTheEnd() {
        var cache = VerdictCache(capacity: 2)
        cache["a"] = true
        cache["b"] = true
        cache["a"] = false
        cache["c"] = true
        #expect(cache["b"] == nil)
        #expect(cache["a"] == false)
        #expect(cache.count == 2)
    }
}
