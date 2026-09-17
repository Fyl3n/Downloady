//
//  BrowserURLProvider.swift
//  Dropload
//
//  Reads the front tab's URL from the frontmost browser, so the URL bar can
//  fill itself in. Uses Apple events (`apple-events` capability); the first
//  read per browser triggers macOS's Automation prompt.
//
//  Firefox has no AppleScript dictionary for tabs and is not supported.
//

import AppKit
import Foundation

/// A browser the droplet knows how to ask for its current URL.
public struct SupportedBrowser: Equatable, Sendable {
    public enum Family: Sendable {
        /// `URL of front document`
        case safari
        /// `URL of active tab of front window`
        case chromium
    }

    public let bundleID: String
    public let name: String
    public let family: Family

    /// The AppleScript that returns the front tab's URL.
    public var script: String {
        switch family {
        case .safari:
            "tell application id \"\(bundleID)\" to return URL of front document"
        case .chromium:
            "tell application id \"\(bundleID)\" to return URL of active tab of front window"
        }
    }

    public static let all: [SupportedBrowser] = [
        SupportedBrowser(bundleID: "com.apple.Safari", name: "Safari", family: .safari),
        SupportedBrowser(bundleID: "com.apple.SafariTechnologyPreview", name: "Safari Technology Preview", family: .safari),
        SupportedBrowser(bundleID: "com.google.Chrome", name: "Chrome", family: .chromium),
        SupportedBrowser(bundleID: "com.google.Chrome.beta", name: "Chrome Beta", family: .chromium),
        SupportedBrowser(bundleID: "com.google.Chrome.canary", name: "Chrome Canary", family: .chromium),
        SupportedBrowser(bundleID: "company.thebrowser.Browser", name: "Arc", family: .chromium),
        SupportedBrowser(bundleID: "company.thebrowser.dia", name: "Dia", family: .chromium),
        SupportedBrowser(bundleID: "com.brave.Browser", name: "Brave", family: .chromium),
        SupportedBrowser(bundleID: "com.microsoft.edgemac", name: "Edge", family: .chromium),
        SupportedBrowser(bundleID: "com.vivaldi.Vivaldi", name: "Vivaldi", family: .chromium),
        SupportedBrowser(bundleID: "com.operasoftware.Opera", name: "Opera", family: .chromium),
        SupportedBrowser(bundleID: "org.chromium.Chromium", name: "Chromium", family: .chromium)
    ]

    public static func matching(bundleID: String?) -> SupportedBrowser? {
        guard let bundleID else { return nil }
        return all.first { $0.bundleID == bundleID }
    }
}

/// What one read of the browser's front tab produced.
public enum BrowserReadOutcome: Equatable, Sendable {
    /// An http(s) URL from `browser`.
    case url(URL, SupportedBrowser)
    /// Nothing usable: no remembered browser, not running, no window, or not
    /// an http(s) page.
    case nothing
    /// macOS refused the Apple event (error -1743).
    case notAuthorized(SupportedBrowser)

    public var url: URL? {
        if case .url(let url, _) = self { return url }
        return nil
    }
}

@MainActor
public protocol BrowserURLProviding: AnyObject {
    /// Reads the front tab of the most recent frontmost supported browser.
    func currentURL() async -> BrowserReadOutcome

    /// Starts calling `onChange` with a read whenever a supported browser
    /// becomes frontmost. `stop()` tears it down.
    func start(onChange: @escaping @MainActor (BrowserReadOutcome) -> Void)

    func stop()
}

/// The real implementation.
///
/// Remembers the most recent frontmost supported browser (opening Droppy's
/// shelf does not activate Droppy, and an activation of Droppy itself is
/// ignored), and reads its front tab with `NSAppleScript` on a private serial
/// queue, never on the main actor. A browser that is no longer running is
/// never asked, so a read cannot launch it. Reads are coalesced: while one is
/// running, callers share it, and each activation starts at most one.
@MainActor
public final class BrowserURLProvider: BrowserURLProviding {
    private let log: @MainActor (String) -> Void
    private var observer: NSObjectProtocol?
    private var onChange: (@MainActor (BrowserReadOutcome) -> Void)?
    private var activationTask: Task<Void, Never>?
    private var inFlight: Task<BrowserReadOutcome, Never>?
    /// The most recent frontmost supported browser.
    public private(set) var lastBrowser: SupportedBrowser?

