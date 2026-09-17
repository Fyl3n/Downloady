//
//  DroploadDetailView.swift
//  Dropload
//
//  The takeover: the same form with room for the fetched title, duration and
//  thumbnail, and the progress of the running download.
//

import DroppyKit
import SwiftUI

struct DroploadDetailView: View {
    let droplet: DroploadDroplet
    @ObservedObject var model: DownloadModel
    let context: ExpandedSurfaceContext

    var body: some View {
        VStack(alignment: .leading, spacing: DroppySpacing.md) {
            URLBar(model: model)
            MediaSummary(model: model)
            FormatPickers(model: model)
            Text(model.options.summary)
                .font(.system(size: 11))
                .foregroundStyle(AdaptiveColors.notchSurfaceTertiaryText)
                .lineLimit(1)
            Spacer(minLength: 0)
            if model.toolStatus.isReady {
                DownloadActionRow(model: model, showsLookupStatus: false)
            } else {
                ToolInstallRow(model: model)
            }
        }
        .padding(DroppySpacing.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// Thumbnail, title and duration of the fetched URL, or what the lookup says.
struct MediaSummary: View {
    @ObservedObject var model: DownloadModel

    private static let thumbnailSize = CGSize(width: 80, height: 45)

    var body: some View {
        HStack(spacing: DroppySpacing.sm) {
            thumbnail
                .frame(width: Self.thumbnailSize.width, height: Self.thumbnailSize.height)
                .clipShape(RoundedRectangle(cornerRadius: DroppyRadius.sm, style: .continuous))
            VStack(alignment: .leading, spacing: DroppySpacing.xs) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
                    .lineLimit(2)
                    .help(title)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .monospacedDigit()
                        .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .animation(DroppyAnimation.state, value: model.info)
    }

    @ViewBuilder
    private var thumbnail: some View {
        let placeholder = ZStack {
            AdaptiveColors.notchSurfaceCardFill
            Image(systemName: model.phase == .fetchingInfo ? "hourglass" : "play.rectangle")
                .font(.system(size: 14))
                .foregroundStyle(AdaptiveColors.notchSurfaceTertiaryText)
        }
        if let string = model.info?.thumbnail, let url = URL(string: string), url.scheme == "https" {
            AsyncImage(url: url) { image in
                image.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                placeholder
            }
        } else {
            placeholder
        }
    }

    private var title: String {
        if let info = model.info { return info.title }
        switch model.phase {
        case .fetchingInfo: return "Looking up the link…"
        case .unsupported: return "Unsupported page"
        case .failed: return "Could not read this link"
        default: return model.urlText.isEmpty ? "Paste a link to start" : "No details yet"
        }
    }

    private var subtitle: String? {
        if let info = model.info {
            var parts: [String] = []
            if let duration = info.duration, duration > 0 {
                parts.append(Self.formatDuration(duration))
            }
            if let extractor = info.extractorKey, info.isDedicatedExtractor {
                parts.append(extractor)
            }
            return parts.isEmpty ? nil : parts.joined(separator: " · ")
        }
        switch model.phase {
        case .unsupported: return "yt-dlp has nothing to download here"
        case .failed(let message): return message
        default: return nil
        }
    }

    static func formatDuration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%d:%02d", minutes, secs)
    }
}
