//
//  DroploadDetailView.swift
//  Dropload
//
//  The takeover: the same form with room for the fetched title, duration and
//  thumbnail, and the progress of the running download.
//

import DroppyKit
import SwiftUI

/// TODO(T2): title/duration/thumbnail from `.ready(info)`, a readable
/// explanation of what the pickers will produce, progress and result rows.
struct DroploadDetailView: View {
    let droplet: DroploadDroplet
    @ObservedObject var model: DownloadModel
    let context: ExpandedSurfaceContext

    var body: some View {
        VStack(alignment: .leading, spacing: DroppySpacing.md) {
            URLBar(model: model)
            FormatPickers(model: model)
            Spacer(minLength: 0)
            HStack {
                Spacer(minLength: 0)
                Button("Download") { model.startDownload() }
                    .buttonStyle(DroppyAccentButtonStyle(size: .small))
                    .disabled(!model.canDownload)
            }
        }
        .padding(DroppySpacing.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