    nonisolated private static let queue = DispatchQueue(label: "dropload.browser-url", qos: .userInitiated)

    public init(log: @escaping @MainActor (String) -> Void) {
        self.log = log
    }

    public func currentURL() async -> BrowserReadOutcome {
        if let inFlight { return await inFlight.value }
        guard let browser = lastBrowser else { return .nothing }
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: browser.bundleID).isEmpty else {
            return .nothing
        }
        log("Reading the front tab of \(browser.name)")
        let script = browser.script
        let task = Task { () -> BrowserReadOutcome in
            let result = await Self.runScript(script)
            return Self.outcome(for: result, browser: browser)
        }
        inFlight = task
        let outcome = await task.value
        inFlight = nil
        if case .notAuthorized = outcome {
            log("\(browser.name) refused the Apple event: Automation is not allowed")
        }
        return outcome
    }

    public func start(onChange: @escaping @MainActor (BrowserReadOutcome) -> Void) {
        stop()
        self.onChange = onChange
        remember(NSWorkspace.shared.frontmostApplication)
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let bundleID = app?.bundleIdentifier
            MainActor.assumeIsolated {
                self?.applicationDidActivate(bundleID: bundleID)
            }
        }
    }

    public func stop() {
        if let observer {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        observer = nil
        onChange = nil
        activationTask?.cancel()
        activationTask = nil
    }

    private func remember(_ app: NSRunningApplication?) {
        if let browser = SupportedBrowser.matching(bundleID: app?.bundleIdentifier) {
            lastBrowser = browser
        }
    }

    private func applicationDidActivate(bundleID: String?) {
        // Droppy itself (or anything that is not a browser) keeps the last one.
        guard bundleID != Bundle.main.bundleIdentifier,
              let browser = SupportedBrowser.matching(bundleID: bundleID)
        else { return }
        lastBrowser = browser
        // One read per activation; a newer activation replaces a pending one.
        activationTask?.cancel()
        activationTask = Task { [weak self] in
            guard let self else { return }
            let outcome = await self.currentURL()
            guard !Task.isCancelled else { return }
            self.onChange?(outcome)
        }
    }

    // MARK: AppleScript

    /// The raw result of one script run.
    enum ScriptResult: Equatable, Sendable {
        case string(String?)
        case error(Int)
    }

    nonisolated private static func runScript(_ source: String) async -> ScriptResult {
        await withCheckedContinuation { continuation in
            queue.async {
                var errorInfo: NSDictionary?
                let descriptor = NSAppleScript(source: source)?.executeAndReturnError(&errorInfo)
                if let errorInfo {
                    let number = (errorInfo[NSAppleScript.errorNumber] as? NSNumber)?.intValue ?? 0
                    continuation.resume(returning: .error(number))
                } else {
                    continuation.resume(returning: .string(descriptor?.stringValue))
                }
            }
        }
    }

    /// Error -1743: the user (or the system) has not allowed Automation.
    nonisolated static let notAuthorizedError = -1743
    /// Error -600: the application is not running.
    nonisolated static let notRunningError = -600

    nonisolated static func outcome(for result: ScriptResult, browser: SupportedBrowser) -> BrowserReadOutcome {
        switch result {
        case .string(let text):
            guard let url = acceptedURL(from: text) else { return .nothing }
            return .url(url, browser)
        case .error(notAuthorizedError):
            return .notAuthorized(browser)
        case .error:
            // -600 (not running), -1728 (no window) and the rest: nothing to read.
            return .nothing
        }
    }

    /// The URL when `text` is an http or https address with a host.
    nonisolated static func acceptedURL(from text: String?) -> URL? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines),
              let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              url.host?.isEmpty == false
        else { return nil }
        return url
    }
}
