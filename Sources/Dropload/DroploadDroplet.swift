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

    private(set) var host: DropletHost?
    public let model = DownloadModel()

    public func activate(host: DropletHost) throws {
        self.host = host
        model.start(host: host)
        host.log.info("Dropload activated")
    }

    public func deactivate() {
        // Everything activate() started is torn down here. Swift cannot unload
        // code, so anything left running keeps running until Droppy relaunches.
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
                    contentHeight: .fixed(150)
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
        CGSize(
            width: max(proposal.standardSize.width, 460),
            height: min(proposal.maximumSize.height, 260)
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
