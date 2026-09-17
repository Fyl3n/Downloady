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
    /// Set once the user pressed Install; from then on a missing yt-dlp is
    /// reinstalled on activation without asking again.
    public static let toolsInstallRequested = "toolsInstallRequested"
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
    @Published public private(set) var toolStatus: ToolStatus = .unknown {
        didSet {
            if case .installing = toolStatus { return }
            detectedFFmpeg = toolStatus.ffmpeg ?? tools?.locateFFmpeg()
        }
    }
    /// ffmpeg as Settings shows it: from `toolStatus` when ready, otherwise
    /// looked up on its own so a missing yt-dlp does not hide it.
    @Published public private(set) var detectedFFmpeg: ToolLocation?
    /// An update check is running.
    @Published public private(set) var isUpdatingTools = false
    /// The outcome of the last update check, for Settings.
    @Published public private(set) var toolUpdateMessage: String?

    private var host: DropletHost?
    private var tools: ToolManaging?
    private var ytDlp: YtDlpRunning?
    private var browser: BrowserURLProviding?
    private var work: Task<Void, Never>?
    private var toolTask: Task<Void, Never>?

    public init() {}

    // MARK: Lifecycle

    func start(host: DropletHost) {
        self.host = host
        options = host.preferences.value(forKey: PreferenceKey.options, default: DownloadOptions())

        let logger = host.log
        let tools = ToolManager(
            containerDirectory: host.environment.containerDirectory,
            customPaths: { [weak self] in (self?.customYtDlpPath, self?.customFFmpegPath) },
            networkGranted: { [weak self] in self?.canUseNetwork ?? false },
            log: { logger.info($0) }
        )
        self.tools = tools
        self.ytDlp = YtDlpClient(tools: { [weak self] in self?.toolStatus ?? .unknown }) { logger.info($0) }
        self.browser = BrowserURLProvider { logger.info($0) }

        let installRequested = host.preferences.value(forKey: PreferenceKey.toolsInstallRequested, default: false)
        toolTask = Task { [weak self] in
            let status = await tools.resolve()
            guard let self, !Task.isCancelled else { return }
            self.toolStatus = status
            self.toolTask = nil
            // Never download silently the first time: only once the user asked.
            if status == .missing, installRequested {
                self.installTools()
            }
        }

        // TODO(T3): start the browser provider when `autoFillFromBrowser` is on
        // and `apple-events` is granted, feeding `browserDidReport(_:)`.
    }

    func stop() {
        work?.cancel()
        work = nil
        toolTask?.cancel()
        toolTask = nil
        isUpdatingTools = false
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

    /// Downloads the missing tools, driving `toolStatus` through
    /// `.installing(progress:)` to `.ready` or `.failed`.
    public func installTools() {
        guard let tools, let host, toolTask == nil else { return }
        host.preferences.setValue(true, forKey: PreferenceKey.toolsInstallRequested)
        guard canUseNetwork else {
            toolStatus = .failed("Allow network access and downloads for Dropload")
            return
        }
        toolUpdateMessage = nil
        toolStatus = .installing(progress: 0)
        toolTask = Task { [weak self] in
            let result: ToolStatus
            do {
                result = try await tools.installMissing { fraction in
                    // Late progress hops must not overwrite the final status.
                    guard let self, case .installing = self.toolStatus else { return }
                    self.toolStatus = .installing(progress: fraction)
                }
            } catch is CancellationError {
                return
            } catch {
                result = .failed(error.localizedDescription)
            }
            guard let self, !Task.isCancelled else { return }
            self.toolStatus = result
            self.toolTask = nil
        }
    }

    /// Reinstalls the managed yt-dlp when GitHub has a newer release.
    public func updateYtDlp() {
        guard let tools, toolTask == nil else { return }
        guard canUseNetwork else {
            toolUpdateMessage = "Allow network access and downloads for Dropload"
            return
        }
        let before = toolStatus.ytDlp?.version
        isUpdatingTools = true
        toolUpdateMessage = nil
        toolTask = Task { [weak self] in
            var message: String?
            var result: ToolStatus?
            do {
                let status = try await tools.updateYtDlp()
                result = status
                let after = status.ytDlp?.version
                message = after == before ? "Up to date" : "Updated to \(after ?? "the latest release")"
            } catch is CancellationError {
                return
            } catch {
                message = error.localizedDescription
            }
            guard let self, !Task.isCancelled else { return }
            if let result { self.toolStatus = result }
            self.toolUpdateMessage = message
            self.isUpdatingTools = false
            self.toolTask = nil
        }
    }

    /// Looks the tools up again, e.g. after a custom path changed.
    public func refreshTools() {
        guard let tools, toolTask == nil else { return }
        toolTask = Task { [weak self] in
            let status = await tools.resolve()
            guard let self, !Task.isCancelled else { return }
            self.toolStatus = status
            self.toolTask = nil
        }
    }

    private var canUseNetwork: Bool {
        guard let host else { return false }
        return host.isGranted(.networkClient) && host.isGranted(.downloads)
    }

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

    public var customYtDlpPath: String? {
        get { host?.preferences.value(forKey: PreferenceKey.customYtDlpPath, as: String.self) }
        set { setCustomPath(newValue, forKey: PreferenceKey.customYtDlpPath) }
    }

    public var customFFmpegPath: String? {
        get { host?.preferences.value(forKey: PreferenceKey.customFFmpegPath, as: String.self) }
        set { setCustomPath(newValue, forKey: PreferenceKey.customFFmpegPath) }
    }

    private func setCustomPath(_ path: String?, forKey key: String) {
        let trimmed = path?.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = trimmed?.isEmpty == false ? trimmed : nil
        guard value != host?.preferences.value(forKey: key, as: String.self) else { return }
        host?.preferences.setValue(value, forKey: key)
        objectWillChange.send()
        refreshTools()
    }

    public var canDownload: Bool {
        guard toolStatus.isReady, URL(string: urlText)?.scheme?.hasPrefix("http") == true else { return false }
        switch phase {
        case .downloading, .postProcessing, .fetchingInfo, .unsupported: return false
        default: return true
        }
    }
}
