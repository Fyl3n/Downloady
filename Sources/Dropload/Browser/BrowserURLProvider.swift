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

@MainActor
public protocol BrowserURLProviding: AnyObject {
    /// The front tab's http(s) URL of the frontmost supported browser, or
    /// `nil` (not a browser, no window, permission denied, not http(s)).
    func currentURL() async -> URL?

    /// Starts calling `onChange` with the browser's URL whenever a supported
    /// browser becomes frontmost. Returns nothing; `stop()` tears it down.
    func start(onChange: @escaping @MainActor (URL) -> Void)

    func stop()
}

/// The real implementation.
///
/// TODO(T3): implement.
/// - Watch `NSWorkspace.didActivateApplicationNotification`. Droppy's own
///   shelf opening does not make Droppy frontmost, so also remember the last
///   frontmost *browser* and read it when the widget appears.
/// - Run `NSAppleScript` off the main thread; handle error -1743 (not
///   authorised) by reporting it so Settings can offer
///   `host.permissions.openSystemSettings(for: .appleEvents)`.
/// - Only accept http/https URLs; debounce; never overwrite a URL the user
///   typed (the model decides that, not this type).
@MainActor
public final class BrowserURLProvider: BrowserURLProviding {
    private let log: @MainActor (String) -> Void

    public init(log: @escaping @MainActor (String) -> Void) {
        self.log = log
    }

    public func currentURL() async -> URL? {
        nil
    }

    public func start(onChange: @escaping @MainActor (URL) -> Void) {
        log("BrowserURLProvider.start not implemented yet")
    }

    public func stop() {}
}
