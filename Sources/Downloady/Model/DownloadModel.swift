//
//  DownloadModel.swift
//  Downloady
//
//  The one piece of state every surface draws: the URL bar, the pickers, the
//  tools, and the download in flight. The widget, the takeover and the
//  settings pane all observe the same instance.
//

import AppKit
import Combine
import DroppyKit
import Foundation

/// Keys in `host.preferences` (namespaced by the host to `droplet.downloady.*`).
public enum PreferenceKey {
    /// The default format and quality, what every new download starts on.
    /// (The key predates the split between the default and the current one.)
    public static let options = "options"
    public static let downloadFolder = "downloadFolder"
    public static let autoFillFromBrowser = "autoFillFromBrowser"
    /// `BackgroundTabCheck` raw value. Unset: `.always`.
    public static let backgroundTabCheck = "backgroundTabCheck"
    /// `[bundle ID: allowed]`, what macOS last said about each browser.
    public static let browserPermissions = "browserPermissions"
    public static let customYtDlpPath = "customYtDlpPath"
    public static let customFFmpegPath = "customFFmpegPath"
    /// `ToolLocation.Source` raw values. Unset: yt-dlp is Downloady's copy,
    /// ffmpeg the Mac's when there is one.
    public static let ytDlpSource = "ytDlpSource"
    public static let ffmpegSource = "ffmpegSource"
}

/// When auto-fill reads the browser's tab while the shelf is closed, so the
/// link is already looked up when the shelf opens. The tab is read when a
/// browser comes to the front and polled while it stays there. Opening the
/// shelf reads the tab whatever this says.
public enum BackgroundTabCheck: String, CaseIterable, Sendable {
    /// Whenever a supported browser is in front.
    case always
    /// Only while the Downloady widget is on one of the user's shelf layouts.
    case whenWidgetOnShelf
    /// Only when the shelf opens.
    case never

    public var title: String {
        switch self {
        case .always: "Always"
        case .whenWidgetOnShelf: "Widget on shelf"
        case .never: "Never"
        }
    }

    public var systemImage: String {
        switch self {
        case .always: "arrow.triangle.2.circlepath"
        case .whenWidgetOnShelf: "square.grid.2x2"
        case .never: "pause.circle"
        }
    }

    /// Whether the browser in front is read, given whether the widget is on a
    /// shelf layout and whether a URL bar is on screen (the shelf is open, not
    /// merely the widget mounted behind a closed one).
    public func readsOnActivation(widgetOnShelf: Bool, formVisible: Bool) -> Bool {
        if formVisible { return true }
        switch self {
        case .always: return true
        case .whenWidgetOnShelf: return widgetOnShelf
        case .never: return false
        }
    }
}

@MainActor
public final class DownloadModel: ObservableObject {
    /// What the URL bar knows about the link in it. The download itself is a
    /// job in `jobs`, so the form is free the moment one starts.
    public enum Phase: Equatable {
        case idle
        case fetchingInfo
        case ready(MediaInfo)
        case unsupported
        case failed(String)
    }

    /// Something worth a HUD happened to a job.
    public enum Notice: Equatable, Sendable {
        /// The media landed.
        case downloaded(DownloadJob)
        /// The `.srt` landed, a while after the media.
        case transcribed(DownloadJob)
    }

    /// What is in the URL bar.
    @Published public var urlText = ""
    /// Whether the user typed `urlText` (auto-fill never overwrites it).
    @Published public private(set) var urlWasTyped = false
    /// The browser `urlText` came from, while it is an auto-filled URL.
    @Published public private(set) var autoFilledBrowser: SupportedBrowser?
    /// What macOS last said about each browser's Automation permission, by
    /// bundle ID: `true` allowed, `false` denied. Saved, so a browser that is
    /// not running still shows in Settings.
    @Published public private(set) var browserPermissions: [String: Bool] = [:]
    /// Running browsers macOS has not asked about yet.
    @Published public private(set) var browsersToAsk: [SupportedBrowser] = []
    /// The format of the download in the shelf. Starts on `defaultOptions`
    /// and goes back to it after each download; never saved.
    @Published public var options = DownloadOptions() {
        didSet {
            // An audio format the container cannot hold falls back to original.
            let normalized = options.normalized
            if normalized != options { options = normalized }
        }
    }
    /// The format Settings sets, saved: what every new download starts on.
    @Published public var defaultOptions = DownloadOptions() {
        didSet {
            let normalized = defaultOptions.normalized
            if normalized != defaultOptions { defaultOptions = normalized }
            guard defaultOptions != oldValue else { return }
            if defaultOptions.quality.includesVideo { lastDefaultVideoQuality = defaultOptions.quality }
            host?.preferences.setValue(defaultOptions, forKey: PreferenceKey.options)
            // The form follows a new default; jobs already queued keep theirs.
            resetOptionsToDefault()
        }
    }
    @Published public private(set) var availability = FormatAvailability.unrestricted
    @Published public private(set) var phase: Phase = .idle
    @Published public private(set) var toolStatus: ToolStatus = .unknown {
        didSet {
            if toolStatus.isReady { detectedFFmpeg = toolStatus.ffmpeg }
            // A link typed before yt-dlp was ready is looked up now.
            if toolStatus.isReady, !oldValue.isReady, phase == .idle, !urlText.isEmpty {
                fetchInfo()
            }
        }
    }
    /// ffmpeg as Settings shows it: from `toolStatus` when ready, otherwise
    /// looked up on its own so a missing yt-dlp does not hide it.
    @Published public private(set) var detectedFFmpeg: ToolLocation?
    /// What the running install is fetching, for the progress label.
    @Published public private(set) var installingTools: Set<ToolLocation.Tool> = []
    /// Why a tool's source changed or its install failed, shown in its card.
    @Published public private(set) var toolNotices: [ToolLocation.Tool: String] = [:]
    /// An update check is running.
    @Published public private(set) var isUpdatingTools = false
    /// The outcome of the last update check, for Settings.
    @Published public private(set) var toolUpdateMessage: String?
    /// The newer yt-dlp release, when one was found. Settings offers Update
    /// only while this is set.
    @Published public private(set) var ytDlpUpdate: String?

    /// The queue: everything started and not yet cleared, oldest first.
    @Published public private(set) var jobs: [DownloadJob] = []
    /// Fires when a file lands, for the completion HUD.
    public let notices = PassthroughSubject<Notice, Never>()

