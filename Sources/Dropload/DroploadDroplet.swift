//
//  DroploadDroplet.swift
//  Dropload
//
//  Entry point and surface conformances. The state lives in `DownloadModel`;
//  the views live in `UI/`.
//

import Combine
import DroppyKit
import SwiftUI

/// The class Droppy's loader instantiates, named in the bundle's
/// `NSPrincipalClass`. Keep it empty: it runs before the host is ready.
@objc(DroploadPrincipal)
public final class DroploadPrincipal: NSObject, DropletPrincipal {
    public override init() { super.init() }

    @MainActor public func makeDroplet() -> AnyObject { DroploadDroplet() }
}

/// Dropload: download the video in front of you with yt-dlp.
@MainActor
public final class DroploadDroplet: NSObject, ObservableObject, Droplet {
    /// Must equal `DroppyDropletID` in the bundle's Info.plist and `id` in
    /// droplet.json. The loader refuses the bundle if the three disagree.
    public nonisolated static let id: DropletID = "dropload"

    static let widgetID: ShelfWidgetID = "dropload"
    static let detailSurfaceID: ExpandedSurfaceID = "dropload-detail"

    /// The HUD shown when a download ends, and the card it grows into.
    static let completionHUDID = "dropload.finished"

    private(set) var host: DropletHost?
    public let model = DownloadModel()

    /// What the host reads for the compact live activity. `nil` stands down.
    private let activitySubject = CurrentValueSubject<LiveActivityState?, Never>(nil)
    /// The phase subscription that drives the HUD and the live activity.
    private var phaseObserver: AnyCancellable?
    /// Grows the completion strip into its card a beat after it appears.
    private var hudTask: Task<Void, Never>?
    /// The file the completion HUD is about, while it is up.
    private var hudFile: URL?

    public func activate(host: DropletHost) throws {
        self.host = host
        model.start(host: host)
        // The HUD and the live activity are both a pure function of the phase.
        phaseObserver = model.$phase.sink { [weak self] phase in
            self?.phaseDidChange(phase)
        }
        host.log.info("Dropload activated")
    }

    public func deactivate() {
        // Everything activate() started is torn down here. Swift cannot unload
        // code, so anything left running keeps running until Droppy relaunches.
        phaseObserver?.cancel()
        phaseObserver = nil
        hudTask?.cancel()
        hudTask = nil
        if hudFile != nil {
            host?.hud.dismiss(id: Self.completionHUDID)
            hudFile = nil
        }
        activitySubject.send(nil)
        model.stop()
        host = nil
    }

    /// Refuse removal while a download is running.
    public func prepareForRemoval() -> Bool {
        switch model.phase {
        case .downloading, .postProcessing: false
        default: true
        }
    }

    /// Opens the takeover from the widget.
    func openDetail() {
        let presentation = host?.notchSurface.presentExpandedSurface(
            ExpandedSurfacePresentationRequest(surfaceID: Self.detailSurfaceID, opensShelf: true)
        )
        if presentation == nil { host?.log.debug("detail surface not shown") }
    }

    func openSettings() {
        _ = host?.workspace.openSettings()
    }

    // MARK: Phase side effects

    /// Publishes the live activity for the new phase, and puts the completion
    /// HUD up when a download just ended off-screen.
    private func phaseDidChange(_ phase: DownloadModel.Phase) {
        publishActivity(for: phase)
        if case .finished(let file) = phase {
            presentCompletionHUD(for: file)
        } else if hudFile != nil {
            hudTask?.cancel()
            hudTask = nil
            host?.hud.dismiss(id: Self.completionHUDID)
            hudFile = nil
        }
    }
}

// MARK: - Shelf widget

extension DroploadDroplet: ShelfWidgetProviding {
    public var widgetDescriptors: [ShelfWidgetDescriptor] {
        [
            ShelfWidgetDescriptor(
                id: Self.widgetID,
                title: "Dropload",
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
                    contentHeight: .fixed(DroploadWidget.soloContentHeight)
                )
            )
        ]
    }

    public func makeWidgetView(_ id: ShelfWidgetID, context: ShelfWidgetContext) -> AnyView {
        AnyView(DroploadWidget(droplet: self, model: model, context: context))
    }

    public func makeWidgetSettingsPopover(_ id: ShelfWidgetID) -> AnyView? { nil }
}

