//
//  DownloadySettingsView.swift
//  Downloady
//
//  Settings, built from DroppyKit's settings rows.
//

import AppKit
import DroppyKit
import SwiftUI

struct DownloadySettingsView: View {
    let droplet: DownloadyDroplet
    @ObservedObject var model: DownloadModel

    var body: some View {
        VStack(alignment: .leading, spacing: DroppySpacing.xxl) {
            section("General") {
                DownloadsCard(model: model)
                TranscriptCard(model: model)
                BrowserCard(model: model)
            }
            section("Compatible websites") {
                SupportedSitesCard(model: model)
            }
            section("Providers") {
                ToolCard(model: model, tool: .ytDlp)
                ToolCard(model: model, tool: .ffmpeg)
            }
        }
    }

    /// A header in Droppy's own section style over its cards.
    private func section<Content: View>(
        _ title: LocalizedStringKey,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: DroppySpacing.sm) {
            settingsSectionHeader(title)
                .padding(.leading, DroppySpacing.xs)
            VStack(alignment: .leading, spacing: DroppySpacing.lg) {
                content()
            }
        }
    }
}

/// Auto-fill from the browser: the toggle, and the browsers macOS lets
/// Downloady read.
struct BrowserCard: View {
    @ObservedObject var model: DownloadModel

    var body: some View {
        DropletSettingsCard {
            DropletToggleRow(
                title: "Fill in the link from your browser",
                subtitle: "Reads the current tab of Safari or a Chromium browser. "
                    + "Not supported on Firefox.",
                isOn: Binding(get: { model.autoFillFromBrowser }, set: { model.autoFillFromBrowser = $0 })
            )
            DropletSettingsDivider()
            backgroundCheckRow
            DropletSettingsDivider()
            DropletControlRow(
                title: "Currently allowed on",
                icon: "hand.raised",
                infoTip: permissionTip
            ) {
                HStack(spacing: DroppySpacing.xsm) {
                    allowedValue
                    permissionAction
                }
            }
        }
        .onAppear { model.refreshBrowserPermissions() }
    }

    /// When the tab is read with the shelf closed. Only means something
    /// while auto-fill is on.
    private var backgroundCheckRow: some View {
        let enabled = model.autoFillFromBrowser
        let selected = model.backgroundTabCheck
        return settingsUnifiedPickerRow(
            title: "Check the tab's link in the background when...",
            subtitle: "Looks the page up when you switch to your browser, so the link is ready "
                + "when you open the shelf. 'Never' waits until the shelf opens.",
            icon: "clock.arrow.circlepath",
            options: BackgroundTabCheck.allCases,
            accessibilityLabel: "Check the tab in the background",
            groupPosition: .only,
            isEnabled: { _ in enabled },
            isSelected: { $0 == selected },
            action: { model.backgroundTabCheck = $0 },
            content: { option, isSelected, isEnabled in
                settingsUnifiedSegmentLabel(
                    icon: option.systemImage,
                    title: option.title,
                    isSelected: isSelected,
                    isEnabled: isEnabled
                )
            }
        )
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)
        .help(enabled ? "" : "Turn on filling in the link from your browser first.")
    }

    static func names(_ browsers: [SupportedBrowser]) -> String {
        ListFormatter.localizedString(byJoining: browsers.map(\.name))
    }

    @ViewBuilder
    private var allowedValue: some View {
        let allowed = model.allowedBrowsers
        if !model.appleEventsGranted {
            DropletValuePill(text: "Off in Droppy")
        } else if allowed.isEmpty {
            DropletValuePill(text: "No browser yet")
        } else {
            Text(Self.names(allowed))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(Self.names(allowed))
        }
    }

    private var permissionTip: String {
        guard model.appleEventsGranted else {
            return "Turn on Apple events for Downloady in Droppy's Store settings."
        }
        let denied = model.deniedBrowsers
        if !denied.isEmpty {
            return "Refused on \(Self.names(denied)). Allow Droppy to control it under "
                + "Privacy & Security, Automation."
        }
        return "macOS asks once per browser, the first time Downloady reads its current tab."
    }

    @ViewBuilder
    private var permissionAction: some View {
        if model.appleEventsGranted {
            if !model.deniedBrowsers.isEmpty {
                Button("Open System Settings") { model.openAutomationSettings() }
                    .buttonStyle(DroppyQuietButtonStyle(size: .small))
            } else if !model.browsersToAsk.isEmpty {
                Button("Allow \(Self.names(model.browsersToAsk))") { model.askBrowsers() }
                    .buttonStyle(DroppyAccentButtonStyle(size: .small))
            }
        }
    }
}

/// Search over the websites yt-dlp knows by name.
struct SupportedSitesCard: View {
    @ObservedObject var model: DownloadModel
    @State private var query = ""

    /// How many names the card lists before "and N more".
    static let visibleResults = 6

