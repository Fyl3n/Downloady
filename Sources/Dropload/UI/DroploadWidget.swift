//
//  DroploadWidget.swift
//  Dropload
//
//  The shelf widget. Solo: URL bar, pickers, action row. Paired: URL bar and
//  the download button. Branch on `context.isPaired`, never on a width.
//

import DroppyKit
import SwiftUI

struct DroploadWidget: View {
    let droplet: DroploadDroplet
    @ObservedObject var model: DownloadModel
    let context: ShelfWidgetContext

    var body: some View {
        VStack(alignment: .leading, spacing: DroppySpacing.sm) {
            header
            URLBar(model: model)
            if !context.isPaired {
                FormatPickers(model: model)
            }
            Spacer(minLength: 0)
            // TODO(T1): when tools are not ready, replace the action row with an
            // "Install yt-dlp" row driving `model.installTools()`.
            // TODO(T2): progress bar, speed and ETA while downloading; a
            // "Show in Finder" action when finished; the error when failed.
            actionRow
        }
        .padding(context.contentInsets)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var header: some View {
        HStack(spacing: DroppySpacing.xsm) {
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 12, weight: .medium))
            Text("Dropload")
                .font(.system(size: 12, weight: .semibold))
            Spacer(minLength: 0)
            if !context.isPaired {
                Button {
                    droplet.openDetail()
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                }
                .buttonStyle(DroppyCircleButtonStyle(size: 20))
                .help("Open Dropload")
            }
        }
        .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
    }

    private var actionRow: some View {
        HStack(spacing: DroppySpacing.xsm) {
            Text(statusText)
                .font(.system(size: 11))
                .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                .lineLimit(1)
            Spacer(minLength: 0)
            Button("Download") { model.startDownload() }
                .buttonStyle(DroppyAccentButtonStyle(size: .small))
                .disabled(!model.canDownload)
        }
    }

    private var statusText: String {
        switch model.toolStatus {
        case .unknown: "Checking yt-dlp…"
        case .missing: "yt-dlp is not installed"
        case .installing: "Installing yt-dlp…"
        case .failed(let message): message
        case .ready: model.urlText.isEmpty ? "Paste a link to start" : ""
        }
    }
}
