//
//  DownloadForm.swift
//  Dropload
//
//  The pieces the widget and the takeover share: the URL bar, the three
//  pickers, and the row that shows the download.
//

import AppKit
import DroppyKit
import SwiftUI

/// The URL bar: a raised chip with the field, a state glyph for `phase`
/// (spinner while fetching, checkmark when ready, warning when unsupported
/// or failed) and a paste button.
struct URLBar: View {
    @ObservedObject var model: DownloadModel

    var body: some View {
        HStack(spacing: DroppySpacing.xsm) {
            TextField(
                "Paste a video link",
                text: Binding(get: { model.urlText }, set: { model.userEditedURL($0) })
            )
            .textFieldStyle(.plain)
            .font(.system(size: 12))
            .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
            .disabled(model.isBusy)
            .onSubmit { model.fetchInfo() }

            stateGlyph
                .frame(width: 14, height: 14)

            Button {
                model.pasteURL(NSPasteboard.general.string(forType: .string))
            } label: {
                Image(systemName: "doc.on.clipboard")
            }
            .buttonStyle(DroppyCircleButtonStyle(size: 20))
            .disabled(model.isBusy)
            .help("Paste link")
        }
        .padding(.leading, DroppySpacing.sm)
        .padding(.trailing, DroppySpacing.xs)
        .padding(.vertical, DroppySpacing.xs)
        .background(
            RoundedRectangle(cornerRadius: DroppyRadius.sm, style: .continuous)
                .fill(AdaptiveColors.notchSurfaceCardFill)
        )
    }

    @ViewBuilder
    private var stateGlyph: some View {
        Group {
            switch model.phase {
            case .fetchingInfo:
                ProgressView()
                    .controlSize(.mini)
                    .help("Looking up the link")
            case .ready(let info):
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Color(nsColor: .systemGreen))
                    .help(info.title)
            case .unsupported:
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Color(nsColor: .systemOrange))
                    .help("yt-dlp cannot download from this page")
            case .failed(let message):
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Color(nsColor: .systemOrange))
                    .help(message)
            default:
                Color.clear
            }
        }
        .font(.system(size: 12))
        .transition(DroppyTransition.element)
        .id(glyphID)
    }

    private var glyphID: String {
        switch model.phase {
        case .fetchingInfo: "fetching"
        case .ready: "ready"
        case .unsupported, .failed: "warning"
        default: "none"
        }
    }
}

/// Quality, video container, audio format.
///
/// Qualities the fetched URL cannot reach are disabled, the video picker is
/// disabled for audio only, and the audio picker offers only what
/// `AudioFormat.isAvailable(with:container:)` allows.
struct FormatPickers: View {
    @ObservedObject var model: DownloadModel

    var body: some View {
        HStack(spacing: DroppySpacing.xsm) {
            Picker("Quality", selection: $model.options.quality) {
                ForEach(DownloadQuality.allCases) { quality in
                    Text(quality.title)
                        .tag(quality)
                        .disabled(!model.availability.qualities.contains(quality))
                }
            }
            Picker("Video", selection: $model.options.container) {
                ForEach(VideoContainer.allCases) { container in
                    Text(container.title)
                        .tag(container)
                        .disabled(!model.availability.containers.contains(container))
                }
            }
            .disabled(!model.options.quality.includesVideo)
            Picker("Audio", selection: $model.options.audio) {
                ForEach(audioChoices) { audio in
                    Text(audio.title)
                        .tag(audio)
                        .disabled(!model.availability.audioFormats.contains(audio))
                }
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .controlSize(.small)
        .disabled(model.isBusy)
    }

    private var audioChoices: [AudioFormat] {
        AudioFormat.allCases.filter {
            $0.isAvailable(with: model.options.quality, container: model.options.container)
        }
    }
}

/// The bottom row: status and Download, the progress with Cancel while it
/// runs, the file with Show in Finder when done, the error when it failed.
struct DownloadActionRow: View {
    @ObservedObject var model: DownloadModel
    /// Paired widget: only the control, no status text.
    var compact = false
    /// The takeover shows the title and lookup state above; skip them here.
    var showsLookupStatus = true

    var body: some View {
        Group {
            switch model.phase {
            case .downloading(let fraction, let speed, let eta):
                progressRow(fraction: fraction, detail: Self.progressDetail(fraction: fraction, speed: speed, eta: eta))
                    .id("progress")
            case .postProcessing:
                progressRow(fraction: 1, detail: "Finishing…")
                    .id("progress")
            case .finished(let file):
                finishedRow(file)
                    .id("finished")
            case .failed(let message):
                idleRow(text: message, icon: "exclamationmark.triangle.fill", tip: message)
                    .id("failed")
            default:
                idleRow(text: showsLookupStatus ? statusText : "", icon: nil, tip: nil)
                    .id("idle")
            }
        }
        .transition(DroppyTransition.element)
        .animation(DroppyAnimation.state, value: phaseKind)
    }

    private func progressRow(fraction: Double, detail: String) -> some View {
        HStack(spacing: DroppySpacing.xsm) {
            VStack(alignment: .leading, spacing: DroppySpacing.xs) {
                if !compact {
                    Text(detail)
                        .font(.system(size: 11))
                        .monospacedDigit()
                        .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                        .lineLimit(1)
                }
                ToolProgressBar(fraction: fraction, label: "Download progress")
            }
            .help(detail)
            Button {
                model.cancelDownload()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(DroppyCircleButtonStyle(size: 24))
            .help("Cancel download")
        }
    }

    private func finishedRow(_ file: URL) -> some View {
        HStack(spacing: DroppySpacing.xsm) {
            if !compact {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Color(nsColor: .systemGreen))
                Text(file.lastPathComponent)
                    .font(.system(size: 11))
                    .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(file.path)
            }
            Spacer(minLength: 0)
            Button("Show in Finder") { model.revealDownloadedFile() }
                .buttonStyle(DroppyQuietButtonStyle(size: .small))
        }
    }

    private func idleRow(text: String, icon: String?, tip: String?) -> some View {
        HStack(spacing: DroppySpacing.xsm) {
            if !compact {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 11))
                        .foregroundStyle(Color(nsColor: .systemOrange))
                }
                Text(text)
                    .font(.system(size: 11))
                    .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                    .lineLimit(1)
                    .help(tip ?? text)
            }
            Spacer(minLength: 0)
            Button("Download") { model.startDownload() }
                .buttonStyle(DroppyAccentButtonStyle(size: .small))
                .disabled(!model.canDownload)
        }
    }

    private var statusText: String {
        switch model.phase {
        case .fetchingInfo: "Looking up the link…"
        case .ready(let info): info.title
        case .unsupported: "Unsupported page"
        default: model.urlText.isEmpty ? "Paste a link to start" : ""
        }
    }

    private var phaseKind: String {
        switch model.phase {
        case .downloading, .postProcessing: "progress"
        case .finished: "finished"
        case .failed: "failed"
        default: "idle"
        }
    }

    static func progressDetail(fraction: Double, speed: String?, eta: String?) -> String {
        var parts = [fraction.formatted(.percent.precision(.fractionLength(0)))]
        if let speed { parts.append(speed) }
        if let eta { parts.append("\(eta) left") }
        return parts.joined(separator: " · ")
    }
}
