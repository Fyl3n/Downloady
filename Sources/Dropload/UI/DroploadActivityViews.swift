//
//  DroploadActivityViews.swift
//  Dropload
//
//  What Dropload draws outside the shelf: the compact live activity that
//  shows a running download, and the card the completion HUD grows into.
//

import DroppyKit
import SwiftUI

/// The leading wing of the live activity: a ring that fills as the download
/// runs, with the download glyph inside it.
struct DownloadActivityRing: View {
    @ObservedObject var model: DownloadModel

    var body: some View {
        ZStack {
            Circle()
                .stroke(
                    AdaptiveColors.notchSurfaceTertiaryText,
                    lineWidth: DroppyLiveActivityMetrics.progressRingLineWidth
                )
            Circle()
                .trim(from: 0, to: max(fraction, 0.02))
                .stroke(
                    AdaptiveColors.selectionBlueAuto,
                    style: StrokeStyle(
                        lineWidth: DroppyLiveActivityMetrics.progressRingLineWidth,
                        lineCap: .round
                    )
                )
                .rotationEffect(.degrees(-90))
            Image(systemName: "arrow.down")
                .font(.system(size: DroppyLiveActivityMetrics.progressRingGlyphSize, weight: .bold))
                .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
        }
        .frame(
            width: DroppyLiveActivityMetrics.progressRingSize,
            height: DroppyLiveActivityMetrics.progressRingSize
        )
        .padding(.trailing, DroppySpacing.sm)
        .animation(DroppyAnimation.state, value: fraction)
        .accessibilityElement()
        .accessibilityLabel("Download progress")
        .accessibilityValue(Text(fraction, format: .percent.precision(.fractionLength(0))))
    }

    private var fraction: Double {
        switch model.phase {
        case .downloading(let fraction, _, _): min(max(fraction, 0), 1)
        case .postProcessing: 1
        default: 0
        }
    }
}

/// The trailing wing: the percentage, or "Finishing" while ffmpeg muxes.
struct DownloadActivityValue: View {
    @ObservedObject var model: DownloadModel

    var body: some View {
        Text(label)
            .font(.system(size: DroppyLiveActivityMetrics.labelFontSize, weight: .medium, design: .rounded))
            .monospacedDigit()
            .lineLimit(1)
            .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
            .padding(.leading, DroppySpacing.sm)
            .id(label)
            .transition(DroppyTransition.compactContent)
            .animation(DroppyAnimation.state, value: label)
    }

    private var label: String {
        switch model.phase {
        case .downloading(let fraction, _, _):
            fraction.formatted(.percent.precision(.fractionLength(0)))
        case .postProcessing:
            "Finishing"
        default:
            ""
        }
    }
}

/// The card the completion HUD grows into: what landed, and where to see it.
struct DownloadedHUDCard: View {
    let name: String
    let reveal: () -> Void

    var body: some View {
        HStack(spacing: DroppySpacing.sm) {
            VStack(alignment: .leading, spacing: DroppySpacing.xs) {
                Text("Downloaded")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                Text(name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
            Button("Show in Finder", action: reveal)
                .buttonStyle(DroppyQuietButtonStyle(size: .small))
                // The island's card is 208pt wide: the name gives way, the
                // button never truncates its own label.
                .fixedSize()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
