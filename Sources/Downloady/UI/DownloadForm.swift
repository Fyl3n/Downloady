//
//  DownloadForm.swift
//  Downloady
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
            if let source = model.autoFilledBrowser {
                Image(systemName: source.family == .safari ? "safari" : "globe")
                    .font(.system(size: 11))
                    .foregroundStyle(AdaptiveColors.notchSurfaceTertiaryText)
                    .help("From \(source.name)")
                    .accessibilityLabel("From \(source.name)")
                    .transition(DroppyTransition.element)
            }
            TextField(
                "Paste a video link",
                text: Binding(get: { model.urlText }, set: { model.userEditedURL($0) })
            )
            .textFieldStyle(.plain)
            .font(.system(size: 12))
            .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
            .onSubmit { model.fetchInfo() }

            stateGlyph
                .frame(width: 14, height: 14)

            Button {
                model.pasteURL(NSPasteboard.general.string(forType: .string))
            } label: {
                Image(systemName: "doc.on.clipboard")
            }
            .buttonStyle(DroppyCircleButtonStyle(size: 20))
            .help("Paste link")
        }
        .padding(.leading, DroppySpacing.sm)
        .padding(.trailing, DroppySpacing.xs)
        .padding(.vertical, DroppySpacing.xs)
        .background(
            RoundedRectangle(cornerRadius: DroppyRadius.sm, style: .continuous)
                .fill(AdaptiveColors.notchSurfaceCardFill)
        )
        .animation(DroppyAnimation.state, value: model.autoFilledBrowser)
        .onAppear { model.formDidAppear() }
        .onDisappear { model.formDidDisappear() }
    }

    @ViewBuilder
    private var stateGlyph: some View {
        Group {
            switch model.phase {
            case .unsupported:
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Color(nsColor: .systemOrange))
                    .help("yt-dlp cannot download from this page")
            case .failed(let message):
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Color(nsColor: .systemOrange))
                    .help(message)
            default:
                // Only a link yt-dlp has claimed; the card carries the
                // lookup's own spinner.
                if model.linkIsConfirmed {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color(nsColor: .systemGreen))
                        .help(model.info?.title ?? "Ready to download")
                } else {
                    Color.clear
                }
            }
        }
        .font(.system(size: 12))
        .transition(DroppyTransition.element)
        .id(glyphID)
    }

    private var glyphID: String {
        switch model.phase {
        case .unsupported, .failed: "warning"
        default: model.linkIsConfirmed ? "ready" : "none"
        }
    }
}

/// The pickers, in two titled groups split by a thin rule: Format (video
/// container, audio format) and Quality (video definition, audio bitrate),
/// video first in both so each column lines up with its partner.
///
/// Audio only is the switch in `MediaCard` (and in Settings), not a quality:
/// while it is on, both video pickers are disabled. Qualities the fetched URL
/// cannot reach are disabled, the audio format picker offers only what
/// `AudioFormat.isAvailable(with:container:)` allows, and the bitrate picker
/// is disabled for lossless output.
struct FormatPickers: View {
    @ObservedObject var model: DownloadModel
    /// The shelf's download, or Settings' default.
    var target: FormatTarget = .current

    private var inSettings: Bool { target == .defaults }
    private var options: Binding<DownloadOptions> { target.options(model) }
    private var availability: FormatAvailability { target.availability(model) }

    /// The section title (13), its step, and the picker row (20).
    static let height: CGFloat = 13 + DroppySpacing.xs + 20