    var body: some View {
        DropletSettingsCard {
            VStack(alignment: .leading, spacing: DroppySpacing.sm) {
                searchField
                results
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(DroppySettingsLayoutMetrics.rowPadding)
        }
        .onAppear { model.loadSupportedSites() }
        .onChange(of: model.toolStatus) { _, _ in model.loadSupportedSites() }
    }

    private var searchField: some View {
        HStack(spacing: DroppySpacing.xsm) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            TextField("Search a website", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
        }
        .padding(.horizontal, DroppySpacing.sm)
        .padding(.vertical, DroppySpacing.xs)
        .background(
            RoundedRectangle(cornerRadius: DroppyRadius.sm, style: .continuous)
                .fill(AdaptiveColors.overlayAuto(0.08))
        )
    }

    @ViewBuilder
    private var results: some View {
        if let sites = model.supportedSites {
            let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                note("yt-dlp knows \(sites.sites.count.formatted()) websites. Downloady fills in a page "
                    + "from these only; a link to another page can still work when you paste it.")
            } else {
                matches(in: sites, for: trimmed)
            }
        } else if model.toolStatus.isReady {
            note("Reading yt-dlp's list…")
        } else {
            note("The list appears once yt-dlp is installed.")
        }
    }

    @ViewBuilder
    private func matches(in sites: SupportedSites, for query: String) -> some View {
        let found = sites.matching(query)
        if found.isEmpty {
            note("yt-dlp does not know this website.")
        } else {
            VStack(alignment: .leading, spacing: DroppySpacing.xs) {
                ForEach(found.prefix(Self.visibleResults)) { site in
                    HStack(spacing: DroppySpacing.xsm) {
                        Text(site.name)
                            .font(.system(size: 12))
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        if site.isBroken {
                            DropletValuePill(text: "Currently broken")
                                .help("yt-dlp marks every extractor of this website as broken")
                        }
                    }
                }
                if found.count > Self.visibleResults {
                    note("and \(found.count - Self.visibleResults) more")
                }
            }
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Whether this Mac can transcribe, and the speech permission that lets it.
/// The Text choice itself is with the default format.
///
/// Subtitles come from the site and cost nothing. A transcript is made here,
/// by macOS 26's speech models, after the download, while the user carries on
/// browsing; before macOS 26 the choice is greyed out and this card says so.
struct TranscriptCard: View {
    @ObservedObject var model: DownloadModel

    var body: some View {
        DropletSettingsCard {
            DropletControlRow(
                title: "Transcribe on this Mac",
                icon: "waveform",
                infoTip: model.transcriptionUnavailableReason
                    ?? "Runs after the download, in the background. The audio never leaves this Mac."
            ) {
                statusControl
            }
            if let reason = model.transcriptionUnavailableReason {
                Label(reason, systemImage: "info.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(DroppySettingsLayoutMetrics.rowPadding)
            }
        }
        .animation(DroppyAnimation.state, value: model.transcriptionUnavailableReason)
        .animation(DroppyAnimation.state, value: model.speechStatus)
        .onAppear { model.refreshSpeechStatus() }
    }

    /// "Allowed" once macOS said yes; until then, and after a refusal, the
    /// Grant button in its place, which asks macOS again (or opens System
    /// Settings, the only place a refusal can be undone).
    @ViewBuilder
    private var statusControl: some View {
        if !model.transcriptionIsPossible {
            DropletValuePill(text: "Unavailable")
        } else {
            switch model.speechStatus {
            case .granted:
                DropletValuePill(text: "Allowed")
            case .notDetermined, .denied:
                Button("Grant") { model.grantSpeechRecognition() }
                    .buttonStyle(DroppyAccentButtonStyle(size: .small))
                    .help(model.speechStatus == .denied
                        ? "macOS refused speech recognition for Droppy. Grant asks again, in System Settings."
                        : "Asks macOS to let Droppy recognise speech.")
                    .transition(DroppyTransition.element)
            case .unavailable:
                DropletValuePill(text: "Unavailable")
            @unknown default:
                DropletValuePill(text: "Unknown")
            }
        }
    }
}

/// One tool: its version and where it comes from, with Install / Update,
/// the source picker (Downloady's copy, this Mac's, a custom path) and, for
/// Custom, the path field in the same card.
struct ToolCard: View {
    @ObservedObject var model: DownloadModel
    let tool: ToolLocation.Tool
    @State private var path = ""

    var body: some View {
        let source = model.source(for: tool)
        let showsPath = source == .custom
        let notice = model.toolNotices[tool]
        DropletSettingsCard {
            DropletControlRow(
                title: tool.name,
                icon: tool == .ytDlp ? "arrow.down.circle" : "film",
                infoTip: statusTip
            ) {
                HStack(spacing: DroppySpacing.xsm) {
                    if tool == .ytDlp, let message = model.toolUpdateMessage {
                        Text(message)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    pills
                    action
                }
            }
            DropletSettingsDivider()
            settingsUnifiedPickerRow(
                title: "Source",
                subtitle: sourceTip,
                icon: "shippingbox",
                options: ToolLocation.Source.allCases,
                accessibilityLabel: "\(tool.name) source",
                groupPosition: showsPath || notice != nil ? .top : .only,
                isSelected: { $0 == source },
                action: { model.selectSource($0, for: tool) },
                content: { option, isSelected, isEnabled in
                    settingsUnifiedSegmentLabel(
                        icon: Self.icon(for: option),
                        title: option.title,
                        isSelected: isSelected,
                        isEnabled: isEnabled
                    )
                }
            )
            if showsPath || notice != nil {
                VStack(alignment: .leading, spacing: DroppySpacing.sm) {
                    if let notice {
                        Label(notice, systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .symbolRenderingMode(.multicolor)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if showsPath {
                        pathField
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(DroppySettingsLayoutMetrics.rowPadding)
            }
        }
        .animation(DroppyAnimation.state, value: showsPath)
        .animation(DroppyAnimation.state, value: notice)
        .onAppear {
            if tool == .ytDlp { model.checkForYtDlpUpdate() }
            path = model.customPath(for: tool) ?? ""
        }
        .onDisappear { commitPath() }
    }

    private var location: ToolLocation? {
        tool == .ytDlp ? model.toolStatus.ytDlp : model.detectedFFmpeg
    }

    private var isInstalling: Bool { model.installingTools.contains(tool) }

    @ViewBuilder
    private var pills: some View {
        if isInstalling {
            if case .installing(let progress) = model.toolStatus {
                DropletValuePill(text: "Installing \(Int((progress * 100).rounded()))%")
            } else {
                DropletValuePill(text: "Installing…")
            }
        } else if let location {
            DropletValuePill(text: location.version ?? "Unknown version")
        } else if tool == .ytDlp, model.toolStatus == .unknown {
            DropletValuePill(text: "Checking…")
        } else {
            DropletValuePill(text: "Not found")
        }
    }

    @ViewBuilder
    private var action: some View {
        if tool == .ytDlp, location?.source == .managed, model.ytDlpUpdate != nil {
            Button(model.isUpdatingTools ? "Updating…" : "Update") { model.updateYtDlp() }
                .buttonStyle(DroppyAccentButtonStyle(size: .small))
                .disabled(model.isUpdatingTools)
                .help("yt-dlp \(model.ytDlpUpdate ?? "") is available")
        } else if location == nil, !isInstalling, model.source(for: tool) == .managed, model.toolStatus != .unknown {
            // The automatic install failed: the same install, by hand.
            Button("Install") { model.installTools() }
                .buttonStyle(DroppyAccentButtonStyle(size: .small))
        }
    }

    private var statusTip: String {
        if let location { return location.url.path }
        switch tool {
        case .ytDlp: return "Downloads the video. Downloady keeps its own copy up to date."
        case .ffmpeg: return "Merges video and audio and converts between formats."
        }
    }

    private var sourceTip: String {
        switch tool {
        case .ytDlp:
            return "Downloady installs yt-dlp for you and offers updates as they come out. This Mac uses a copy you installed, for example with Homebrew; Custom uses the file you point to."
        case .ffmpeg:
            let found = model.systemCopy(of: .ffmpeg).map { " (found at \($0.path))" } ?? ""
            return "This Mac uses the ffmpeg you installed\(found). Downloady downloads its own copy; Custom uses the file you point to."
        }
    }

    static func icon(for source: ToolLocation.Source) -> String {
        switch source {
        case .managed: "arrow.down.app"
        case .system: "desktopcomputer"
        case .custom: "folder"
        }
    }

    private var pathField: some View {
        HStack(spacing: DroppySpacing.xsm) {
            TextField("/opt/homebrew/bin/\(tool.name)", text: $path)
                .textFieldStyle(.plain)
                .font(.system(size: 12, design: .monospaced))
                .padding(.horizontal, DroppySpacing.sm)
                .padding(.vertical, DroppySpacing.xs)
                .background(
                    RoundedRectangle(cornerRadius: DroppyRadius.sm, style: .continuous)
                        .fill(AdaptiveColors.overlayAuto(0.08))
                )
                .onSubmit(commitPath)
            Button("Choose…") { choosePath() }
                .buttonStyle(DroppyQuietButtonStyle(size: .small))
        }
    }

    private func commitPath() {
        model.setCustomPath(path, for: tool)
    }

    private func choosePath() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = true
        panel.showsHiddenFiles = true
        panel.directoryURL = URL(fileURLWithPath: path.isEmpty ? "/opt/homebrew/bin" : (path as NSString).deletingLastPathComponent)
        panel.prompt = "Choose"
        panel.message = "Choose the \(tool.name) executable"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                path = url.path
                commitPath()
            }
        }
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
                title: "Default format and quality",
                icon: "slider.horizontal.3",
                infoTip: "What every new download starts on. A change made in the shelf applies to that download only."
            ) {
                VStack(alignment: .leading, spacing: DroppySpacing.sm) {
                    AudioOnlySwitch(model: model, target: .defaults)
                    FormatPickers(model: model, target: .defaults)
                    Text(model.defaultOptions.summary)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var folderTip: String {
        if let message = model.downloadFolderMessage { return message }
        if !model.downloadFolderIsWritable { return "Downloady cannot write to \(model.downloadFolder.path)" }
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
        panel.message = "Choose where Downloady saves downloads"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in model.setDownloadFolder(url) }
        }
    }
}
