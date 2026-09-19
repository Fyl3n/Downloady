//
//  DownloadyDroplet.swift
//  Downloady
//
//  Entry point and surface conformances. The state lives in `DownloadModel`;
//  the views live in `UI/`.
//

import Combine
import DroppyKit
import SwiftUI

/// The class Droppy's loader instantiates, named in the bundle's
/// `NSPrincipalClass`. Keep it empty: it runs before the host is ready.
@objc(DownloadyPrincipal)
public final class DownloadyPrincipal: NSObject, DropletPrincipal {
    public override init() { super.init() }

    @MainActor public func makeDroplet() -> AnyObject { DownloadyDroplet() }
}

/// Downloady: download the video in front of you with yt-dlp.
@MainActor
public final class DownloadyDroplet: NSObject, ObservableObject, Droplet {
    /// Must equal `DroppyDropletID` in the bundle's Info.plist and `id` in
    /// droplet.json. The loader refuses the bundle if the three disagree.
    public nonisolated static let id: DropletID = "downloady"

    static let widgetID: ShelfWidgetID = "downloady"
    static let detailSurfaceID: ExpandedSurfaceID = "downloady-detail"
    static let queueSurfaceID: ExpandedSurfaceID = "downloady-queue"

    /// The HUD shown when a file lands, and the card it grows into.
    static let completionHUDID = "downloady.finished"

    private(set) var host: DropletHost?
    public let model = DownloadModel()

    /// What the host reads for the compact live activity. `nil` stands down.
    private let activitySubject = CurrentValueSubject<LiveActivityState?, Never>(nil)
    /// The queue subscription that drives the live activity.
    private var queueObserver: AnyCancellable?
    /// The one that puts a HUD up when a file lands.
    private var noticeObserver: AnyCancellable?
    /// Grows the completion strip into its card a beat after it appears.
    private var hudTask: Task<Void, Never>?
    /// The file the completion HUD is about, while it is up.
    private var hudFile: URL?
    /// Whether the queue was opened from the takeover, so Back goes there.
    private var queueReturnsToDetail = false

    public func activate(host: DropletHost) throws {
        self.host = host
        model.start(host: host)
        // The live activity is a pure function of the queue.
        // Only the stage reaches the host: the percentage ticks inside the
        // wings, which observe the model, and never re-publishes the state.
        queueObserver = model.$jobs
            .map { Self.activityState(for: QueueSummary(jobs: $0)) }
            .removeDuplicates()
            .sink { [weak self] state in self?.activitySubject.send(state) }
        noticeObserver = model.notices.sink { [weak self] notice in
            self?.present(notice)
        }
        registerQuickActions(host: host)
        host.log.info("Downloady activated")
    }

    public func deactivate() {
        // Everything activate() started is torn down here. Swift cannot unload
        // code, so anything left running keeps running until Droppy relaunches.
        queueObserver?.cancel()
        queueObserver = nil
        noticeObserver?.cancel()
        noticeObserver = nil
        hudTask?.cancel()
        hudTask = nil
        if hudFile != nil {
            host?.hud.dismiss(id: Self.completionHUDID)
            hudFile = nil
        }
        activitySubject.send(nil)
        // The host unregisters the shortcuts on deactivate; this says so here.
        for action in QuickAction.allCases {
            host?.shortcuts.unregister(id: action.rawValue)
        }
        model.stop()
        host = nil
    }

    /// Refuse removal while anything is still running.
    public func prepareForRemoval() -> Bool { !model.hasActiveJobs }

    /// Opens the takeover from the widget.
    func openDetail() {
        present(Self.detailSurfaceID)
    }

    /// Opens the queue, from the queue button in the form. `fromDetail` says
    /// where Back returns to: the takeover it was opened from, or the shelf.
    func openQueue(fromDetail: Bool) {
        queueReturnsToDetail = fromDetail
        present(Self.queueSurfaceID)
    }

    /// The queue's Back button.
    func closeQueue() {
        if queueReturnsToDetail {
            present(Self.detailSurfaceID)
        } else {
            host?.notchSurface.dismissExpandedSurface(Self.queueSurfaceID)
        }
    }

    private func present(_ id: ExpandedSurfaceID) {
        guard let host else { return }
        let presentation = host.notchSurface.presentExpandedSurface(
            ExpandedSurfacePresentationRequest(surfaceID: id, opensShelf: true)
        )
        host.log.info("\(id.rawValue) presented: \(presentation != nil)")
    }

    func openSettings() {
        _ = host?.workspace.openSettings()
    }

    // MARK: Quick actions

    /// Global shortcuts the user binds in Droppy's Settings, Shortcuts page.
    /// DroppyKit has no quick-action surface of its own, so these are how the
    /// rest of Droppy reaches Downloady. None ships with a default binding.
    enum QuickAction: String, CaseIterable {
        case open = "open"
        case downloadFrontTab = "download-front-tab"
        case downloadPasted = "download-pasted"
        case downloadFrontTabAudio = "download-front-tab-audio"
        case downloadPastedAudio = "download-pasted-audio"

