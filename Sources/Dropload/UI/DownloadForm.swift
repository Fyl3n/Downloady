//
//  DownloadForm.swift
//  Dropload
//
//  The pieces the widget and the takeover share: the URL bar and the three
//  pickers.
//

import DroppyKit
import SwiftUI

/// The URL bar.
///
/// TODO(T2): Droppy-styled field (no border of our own; `notchSurfaceCardFill`
/// chip), paste button, a trailing state glyph for `phase` (spinner while
/// fetching, checkmark when ready, warning when unsupported).
struct URLBar: View {
    @ObservedObject var model: DownloadModel

    var body: some View {
        TextField(
            "Paste a video link",
            text: Binding(get: { model.urlText }, set: { model.userEditedURL($0) })
        )
        .textFieldStyle(.plain)
        .font(.system(size: 12))
        .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
        .padding(.horizontal, DroppySpacing.sm)
        .padding(.vertical, DroppySpacing.xsm)
        .background(
            RoundedRectangle(cornerRadius: DroppyRadius.sm, style: .continuous)
                .fill(AdaptiveColors.notchSurfaceCardFill)
        )
    }
}

/// Quality, video container, audio format.
///
/// TODO(T2): grey out entries `model.availability` rules out; disable the
/// video picker for audio only; restrict the audio picker with
/// `AudioFormat.isAvailable(with:container:)`.
struct FormatPickers: View {
    @ObservedObject var model: DownloadModel

    var body: some View {
        HStack(spacing: DroppySpacing.xsm) {
            Picker("Quality", selection: $model.options.quality) {
                ForEach(DownloadQuality.allCases) { Text($0.title).tag($0) }
            }
            Picker("Video", selection: $model.options.container) {
                ForEach(VideoContainer.allCases) { Text($0.title).tag($0) }
            }
            Picker("Audio", selection: $model.options.audio) {
                ForEach(AudioFormat.allCases) { Text($0.title).tag($0) }
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .controlSize(.small)
    }
}
