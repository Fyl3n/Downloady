//
//  DownloadySettingsView.swift
//  Downloady
//
//  Settings, built from DroppyKit's settings rows. The root is
//  `DropletSettingsPane` (DroppyKit 1.9.0): on macOS 15 and later Droppy
//  mounts the sections in its grouped Form, the page System Settings is made
//  of; on macOS 14 the cards draw their own chrome as before.
//

import AppKit
import DroppyKit
import SwiftUI

struct DownloadySettingsView: View {
    let droplet: DownloadyDroplet
    @ObservedObject var model: DownloadModel

    /// A list of sections, never a stack: a `VStack` inside the Form is one
    /// row. Every card inside a `DropletSettingsSection` joins its one
    /// section, so a header goes over the first card of a group and the
    /// cards after it are headerless sections under it, the way System
    /// Settings stacks them. The general cards open the page with no header,
    /// as World Clock's do: the Form styles a first section's header apart
    /// from the others.
    var body: some View {
        DropletSettingsPane {
            if !model.unavailableTools.isEmpty {
                MissingToolsCard(model: model)
            }
            DownloadsCard(model: model)
            TranscriptCard(model: model)
            BrowserCard(model: model)
            ShortcutsCard(droplet: droplet)

            DropletSettingsSection {
                settingsSectionHeader("Compatible websites")
            } content: {
                SupportedSitesCard(model: model)
            }

            DropletSettingsSection {
                settingsSectionHeader("Providers")
            } content: {
                ToolCard(model: model, tool: .ytDlp)
            }
            ToolCard(model: model, tool: .ffmpeg)
            ToolCard(model: model, tool: .deno)
        }
    }
}

extension View {
    /// The padding of a row Downloady builds itself. Inside the Form (macOS
    /// 15 and later, the check `DropletSettingsPane` makes) the Form pays a
    /// row's padding; before that the card is drawn by hand and the row pads
    /// itself, like the kit's rows do.
    @ViewBuilder
    func handBuiltSettingsRow() -> some View {
        if #available(macOS 15.0, *) {
            frame(maxWidth: .infinity, alignment: .leading)
        } else {
            frame(maxWidth: .infinity, alignment: .leading)
                .padding(DroppySettingsLayoutMetrics.rowPadding)
        }
    }
}

/// Where the quick actions' shortcuts are bound: Droppy's Shortcuts page
/// lists them in Downloady's section (DroppyKit 1.16.0).
struct ShortcutsCard: View {
    let droplet: DownloadyDroplet