    var body: some View {
        HStack(alignment: .top, spacing: DroppySpacing.md) {
            group("Format") {
                Picker("Video format", selection: options.container) {
                    ForEach(VideoContainer.allCases) { container in
                        Label(container.title, systemImage: "film")
                            .tag(container)
                            .disabled(!availability.containers.contains(container))
                    }
                }
                .disabled(options.wrappedValue.quality == .audioOnly)
                Picker("Audio format", selection: options.audio) {
                    ForEach(audioChoices) { audio in
                        Label(audio.title, systemImage: "waveform")
                            .tag(audio)
                            .disabled(!availability.audioFormats.contains(audio))
                    }
                }
            }
            rule
            group("Quality") {
                Picker("Video quality", selection: target.videoQuality(model)) {
                    ForEach(DownloadQuality.allCases.filter(\.includesVideo)) { quality in
                        Label(quality.title, systemImage: "film")
                            .tag(quality)
                            .disabled(!availability.qualities.contains(quality))
                    }
                }
                .disabled(options.wrappedValue.quality == .audioOnly)
                Picker("Audio quality", selection: options.audioQuality) {
                    ForEach(AudioQuality.allCases) { quality in
                        Label(quality.title, systemImage: "waveform")
                            .tag(quality)
                    }
                }
                .disabled(!options.wrappedValue.normalized.usesAudioQuality)
            }
            rule
            group("Text") {
                Picker("Transcript", selection: options.transcript) {
                    ForEach(TranscriptMode.allCases) { mode in
                        Label(mode.title, systemImage: "text.quote")
                            .tag(mode)
                            .disabled(!model.isTranscriptModeAvailable(mode, isDefault: inSettings))
                            .help(mode == .transcribe ? transcribeItemTip ?? "" : "")
                    }
                }
                .help(transcriptTip)
            }
            // One picker, not two: the group takes the width of its content.
            .fixedSize()
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .controlSize(.small)
    }

    private var rule: some View {
        Rectangle()
            .fill(inSettings ? AdaptiveColors.overlayAuto(0.12) : AdaptiveColors.notchSurfaceCardFill)
            .frame(width: 1, height: Self.height)
    }

    /// Why Transcribe is greyed out, on the item itself.
    private var transcribeItemTip: String? {
        guard !model.canTranscribeLocally else { return nil }
        if model.speechIsDenied { return Self.speechDeniedTip }
        return model.transcriptionUnavailableReason
    }

    static let speechDeniedTip =
        "Transcribe is off: speech recognition is not allowed for Droppy. Grant it in Downloady's settings."

    private var transcriptTip: String {
        if model.speechIsDenied { return Self.speechDeniedTip }
        if inSettings {
            return "Every new download starts on this. Subtitles come from the site; a transcript is made on this Mac."
        }
        if !model.isTranscriptModeAvailable(.subtitles) {
            return model.canTranscribeLocally
                ? "This page has no subtitles. Transcribe makes one on this Mac, in the background."
                : "This page has no subtitles, and transcribing needs macOS 26 or later."
        }
        return "Writes an .srt beside the video: the site's subtitles, or one made on this Mac."
    }

    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: DroppySpacing.xs) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(inSettings ? AdaptiveColors.secondaryTextAuto : AdaptiveColors.notchSurfaceSecondaryText)
                .frame(height: 13)
            HStack(spacing: DroppySpacing.xsm) {
                content()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var audioChoices: [AudioFormat] {
        AudioFormat.allCases.filter {
            $0.isAvailable(with: options.wrappedValue.quality, container: options.wrappedValue.container)
        }
    }
}

/// Which format the pickers edit: the download in the shelf, or the default
/// Settings keeps for every new one. The default knows no URL, so every
/// choice is open.
enum FormatTarget {
    case current
    case defaults

    @MainActor func options(_ model: DownloadModel) -> Binding<DownloadOptions> {
        switch self {
        case .current: Binding(get: { model.options }, set: { model.options = $0 })
        case .defaults: Binding(get: { model.defaultOptions }, set: { model.defaultOptions = $0 })
        }
    }

    @MainActor func availability(_ model: DownloadModel) -> FormatAvailability {
        self == .current ? model.availability : .unrestricted
    }