    private var host: DropletHost?
    private var tools: ToolManaging?
    private var ytDlp: YtDlpRunning?
    private var transcriber: Transcribing?
    private var browser: BrowserURLProviding?
    /// The download lane and the transcription lane: one job each, so a
    /// transcript can run while the next video downloads, and neither can
    /// flood the Mac.
    private var downloadTask: Task<Void, Never>?
    private var transcriptTask: Task<Void, Never>?
    /// Finished and failed jobs kept in the queue, oldest dropped first.
    static let historyLimit = 6
    private var browserIsWatching = false
    private var browserReadTask: Task<Void, Never>?
    /// What auto-fill replaced, restored when the new URL is unsupported.
    private var beforeAutoFill: AutoFillSnapshot?
    /// Whether yt-dlp could handle a URL, for the last 50 URLs seen.
    private var verdicts = VerdictCache(capacity: 50)
    /// Whether one of yt-dlp's extractors claims a URL (the quick probe), for
    /// the last 50 URLs seen.
    private var support = VerdictCache(capacity: 50)
    /// The probe of the URL auto-fill is about to put in the bar.
    private var probeTask: Task<Void, Never>?
    /// The URL `probeTask` is probing, so a poll of the same tab does not
    /// restart it.
    private var probingKey: String?
    /// The last few lookups that succeeded, by the text in the bar, so going
    /// back to a recent tab shows its card at once, without yt-dlp.
    private var recentLookups = RecentCache<MediaInfo>(capacity: 3)
    /// Thumbnails and favicons of those lookups, by image URL.
    private var images = RecentCache<PreviewImage>(capacity: 6)
    private var imageTasks: [String: Task<Void, Never>] = [:]
    /// The front tab's URL at the last read, `nil` for no web page.
    private var lastTabURL: URL?
    /// How many URL bars are on screen (the widget, the takeover).
    private var visibleForms = 0
    /// Whether the next read opens a new look at the shelf. It is set while
    /// Downloady is out of sight: a tab that changed meanwhile replaces the
    /// bar outright, while one that changes under the open shelf only
    /// replaces it with something downloadable.
    private var sessionIsFresh = true
    private var shelfObserver: AnyCancellable?
    /// The job each lane is running, so cancelling one knows whose task to
    /// cancel.
    private var currentDownloadID: UUID?
    private var currentTranscriptID: UUID?
    private var infoTask: Task<Void, Never>?
    /// The URL a quick action put in the bar, downloaded as soon as its
    /// lookup ends.
    private(set) var pendingDownload: String?
    /// The front-tab read a quick action started.
    private var quickActionTask: Task<Void, Never>?
    /// The metadata of the URL in the bar, kept while a download runs so
    /// cancelling returns to `.ready`.
    @Published public private(set) var info: MediaInfo?
    /// How long typing has to pause before the URL is looked up.
    var fetchDebounce: Duration = .milliseconds(600)
    private var toolTask: Task<Void, Never>?
    private var updateCheckTask: Task<Void, Never>?
    /// The video quality the audio-only switch returns to.
    private var lastVideoQuality: DownloadQuality = .best
    /// The same, for the default the Settings switch returns to.
    private var lastDefaultVideoQuality: DownloadQuality = .best

    public init() {}

    // MARK: Lifecycle

    func start(host: DropletHost) {
        self.host = host
        let logger = host.log
        let tools = ToolManager(
            containerDirectory: host.environment.containerDirectory,
            choices: { [weak self] in self?.toolChoices ?? ToolChoices() },
            networkGranted: { [weak self] in self?.canUseNetwork ?? false },
            log: { logger.info($0) }
        )
        self.tools = tools
        self.ytDlp = YtDlpClient(tools: { [weak self] in self?.toolStatus ?? .unknown }) { logger.info($0) }
        self.transcriber = SpeechTranscriptionService { logger.info($0) }
        self.browser = BrowserURLProvider { logger.info($0) }

        // After the transcriber and the permission are known, so the shelf
        // steps off a Transcribe default only when this Mac cannot transcribe.
        refreshSpeechStatus()
        defaultOptions = host.preferences.value(forKey: PreferenceKey.options, default: DownloadOptions())
        browserPermissions = host.preferences.value(forKey: PreferenceKey.browserPermissions, default: [String: Bool]())
        resetOptionsToDefault()

        reloadTools()
        updateBrowserWatching()
        shelfObserver = host.shelf.didChange.sink { [weak self] in
            self?.shelfDidChange()
        }
    }

