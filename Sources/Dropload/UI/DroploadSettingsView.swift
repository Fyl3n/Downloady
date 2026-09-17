//
//  DroploadSettingsView.swift
//  Dropload
//
//  Settings, built from DroppyKit's settings rows.
//

import DroppyKit
import SwiftUI

/// TODO(T1): tools card — yt-dlp version and source, "Install" / "Update"
/// buttons, ffmpeg source (system / downloaded / custom path).
/// TODO(T2): download folder picker (NSOpenPanel), default options.
/// TODO(T3): browser auto-fill toggle, Automation permission status with
/// `host.permissions.openSystemSettings(for: .appleEvents)`, list of
/// supported browsers.
struct DroploadSettingsView: View {
    let droplet: DroploadDroplet
    @ObservedObject var model: DownloadModel

    var body: some View {
        VStack(alignment: .leading, spacing: DroppySpacing.lg) {
            DropletSettingsCard {
                DropletControlRow(title: "yt-dlp") {
                    DropletValuePill(text: model.toolStatus.isReady ? "Ready" : "Not installed")
                }
                DropletSettingsDivider()
                DropletControlRow(title: "Download folder") {
                    DropletValuePill(text: model.downloadFolder.lastPathComponent)
                }
            }
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
