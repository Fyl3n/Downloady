# T1: Tool management: yt-dlp and ffmpeg

**Depends on:** none · **Files:** `Tools/ToolManager.swift`,
`Model/DownloadModel.swift` (`installTools`, tool status),
`UI/DownloadySettingsView.swift` (tools card), `UI/DownloadyWidget.swift`
(install row).

## Goal

The first time Downloady runs, it gets a working yt-dlp, and ffmpeg when
needed, with no terminal. The Settings pane shows where each tool came from
and can update yt-dlp.

## Scope

1. `ToolManager.resolve()`, with no network access:
   - yt-dlp: use the custom path from `PreferenceKey.customYtDlpPath` if set.
     Otherwise use `<container>/tools/yt-dlp/yt-dlp_macos` if it is
     executable. Otherwise the tool is missing.
   - ffmpeg: custom path, then `/opt/homebrew/bin/ffmpeg`,
     `/usr/local/bin/ffmpeg`, then a lookup on `PATH`, then
     `<container>/tools/ffmpeg`. ffmpeg being absent does **not** make the
     status `.missing`; it is reported as `ffmpeg: nil`.
   - Versions: `yt-dlp --version` and `ffmpeg -version` (first line), run off
     the main actor with a timeout.
2. `installMissing(progress:)`:
   - Download
     `https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp_macos.zip`
     and `SHA2-256SUMS` from the same release. Verify the checksum with
     CryptoKit, unzip with `/usr/bin/ditto -x -k` into a temporary folder,
     then move it atomically into `<container>/tools/yt-dlp/`, and
     `chmod +x`.
   - If there is no system ffmpeg, download a static macOS build for
     `arm64` or `x86_64` (for example from `ffmpeg.martin-riedl.de`, which
     publishes checksums), verify it, and install it as
     `<container>/tools/ffmpeg`.
   - Progress: yt-dlp is about 70% of the bar, ffmpeg the rest. Downloads use
     `URLSession` with a delegate, not `Data(contentsOf:)`.
   - Gate on `host.isGranted(.networkClient)` and `.downloads`. A refusal
     becomes `.failed("…")`, never a crash.
3. `updateYtDlp()`: compare against the GitHub latest-release tag (or run
   `yt-dlp_macos --update-to` inside the onedir copy, whichever works with the
   zip build) and reinstall when it is newer.
4. `DownloadModel.installTools()` drives `toolStatus`, including
   `.installing(progress:)`. It runs installation automatically on
   activation **only** after the user has pressed Install once (store a
   preference flag); never download silently the very first time.
5. UI:
   - Widget: when `toolStatus` is not ready, the action row becomes
     "yt-dlp is needed" with an **Install** button
     (`DroppyAccentButtonStyle(.small)`) and a progress bar while installing.
   - Settings: a tools card with a yt-dlp row (version, source pill, and an
     Update button), an ffmpeg row (version and source: system, downloaded,
     custom, or missing), and a stacked row for custom paths.
6. Cancel any running install in `stop()`.

## Acceptance

- On a clean container, pressing Install shows progress and ends in
  `.ready`, and `yt-dlp_macos --version` runs.
- With a checksum mismatch (test it with an injected bad sum), nothing is
  installed and the status is `.failed`.
- Homebrew ffmpeg is detected as `system` on this Mac.
- Unit tests: checksum parsing of `SHA2-256SUMS`, and ffmpeg lookup order
  (use an injected file-exists closure).
- The Definition of done in `docs/PLAN.md` is met.