    @MainActor func videoQuality(_ model: DownloadModel) -> Binding<DownloadQuality> {
        switch self {
        case .current: Binding(get: { model.videoQuality }, set: { model.videoQuality = $0 })
        case .defaults: Binding(get: { model.defaultVideoQuality }, set: { model.defaultVideoQuality = $0 })
        }
    }

    @MainActor func audioOnly(_ model: DownloadModel) -> Binding<Bool> {
        switch self {
        case .current: Binding(get: { model.isAudioOnly }, set: { model.setAudioOnly($0) })
        case .defaults: Binding(
            get: { model.defaultOptions.quality == .audioOnly },
            set: { model.setDefaultAudioOnly($0) }
        )
        }
    }
}

/// The audio-only switch, a mini switch with its label.
struct AudioOnlySwitch: View {
    @ObservedObject var model: DownloadModel
    var target: FormatTarget = .current

    private var inSettings: Bool { target == .defaults }

    var body: some View {
        // The label is its own Text, next to a switch whose label is hidden,
        // so it reads the same wherever the switch sits.
        HStack(spacing: DroppySpacing.xs) {
            Toggle("Audio only", isOn: target.audioOnly(model))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
            Text("Audio only")
                .font(.system(size: 11))
                .foregroundStyle(inSettings ? AdaptiveColors.secondaryTextAuto : AdaptiveColors.notchSurfaceSecondaryText)
                .lineLimit(1)
        }
        .disabled(target == .current && !model.availability.qualities.contains(.audioOnly))
        .fixedSize()
    }
}

/// The detected media as a raised tile: the preview on the left (the
/// thumbnail, else the site's favicon, else a glyph), the title on the right
/// and, under it, the audio-only switch when the media has video.
struct MediaCard: View {
    @ObservedObject var model: DownloadModel
    var thumbnailSize = CGSize(width: 64, height: 36)

    /// The card around a thumbnail of `thumbnailSize`.
    static func height(thumbnailHeight: CGFloat) -> CGFloat {
        thumbnailHeight + 2 * DroppySpacing.xsm
    }

    var body: some View {
        HStack(spacing: DroppySpacing.sm) {
            MediaPreview(model: model)
                .frame(width: thumbnailSize.width, height: thumbnailSize.height)
                .clipShape(RoundedRectangle(cornerRadius: DroppyRadius.sm, style: .continuous))
            VStack(alignment: .leading, spacing: DroppyRadius.micro) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
                    .lineLimit(1)
                    .help(title)
                HStack(spacing: DroppySpacing.xsm) {
                    if model.mediaHasVideo {
                        AudioOnlySwitch(model: model)
                    } else if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 11))
                            .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                            .lineLimit(1)
                            .help(subtitle)
                    }
                    Spacer(minLength: 0)
                    if let duration = model.info?.duration, duration > 0 {
                        Text(Self.formatDuration(duration))
                            .font(.system(size: 11))
                            .monospacedDigit()
                            .foregroundStyle(AdaptiveColors.notchSurfaceTertiaryText)
                    }
                }
                .frame(minHeight: 16)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(DroppySpacing.xsm)
        .frame(height: Self.height(thumbnailHeight: thumbnailSize.height))
        .background(
            RoundedRectangle(cornerRadius: DroppyRadius.small, style: .continuous)
                .fill(AdaptiveColors.notchSurfaceCardFill)
        )
        .animation(DroppyAnimation.state, value: model.info)
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
            if let extractor = info.extractorKey, info.isDedicatedExtractor { return extractor }
            return nil
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

/// The card's preview: the fetched thumbnail, falling back to the page's
/// favicon, falling back to a glyph. The images come from the model, which
/// keeps those of the last few lookups, so a card shown again is complete at
/// once.
struct MediaPreview: View {
    @ObservedObject var model: DownloadModel

