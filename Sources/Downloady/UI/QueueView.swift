//
//  QueueView.swift
//  Downloady
//
//  The queue takeover: every job Downloady is working on or just finished,
//  one row each, with the only two things a row needs — stop it, or show the
//  file it left.
//

import DroppyKit
import SwiftUI

struct QueueView: View {
    /// The header: the back button (24) sets its height.
    static let headerHeight: CGFloat = 24
    static let rowHeight: CGFloat = 40
    /// Rows past this one scroll rather than make the surface taller.
    static let visibleRows = 4

    /// What the surface asks the host for, for the rows it has now: the
    /// header, the rows and the one-point rules between them.
    static func contentHeight(rows: Int) -> CGFloat {
        let count = CGFloat(max(1, min(rows, visibleRows)))
        return headerHeight
            + count * rowHeight + (count - 1)
            + DroppySpacing.md + 2 * DroppySpacing.lg
    }

    let droplet: DownloadyDroplet
    @ObservedObject var model: DownloadModel
    let context: ExpandedSurfaceContext

    var body: some View {
        VStack(alignment: .leading, spacing: DroppySpacing.md) {
            HStack(spacing: DroppySpacing.sm) {
                Button {
                    droplet.closeQueue()
                } label: {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(DroppyCircleButtonStyle(size: 24))
                .help("Back")
                Text("Downloads")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
                Spacer(minLength: 0)
                if model.jobs.contains(where: { !$0.isActive }) {
                    Button("Clear finished") { model.clearFinishedJobs() }
                        .buttonStyle(DroppyQuietButtonStyle(size: .small))
                }
            }
            .frame(height: Self.headerHeight)

            if model.jobs.isEmpty {
                Text("Nothing in the queue.")
                    .font(.system(size: 11))
                    .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                ScrollView(.vertical) {
                    VStack(spacing: 0) {
                        ForEach(Array(model.jobs.enumerated()), id: \.element.id) { index, job in
                            if index > 0 {
                                Rectangle()
                                    .fill(AdaptiveColors.notchSurfaceCardFill)
                                    .frame(height: 1)
                            }
                            QueueRow(model: model, job: job)
                        }
                    }
                }
                .scrollIndicators(.never)
                // No Spacer under it: the list takes the room the surface was
                // measured for, instead of sharing it with empty space.
                .frame(maxHeight: .infinity, alignment: .top)
            }
        }
        .droppyFlatGlassControls()
        .padding(DroppySpacing.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .animation(DroppyAnimation.state, value: model.jobs)
    }
}

/// One job: what it is, how far along, and the one control it deserves.
struct QueueRow: View {
    @ObservedObject var model: DownloadModel
    let job: DownloadJob

    var body: some View {
        HStack(spacing: DroppySpacing.sm) {
            Image(systemName: job.systemImage)
                .font(.system(size: 12))
                .foregroundStyle(glyphColor)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: DroppySpacing.xs) {
                Text(job.title)
                    .font(.system(size: 12))
                    .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
                    .lineLimit(1)
                    .help(job.url.absoluteString)
                HStack(spacing: DroppySpacing.xsm) {
                    // The bar keeps its width so the words beside it are
                    // never the part that gives way.
                    if let fraction = job.fraction, job.isActive {
                        ToolProgressBar(fraction: fraction, label: "Progress")
                            .frame(width: 72)
                    }
                    Text(job.statusText)
                        .font(.system(size: 11))
                        .monospacedDigit()
                        .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(job.statusText)
                    Spacer(minLength: 0)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            trailing
        }
        .frame(height: QueueView.rowHeight)
    }

    @ViewBuilder
    private var trailing: some View {
        if job.isActive {
            Button {
                model.cancelJob(job.id)
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(DroppyCircleButtonStyle(size: 28))
            .help(job.isTranscribing ? "Stop transcribing" : "Cancel download")
        } else if let file = job.file {
            Button {
                model.reveal(job.transcript ?? file)
            } label: {
                Image(systemName: "folder")
            }
            .buttonStyle(DroppyCircleButtonStyle(size: 28))
            .help("Show in Finder")
        } else {
            Button {
                model.cancelJob(job.id)
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(DroppyCircleButtonStyle(size: 28))
            .help("Remove")
        }
    }

    private var glyphColor: Color {
        switch job.state {
        case .finished: Color(nsColor: .systemGreen)
        case .failed: Color(nsColor: .systemOrange)
        default: AdaptiveColors.notchSurfaceSecondaryText
        }
    }
}
