//
//  DroploadSettingsView.swift
//  Dropload
//
//  Settings, built from DroppyKit's settings rows.
//

import AppKit
import DroppyKit
import SwiftUI

/// TODO(T3): browser auto-fill toggle, Automation permission status with
/// `host.permissions.openSystemSettings(for: .appleEvents)`, list of
/// supported browsers.
struct DroploadSettingsView: View {
    let droplet: DroploadDroplet
    @ObservedObject var model: DownloadModel

    var body: some View {
        VStack(alignment: .leading, spacing: DroppySpacing.lg) {
            ToolsCard(model: model)
            DownloadsCard(model: model)
            DropletSettingsCard {
                DropletToggleRow(
                    title: "Fill in the link from your browser",
                    subtitle: "Reads the current tab of Safari or a Chromium browser when you open the shelf.",
                    isOn: Binding(get: { model.autoFillFromBrowser }, set: { model.autoFillFromBrowser = $0 })
                )
            }
        }
    }
}

/// Where yt-dlp and ffmpeg come from, with Install / Update and the custom
/// path overrides.
struct ToolsCard: View {
    @ObservedObject var model: DownloadModel
    @State private var ytDlpPath = ""
    @State private var ffmpegPath = ""

    var body: some View {
        DropletSettingsCard {
            DropletControlRow(
                title: "yt-dlp",
                icon: "arrow.down.circle",
                infoTip: model.toolStatus.ytDlp?.url.path ?? model.toolUpdateMessage
            ) {
                HStack(spacing: DroppySpacing.xsm) {
                    if let message = model.toolUpdateMessage {
                        Text(message)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    ytDlpPills
                    ytDlpAction
                }
            }
            DropletSettingsDivider()
            DropletControlRow(
                title: "ffmpeg",
                icon: "film",
                infoTip: model.detectedFFmpeg?.url.path
                    ?? "Used to merge video and audio and to convert. Install it with Homebrew, or Dropload downloads a copy."
            ) {
                HStack(spacing: DroppySpacing.xsm) {
                    if let version = model.detectedFFmpeg?.version {
                        DropletValuePill(text: version)
                    }
                    DropletValuePill(text: ffmpegSource)
                }
            }
            DropletSettingsDivider()
            DropletStackedRow(
                title: "Custom paths",
                icon: "folder",
                infoTip: "Use your own executables instead. Leave a field empty to go back to the default."
            ) {
                VStack(alignment: .leading, spacing: DroppySpacing.xsm) {
                    pathField("yt-dlp, e.g. /opt/homebrew/bin/yt-dlp", text: $ytDlpPath) {
                        model.customYtDlpPath = ytDlpPath
                    }
                    pathField("ffmpeg, e.g. /opt/homebrew/bin/ffmpeg", text: $ffmpegPath) {
                        model.customFFmpegPath = ffmpegPath
                    }
                }
            }
        }
        .onAppear {
            ytDlpPath = model.customYtDlpPath ?? ""
            ffmpegPath = model.customFFmpegPath ?? ""
        }
        .onDisappear {
            model.customYtDlpPath = ytDlpPath
            model.customFFmpegPath = ffmpegPath
        }
    }

    @ViewBuilder
    private var ytDlpPills: some View {
        switch model.toolStatus {
        case .ready(let ytDlp, _):
            if let version = ytDlp.version { DropletValuePill(text: version) }
            DropletValuePill(text: ytDlp.source.title)
        case .installing(let progress):
            DropletValuePill(text: "Installing \(Int((progress * 100).rounded()))%")
        case .unknown:
            DropletValuePill(text: "Checking…")
        case .missing, .failed:
            DropletValuePill(text: "Not installed")
        }
    }

    @ViewBuilder
    private var ytDlpAction: some View {
        switch model.toolStatus {
        case .ready(let ytDlp, _) where ytDlp.source == .managed:
            Button(model.isUpdatingTools ? "Checking…" : "Update") { model.updateYtDlp() }
                .buttonStyle(DroppyQuietButtonStyle(size: .small))
                .disabled(model.isUpdatingTools)
        case .missing, .failed:
            Button("Install") { model.installTools() }
                .buttonStyle(DroppyAccentButtonStyle(size: .small))
        default:
            EmptyView()
        }
    }

    private var ffmpegSource: String {
        if let ffmpeg = model.detectedFFmpeg { return ffmpeg.source.title }
        switch model.toolStatus {
        case .unknown, .installing: return "Checking…"
        default: return "Missing"
        }
    }

    private func pathField(_ prompt: String, text: Binding<String>, commit: @escaping () -> Void) -> some View {
        TextField(prompt, text: text)
            .textFieldStyle(.plain)
            .font(.system(size: 12, design: .monospaced))
            .padding(.horizontal, DroppySpacing.sm)
            .padding(.vertical, DroppySpacing.xs)
            .background(
                RoundedRectangle(cornerRadius: DroppyRadius.sm, style: .continuous)
                    .fill(AdaptiveColors.overlayAuto(0.08))
            )
            .onSubmit(commit)
    }
}

/// Where downloads land and what the pickers start on.
struct DownloadsCard: View {
    @ObservedObject var model: DownloadModel

    var body: some View {
        DropletSettingsCard {
            DropletControlRow(
                title: "Download folder",
                icon: "folder",
                infoTip: folderTip
            ) {
                HStack(spacing: DroppySpacing.xsm) {
                    if !model.downloadFolderIsWritable || model.downloadFolderMessage != nil {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(Color(nsColor: .systemOrange))
                            .help(folderTip)
                    }
                    DropletValuePill(text: model.downloadFolder.lastPathComponent)
                    Button("Choose…") { chooseFolder() }
                        .buttonStyle(DroppyQuietButtonStyle(size: .small))
                }
            }
            DropletSettingsDivider()
            DropletStackedRow(
                title: "Format",
                icon: "slider.horizontal.3",
                infoTip: "Quality, video container and audio format. The shelf widget uses the same choice."
            ) {
                VStack(alignment: .leading, spacing: DroppySpacing.xs) {
                    FormatPickers(model: model)
                    Text(model.options.summary)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var folderTip: String {
        if let message = model.downloadFolderMessage { return message }
        if !model.downloadFolderIsWritable { return "Dropload cannot write to \(model.downloadFolder.path)" }
        return model.downloadFolder.path
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = model.downloadFolder
        panel.prompt = "Choose"
        panel.message = "Choose where Dropload saves downloads"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in model.setDownloadFolder(url) }
        }
    }
}