    var body: some View {
        DropletSettingsCard {
            DropletControlRow(
                title: "Keyboard shortcuts",
                icon: "keyboard",
                infoTip: "Open Downloady, or download the current tab or the pasted link, from anywhere."
            ) {
                Button("Edit") { droplet.openShortcuts() }
                    .buttonStyle(DroppyQuietButtonStyle(size: .small))
                    // Every row button sets this: the Form's card (macOS 15+)
                    // does not publish the compact 24pt height the hand-drawn
                    // card does, and a `.small` button there drops below its title.
                    .droppySettingsCompactControls()
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
                HStack(alignment: .firstTextBaseline, spacing: DroppySpacing.xsm) {
                    allowedValue
                    permissionAction
                }
                .droppySettingsCompactControls()
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
            subtitle: "Looks up the page you're on while your browser is in front, so the link is "
                + "ready when you open the shelf. 'Never' waits until the shelf opens.",
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
            DropletStackedRow(title: "Find a website", icon: "magnifyingglass") {
                VStack(alignment: .leading, spacing: DroppySpacing.sm) {
                    searchField
                    results
                }
            }
        }
        .onAppear { model.loadSupportedSites() }
        .onChange(of: model.toolStatus) { _, _ in model.loadSupportedSites() }
    }

    /// A native field, so the system border and focus ring stay intact.
    private var searchField: some View {
        TextField("Search a website", text: $query, prompt: Text("Search a website"))
            .textFieldStyle(.roundedBorder)
            .labelsHidden()
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
                    .droppySettingsCompactControls()
            }
            if let reason = model.transcriptionUnavailableReason {
                Label(reason, systemImage: "info.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .handBuiltSettingsRow()
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

/// One tool: what it does, its version with Install, any newer release
/// with the way to get it, the source picker (Downloady's copy, this Mac's, a custom path) and, for
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
                icon: Self.icon(for: tool),
                infoTip: location?.url.path
            ) {
                Text(Self.summary(of: tool))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
            }
            DropletSettingsDivider()
            DropletControlRow(title: "Version", icon: "tag") {
                HStack(alignment: .center, spacing: DroppySpacing.xsm) {
                    if let message = model.toolUpdateMessages[tool] {
                        Text(message)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    pills
                    updateStatus
                    installButton
                }
                .droppySettingsCompactControls()
            }
            // Only once every check is back, so a stale offer never shows.
            if !model.isCheckingTools, let update = model.toolUpdates[tool] {
                DropletSettingsDivider()
                updateRow(update)
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
                .handBuiltSettingsRow()
            }
        }
        .animation(DroppyAnimation.state, value: showsPath)
        .animation(DroppyAnimation.state, value: notice)
        .animation(DroppyAnimation.state, value: model.isCheckingTools)
        .onAppear {
            // Once per pane: the user may have updated a tool in Terminal since.
            if tool == .ytDlp { model.refreshTools() }
            path = model.customPath(for: tool) ?? ""
        }
        // A path chosen elsewhere (the missing-tools card) replaces the field,
        // so closing the pane does not commit the old text over it.
        .onChange(of: model.customPath(for: tool)) { _, stored in path = stored ?? "" }
        .onDisappear { commitPath() }
    }

    private var location: ToolLocation? {
        model.location(of: tool)
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
        } else if model.isCheckingTools || (tool == .ytDlp && model.toolStatus == .unknown) {
            DropletValuePill(text: "Checking…")
        } else {
            DropletValuePill(text: "Not found")
        }
    }

    /// Right of the version: the check running, then its verdict. Nothing
    /// when an update was found (its own line says so) or the check could
    /// not tell.
    @ViewBuilder
    private var updateStatus: some View {
        if location != nil, !isInstalling {
            if model.isCheckingTools {
                HStack(spacing: 2) {
                    Text("(")
                    ProgressView().controlSize(.mini)
                    Text("Checking for updates…)")
                }
                .foregroundStyle(.secondary)
                .transition(DroppyTransition.element)
            } else if model.upToDateTools.contains(tool) {
                Text("(Up to date)")
                    .foregroundStyle(.secondary)
                    .transition(DroppyTransition.element)
            }
        }
    }

    @ViewBuilder
    private var installButton: some View {
        if location == nil, !isInstalling, model.source(for: tool) == .managed, model.toolStatus != .unknown {
            // The automatic install failed: the same install, by hand.
            Button("Install") { model.installTools() }
                .buttonStyle(DroppyAccentButtonStyle(size: .small))
        }
    }

    /// A newer release. Downloady updates its own copy; it does not change
    /// what it did not install: for the Mac's copy it hands over the
    /// command, or runs it in Terminal where the user watches it and answers
    /// any password prompt.
    private func updateRow(_ update: ToolUpdate) -> some View {
        DropletControlRow(
            title: "\(update.version) is available",
            icon: "arrow.up.circle",
            infoTip: updateTip(update)
        ) {
            HStack(spacing: DroppySpacing.xsm) {
                if location?.source == .managed {
                    Button {
                        model.updateTool(tool)
                    } label: {
                        Label(model.updatingTool == tool ? "Updating…" : "Update", systemImage: "arrow.up")
                    }
                    .buttonStyle(DroppyAccentButtonStyle(size: .small))
                    .disabled(model.updatingTool != nil)
                } else if update.command != nil {
                    Button { model.copyUpdateCommand(for: tool) } label: {
                        Label("Copy command", systemImage: "doc.on.doc")
                    }
                    .buttonStyle(DroppyQuietButtonStyle(size: .small))
                    Button { model.runUpdateCommand(for: tool) } label: {
                        Label("Update in Terminal", systemImage: "arrow.up")
                    }
                    .buttonStyle(DroppyAccentButtonStyle(size: .small))
                }
            }
            .droppySettingsCompactControls()
        }
    }

