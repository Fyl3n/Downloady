//
//  DownloadyWidget.swift
//  Downloady
//
//  The shelf widget: one card, the URL bar on top, a full-width rule, and
//  under it the preview zone: the thumbnail, the title, and on the zone's
//  bottom line the audio-only switch with the format ellipsis and Download
//  at the trailing end. Paired drops the switch and Download's label.
//  Branch on `context.isPaired`, never on a width.
//

import DroppyKit
import SwiftUI

struct DownloadyWidget: View {
    /// The card's corners, which the preview inside it repeats.
    static let cornerRadius = DroppyRadius.medium
    /// The URL bar's buttons.
    static let urlButtonSize: CGFloat = 24
    /// The URL bar: its buttons inside `DroppySpacing.xs` above and below.
    static let urlRowHeight: CGFloat = urlButtonSize + 2 * DroppySpacing.xs

    let droplet: DownloadyDroplet
    @ObservedObject var model: DownloadModel
    let context: ShelfWidgetContext

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: DroppySpacing.xs) {
                URLBar(model: model, isBare: true, buttonSize: Self.urlButtonSize)
                if !context.isPaired {
                    Button {
                        droplet.openDetail()
                    } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                    }
                    .buttonStyle(DroppyCircleButtonStyle(size: Self.urlButtonSize))
                    .help("Open Downloady")
                    .padding(.trailing, DroppySpacing.xs)
                }
            }
            .frame(height: Self.urlRowHeight)
            Rectangle()
                .fill(AdaptiveColors.notchSurfaceCardFill)
                .frame(height: 1)
            MediaCard(
                model: model,
                bottomRow: AnyView(bottomRow),
                previewCornerRadius: Self.cornerRadius
            )
            // A step tighter above and below than at the sides, so the
            // title keeps a line beside the Download pill at 93pt.
            .padding(.horizontal, DroppySpacing.sm)
            .padding(.vertical, DroppySpacing.xsm)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(
            RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                .fill(AdaptiveColors.notchSurfaceCardFill)
        )
        // The island's inset clears its 34pt arc for a solo card that fills
        // it. In a row the card sits between Droppy's own widgets, which draw
        // flush to their rectangles, and the inset would shrink it by 12pt on
        // every side.
        .padding(context.isPaired ? EdgeInsets() : context.contentInsets)
    }

    @ViewBuilder
    private var bottomRow: some View {
        if model.toolStatus.isReady {
            DownloadActionRow(
                model: model,
                compact: context.isPaired,
                onOpenFormats: { [droplet] in droplet.openDetail() },
                onOpenQueue: { [droplet] in droplet.openQueue(fromDetail: false) },
                idleLeading: context.isPaired || !model.mediaHasVideo
                    ? AnyView(EmptyView()) : AnyView(AudioOnlySwitch(model: model))
            )
        } else {
            ToolInstallRow(model: model) { [droplet] in droplet.openSettings() }
        }
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
        model.installingTools.count > 1 ? "Installing yt-dlp and its helpers…" : "Installing yt-dlp…"
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
