//
//  DownloadyDetailView.swift
//  Downloady
//
//  The takeover: the URL bar, the media card, the format pickers, and the
//  progress of the running download.
//

import DroppyKit
import SwiftUI

struct DownloadyDetailView: View {
    /// What `expandedSurfaceSize` asks the host for: the URL bar (28), the
    /// media card, the titled pickers and the action row (25), with a
    /// `DroppySpacing.md` step between them, inside
    /// `DroppySpacing.lg`. The host draws whatever this asks for, so a number
    /// larger than the content leaves empty surface under the last row.
    static let contentHeight: CGFloat =
        28 + MediaCard.height(thumbnailHeight: thumbnailSize.height) + FormatPickers.height + 25
            + 3 * DroppySpacing.md + 2 * DroppySpacing.lg

    static let thumbnailSize = CGSize(width: 80, height: 45)

    let droplet: DownloadyDroplet
    @ObservedObject var model: DownloadModel
    let context: ExpandedSurfaceContext

    var body: some View {
        VStack(alignment: .leading, spacing: DroppySpacing.md) {
            URLBar(model: model)
            MediaCard(model: model, thumbnailSize: Self.thumbnailSize)
            FormatPickers(model: model)
            Spacer(minLength: 0)
            if model.toolStatus.isReady {
                DownloadActionRow(model: model, onOpenQueue: { [droplet] in droplet.openQueue(fromDetail: true) })
            } else {
                ToolInstallRow(model: model) { [droplet] in droplet.openSettings() }
            }
        }
        .padding(DroppySpacing.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