    var body: some View {
        ZStack {
            AdaptiveColors.notchSurfaceCardFill
            if model.phase == .fetchingInfo {
                ProgressView()
                    .controlSize(.small)
            } else if let thumbnail = Self.httpsURL(model.info?.thumbnail) {
                switch model.previewImage(at: thumbnail) {
                case .image(let image):
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                case .failed:
                    favicon
                case nil:
                    glyph.task(id: thumbnail) { model.loadPreviewImage(at: thumbnail) }
                }
            } else {
                favicon
            }
        }
    }

    @ViewBuilder
    private var favicon: some View {
        if model.info != nil, let url = Self.faviconURL(page: model.info?.webpageURL ?? model.urlText) {
            if case .image(let image) = model.previewImage(at: url) {
                Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                    .frame(width: 18, height: 18)
            } else {
                glyph.task(id: url) { model.loadPreviewImage(at: url) }
            }
        } else {
            glyph
        }
    }

    private var glyph: some View {
        Image(systemName: "play.rectangle")
            .font(.system(size: 14))
            .foregroundStyle(AdaptiveColors.notchSurfaceTertiaryText)
    }

    static func httpsURL(_ string: String?) -> URL? {
        guard let string, let url = URL(string: string), url.scheme == "https" else { return nil }
        return url
    }

    /// `https://<host>/favicon.ico` for the page, the one place every site
    /// is expected to answer, without asking a third-party favicon service.
    static func faviconURL(page: String) -> URL? {
        guard let host = DownloadModel.webURL(from: page)?.host(), !host.isEmpty else { return nil }
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = "/favicon.ico"
        return components.url
    }
}

/// The bottom row.
///
/// It follows the job started from the link in the bar: the format summary
/// and Download before it starts, then its progress with Cancel, then the
/// file with Show in Finder. Everything else Downloady is doing sits in the
/// queue button beside the others, which opens the queue.
struct DownloadActionRow: View {
    @ObservedObject var model: DownloadModel
    /// Paired widget: only the controls, no status text.
    var compact = false
    /// The widget offers Format…, which opens the takeover with the pickers.
    var onOpenFormats: (() -> Void)?
    /// Opens the queue surface.
    var onOpenQueue: (() -> Void)?

    private var job: DownloadJob? { model.currentJob }

    var body: some View {
        Group {
            if let job {
                switch job.state {
                case .finished:
                    finishedRow(job)
                        .id("finished")
                case .failed(let message):
                    idleRow(text: message, icon: "exclamationmark.triangle.fill", tip: message)
                        .id("failed")
                default:
                    progressRow(job)
                        .id("progress")
                }
            } else if case .failed(let message) = model.phase {
                idleRow(text: message, icon: "exclamationmark.triangle.fill", tip: message)
                    .id("failed")
            } else {
                idleRow(text: model.options.summary, icon: nil, tip: nil)
                    .id("idle")
            }
        }
        .transition(DroppyTransition.element)
        .animation(DroppyAnimation.state, value: rowKind)
    }

    private func progressRow(_ job: DownloadJob) -> some View {
        HStack(spacing: DroppySpacing.xsm) {
            VStack(alignment: .leading, spacing: DroppySpacing.xs) {
                if !compact {
                    Text(job.statusText)
                        .font(.system(size: 11))
                        .monospacedDigit()
                        .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                        .lineLimit(1)
                }
                ToolProgressBar(fraction: job.fraction ?? 0, label: "Download progress")
            }
            .help(job.statusText)
            queueButton
            Button {
                model.cancelJob(job.id)
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(DroppyCircleButtonStyle(size: 24))
            .help(job.isTranscribing ? "Stop transcribing" : "Cancel download")
        }
    }

    private func finishedRow(_ job: DownloadJob) -> some View {
        HStack(spacing: DroppySpacing.xsm) {
            if !compact, let file = job.file {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Color(nsColor: .systemGreen))
                Text(file.lastPathComponent)
                    .font(.system(size: 11))
                    .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .layoutPriority(-1)
                    .help(job.transcript.map { "\(file.path)\n\($0.lastPathComponent)" } ?? file.path)
            }
            Spacer(minLength: 0)
            queueButton
            if let file = job.file {
                Button("Show in Finder") { model.reveal(file) }
                    .buttonStyle(DroppyQuietButtonStyle(size: .small))
            }
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
                    .truncationMode(.tail)
                    // The buttons keep their width; the status gives way, so
                    // a long summary can never push them out of the widget.
                    .layoutPriority(-1)
                    .help(tip ?? text)
            }
            Spacer(minLength: 0)
            queueButton
            if let onOpenFormats {
                if compact {
                    Button(action: onOpenFormats) {
                        Image(systemName: "ellipsis.circle")
                    }
                    .buttonStyle(BareIconButtonStyle())
                    .help("Format…")
                } else {
                    Button("Format…", action: onOpenFormats)
                        .buttonStyle(DroppyQuietButtonStyle(size: .small))
                }
            }
            Button { model.startDownload() } label: {
                Label("Download", systemImage: "arrow.down.circle")
            }
            .buttonStyle(DroppyAccentButtonStyle(size: .small))
            .disabled(!model.canDownload)
        }
    }