    func stop() {
        downloadTask?.cancel()
        downloadTask = nil
        transcriptTask?.cancel()
        transcriptTask = nil
        infoTask?.cancel()
        infoTask = nil
        quickActionTask?.cancel()
        quickActionTask = nil
        pendingDownload = nil
        toolTask?.cancel()
        toolTask = nil
        installingTools = []
        updateCheckTask?.cancel()
        updateCheckTask = nil
        isUpdatingTools = false
        // Each download the client stops removes its own half-written files
        // once its process has exited.
        ytDlp?.cancelAll()
        transcriber?.cancelAll()
        jobs = []
        browser?.stop()
        browserIsWatching = false
        browserReadTask?.cancel()
        browserReadTask = nil
        probeTask?.cancel()
        probeTask = nil
        probingKey = nil
        imageTasks.values.forEach { $0.cancel() }
        imageTasks = [:]
        recentLookups = RecentCache(capacity: 3)
        images = RecentCache(capacity: 6)
        supportedSitesTask?.cancel()
        supportedSitesTask = nil
        shelfObserver?.cancel()
        shelfObserver = nil
        beforeAutoFill = nil
        lastTabURL = nil
        visibleForms = 0
        sessionIsFresh = true
        tools = nil
        ytDlp = nil
        transcriber = nil
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
        pendingDownload = nil
        probeTask?.cancel()
        probeTask = nil
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

    /// A URL bar came on screen (the shelf or the takeover opened): read the
    /// browser now, so the URL is the one in front of the user.
    public func formDidAppear() {
        visibleForms += 1
        refreshSpeechStatus()
        refreshFromBrowser()
    }

    /// A URL bar left the screen. With none left, Downloady is out of sight.
    public func formDidDisappear() {
        visibleForms = max(visibleForms - 1, 0)
        if visibleForms == 0 { sessionIsFresh = true }
    }

    /// The shelf closing puts Downloady out of sight even when the host keeps
    /// the widget mounted, and reopening it reads the browser again.
    private func shelfDidChange() {
        guard let host else { return }
        if !host.shelf.isExpanded {
            sessionIsFresh = true
        } else if sessionIsFresh, visibleForms > 0 {
            refreshFromBrowser()
        }
    }

    /// Reads the browser's front tab.
    public func refreshFromBrowser() {
        guard browserIsWatching, let browser, browserReadTask == nil else { return }
        browserReadTask = Task { [weak self] in
            let outcome = await browser.currentURL()
            guard let self, !Task.isCancelled else { return }
            self.browserReadTask = nil
            self.browserDidRead(outcome)
        }
    }

    // MARK: Quick actions

    /// "Download this video": reads the front tab of the browser the shortcut
    /// was pressed in and downloads it. Works with auto-fill off; it needs the
    /// `apple-events` grant and the browser's Automation permission.
    /// `audioOnly` keeps only the sound, for this download alone.
    public func downloadFrontTab(audioOnly: Bool = false) {
        guard let host, let browser else { return }
        guard host.isGranted(.appleEvents) else {
            showQuickActionProblem("Droppy does not let Downloady read your browser")
            return
        }
        browser.rememberFrontmostApplication()
        quickActionTask?.cancel()
        quickActionTask = Task { [weak self] in
            let outcome = await browser.currentURL()
            guard let self, !Task.isCancelled else { return }
            self.quickActionTask = nil
            switch outcome {
            case .url(let url, let source):
                self.record(.allowed, for: source)
                self.lastTabURL = url
                self.downloadNow(url, audioOnly: audioOnly)
            case .notAuthorized(let source):
                self.record(.denied, for: source)
                self.showQuickActionProblem("\(source.name) does not let Downloady read its tabs")
            case .nothing:
                self.showQuickActionProblem("No web page in front")
            }
        }
    }

    /// "Download the pasted video": downloads the link on the clipboard.
    /// Reads the pasteboard once, when the shortcut is pressed, the way the
    /// URL bar's paste button does. `clipboard-read` is Droppy's clipboard
    /// history, which Downloady never touches. `audioOnly` keeps only the
    /// sound, for this download alone.
    public func downloadPasted(audioOnly: Bool = false) {
        guard host != nil else { return }
        guard let text = NSPasteboard.general.string(forType: .string),
              let url = Self.webURL(from: text)
        else {
            showQuickActionProblem("The clipboard holds no link")
            return
        }
        downloadNow(url, audioOnly: audioOnly)
    }

    /// Puts `url` in the bar as if the user had typed it, looks it up, and
    /// downloads it as soon as the lookup ends. The bar then shows the job,
    /// or the reason it could not start. `audioOnly` switches the form to
    /// audio only; starting the download puts it back on the default.
    func downloadNow(_ url: URL, audioOnly: Bool = false) {
        quickActionTask?.cancel()
        quickActionTask = nil
        clearBar()
        if audioOnly { setAudioOnly(true) }
        urlText = url.absoluteString
        // Typed, so neither a browser read nor auto-fill replaces it while the
        // lookup runs, and the bar is not emptied when the takeover appears.
        urlWasTyped = true
        sessionIsFresh = false
        guard toolStatus.isReady else { return }
        pendingDownload = urlText
        fetchInfo()
    }

    /// Starts the download a quick action asked for, once its lookup ended
    /// well. A failed lookup leaves the error in the bar and starts nothing.
    private func startPendingDownload(after outcome: Result<MediaInfo, Error>, for text: String) {
        guard pendingDownload == text else { return }
        pendingDownload = nil
        guard case .success = outcome else { return }
        startDownload()
    }

    private func showQuickActionProblem(_ message: String) {
        host?.log.info("Quick action: \(message)")
        clearBar()
        // So the takeover opening does not treat the empty bar as a fresh look.
        sessionIsFresh = false
        phase = .failed(message)
    }

    /// What a read of the front tab does to the bar.
    ///
    /// - A tab that changed while Downloady was out of sight replaces the bar:
    ///   emptied, then filled once yt-dlp claims the new page. The download
    ///   started from the old page carries on in the queue.
    /// - A tab that changes while the shelf is open only replaces the bar
    ///   with a page yt-dlp claims, so a download in progress stays in view.
    /// - Either way the URL goes in only after the probe says yes.
    func browserDidRead(_ outcome: BrowserReadOutcome) {
        let tab: URL?
        switch outcome {
        case .url(let url, let source):
            record(.allowed, for: source)
            tab = url
        case .notAuthorized(let source):
            record(.denied, for: source)
            return
        case .nothing:
            tab = nil
        }
        // Without yt-dlp nothing can be judged; the tab is read again later.
        guard toolStatus.isReady else { return }
        let replaces = sessionIsFresh
        if visibleForms > 0 { sessionIsFresh = false }
        let tabChanged = tab != lastTabURL
        lastTabURL = tab
        if tabChanged, replaces { clearBar() }
        guard let tab, case .url(_, let source) = outcome else {
            probeTask?.cancel()
            probeTask = nil
            return
        }
        // An unchanged tab only refills a bar that was emptied.
        guard tabChanged || urlText.isEmpty else { return }
        browserDidReport(tab, from: source)
    }

    /// Empties the bar, as if nothing had been read or typed yet.
    private func clearBar() {
        probeTask?.cancel()
        probeTask = nil
        infoTask?.cancel()
        infoTask = nil
        beforeAutoFill = nil
        pendingDownload = nil
        urlText = ""
        urlWasTyped = false
        autoFilledBrowser = nil
        info = nil
        availability = .unrestricted
        phase = .idle
    }

    /// The browser provider saw a URL: probe it, and fill the bar if one of
    /// yt-dlp's extractors claims it.
    func browserDidReport(_ url: URL, from source: SupportedBrowser) {
        let decision = Self.autoFillDecision(
            for: url,
            currentText: urlText,
            urlWasTyped: urlWasTyped,
            toolsReady: toolStatus.isReady,
            verdict: verdicts[url.absoluteString]
        )
        let key = url.absoluteString
        // A poll of the tab being probed leaves the probe running.
        if decision == .fill, probeTask != nil, probingKey == key { return }
        probeTask?.cancel()
        probeTask = nil
        probingKey = nil
        guard decision == .fill else { return }
        if let known = support[key] {
            if known { fill(url, from: source) }
            return
        }
        guard let ytDlp else { return }
        probingKey = key
        probeTask = Task { [weak self] in
            let supported = await ytDlp.isSupported(url)
            guard let self, !Task.isCancelled else { return }
            self.probeTask = nil
            self.probingKey = nil
            self.support[key] = supported
            // The user may have typed while the probe ran.
            guard supported, !self.urlWasTyped else { return }
            self.fill(url, from: source)
        }
    }

    /// Puts a probed URL in the bar and looks it up.
    private func fill(_ url: URL, from source: SupportedBrowser) {
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

    /// A download in flight is no reason to skip: it runs in the queue, and
    /// the bar is free for the next page.
    static func autoFillDecision(
        for url: URL,
        currentText: String,
        urlWasTyped: Bool,
        toolsReady: Bool,
        verdict: Bool?
    ) -> AutoFillDecision {
        guard !urlWasTyped, toolsReady else { return .skip }
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
            browser.start(
                shouldRead: { [weak self] in self?.readsTabOnActivation ?? false },
                onChange: { [weak self] outcome in self?.browserDidRead(outcome) }
            )
            host.log.info("Browser auto-fill on")
        } else {
            browser.stop()
            browserReadTask?.cancel()
            browserReadTask = nil
            probeTask?.cancel()
            probeTask = nil
            lastTabURL = nil
            host.log.info("Browser auto-fill off")
        }
    }

    /// Looks up the URL in the bar with `yt-dlp -J`: `.fetchingInfo`, then
    /// `.ready`, `.unsupported` or `.failed`. Narrows `availability` and steps
    /// the quality down when the source cannot reach it.
    public func fetchInfo() {
        guard let url = Self.webURL(from: urlText) else { return }
        guard let ytDlp, toolStatus.isReady else { return }
        infoTask?.cancel()
        infoTask = nil
        let requested = urlText
        if let known = recentLookups[requested] {
            recentLookups[requested] = known
            finishLookup(.success(known), for: requested)
            return
        }
        phase = .fetchingInfo
        infoTask = Task { [weak self] in
            let outcome: Result<MediaInfo, Error>
            do {
                outcome = .success(try await ytDlp.fetchInfo(for: url))
            } catch {
                outcome = .failure(error)
            }
            guard let self, !Task.isCancelled, self.urlText == requested else { return }
            self.infoTask = nil
            self.finishLookup(outcome, for: requested)
        }
    }

    /// Records the verdict, and for an auto-filled URL yt-dlp cannot use,
    /// puts the bar back the way it was without a warning.
    func finishLookup(_ outcome: Result<MediaInfo, Error>, for text: String) {
        switch outcome {
        case .success(let fetched):
            verdicts[text] = true
            recentLookups[text] = fetched
            loadPreviewImages(for: fetched, page: text)
        case .failure(YtDlpError.unsupportedURL): verdicts[text] = false
        default: break
        }
        guard autoFilledBrowser != nil else {
            applyInfo(outcome)
            startPendingDownload(after: outcome, for: text)
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
            normalizeTranscript()
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

    /// The websites yt-dlp knows by name, for Settings' search. Loaded by
    /// `loadSupportedSites()`, again after yt-dlp changes.
    @Published public private(set) var supportedSites: SupportedSites?
    /// The yt-dlp `supportedSites` came from.
    private var supportedSitesSource: ToolLocation?
    private var supportedSitesTask: Task<Void, Never>?

    /// Lists yt-dlp's extractors, once per yt-dlp.
    public func loadSupportedSites() {
        guard let ytDlp, let location = toolStatus.ytDlp, supportedSitesTask == nil else { return }
        guard supportedSites == nil || supportedSitesSource != location else { return }
        supportedSitesTask = Task { [weak self] in
            let output = await ytDlp.listExtractors()
            guard let self, !Task.isCancelled else { return }
            self.supportedSitesTask = nil
            guard let output else { return }
            self.supportedSites = SupportedSites(listOutput: output)
            self.supportedSitesSource = location
        }
    }

    /// Whether the URL bar vouches for its link with a checkmark: once the
    /// lookup succeeded, or as soon as yt-dlp's probe claimed it. A link that
    /// merely parses is not enough.
    public var linkIsConfirmed: Bool {
        guard Self.webURL(from: urlText) != nil else { return false }
        if case .ready = phase { return true }
        if case .unsupported = phase { return false }
        if case .failed = phase { return false }
        let text = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        return autoFilledBrowser != nil || support[text] == true
    }

    /// Whether the download keeps only the audio.
    public var isAudioOnly: Bool { options.quality == .audioOnly }

    /// Whether the fetched media has a video stream, which is when the
    /// audio-only switch means something.
    public var mediaHasVideo: Bool {
        info != nil && availability.qualities.contains(.best)
    }

    /// The quality the video picker shows, audio only or not.
    public var videoQuality: DownloadQuality {
        get { options.quality.includesVideo ? options.quality : lastVideoQuality }
        set {
            guard newValue.includesVideo else { return }
            lastVideoQuality = newValue
            if !isAudioOnly { options.quality = newValue }
        }
    }

    /// The audio-only switch. Off returns to the last video quality the URL
    /// can reach.
    public func setAudioOnly(_ on: Bool) {
        if on {
            guard !isAudioOnly else { return }
            lastVideoQuality = options.quality
            options.quality = .audioOnly
        } else {
            guard isAudioOnly else { return }
            options.quality = availability.fallback(for: lastVideoQuality)
        }
    }

    /// Puts the shelf's format back on the default, stepped down to what the
    /// URL in the bar can reach.
    func resetOptionsToDefault() {
        var reset = defaultOptions
        reset.quality = availability.fallback(for: reset.quality)
        options = reset
        normalizeTranscript()
        lastVideoQuality = defaultOptions.quality.includesVideo ? defaultOptions.quality : lastDefaultVideoQuality
    }

    /// The video quality the Settings picker shows, audio only or not.
    public var defaultVideoQuality: DownloadQuality {
        get { defaultOptions.quality.includesVideo ? defaultOptions.quality : lastDefaultVideoQuality }
        set {
            guard newValue.includesVideo else { return }
            lastDefaultVideoQuality = newValue
            if defaultOptions.quality.includesVideo { defaultOptions.quality = newValue }
        }
    }

    /// The Settings audio-only switch.
    public func setDefaultAudioOnly(_ on: Bool) {
        if on {
            guard defaultOptions.quality.includesVideo else { return }
            lastDefaultVideoQuality = defaultOptions.quality
            defaultOptions.quality = .audioOnly
        } else {
            guard !defaultOptions.quality.includesVideo else { return }
            defaultOptions.quality = lastDefaultVideoQuality
        }
    }

    // MARK: The queue

    /// Queues the URL in the bar and starts it when the lane is free. The
    /// form stays where it is: the shelf can close, the page can change, and
    /// the job keeps running until it is done or cancelled.
    public func startDownload() {
        guard canDownload, let url = Self.webURL(from: urlText) else { return }
        let folder = downloadFolder
        guard Self.isWritableFolder(folder) else {
            phase = .failed("Downloady cannot write to \(folder.path)")
            return
        }
        let job = DownloadJob(
            url: url,
            title: info?.title ?? url.host() ?? url.absoluteString,
            options: options,
            subtitleLanguage: info?.subtitleLanguage(preferring: Self.preferredLanguages)
                ?? Self.preferredLanguages.first ?? "en",
            duration: info?.duration
        )
        jobs.append(job)
        trimHistory()
        // The next media starts on the default format again, and auto-fill
        // picks up the next page.
        resetOptionsToDefault()
        urlWasTyped = false
        pump()
    }

    /// Stops a job and takes its half-written files with it. A finished job
    /// just leaves the queue.
    public func cancelJob(_ id: UUID) {
        guard let job = jobs[id: id] else { return }
        if job.isDownloading, currentDownloadID == id {
            downloadTask?.cancel()
            downloadTask = nil
            currentDownloadID = nil
        }
        if job.isTranscribing, currentTranscriptID == id {
            transcriptTask?.cancel()
            transcriptTask = nil
            currentTranscriptID = nil
        }
        // A running download's files are removed by the client once yt-dlp
        // has exited; a waiting one has written nothing.
        jobs.removeAll { $0.id == id }
        pump()
    }

    /// Takes the finished and failed rows out of the queue.
    public func clearFinishedJobs() {
        jobs.removeAll { !$0.isActive }
    }

    /// The job the URL in the bar belongs to, so a single download still
    /// shows its progress in the form it was started from.
    public var currentJob: DownloadJob? {
        let text = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return jobs.last { $0.url.absoluteString == text }
    }

    /// The jobs behind the queue button: everything except the one already
    /// shown in the form.
    public var backgroundJobs: [DownloadJob] {
        let current = currentJob?.id
        return jobs.filter { $0.id != current }
    }

    public var summary: QueueSummary { QueueSummary(jobs: jobs) }

    public var hasActiveJobs: Bool { jobs.contains(where: \.isActive) }

    /// Starts whatever each lane can take.
    private func pump() {
        if downloadTask == nil, let next = jobs.nextToDownload {
            startDownloadTask(for: next)
        }
        if transcriptTask == nil, let next = jobs.nextToTranscribe {
            startTranscriptTask(for: next)
        }
    }

    private func startDownloadTask(for job: DownloadJob) {
        guard let ytDlp else { return }
        let id = job.id
        currentDownloadID = id
        update(id) { $0.state = .downloading(fraction: 0, speed: nil, eta: nil) }
        let events = ytDlp.download(
            job.url,
            options: job.options,
            into: downloadFolder,
            subtitleLanguage: job.subtitleLanguage
        )
        downloadTask = Task { [weak self] in
            var finalFile: URL?
            var failure: Error?
            do {
                for try await event in events {
                    guard let self, !Task.isCancelled else { return }
                    switch event {
                    case .destination:
                        break
                    case .progress(let fraction, let speed, let eta):
                        self.updateProgress(id, to: .downloading(fraction: fraction, speed: speed, eta: eta))
                    case .postProcessing:
                        self.update(id) { $0.state = .postProcessing }
                    case .finished(let file):
                        finalFile = file
                    }
                }
            } catch {
                failure = error
            }
            guard let self, !Task.isCancelled else { return }
            self.downloadTask = nil
            self.currentDownloadID = nil
            self.downloadDidEnd(id, file: finalFile, failure: failure)
            self.pump()
        }
    }

    private func downloadDidEnd(_ id: UUID, file: URL?, failure: Error?) {
        progressPublishedAt[id] = nil
        guard let job = jobs[id: id] else { return }
        guard let file else {
            if let failure, failure as? YtDlpError != .cancelled {
                update(id) { $0.state = .failed(failure.localizedDescription) }
            } else {
                jobs.removeAll { $0.id == id }
            }
            return
        }
        update(id) { $0.file = file }
        if job.options.transcript.writesSubtitles {
            update(id) { $0.transcript = Self.subtitleFile(beside: file) }
        }
        if job.options.transcript.transcribesLocally, transcriber?.isSupported == true {
            update(id) { $0.state = .waitingForTranscript }
        } else {
            update(id) { $0.state = .finished }
        }
        if let finished = jobs[id: id] {
            notices.send(.downloaded(finished))
            trimHistory()
        }
    }

    private func startTranscriptTask(for job: DownloadJob) {
        guard let transcriber, let media = job.file else { return }
        let id = job.id
        currentTranscriptID = id
        update(id) { $0.state = .transcribing(fraction: 0) }
        let ffmpeg = toolStatus.ffmpeg?.url
        let duration = job.duration
        transcriptTask = Task { [weak self] in
            guard let self else { return }
            var transcript: URL?
            var failure: Error?
            if await self.allowSpeechRecognition() {
                do {
                    transcript = try await transcriber.transcribe(
                        media: media,
                        duration: duration,
                        ffmpeg: ffmpeg
                    ) { [weak self] event in
                        guard let self else { return }
                        switch event {
                        case .preparing:
                            self.update(id) { $0.state = .preparingTranscript }
                        case .progress(let fraction):
                            self.updateProgress(id, to: .transcribing(fraction: fraction))
                        }
                    }
                } catch {
                    failure = error
                }
            } else {
                failure = TranscriptionError.notAuthorized
            }
            // Every way out below frees the lane: returning early here once
            // left the next transcript waiting forever.
            guard !Task.isCancelled else { return }
            self.transcriptTask = nil
            self.currentTranscriptID = nil
            self.transcriptDidEnd(id, transcript: transcript, failure: failure)
            self.pump()
        }
    }

    private func transcriptDidEnd(_ id: UUID, transcript: URL?, failure: Error?) {
        progressPublishedAt[id] = nil
        guard jobs[id: id] != nil else { return }
        if let transcript {
            update(id) {
                $0.transcript = transcript
                $0.state = .finished
            }
            if let finished = jobs[id: id] { notices.send(.transcribed(finished)) }
        } else if let failure, failure as? TranscriptionError != .cancelled {
            // The media is on disk either way: a failed transcript is a note
            // on a finished download, not a lost file.
            update(id) { $0.state = .failed(failure.localizedDescription) }
        } else {
            update(id) { $0.state = .finished }
        }
        trimHistory()
    }

    /// Asks Droppy for speech recognition the first time a transcript runs.
    private func allowSpeechRecognition() async -> Bool {
        guard let host, host.isGranted(.speechRecognition) else { return false }
        refreshSpeechStatus()
        switch speechStatus {
        case .granted:
            return true
        case .notDetermined:
            _ = await host.permissions.request(.speechRecognition)
            refreshSpeechStatus()
            return speechStatus == .granted
        default:
            return false
        }
    }

    private func update(_ id: UUID, _ change: (inout DownloadJob) -> Void) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        change(&jobs[index])
    }

    /// When each job's progress was last published, for `updateProgress`.
    private var progressPublishedAt: [UUID: Date] = [:]

    /// A progress tick, coalesced: see `DownloadJob.shouldPublish`.
    private func updateProgress(_ id: UUID, to state: DownloadJob.State) {
        guard let old = jobs[id: id]?.state else { return }
        let now = Date()
        let elapsed = progressPublishedAt[id].map { now.timeIntervalSince($0) } ?? .infinity
        guard DownloadJob.shouldPublish(state, over: old, elapsed: elapsed) else { return }
        progressPublishedAt[id] = now
        update(id) { $0.state = state }
    }

    /// Keeps the queue short: the oldest finished rows go first.
    private func trimHistory() {
        var done = jobs.filter { !$0.isActive }
        guard done.count > Self.historyLimit else { return }
        done.removeLast(Self.historyLimit)
        let stale = Set(done.map(\.id))
        jobs.removeAll { stale.contains($0.id) }
    }

    /// The `.srt` yt-dlp wrote next to the media, whatever language it chose.
    /// yt-dlp names it `<media stem>.<lang>.srt`.
    static func subtitleFile(beside media: URL) -> URL? {
        let folder = media.deletingLastPathComponent()
        let stem = media.deletingPathExtension().lastPathComponent
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names
            .filter { $0.hasPrefix(stem + ".") && $0.hasSuffix(".srt") }
            .sorted()
            .first
            .map { folder.appendingPathComponent($0) }
    }

    /// Shows a file in Finder.
    public func reveal(_ file: URL) {
        host?.workspace.revealInFinder(file)
    }

    /// Replaces the bar with the pasteboard's text, when it holds a web link.
    public func pasteURL(_ text: String?) {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return }
        userEditedURL(text)
    }

    /// Fills the queue with jobs that are not running, for the harness. No
    /// process is started and no file is touched; nothing in the droplet
    /// calls this.
    public func fillWithDemoJobs() {
        func demo(_ title: String, _ state: DownloadJob.State, transcript: TranscriptMode = .off) -> DownloadJob {
            DownloadJob(
                url: URL(string: "https://www.youtube.com/watch?v=\(abs(title.hashValue))")!,
                title: title,
                options: DownloadOptions(transcript: transcript),
                state: state,
                file: URL(fileURLWithPath: "/tmp/\(title).mp4")
            )
        }
        jobs = [
            demo("Chopin nocturnes, full album", .downloading(fraction: 0.62, speed: "4.20MiB/s", eta: "00:38")),
            demo("WWDC keynote", .transcribing(fraction: 0.31), transcript: .transcribe),
            demo("How a lock works", .waiting),
            demo("Interview with the architect", .finished, transcript: .subtitles),
        ]
    }

    /// The languages the user reads, for the subtitle track yt-dlp is asked
    /// for.
    static var preferredLanguages: [String] {
        let codes = Locale.preferredLanguages.compactMap { Locale(identifier: $0).language.languageCode?.identifier }
        return codes.isEmpty ? ["en"] : codes
    }

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

    /// Downloads the tools set to Downloady's copy that are missing. A
    /// missing yt-dlp drives `toolStatus` through `.installing(progress:)`;
    /// ffmpeg alone installs behind a ready yt-dlp, shown in Settings only.
    public func installTools() {
        guard let tools, toolTask == nil else { return }
        let missing = tools.missingManagedTools()
        guard !missing.isEmpty else { return }
        guard canUseNetwork else {
            let reason = "Allow network access and downloads for Downloady"
            if missing.contains(.ytDlp) { toolStatus = .failed(reason) }
            for tool in missing { toolNotices[tool] = reason }
            return
        }
        for tool in missing { toolNotices[tool] = nil }
        toolUpdateMessage = nil
        installingTools = missing
        let blocksDownloads = missing.contains(.ytDlp)
        if blocksDownloads { toolStatus = .installing(progress: 0) }
        toolTask = Task { [weak self] in
            var result: ToolStatus
            var failure: String?
            do {
                result = try await tools.installMissing { fraction in
                    // Late progress hops must not overwrite the final status.
                    guard let self, case .installing = self.toolStatus else { return }
                    self.toolStatus = .installing(progress: fraction)
                }
            } catch is CancellationError {
                return
            } catch {
                failure = error.localizedDescription
                if blocksDownloads {
                    result = .failed(error.localizedDescription)
                } else {
                    result = await tools.resolve()
                }
            }
            let ffmpeg = result.isReady ? result.ffmpeg : await tools.resolveFFmpeg()
            guard let self, !Task.isCancelled else { return }
            self.installingTools = []
            self.detectedFFmpeg = ffmpeg
            self.toolStatus = result
            if let failure {
                for tool in missing { self.toolNotices[tool] = failure }
            } else if missing.contains(.ffmpeg), ffmpeg?.source != .managed {
                self.toolNotices[.ffmpeg] = "ffmpeg could not be installed. Try again, or pick another source."
            }
            self.toolTask = nil
            self.checkForYtDlpUpdate()
        }
    }

    /// Reinstalls the managed yt-dlp when GitHub has a newer release.
    public func updateYtDlp() {
        guard let tools, toolTask == nil else { return }
        guard canUseNetwork else {
            toolUpdateMessage = "Allow network access and downloads for Downloady"
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
            if let result {
                self.toolStatus = result
                self.ytDlpUpdate = nil
            }
            self.toolUpdateMessage = message
            self.isUpdatingTools = false
            self.toolTask = nil
        }
    }

    /// Asks GitHub whether the managed yt-dlp has a newer release, without
    /// installing it. Quiet: a failed check just offers no update.
    public func checkForYtDlpUpdate() {
        guard let tools, canUseNetwork, updateCheckTask == nil, !isUpdatingTools,
              toolStatus.ytDlp?.source == .managed else { return }
        updateCheckTask = Task { [weak self] in
            let tag = try? await tools.availableYtDlpUpdate()
            guard let self, !Task.isCancelled else { return }
            self.ytDlpUpdate = tag
            self.updateCheckTask = nil
        }
    }

    /// Looks the tools up again, e.g. after a source or a custom path
    /// changed, and installs Downloady's copy of whichever is set to it and
    /// missing. Replaces a lookup or an install still running.
    public func reloadTools() {
        guard let tools else { return }
        toolTask?.cancel()
        installingTools = []
        isUpdatingTools = false
        toolTask = Task { [weak self] in
            let status = await tools.resolve()
            let ffmpeg = status.isReady ? status.ffmpeg : await tools.resolveFFmpeg()
            guard let self, !Task.isCancelled else { return }
            self.detectedFFmpeg = ffmpeg
            self.toolStatus = status
            self.toolTask = nil
            if tools.missingManagedTools().isEmpty {
                self.checkForYtDlpUpdate()
            } else {
                // First run, or a source just switched to Downloady's copy:
                // fetch it now rather than wait for a click.
                self.installTools()
            }
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
    /// when Downloady cannot write there.
    @discardableResult
    public func setDownloadFolder(_ folder: URL) -> Bool {
        guard Self.isWritableFolder(folder) else {
            downloadFolderMessage = "Downloady cannot write to \(folder.lastPathComponent)"
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

    /// When the tab is read while the shelf is closed.
    public var backgroundTabCheck: BackgroundTabCheck {
        get {
            host?.preferences.value(forKey: PreferenceKey.backgroundTabCheck, as: String.self)
                .flatMap(BackgroundTabCheck.init(rawValue:)) ?? .always
        }
        set {
            host?.preferences.setValue(newValue.rawValue, forKey: PreferenceKey.backgroundTabCheck)
            objectWillChange.send()
        }
    }

    /// Asked by the browser provider before each read of the browser in front.
    private var readsTabOnActivation: Bool {
        guard let host else { return false }
        let state = host.installState.state
        return backgroundTabCheck.readsOnActivation(
            widgetOnShelf: state.isEnabled && state.activeWidgetIDs.contains(DownloadyDroplet.widgetID),
            formVisible: visibleForms > 0 && host.shelf.isExpanded
        )
    }

    // MARK: Preview images

    /// The thumbnail or favicon at `url`: `nil` while it has not loaded yet.
    public func previewImage(at url: URL) -> PreviewImage? {
        images[url.absoluteString]
    }

    /// Loads the image at `url` unless it is known or on its way. The card
    /// asks when it shows a URL whose image is not in `images`.
    public func loadPreviewImage(at url: URL) {
        let key = url.absoluteString
        guard images[key] == nil, imageTasks[key] == nil, host?.isGranted(.networkClient) == true else { return }
        imageTasks[key] = Task { [weak self] in
            let image: NSImage?
            do {
                let (data, response) = try await URLSession.shared.data(from: url)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 200
                image = (200..<300).contains(status) ? NSImage(data: data) : nil
            } catch {
                image = nil
            }
            guard let self, !Task.isCancelled else { return }
            self.imageTasks[key] = nil
            self.objectWillChange.send()
            self.images[key] = image.map(PreviewImage.image) ?? .failed
        }
    }

    /// Fetches a lookup's thumbnail and favicon as soon as it ends, so a card
    /// looked up in the background is complete when the shelf opens.
    private func loadPreviewImages(for info: MediaInfo, page: String) {
        if let thumbnail = MediaPreview.httpsURL(info.thumbnail) { loadPreviewImage(at: thumbnail) }
        if let favicon = MediaPreview.faviconURL(page: info.webpageURL ?? page) { loadPreviewImage(at: favicon) }
    }

    /// Whether Droppy granted the `apple-events` capability.
    public var appleEventsGranted: Bool { host?.isGranted(.appleEvents) ?? false }

    /// The browsers macOS lets Downloady read, in `SupportedBrowser.all` order.
    public var allowedBrowsers: [SupportedBrowser] {
        SupportedBrowser.all.filter { browserPermissions[$0.bundleID] == true }
    }

    /// The browsers the user refused under Privacy & Security, Automation.
    public var deniedBrowsers: [SupportedBrowser] {
        SupportedBrowser.all.filter { browserPermissions[$0.bundleID] == false }
    }

    /// Settings appeared: asks macOS, without prompting, about every running
    /// browser. A browser that is not running keeps what was last recorded.
    public func refreshBrowserPermissions() {
        guard appleEventsGranted else { return }
        Task { [weak self] in
            var toAsk: [SupportedBrowser] = []
            for browser in SupportedBrowser.all {
                let status = await BrowserAutomation.status(of: browser, ask: false)
                guard let self else { return }
                if status == .notAsked { toAsk.append(browser) }
                self.record(status, for: browser)
            }
            self?.browsersToAsk = toAsk
        }
    }

    /// The Settings "Allow" button: macOS's prompt for each running browser
    /// it has not asked about, one after the other.
    public func askBrowsers() {
        guard appleEventsGranted else { return }
        let browsers = browsersToAsk
        Task { [weak self] in
            for browser in browsers {
                let status = await BrowserAutomation.status(of: browser, ask: true)
                guard let self else { return }
                self.record(status, for: browser)
                self.browsersToAsk.removeAll { $0 == browser }
            }
            self?.refreshFromBrowser()
        }
    }

    private func record(_ status: BrowserAutomationStatus, for browser: SupportedBrowser) {
        var permissions = browserPermissions
        switch status {
        case .allowed: permissions[browser.bundleID] = true
        case .denied: permissions[browser.bundleID] = false
        case .notAsked: permissions[browser.bundleID] = nil
        case .unknown: return
        }
        guard permissions != browserPermissions else { return }
        browserPermissions = permissions
        host?.preferences.setValue(permissions, forKey: PreferenceKey.browserPermissions)
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

    func customPath(for tool: ToolLocation.Tool) -> String? {
        tool == .ytDlp ? customYtDlpPath : customFFmpegPath
    }

    func setCustomPath(_ path: String?, for tool: ToolLocation.Tool) {
        if tool == .ytDlp { customYtDlpPath = path } else { customFFmpegPath = path }
    }

    private func setCustomPath(_ path: String?, forKey key: String) {
        let trimmed = path?.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = trimmed?.isEmpty == false ? trimmed : nil
        guard value != host?.preferences.value(forKey: key, as: String.self) else { return }
        host?.preferences.setValue(value, forKey: key)
        objectWillChange.send()
        reloadTools()
    }

    private func storedSource(for tool: ToolLocation.Tool) -> ToolLocation.Source? {
        let key = tool == .ytDlp ? PreferenceKey.ytDlpSource : PreferenceKey.ffmpegSource
        if let raw = host?.preferences.value(forKey: key, as: String.self) {
            return ToolLocation.Source(rawValue: raw)
        }
        // Before the source picker, a custom path alone meant "use it".
        return customPath(for: tool) != nil ? .custom : nil
    }

    /// What the tool manager looks up.
    var toolChoices: ToolChoices {
        ToolChoices(
            ytDlpSource: storedSource(for: .ytDlp) ?? .managed,
            ffmpegSource: storedSource(for: .ffmpeg),
            ytDlpPath: customYtDlpPath,
            ffmpegPath: customFFmpegPath
        )
    }

    /// The segment Settings' picker shows for `tool`: the stored choice, or
    /// for ffmpeg's default, the source it resolved to.
    public func source(for tool: ToolLocation.Tool) -> ToolLocation.Source {
        if let stored = storedSource(for: tool) { return stored }
        switch tool {
        case .ytDlp: return .managed
        case .ffmpeg: return tools?.systemCopy(of: .ffmpeg) != nil ? .system : .managed
        }
    }

    /// The copy of `tool` on this Mac, for Settings' This Mac segment.
    public func systemCopy(of tool: ToolLocation.Tool) -> URL? {
        tools?.systemCopy(of: tool)
    }

    /// The user picked where `tool` comes from. This Mac with nothing
    /// installed falls back to Custom, and says so in the tool's card.
    public func selectSource(_ source: ToolLocation.Source, for tool: ToolLocation.Tool) {
        guard let host else { return }
        var chosen = source
        toolNotices[tool] = nil
        if source == .system, systemCopy(of: tool) == nil {
            chosen = .custom
            toolNotices[tool] = "No \(tool.name) was found on this Mac. Enter the path to yours below."
        }
        let key = tool == .ytDlp ? PreferenceKey.ytDlpSource : PreferenceKey.ffmpegSource
        host.preferences.setValue(chosen.rawValue, forKey: key)
        objectWillChange.send()
        if tool == .ytDlp { ytDlpUpdate = nil }
        reloadTools()
    }

    /// Whether the Download button does anything. A job already running for
    /// this very URL is the one case where it does not: the form is showing
    /// its progress.
    public var canDownload: Bool {
        guard toolStatus.isReady, Self.webURL(from: urlText) != nil else { return false }
        guard currentJob?.isActive != true else { return false }
        // A lookup still running is no reason to wait: yt-dlp resolves the
        // URL itself, and the card says what is still loading.
        return phase != .unsupported
    }

    // MARK: Transcripts

    /// Whether this Mac could transcribe, permission aside: macOS 26 or
    /// later, and Droppy passing the speech capability through.
    public var transcriptionIsPossible: Bool {
        (transcriber?.isSupported ?? false) && (host?.isGranted(.speechRecognition) ?? false)
    }

    /// Whether Transcribe can be picked: possible, and macOS has not refused
    /// speech recognition. Not asked yet still counts: the first transcript
    /// asks.
    public var canTranscribeLocally: Bool {
        transcriptionIsPossible && speechStatus != .denied && speechStatus != .unavailable
    }

    /// Whether the user refused speech recognition, which is what greys
    /// Transcribe out on a Mac that could otherwise transcribe.
    public var speechIsDenied: Bool {
        transcriptionIsPossible && speechStatus == .denied
    }

    /// Why Settings says transcribing is off, or `nil` when it is available.
    public var transcriptionUnavailableReason: String? {
        if transcriber?.isSupported == false {
            return "Transcribing on this Mac needs macOS 26 or later. Subtitles still work."
        }
        if host?.isGranted(.speechRecognition) == false {
            return "Turn on speech recognition for Downloady in Droppy's Store settings."
        }
        if speechStatus == .denied {
            return "Speech recognition is not allowed for Droppy. Grant it to transcribe."
        }
        if detectedFFmpeg == nil {
            return "Transcribing needs ffmpeg, which is set up under Tools."
        }
        return nil
    }

    /// Speech recognition as macOS last reported it. Published, so the Text
    /// picker greys Transcribe out as soon as it is refused.
    @Published public private(set) var speechStatus: DropletPermissionStatus = .unavailable {
        didSet {
            guard speechStatus != oldValue else { return }
            normalizeTranscript()
        }
    }

    /// Reads the permission again, when a form or Settings appears: the user
    /// may have changed it in System Settings meanwhile.
    public func refreshSpeechStatus() {
        guard let host, host.isGranted(.speechRecognition) else {
            speechStatus = .unavailable
            return
        }
        speechStatus = host.permissions.status(for: .speechRecognition)
    }

    /// Settings' Grant button. macOS prompts only once: after a refusal the
    /// request comes straight back denied, and System Settings is the one
    /// place left to change it, so that is where the button then leads.
    public func grantSpeechRecognition() {
        guard let host, host.isGranted(.speechRecognition) else { return }
        Task { [weak self] in
            let status = await host.permissions.request(.speechRecognition)
            guard let self else { return }
            self.refreshSpeechStatus()
            if status == .denied {
                host.permissions.openSystemSettings(for: .speechRecognition)
            }
        }
    }

    /// Whether a text choice can be picked for the URL in the bar: there are
    /// no subtitles to write when the site has none, and no transcript
    /// without macOS 26.
    public func isTranscriptModeAvailable(_ mode: TranscriptMode, isDefault: Bool = false) -> Bool {
        switch mode {
        case .off:
            return true
        case .subtitles:
            // Settings knows no URL, and with no metadata yet the choice
            // stays open: yt-dlp answers when the link is looked up.
            guard !isDefault, let info else { return true }
            return info.hasSubtitles
        case .transcribe:
            return canTranscribeLocally
        }
    }

    /// Moves the text picker off a choice the URL or the Mac cannot do:
    /// subtitles the site has none of become a local transcript when this Mac
    /// can, and Off when it cannot.
    private func normalizeTranscript() {
        guard !isTranscriptModeAvailable(options.transcript) else { return }
        switch options.transcript {
        case .subtitles:
            options.transcript = canTranscribeLocally ? .transcribe : .off
        case .transcribe:
            options.transcript = isTranscriptModeAvailable(.subtitles) ? .subtitles : .off
        case .off:
            break
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

/// A thumbnail or favicon, or the knowledge that it could not be loaded.
public enum PreviewImage {
    case image(NSImage)
    case failed
}

/// A small most-recently-set map from URL to "yt-dlp can handle it".
typealias VerdictCache = RecentCache<Bool>

/// A small map that keeps the `capacity` most recently set keys.
struct RecentCache<Value> {
    let capacity: Int
    private var values: [String: Value] = [:]
    private var order: [String] = []

    init(capacity: Int) { self.capacity = capacity }

    var count: Int { values.count }

    subscript(key: String) -> Value? {
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