// MARK: - Expanded surface

extension DroploadDroplet: ExpandedSurfaceProviding {
    public var expandedSurfaces: [ExpandedSurfaceDescriptor] {
        [
            ExpandedSurfaceDescriptor(
                id: Self.detailSurfaceID,
                title: "Dropload",
                systemImage: "arrow.down.circle",
                suppresses: [.shelfWidgets, .autoCollapse]
            )
        ]
    }

    public func makeExpandedSurfaceView(_ id: ExpandedSurfaceID, context: ExpandedSurfaceContext) -> AnyView {
        AnyView(DroploadDetailView(droplet: self, model: model, context: context))
    }

    public func expandedSurfaceSize(_ id: ExpandedSurfaceID, fitting proposal: ExpandedSurfaceSizeProposal) -> CGSize? {
        // The takeover is as tall as its content, not as tall as it may be:
        // a Spacer under the last row is unused space the host drew for us.
        CGSize(
            width: max(proposal.standardSize.width, 460),
            height: min(proposal.maximumSize.height, DroploadDetailView.contentHeight)
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

// MARK: - Settings pane

extension DroploadDroplet: SettingsPaneProviding {
    public func makeSettingsPane(context: SettingsPaneContext) -> AnyView {
        AnyView(DroploadSettingsView(droplet: self, model: model))
    }

    public var settingsSearchEntries: [SettingsSearchEntry] {
        [SettingsSearchEntry(title: "Dropload", keywords: ["yt-dlp", "download", "video", "ffmpeg"])]
    }
}

// MARK: - Completion HUD

extension DroploadDroplet: HUDPresenting {
    /// Tells the user a download ended while they were looking elsewhere.
    ///
    /// The strip is the at-rest form, "Downloaded" and the file name. It grows
    /// into the card a beat later, the way Droppy's own battery HUD does, so
    /// Show in Finder is in reach; growing is one re-present with the same id,
    /// never a second HUD.
    private func presentCompletionHUD(for file: URL) {
        guard let host else { return }
        // Nothing to announce while the user is already looking at the shelf.
        guard !host.shelf.isExpanded else { return }
        hudFile = file
        showCompletionHUD(for: file, expanded: false, duration: nil)
        hudTask?.cancel()
        hudTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(900))
            guard let self, !Task.isCancelled, self.hudFile == file else { return }
            self.showCompletionHUD(for: file, expanded: true, duration: 6)
            self.hudTask = nil
        }
    }

    private func showCompletionHUD(for file: URL, expanded: Bool, duration: TimeInterval?) {
        guard let host else { return }
        let name = file.lastPathComponent
        let request = DropletHUDRequest(
            id: Self.completionHUDID,
            duration: duration,
            priority: .normal,
            accessibilityLabel: "Downloaded \(name)",
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
                    Text("Saved")
                        .font(.system(size: DroppyLiveActivityMetrics.labelFontSize, weight: .semibold))
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity)
                .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
            },
            expanded: { [weak self] in
                DownloadedHUDCard(name: name) { self?.model.revealDownloadedFile() }
            }
        )
        _ = host.hud.present(request)
    }
}

// MARK: - Live activity

extension DroploadDroplet: LiveActivityProviding {
    public var liveActivityState: AnyPublisher<LiveActivityState?, Never> {
        activitySubject.eraseToAnyPublisher()
    }

    /// Asks for the compact seat only while a download is running, and stands
    /// down the moment it ends: the shelf widget is where the finished file is.
    private func publishActivity(for phase: DownloadModel.Phase) {
        switch phase {
        case .downloading, .postProcessing:
            activitySubject.send(
                LiveActivityState(
                    // Below Droppy's own timers and calls: a download is a
                    // status, not something the user is waiting on the second.
                    priority: 150,
                    accessibilityTitle: "Downloading",
                    isInteractive: false,
                    joinsPersistentActivitySet: false,
                    compactPresentation: nil,
                    expandedWidgetID: Self.widgetID.rawValue
                )
            )
        default:
            activitySubject.send(nil)
        }
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