    /// The way into the queue. It stays as long as the queue holds anything,
    /// the job this form is showing included, so a finished download never
    /// takes the way to the others with it.
    @ViewBuilder
    private var queueButton: some View {
        if let onOpenQueue, !model.jobs.isEmpty {
            QueueButton(jobs: model.jobs, action: onOpenQueue)
                .transition(DroppyTransition.element)
        }
    }

    private var rowKind: String {
        guard let job else {
            if case .failed = model.phase { return "failed" }
            return "idle"
        }
        switch job.state {
        case .finished: return "finished"
        case .failed: return "failed"
        default: return "progress"
        }
    }
}

/// The way into the queue: a stacked-list glyph laid straight on the
/// surface, with a small spinner at its bottom-right corner while something
/// is downloading or transcribing.
struct QueueButton: View {
    let jobs: [DownloadJob]
    let action: () -> Void

    private var summary: QueueSummary { QueueSummary(jobs: jobs) }

    var body: some View {
        Button(action: action) {
            Image(systemName: "list.bullet")
                .overlay(alignment: .bottomTrailing) {
                    if summary.isActive {
                        QueueSpinner()
                            .frame(width: 9, height: 9)
                            .offset(x: 5, y: 2)
                            .transition(.opacity)
                    }
                }
        }
        .buttonStyle(BareIconButtonStyle())
        .animation(DroppyAnimation.state, value: summary.isActive)
        .help(helpText)
        .accessibilityLabel("Downloads queue")
        .accessibilityValue(helpText)
    }

    private var helpText: String {
        guard summary.isActive else { return "Recent downloads" }
        return summary.activeCount == 1 ? "1 job running" : "\(summary.activeCount) jobs running"
    }
}

/// An icon button with no plate behind it: the glyph alone, larger than it
/// would be inside a glass circle, dimming while pressed and when disabled.
struct BareIconButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
            .frame(width: 24, height: 24)
            .contentShape(Rectangle())
            .opacity(isEnabled ? (configuration.isPressed ? 0.5 : 0.85) : 0.35)
            .animation(DroppyAnimation.state, value: configuration.isPressed)
    }
}

/// A small ring with an arc turning on it while the queue works. It says
/// "busy", not "how far": the queue itself has the numbers.
struct QueueSpinner: View {
    @State private var turning = false

    var body: some View {
        Circle()
            .trim(from: 0, to: 0.3)
            .stroke(AdaptiveColors.selectionBlueAuto, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
            .background(Circle().stroke(AdaptiveColors.notchSurfaceCardFill, lineWidth: 1.5))
            .rotationEffect(.degrees(turning ? 360 : 0))
            .animation(.linear(duration: 1).repeatForever(autoreverses: false), value: turning)
            .onAppear { turning = true }
            .accessibilityHidden(true)
    }
}