    private func updateTip(_ update: ToolUpdate) -> String {
        if location?.source == .managed { return "Downloady downloads it and replaces its copy." }
        if let command = update.command { return "Updates the copy on this Mac with: \(command)" }
        return "Update it the way you installed it."
    }

    /// What the tool does, for someone who has never heard of it.
    static func summary(of tool: ToolLocation.Tool) -> String {
        switch tool {
        case .ytDlp: "Finds the video on the page and downloads it."
        case .ffmpeg: "Joins video and sound, and converts files to the format you pick."
        case .deno: "Answers YouTube's checks, so every quality stays available."
        }
    }

    static func icon(for tool: ToolLocation.Tool) -> String {
        switch tool {
        case .ytDlp: "arrow.down.circle"
        case .ffmpeg: "film"
        case .deno: "curlybraces"
        }
    }

    private var sourceTip: String {
        switch tool {
        case .ytDlp:
            return "Downloady installs yt-dlp for you and offers updates as they come out. This Mac uses a copy you installed, for example with Homebrew; Custom uses the file you point to."
        case .ffmpeg, .deno:
            let found = model.systemCopy(of: tool).map { " (found at \($0.path))" } ?? ""
            return "This Mac uses the \(tool.name) you installed\(found). Downloady downloads its own copy; Custom uses the file you point to."
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
            // Native, so the system border and focus ring stay intact.
            TextField("\(tool.name) path", text: $path, prompt: Text("/opt/homebrew/bin/\(tool.executableName)"))
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
                .font(.system(size: 12, design: .monospaced))
                .onSubmit(commitPath)
            Button("Choose…") { choosePath() }
                .buttonStyle(DroppyQuietButtonStyle(size: .small))
        }
        .droppySettingsCompactControls()
    }

    private func commitPath() {
        model.setCustomPath(path, for: tool)
    }

    private func choosePath() {
        ToolPathPanel.choose(tool, near: path) { chosen in
            path = chosen
            commitPath()
        }
    }
}

/// The open panel for a tool's executable.
enum ToolPathPanel {
    @MainActor
    static func choose(_ tool: ToolLocation.Tool, near path: String = "", completion: @escaping @MainActor (String) -> Void) {
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
            Task { @MainActor in completion(url.path) }
        }
    }
}

/// Tools the default could not get from either source: Downloady's copy did
/// not install and the Mac has none. On top of the page, because a missing
/// yt-dlp stops every download.
struct MissingToolsCard: View {
    @ObservedObject var model: DownloadModel

    var body: some View {
        DropletSettingsCard {
            ForEach(Array(model.unavailableTools.enumerated()), id: \.element) { index, tool in
                if index > 0 { DropletSettingsDivider() }
                DropletStackedRow(
                    title: "\(tool.name) is missing",
                    icon: "exclamationmark.triangle.fill",
                    iconColor: Color(nsColor: .systemOrange)
                ) {
                    VStack(alignment: .leading, spacing: DroppySpacing.sm) {
                        Text(Self.message(for: tool, reason: model.installFailures[tool]))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: DroppySpacing.xsm) {
                            Button(model.installingTools.contains(tool) ? "Installing…" : "Try again") {
                                model.installTools()
                            }
                            .buttonStyle(DroppyAccentButtonStyle(size: .small))
                            .disabled(!model.installingTools.isEmpty)
                            Button("Choose file…") {
                                ToolPathPanel.choose(tool) { model.chooseCustomPath($0, for: tool) }
                            }
                            .buttonStyle(DroppyQuietButtonStyle(size: .small))
                        }
                        .droppySettingsCompactControls()
                    }
                }
            }
        }
    }

    static func message(for tool: ToolLocation.Tool, reason: String?) -> String {
        let impact = switch tool {
        case .ytDlp: "Nothing can be downloaded until it is back."
        case .ffmpeg: "Downloads still work, but video and sound may stay in separate files and formats cannot be converted."
        case .deno: "Downloads still work, but YouTube may offer fewer qualities."
        }
        let why = reason.map { " (\($0))" } ?? ""
        return "\(impact) Downloady could not install it\(why), and none was found on this Mac."
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
                HStack(alignment: .firstTextBaseline, spacing: DroppySpacing.xsm) {
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
                .droppySettingsCompactControls()
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
