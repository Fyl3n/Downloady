//
//  DownloadyWidget.swift
//  Downloady
//
//  The shelf widget: URL bar, the media card, and the action row with
//  Format… (which opens the takeover's pickers) and Download. Paired keeps
//  the same stack with icon-only controls. Branch on `context.isPaired`,
//  never on a width.
//

import DroppyKit
import SwiftUI

struct DownloadyWidget: View {
    /// The rectangle the widget asks the shelf for, measured off the stack:
    /// the URL bar (28), the media card and the action row (25), with a
    /// `DroppySpacing.sm` step between them, plus the step the first and last
    /// row take away from the rounded corners.
    static let soloContentHeight: CGFloat =
        28 + MediaCard.height(thumbnailHeight: 36) + 25 + 2 * DroppySpacing.sm
            + 2 * DroppySpacing.xs

    let droplet: DownloadyDroplet
    @ObservedObject var model: DownloadModel
    let context: ShelfWidgetContext

    var body: some View {
        VStack(alignment: .leading, spacing: DroppySpacing.sm) {
            HStack(spacing: DroppySpacing.xsm) {
                URLBar(model: model)
                if !context.isPaired {
                    Button {
                        droplet.openDetail()
                    } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                    }
                    .buttonStyle(DroppyCircleButtonStyle(size: 24))
                    .help("Open Downloady")
                }
            }
            // The widget's rectangle has rounded corners, tightest as an
            // island: the first and last row step away from the edge.
            .padding(.top, DroppySpacing.xs)
            MediaCard(model: model)
            Spacer(minLength: 0)
            if model.toolStatus.isReady {
                DownloadActionRow(
                    model: model,
                    compact: context.isPaired,
                    onOpenFormats: { [droplet] in droplet.openDetail() },
                    onOpenQueue: { [droplet] in droplet.openQueue(fromDetail: false) }
                )
                .padding(.horizontal, DroppySpacing.lg)
                .padding(.bottom, DroppySpacing.xs)
            } else {
                ToolInstallRow(model: model) { [droplet] in droplet.openSettings() }
                    .padding(.horizontal, DroppySpacing.lg)
                    .padding(.bottom, DroppySpacing.xs)
            }
        }
        .padding(context.contentInsets)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// Stands in for the action row until yt-dlp is ready: the progress of the
/// automatic install, or what is wrong with a Retry or a way to Settings.
struct ToolInstallRow: View {
    @ObservedObject var model: DownloadModel
    /// Opens Downloady's settings pane, where the tool sources are.
    var openSettings: (() -> Void)?

    var body: some View {
        Group {
            if case .installing(let progress) = model.toolStatus {
                VStack(alignment: .leading, spacing: DroppySpacing.xs) {
                    HStack(spacing: DroppySpacing.xsm) {
                        Text(installLabel)
                            .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                        Spacer(minLength: 0)
                        Text(progress, format: .percent.precision(.fractionLength(0)))
                            .monospacedDigit()
                            .foregroundStyle(AdaptiveColors.notchSurfaceTertiaryText)
                    }
                    .font(.system(size: 11))
                    ToolProgressBar(fraction: progress)
                }
                .transition(DroppyTransition.element)
            } else {
                HStack(spacing: DroppySpacing.xsm) {
                    Text(message)
                        .font(.system(size: 11))
                        .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                        .lineLimit(1)
                        .help(message)
                    Spacer(minLength: 0)
                    if showsRetry {
                        Button("Retry") { model.installTools() }
                            .buttonStyle(DroppyAccentButtonStyle(size: .small))
                    } else if showsSettings, let openSettings {
                        Button("Settings", action: openSettings)
                            .buttonStyle(DroppyQuietButtonStyle(size: .small))
                    }
                }
                .transition(DroppyTransition.element)
            }
        }
        .animation(DroppyAnimation.state, value: model.toolStatus)
    }

    private var installLabel: String {
        model.installingTools.contains(.ffmpeg) && model.installingTools.contains(.ytDlp)
            ? "Installing yt-dlp and ffmpeg…"
            : "Installing yt-dlp…"
    }

    private var message: String {
        switch model.toolStatus {
        case .failed(let reason): return reason
        case .missing:
            switch model.source(for: .ytDlp) {
            case .managed: return "Getting yt-dlp ready…"
            case .system: return "yt-dlp is no longer on this Mac"
            case .custom: return "Choose where yt-dlp is in Settings"
            }
        default: return "Checking yt-dlp…"
        }
    }

    /// Downloady's copy failed to install: the same install, by hand.
    private var showsRetry: Bool {
        if case .failed = model.toolStatus { return model.source(for: .ytDlp) == .managed }
        return false
    }

    private var showsSettings: Bool {
        switch model.toolStatus {
        case .missing, .failed: model.source(for: .ytDlp) != .managed
        default: false
        }
    }
}

/// A thin determinate bar.
struct ToolProgressBar: View {
    let fraction: Double
    var label = "Install progress"

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(AdaptiveColors.notchSurfaceCardFill)
                Capsule(style: .continuous)
                    .fill(AdaptiveColors.selectionBlueAuto)
                    .frame(width: proxy.size.width * min(max(fraction, 0), 1))
            }
        }
        .frame(height: 4)
        .animation(DroppyAnimation.state, value: fraction)
        .accessibilityElement()
        .accessibilityLabel(label)
        .accessibilityValue(Text(fraction, format: .percent.precision(.fractionLength(0))))
    }
}
