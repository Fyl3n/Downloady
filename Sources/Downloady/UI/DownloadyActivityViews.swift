//
//  DownloadyActivityViews.swift
//  Downloady
//
//  What Downloady draws outside the shelf: the compact live activity that
//  shows a running download, and the card the completion HUD grows into.
//

import DroppyKit
import SwiftUI

/// The leading wing of the live activity: a ring that fills as the download
/// runs, with the download glyph inside it. A Recording alone has no
/// percentage, so it shows its glyph without the ring.
struct DownloadActivityRing: View {
    @ObservedObject var model: DownloadModel

    var body: some View {
        ZStack {
            if !isRecording {
                Group {
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
                }
                .transition(DroppyTransition.compactContent)
            }
            Image(systemName: glyph)
                .font(.system(size: DroppyLiveActivityMetrics.progressRingGlyphSize, weight: .bold))
                .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
                .id(glyph)
                .transition(DroppyTransition.compactContent)
        }
        .frame(
            width: DroppyLiveActivityMetrics.progressRingSize,
            height: DroppyLiveActivityMetrics.progressRingSize
        )
        .padding(.trailing, DroppySpacing.sm)
        .animation(DroppyAnimation.state, value: fraction)
        .animation(DroppyAnimation.state, value: isRecording)
        .accessibilityElement()
        .accessibilityLabel(isRecording ? "Recording" : "Download progress")
        .accessibilityValue(isRecording ? Text("") : Text(fraction, format: .percent.precision(.fractionLength(0))))
    }

    private var fraction: Double {
        min(max(model.summary.fraction, 0), 1)
    }

    /// Whether the Recording leads: nothing else is running.
    private var isRecording: Bool {
        if case .recording = model.summary.leading?.state { true } else { false }
    }

    private var glyph: String {
        guard let leading = model.summary.leading else { return "arrow.down" }
        if leading.isTranscribing { return "text.quote" }
        return isRecording ? leading.systemImage : "arrow.down"
    }
}

/// The trailing wing: the percentage, or "Text" before a transcript has one.
/// While a Recording runs, beside a download or not, a pulsing red record
/// circle instead.
struct DownloadActivityValue: View {
    @ObservedObject var model: DownloadModel

    var body: some View {
        Group {
            if model.summary.isRecording {
                // The pulse is a symbol effect inside one view whose identity
                // stays put, so it never replays the swap transition.
                Image(systemName: "record.circle.fill")
                    .font(.system(size: DroppyLiveActivityMetrics.iconSize, weight: .semibold))
                    .foregroundStyle(Color(nsColor: .systemRed))
                    .symbolEffect(.pulse, options: .repeating)
                    .accessibilityLabel("Recording")
            } else {
                Text(label)
                    .font(.system(size: DroppyLiveActivityMetrics.labelFontSize, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
            }
        }
        .padding(.leading, DroppySpacing.sm)
        // Swapped with a transition only when the label changes kind
        // ("Text" to "3 %", or to the record circle); a percentage tick is a
        // plain redraw, or the transition replays in the notch on every tick.
        .id(stage)
        .transition(DroppyTransition.compactContent)
        .animation(DroppyAnimation.state, value: stage)
    }

    private var label: String { model.summary.activityLabel }

    /// The label without its digits: what changes when the stage does.
    private var stage: String { model.summary.isRecording ? "recording" : label.filter { !$0.isNumber } }
}

/// The card the completion HUD grows into: what landed. No controls: Droppy
/// lets clicks fall through a HUD card, so Show in Finder is on the shelf.
struct DownloadedHUDCard: View {
    let title: String
    let name: String

    var body: some View {
        VStack(alignment: .leading, spacing: DroppySpacing.xs) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
            Text(name)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
