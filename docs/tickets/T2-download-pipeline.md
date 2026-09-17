# T2: Metadata fetch and download pipeline

**Depends on:** T1. To start in parallel, point
`PreferenceKey.customYtDlpPath` at `/opt/homebrew/bin/yt-dlp`.
**Files:** `Tools/YtDlpClient.swift`, `Model/MediaInfo.swift`,
`Model/DownloadModel.swift`, `UI/DownloadForm.swift`,
`UI/DroploadWidget.swift`, `UI/DroploadDetailView.swift`,
`UI/DroploadSettingsView.swift` (download folder).

## Goal

Paste a link, the pickers adapt to what the site offers, press Download,
watch the progress, and get the file.

## Scope

1. `YtDlpClient`, built on `Process`:
   - Common arguments: `--no-playlist --newline --no-colors`, plus
     `--ffmpeg-location <path>` when ffmpeg is known.
   - `fetchInfo`: `-J --skip-download <url>`, decoded into `MediaInfo`
     (`JSONDecoder`; ignore unknown keys). A `Generic` extractor with no
     formats becomes `YtDlpError.unsupportedURL`. A non-zero exit becomes
     `.processFailed`, carrying the last stderr line.
   - `download`: `DownloadOptions.ytDlpArguments` plus
     `-o "<folder>/%(title).200B [%(id)s].%(ext)s"`,
     `--progress-template "download:dropload %(progress._percent_str)s|%(progress._speed_str)s|%(progress._eta_str)s"`,
     and `--print after_move:filepath`. Stream stdout line by line off the
     main actor and emit `DownloadEvent`s on it. Lines starting with
     `[Merger]`, `[ExtractAudio]` or `[VideoRemuxer]` produce
     `.postProcessing`.
   - Cancelling the consuming task terminates the process (SIGTERM, then
     SIGKILL after 2 s). `cancelAll()` terminates every child process.
2. `ProgressParser.parse`: trim the percent, speed and ETA fields, turning
   `NA` into `nil`. Unit tests are required.
3. `FormatAvailability.init(info:)`, following the rules in the doc comment.
   Unit tests with fixture JSON: a YouTube-like format list, audio-only
   formats, and no formats.
4. `DownloadModel`:
   - `userEditedURL`: debounce by 600 ms, then `fetchInfo()` if the text is an
     http(s) URL.
   - `fetchInfo`: `.fetchingInfo`, then `.ready(info)`, `.unsupported` or
     `.failed`. Set `availability`. If the selected quality is unavailable,
     step down to the highest available one.
   - `startDownload`: call `host.shelf.setHoldsOpen(true)`, map the events to
     `phase`, and on finish call `setHoldsOpen(false)` and set
     `.finished(url)`. Cancel is `cancelDownload`.
   - `downloadFolder` is settable from Settings with `NSOpenPanel`, stored as a
     path. Check that the folder is writable.
5. UI:
   - `URLBar`: a paste button (`DroppyCircleButtonStyle`) and a trailing state
     glyph (spinner, checkmark, or warning with a tooltip).
   - `FormatPickers`: disable unavailable entries. Disable the video picker for
     audio only. Offer only the audio formats that
     `AudioFormat.isAvailable` allows.
   - Widget (solo): while downloading, the action row becomes a progress bar
     with speed and ETA, plus a cancel button (a circle with an xmark). When
     finished, it shows the file name and a "Show in Finder" action
     (`host.workspace.revealInFinder`). On failure, it shows the error in one
     line with a tooltip for the full message. Paired: the URL bar plus a
     single download/progress control.
   - Detail view: title, duration and thumbnail (`AsyncImage`) from the info,
     a one-line plain summary of what will be produced (for example
     "1080p mp4 with m4a audio"), then the same progress and result rows.

## Acceptance

- A YouTube URL gives the title in the detail view and greys out qualities
  above the source's maximum.
- Downloads land in the chosen folder:
  1080p mp4 → an `.mp4` file; audio only with mp3 → an `.mp3` file;
  best mkv → an `.mkv` file.
- A non-video page (for example `https://example.com`) shows
  "unsupported" and Download stays disabled.
- Cancel stops the process (`pgrep yt-dlp` finds nothing) and returns to the
  ready state.
- Disabling the droplet mid-download terminates the process.
- The Definition of done in `docs/PLAN.md` is met, with shots of the widget
  (solo and paired) and the detail view.