        var title: String {
            switch self {
            case .open: "Open Downloady"
            case .downloadFrontTab: "Download this video"
            case .downloadPasted: "Download the pasted video"
            case .downloadFrontTabAudio: "Download audio from this video"
            case .downloadPastedAudio: "Download audio from the pasted video"
            }
        }
    }

    private func registerQuickActions(host: DropletHost) {
        guard host.isGranted(.globalShortcuts) else { return }
        for action in QuickAction.allCases {
            host.shortcuts.register(id: action.rawValue, title: action.title, defaultShortcut: nil) { [weak self] in
                self?.perform(action)
            }
        }
    }

    /// Opens the takeover, then starts the work: the takeover shows the link,
    /// the job's progress, or why nothing started.
    func perform(_ action: QuickAction) {
        openDetail()
        switch action {
        case .open: break
        case .downloadFrontTab: model.downloadFrontTab()
        case .downloadPasted: model.downloadPasted()
        case .downloadFrontTabAudio: model.downloadFrontTab(audioOnly: true)
        case .downloadPastedAudio: model.downloadPasted(audioOnly: true)
        }
    }

    /// A file landed: say so, unless the user is already looking at the shelf.
    private func present(_ notice: DownloadModel.Notice) {
        switch notice {
        case .downloaded(let job):
            guard let file = job.file else { return }
            presentCompletionHUD(title: "Downloaded", file: file)
        case .transcribed(let job):
            guard let transcript = job.transcript else { return }
            presentCompletionHUD(title: "Transcript ready", file: transcript)
        }
    }
}

// MARK: - Shelf widget

extension DownloadyDroplet: ShelfWidgetProviding {
    public var widgetDescriptors: [ShelfWidgetDescriptor] {
        [
            ShelfWidgetDescriptor(
                id: Self.widgetID,
                title: "Downloady",
                systemImage: "arrow.down.circle",
                layoutTraits: ShelfWidgetLayoutTraits(
                    // Solo: URL bar, the three pickers in a row, the action row.
                    // Paired: URL bar and the download button only.
                    preferredSoloWidth: 420,
                    preferredPairedWidth: 210,
                    // The solo stack, measured: header, URL bar, pickers and
                    // the action row with a DroppySpacing.sm step between
                    // them. The paired composition drops the pickers and is
                    // shorter, but the shelf gives a widget one height.
                    contentHeight: .fixed(DownloadyWidget.soloContentHeight)
                )
            )
        ]
    }

    public func makeWidgetView(_ id: ShelfWidgetID, context: ShelfWidgetContext) -> AnyView {
        AnyView(DownloadyWidget(droplet: self, model: model, context: context))
    }

    public func makeWidgetSettingsPopover(_ id: ShelfWidgetID) -> AnyView? { nil }
}

// MARK: - Expanded surface

extension DownloadyDroplet: ExpandedSurfaceProviding {
    public var expandedSurfaces: [ExpandedSurfaceDescriptor] {
        [
            ExpandedSurfaceDescriptor(
                id: Self.detailSurfaceID,
                title: "Downloady",
                systemImage: "arrow.down.circle",
                suppresses: [.shelfWidgets, .autoCollapse]
            ),
            ExpandedSurfaceDescriptor(
                id: Self.queueSurfaceID,
                title: "Downloads",
                systemImage: "list.bullet",
                suppresses: [.shelfWidgets, .autoCollapse]
            ),
        ]
    }

    public func makeExpandedSurfaceView(_ id: ExpandedSurfaceID, context: ExpandedSurfaceContext) -> AnyView {
        id == Self.queueSurfaceID
            ? AnyView(QueueView(droplet: self, model: model, context: context))
            : AnyView(DownloadyDetailView(droplet: self, model: model, context: context))
    }

    public func expandedSurfaceSize(_ id: ExpandedSurfaceID, fitting proposal: ExpandedSurfaceSizeProposal) -> CGSize? {
        // Each takeover is as tall as its content, not as tall as it may be:
        // a Spacer under the last row is unused space the host drew for us.
        // The queue is measured for the rows it has when it opens; rows added
        // while it is up scroll inside it.
        let height = id == Self.queueSurfaceID
            ? QueueView.contentHeight(rows: model.jobs.count)
            : DownloadyDetailView.contentHeight
        // Five pickers in a row need more than the notch's own width.
        return CGSize(
            width: max(proposal.standardSize.width, min(proposal.maximumSize.width, 540)),
            height: min(proposal.maximumSize.height, height)
        )
    }

    public func expandedSurfaceDidDismiss(
        _ id: ExpandedSurfaceID,
        presentation: ExpandedSurfacePresentation,
        reason: ExpandedSurfaceDismissalReason
    ) {
        host?.log.debug("detail surface dismissed: \(reason)")
    }
}

