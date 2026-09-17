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
    /// The browser `urlText` came from, while it is an auto-filled URL.
    @Published public private(set) var autoFilledBrowser: SupportedBrowser?
    /// A browser refused Dropload's Apple event (error -1743).
    @Published public private(set) var browserAccessDenied = false
    @Published public var options = DownloadOptions() {
        didSet {
            // An audio format the container cannot hold falls back to best.
            let normalized = options.normalized
            if normalized != options { options = normalized }
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
            // A link typed before yt-dlp was ready is looked up now.
            if toolStatus.isReady, !oldValue.isReady, phase == .idle, !urlText.isEmpty {
                fetchInfo()
            }
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
    private var browserIsWatching = false
    private var browserReadTask: Task<Void, Never>?
    /// What auto-fill replaced, restored when the new URL is unsupported.
    private var beforeAutoFill: AutoFillSnapshot?
    /// Whether yt-dlp could handle a URL, for the last 50 URLs seen.
    private var verdicts = VerdictCache(capacity: 50)
    private var work: Task<Void, Never>?
    /// Files yt-dlp said it was writing, so a cancelled download can take its
    /// half-written `.part` files with it instead of leaving them behind.
    private var destinations: [URL] = []
    private var infoTask: Task<Void, Never>?
    /// The metadata of the URL in the bar, kept while a download runs so
    /// cancelling returns to `.ready`.
    @Published public private(set) var info: MediaInfo?
    /// How long typing has to pause before the URL is looked up.
    var fetchDebounce: Duration = .milliseconds(600)
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
        updateBrowserWatching()
    }

    func stop() {
        work?.cancel()
        work = nil
        infoTask?.cancel()
        infoTask = nil
        toolTask?.cancel()
        toolTask = nil
        isUpdatingTools = false
        ytDlp?.cancelAll()
        removePartialFiles()
        browser?.stop()
        browserIsWatching = false
        browserReadTask?.cancel()
        browserReadTask = nil
        beforeAutoFill = nil
        _ = host?.shelf.setHoldsOpen(false)
        if isBusy { phase = info.map(Phase.ready) ?? .idle }
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
        autoFilledBrowser = nil
        beforeAutoFill = nil
        guard !isDownloading else { return }
        infoTask?.cancel()
        infoTask = nil
        info = nil
        phase = .idle
        availability = .unrestricted
        guard Self.webURL(from: text) != nil else { return }
        let delay = fetchDebounce
        infoTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.fetchInfo()
        }
    }

    /// The shelf or the takeover appeared: read the browser now, so the URL
    /// is the one in front of the user at the moment the shelf opens.
    public func refreshFromBrowser() {
        guard browserIsWatching, let browser, browserReadTask == nil else { return }
        browserReadTask = Task { [weak self] in
            let outcome = await browser.currentURL()
            guard let self, !Task.isCancelled else { return }
            self.browserReadTask = nil
            self.browserDidRead(outcome)
        }
    }

    func browserDidRead(_ outcome: BrowserReadOutcome) {
        switch outcome {
        case .url(let url, let source):
            if browserAccessDenied { browserAccessDenied = false }
            browserDidReport(url, from: source)
        case .notAuthorized:
            browserAccessDenied = true
        case .nothing:
            break
        }
    }

    /// The browser provider saw a URL.
    func browserDidReport(_ url: URL, from source: SupportedBrowser) {
        let decision = Self.autoFillDecision(
            for: url,
            currentText: urlText,
            urlWasTyped: urlWasTyped,
            isBusy: isBusy,
            toolsReady: toolStatus.isReady,
            verdict: verdicts[url.absoluteString]
        )
        guard decision == .fill else { return }
        if beforeAutoFill == nil {
            beforeAutoFill = AutoFillSnapshot(
                text: urlText, phase: phase, info: info, availability: availability, browser: autoFilledBrowser
            )
        }
        infoTask?.cancel()
        infoTask = nil
        urlText = url.absoluteString
        urlWasTyped = false
        autoFilledBrowser = source
        info = nil
        availability = .unrestricted
        phase = .idle
        fetchInfo()
    }

    /// Whether an URL the browser reported goes into the bar.
    enum AutoFillDecision: Equatable {
        case fill
        case skip
    }

    static func autoFillDecision(
        for url: URL,
        currentText: String,
        urlWasTyped: Bool,
        isBusy: Bool,
        toolsReady: Bool,
        verdict: Bool?
    ) -> AutoFillDecision {
        guard !urlWasTyped, !isBusy, toolsReady else { return .skip }
        guard BrowserURLProvider.acceptedURL(from: url.absoluteString) != nil else { return .skip }
        guard url.absoluteString != currentText.trimmingCharacters(in: .whitespacesAndNewlines) else { return .skip }
        // A page already known to be unsupported is not tried again.
        guard verdict != false else { return .skip }
        return .fill
    }

    /// Starts or stops the browser provider to match the toggle and the
    /// `apple-events` grant.
    private func updateBrowserWatching() {
        guard let host, let browser else { return }
        let wanted = autoFillFromBrowser && host.isGranted(.appleEvents)
        guard wanted != browserIsWatching else { return }
        browserIsWatching = wanted
        if wanted {
            browser.start { [weak self] outcome in self?.browserDidRead(outcome) }
            host.log.info("Browser auto-fill on")
        } else {
            browser.stop()
            browserReadTask?.cancel()
            browserReadTask = nil
            host.log.info("Browser auto-fill off")
        }
    }

    /// Looks up the URL in the bar with `yt-dlp -J`: `.fetchingInfo`, then
    /// `.ready`, `.unsupported` or `.failed`. Narrows `availability` and steps
    /// the quality down when the source cannot reach it.
    public func fetchInfo() {
        guard !isDownloading, let url = Self.webURL(from: urlText) else { return }
        guard let ytDlp, toolStatus.isReady else { return }
        infoTask?.cancel()
        let requested = urlText
        phase = .fetchingInfo
        infoTask = Task { [weak self] in
            let outcome: Result<MediaInfo, Error>
            do {
                outcome = .success(try await ytDlp.fetchInfo(for: url))
            } catch {
                outcome = .failure(error)
            }
            guard let self, !Task.isCancelled, self.urlText == requested, !self.isDownloading else { return }
            self.infoTask = nil
            self.finishLookup(outcome, for: requested)
        }
    }

    /// Records the verdict, and for an auto-filled URL yt-dlp cannot use,
    /// puts the bar back the way it was without a warning.
    func finishLookup(_ outcome: Result<MediaInfo, Error>, for text: String) {
        switch outcome {
        case .success: verdicts[text] = true
        case .failure(YtDlpError.unsupportedURL): verdicts[text] = false
        default: break
        }
        guard autoFilledBrowser != nil else {
            applyInfo(outcome)
            return
        }
        switch outcome {
        case .success:
            beforeAutoFill = nil
            applyInfo(outcome)
        case .failure(YtDlpError.cancelled), .failure(is CancellationError):
            break
        case .failure:
            restoreBeforeAutoFill()
        }
    }

    private func restoreBeforeAutoFill() {
        let snapshot = beforeAutoFill ?? AutoFillSnapshot(
            text: "", phase: .idle, info: nil, availability: .unrestricted, browser: nil
        )
        beforeAutoFill = nil
        urlText = snapshot.text
        autoFilledBrowser = snapshot.browser
        info = snapshot.info
        availability = snapshot.availability
        phase = snapshot.phase == .fetchingInfo ? .idle : snapshot.phase
    }

    func applyInfo(_ outcome: Result<MediaInfo, Error>) {
        switch outcome {
        case .success(let fetched):
            self.info = fetched
            let availability = FormatAvailability(info: fetched)
            self.availability = availability
            let quality = availability.fallback(for: options.quality)
            if quality != options.quality { options.quality = quality }
            phase = .ready(fetched)
        case .failure(YtDlpError.unsupportedURL):
            info = nil
            availability = .unrestricted
            phase = .unsupported
        case .failure(YtDlpError.cancelled), .failure(is CancellationError):
            break
        case .failure(let error):
            info = nil
            availability = .unrestricted
            phase = .failed(error.localizedDescription)
        }
    }

    /// Downloads the URL in the bar into `downloadFolder`, holding the shelf
    /// open while it runs.
    public func startDownload() {
        guard canDownload, let ytDlp, let host, let url = Self.webURL(from: urlText) else { return }
        let folder = downloadFolder
        guard Self.isWritableFolder(folder) else {
            phase = .failed("Dropload cannot write to \(folder.path)")
            return
        }
        infoTask?.cancel()
        infoTask = nil
        work?.cancel()
        _ = host.shelf.setHoldsOpen(true)
        destinations = []
        phase = .downloading(fraction: 0, speed: nil, eta: nil)
        let events = ytDlp.download(url, options: options, into: folder)
        work = Task { [weak self] in
            var finalFile: URL?
            var failure: Error?
            do {
                for try await event in events {
                    guard let self, !Task.isCancelled else { return }
                    switch event {
                    case .destination(let file):
                        self.destinations.append(file)
                    case .progress(let fraction, let speed, let eta):
                        self.phase = .downloading(fraction: fraction, speed: speed, eta: eta)
                    case .postProcessing:
                        self.phase = .postProcessing
                    case .finished(let file):
                        finalFile = file
                    }
                }
            } catch {
                failure = error
            }
            guard let self, !Task.isCancelled else { return }
            self.work = nil
            _ = self.host?.shelf.setHoldsOpen(false)
            if let finalFile {
                self.destinations = []
                self.phase = .finished(finalFile)
                // Auto-fill picks up the next page again.
                self.urlWasTyped = false
            } else if let failure, failure as? YtDlpError != .cancelled {
                self.removePartialFiles()
                self.phase = .failed(failure.localizedDescription)
            } else {
                self.removePartialFiles()
                self.phase = self.info.map(Phase.ready) ?? .idle
            }
        }
    }

    /// Stops the running download and goes back to the ready state.
    public func cancelDownload() {
        guard isBusy else { return }
        work?.cancel()
        work = nil
        ytDlp?.cancelAll()
        _ = host?.shelf.setHoldsOpen(false)
        removePartialFiles()
        phase = info.map(Phase.ready) ?? .idle
    }

    /// Clears the `.part` files the stopped download left in the folder.
    ///
    /// Only the sidecars of the paths yt-dlp itself announced, never a path
    /// Dropload guessed at, and never a finished stream: a cancelled download
    /// should not leave a growing pile in the user's Downloads folder, and it
    /// should not take anything else with it either.
    private func removePartialFiles() {
        let files = destinations.flatMap(YtDlpClient.partialFiles(for:))
        destinations = []
        guard !files.isEmpty else { return }
        Task.detached(priority: .utility) {
            for file in files {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }

    /// Shows the downloaded file in Finder.
    public func revealDownloadedFile() {
        guard case .finished(let file) = phase else { return }
        host?.workspace.revealInFinder(file)
    }

    /// Replaces the bar with the pasteboard's text, when it holds a web link.
    public func pasteURL(_ text: String?) {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return }
        userEditedURL(text)
    }

    private var isDownloading: Bool {
        switch phase {
        case .downloading, .postProcessing: true
        default: false
        }
    }

    /// A download is running (or winding down).
    public var isBusy: Bool { isDownloading || work != nil }

    static func webURL(from text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              url.host?.isEmpty == false
        else { return nil }
        return url
    }

    static func isWritableFolder(_ folder: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
            && FileManager.default.isWritableFile(atPath: folder.path)
    }

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

    /// Stores a new download folder. Returns `false` (and keeps the old one)
    /// when Dropload cannot write there.
    @discardableResult
    public func setDownloadFolder(_ folder: URL) -> Bool {
        guard Self.isWritableFolder(folder) else {
            downloadFolderMessage = "Dropload cannot write to \(folder.lastPathComponent)"
            return false
        }
        host?.preferences.setValue(folder.path, forKey: PreferenceKey.downloadFolder)
        downloadFolderMessage = nil
        objectWillChange.send()
        return true
    }

    /// Why the last folder choice was refused, for Settings.
    @Published public private(set) var downloadFolderMessage: String?

    public var downloadFolderIsWritable: Bool { Self.isWritableFolder(downloadFolder) }

    public var autoFillFromBrowser: Bool {
        get { host?.preferences.value(forKey: PreferenceKey.autoFillFromBrowser, default: true) ?? true }
        set {
            host?.preferences.setValue(newValue, forKey: PreferenceKey.autoFillFromBrowser)
            objectWillChange.send()
            updateBrowserWatching()
            if newValue { refreshFromBrowser() }
        }
    }

    /// Whether Droppy granted the `apple-events` capability.
    public var appleEventsGranted: Bool { host?.isGranted(.appleEvents) ?? false }

    /// The Automation permission as Settings shows it. A browser that refused
    /// an Apple event counts as denied.
    public var automationStatus: DropletPermissionStatus {
        guard let host else { return .unavailable }
        if browserAccessDenied { return .denied }
        return host.permissions.status(for: .appleEvents)
    }

    /// Asks for Automation. Only called from the Settings "Allow" button.
    public func requestAutomation() {
        guard let host else { return }
        Task { [weak self] in
            let status = await host.permissions.request(.appleEvents)
            guard let self else { return }
            if status == .granted { self.browserAccessDenied = false }
            self.objectWillChange.send()
            self.refreshFromBrowser()
        }
    }

    public func openAutomationSettings() {
        host?.permissions.openSystemSettings(for: .appleEvents)
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
        guard toolStatus.isReady, Self.webURL(from: urlText) != nil, work == nil else { return false }
        switch phase {
        case .downloading, .postProcessing, .fetchingInfo, .unsupported: return false
        default: return true
        }
    }
}

/// The bar as it was before an auto-fill replaced it.
struct AutoFillSnapshot {
    let text: String
    let phase: DownloadModel.Phase
    let info: MediaInfo?
    let availability: FormatAvailability
    let browser: SupportedBrowser?
}

/// A small most-recently-set map from URL to "yt-dlp can handle it".
struct VerdictCache {
    let capacity: Int
    private var values: [String: Bool] = [:]
    private var order: [String] = []

    init(capacity: Int) { self.capacity = capacity }

    var count: Int { values.count }

    subscript(key: String) -> Bool? {
        get { values[key] }
        set {
            order.removeAll { $0 == key }
            guard let newValue else {
                values[key] = nil
                return
            }
            values[key] = newValue
            order.append(key)
            while order.count > capacity {
                values[order.removeFirst()] = nil
            }
        }
    }
}
