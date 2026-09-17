//
//  DroploadWidget.swift
//  Dropload
//
//  The shelf widget. Solo: URL bar, pickers, action row. Paired: URL bar and
//  a single download/progress control. Branch on `context.isPaired`, never on a width.
//

import DroppyKit
import SwiftUI

struct DroploadWidget: View {
    /// The rectangle the widget asks the shelf for, measured off the solo
    /// stack: the header row (15), the URL bar (28), the pickers (20) and the
    /// action row (25), with a `DroppySpacing.sm` step between them. The
    /// paired composition drops the pickers and needs less, but a widget
    /// declares one height for both.
    static let soloContentHeight: CGFloat = 15 + 28 + 20 + 25 + 3 * DroppySpacing.sm

    let droplet: DroploadDroplet
    @ObservedObject var model: DownloadModel
    let context: ShelfWidgetContext

    var body: some View {
        VStack(alignment: .leading, spacing: DroppySpacing.sm) {
            header
            URLBar(model: model)
            if !context.isPaired {
                FormatPickers(model: model)
            }
            Spacer(minLength: 0)
            if model.toolStatus.isReady {
                DownloadActionRow(model: model, compact: context.isPaired)
            } else {
                ToolInstallRow(model: model)
            }
        }
        .padding(context.contentInsets)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var header: some View {
        HStack(spacing: DroppySpacing.xsm) {
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 12, weight: .medium))
            Text("Dropload")
                .font(.system(size: 12, weight: .semibold))
            Spacer(minLength: 0)
            if !context.isPaired {
                Button {
                    droplet.openDetail()
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                }
                .buttonStyle(DroppyCircleButtonStyle(size: 20))
                .help("Open Dropload")
            }
        }
        .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
    }
}

/// Stands in for the action row until yt-dlp is ready: what is missing, an
/// Install button, and a progress bar while it installs.
struct ToolInstallRow: View {
    @ObservedObject var model: DownloadModel

    var body: some View {
        Group {
            if case .installing(let progress) = model.toolStatus {
                VStack(alignment: .leading, spacing: DroppySpacing.xs) {
                    HStack(spacing: DroppySpacing.xsm) {
                        Text("Installing yt-dlp…")
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
                    if showsInstall {
                        Button("Install") { model.installTools() }
                            .buttonStyle(DroppyAccentButtonStyle(size: .small))
                    }
                }
                .transition(DroppyTransition.element)
            }
        }
        .animation(DroppyAnimation.state, value: model.toolStatus)
    }

    private var message: String {
        switch model.toolStatus {
        case .failed(let reason): reason
        case .unknown: "Checking yt-dlp…"
        default: "yt-dlp is needed"
        }
    }

    private var showsInstall: Bool {
        switch model.toolStatus {
        case .missing, .failed: true
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
