//
//  DownloadModel.swift
//  Dropload
//
//  The one piece of state every surface draws: the URL bar, the pickers, the
//  tools, and the download in flight. The widget, the takeover and the
//  settings pane all observe the same instance.
//

import Combine
import DroppyKit
import Foundation

/// Keys in `host.preferences` (namespaced by the host to `droplet.dropload.*`).
public enum PreferenceKey {
    public static let options = "options"
    public static let downloadFolder = "downloadFolder"
    public static let autoFillFromBrowser = "autoFillFromBrowser"
    public static let customYtDlpPath = "customYtDlpPath"
    public static let customFFmpegPath = "customFFmpegPath"
}

@MainActor
public final class DownloadModel: ObservableObject {
    public enum Phase: Equatable {
        case idle
        case fetchingInfo
        case ready(MediaInfo)
        case unsupported
        case downloading(fraction: Double, speed: String?, eta: String?)
        case postProcessing
        case finished(URL)
        case failed(String)
    }

    /// What is in the URL bar.
    @Published public var urlText = ""
    /// Whether the user typed `urlText` (auto-fill never overwrites it).
    @Published public private(set) var urlWasTyped = false
    @Published public var options = DownloadOptions() {
        didSet {
            guard options != oldValue else { return }
            host?.preferences.setValue(options, forKey: PreferenceKey.options)
        }
    }
    @Published public private(set) var availability = FormatAvailability.unrestricted
    @Published public private(set) var phase: Phase = .idle
    @Published public private(set) var toolStatus: ToolStatus = .unknown

    private var host: DropletHost?
    private var tools: ToolManaging?
    private var ytDlp: YtDlpRunning?
    private var browser: BrowserURLProviding?
    private var work: Task<Void, Never>?

    public init() {}

    // MARK: Lifecycle

    func start(host: DropletHost) {
        self.host = host
        options = host.preferences.value(forKey: PreferenceKey.options, default: DownloadOptions())

        let logger = host.log
        let tools = ToolManager(containerDirectory: host.environment.containerDirectory) { logger.info($0) }
        self.tools = tools
        self.ytDlp = YtDlpClient(tools: { [weak self] in self?.toolStatus ?? .unknown }) { logger.info($0) }
        self.browser = BrowserURLProvider { logger.info($0) }

        work = Task { [weak self] in
            let status = await tools.resolve()
            self?.toolStatus = status
        }

        // TODO(T3): start the browser provider when `autoFillFromBrowser` is on
        // and `apple-events` is granted, feeding `browserDidReport(_:)`.
    }

    func stop() {
        work?.cancel()
        work = nil
        ytDlp?.cancelAll()
        browser?.stop()
        _ = host?.shelf.setHoldsOpen(false)
        tools = nil
        ytDlp = nil
        browser = nil
        host = nil
    }

    // MARK: Intents

    /// The user edited the URL bar.
    public func userEditedURL(_ text: String) {
        urlText = text
        urlWasTyped = !text.isEmpty
        phase = .idle
        availability = .unrestricted
        // TODO(T2): debounce, then `fetchInfo()`.
    }

    /// The browser provider saw a new URL.
    func browserDidReport(_ url: URL) {
        guard !urlWasTyped, url.absoluteString != urlText else { return }
        urlText = url.absoluteString
        // TODO(T3): fetch info; if `.unsupported`, clear the bar again.
    }

    /// TODO(T2): run `ytDlp.fetchInfo`, set `phase` to `.ready` / `.unsupported`
    /// / `.failed`, derive `availability`, and fold `options` into it.
    public func fetchInfo() {}

    /// TODO(T2): run the download into the download folder, map events to
    /// `phase`, hold the shelf open while it runs, reveal the file at the end.
    public func startDownload() {}

    /// TODO(T2): cancel the download task and the process.
    public func cancelDownload() {}

    /// TODO(T1): run `tools.installMissing`, driving `toolStatus`.
    public func installTools() {}

    // MARK: Settings

    /// The folder downloads land in. Defaults to ~/Downloads.
    public var downloadFolder: URL {
        if let path = host?.preferences.value(forKey: PreferenceKey.downloadFolder, as: String.self) {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Downloads")
    }

    public var autoFillFromBrowser: Bool {
        get { host?.preferences.value(forKey: PreferenceKey.autoFillFromBrowser, default: true) ?? true }
        set {
            host?.preferences.setValue(newValue, forKey: PreferenceKey.autoFillFromBrowser)
            objectWillChange.send()
        }
    }

    public var canDownload: Bool {
        guard toolStatus.isReady, URL(string: urlText)?.scheme?.hasPrefix("http") == true else { return false }
        switch phase {
        case .downloading, .postProcessing, .fetchingInfo, .unsupported: return false
        default: return true
        }
    }
}