/// How Droppy finds the takeover: it casts the droplet to
/// `ExpandedSurfaceHosting` and asks for the provider. Conforming to
/// `ExpandedSurfaceProviding` alone is enough for the harness, but the real
/// host then refuses every present with "the droplet does not publish a
/// surface with that id".
extension DownloadyDroplet: ExpandedSurfaceHosting {
    public var expandedSurfaceProvider: (any ExpandedSurfaceProviding)? { self }
}

// MARK: - Settings pane

extension DownloadyDroplet: SettingsPaneProviding {
    public func makeSettingsPane(context: SettingsPaneContext) -> AnyView {
        AnyView(DownloadySettingsView(droplet: self, model: model))
    }

    public var settingsSearchEntries: [SettingsSearchEntry] {
        [SettingsSearchEntry(title: "Downloady", keywords: ["yt-dlp", "download", "video", "ffmpeg"])]
    }
}

// MARK: - Completion HUD

extension DownloadyDroplet: HUDPresenting {
    /// Tells the user a download ended while they were looking elsewhere.
    ///
    /// The strip is the at-rest form, "Downloaded" and the file name. It grows
    /// into the card a beat later, the way Droppy's own battery HUD does, so
    /// Show in Finder is in reach; growing is one re-present with the same id,
    /// never a second HUD.
    private func presentCompletionHUD(title: String, file: URL) {
        guard let host else { return }
        // Nothing to announce while the user is already looking at the shelf.
        guard !host.shelf.isExpanded else { return }
        hudFile = file
        showCompletionHUD(title: title, for: file, expanded: false, duration: nil)
        hudTask?.cancel()
        hudTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(900))
            guard let self, !Task.isCancelled, self.hudFile == file else { return }
            self.showCompletionHUD(title: title, for: file, expanded: true, duration: 6)
            self.hudTask = nil
        }
    }

    private func showCompletionHUD(title: String, for file: URL, expanded: Bool, duration: TimeInterval?) {
        guard let host else { return }
        let name = file.lastPathComponent
        let request = DropletHUDRequest(
            id: Self.completionHUDID,
            duration: duration,
            priority: .normal,
            accessibilityLabel: "\(title): \(name)",
            isExpanded: expanded,
            expandedContentHeight: 62,
            content: {
                // A strip is handed the full width across the camera housing:
                // the two outer edges, nothing in the middle. A notch wing is
                // about 60pt beside a 200pt housing, which is one short word.
                // "Downloaded" and the file name are in the card this grows
                // into, where there is room to read them.
                HStack(spacing: 0) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: DroppyLiveActivityMetrics.iconSize, weight: .semibold))
                    Spacer(minLength: 0)
                    Text(file.pathExtension == "srt" ? "Text" : "Saved")
                        .font(.system(size: DroppyLiveActivityMetrics.labelFontSize, weight: .semibold))
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity)
                .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
            },
            expanded: { [weak self] in
                DownloadedHUDCard(title: title, name: name) { self?.model.reveal(file) }
            }
        )
        _ = host.hud.present(request)
    }
}

// MARK: - Live activity

extension DownloadyDroplet: LiveActivityProviding {
    public var liveActivityState: AnyPublisher<LiveActivityState?, Never> {
        activitySubject.eraseToAnyPublisher()
    }

    /// Asks for the compact seat while any job is running — a download, or a
    /// transcript running behind it — and stands down the moment the queue
    /// goes quiet: the shelf is where the finished files are.
    private static func activityState(for summary: QueueSummary) -> LiveActivityState? {
        guard summary.isActive else { return nil }
        return LiveActivityState(
            // Below Droppy's own timers and calls: a download is a
            // status, not something the user is waiting on the second.
            priority: 150,
            accessibilityTitle: summary.leading?.isTranscribing == true ? "Transcribing" : "Downloading",
            isInteractive: false,
            // A download the user started is worth keeping in view until it
            // lands. Left false, the host only reveals the row while the
            // pointer is over the notch.
            joinsPersistentActivitySet: true,
            compactPresentation: nil,
            expandedWidgetID: widgetID.rawValue
        )
    }

    public func liveActivitySeatDidChange(_ seat: DropletLiveActivitySeat) {
        host?.log.debug("live activity seat: \(seat)")
    }

    public func makeCompactLeading() -> AnyView {
        AnyView(DownloadActivityRing(model: model))
    }

    public func makeCompactTrailing() -> AnyView {
        AnyView(DownloadActivityValue(model: model))
    }

    /// Droppy mounts no card for a droplet's activity: hovering the row opens
    /// the shelf, where the widget and its Cancel button are.
    public func makeExpanded(context: LiveActivityContext) -> AnyView {
        AnyView(EmptyView())
    }
}
