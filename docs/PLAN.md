# Downloady: implementation plan

Downloady is a Droppy droplet that downloads video and audio with
[yt-dlp](https://github.com/yt-dlp/yt-dlp). It has a URL bar and three
pickers (quality, video container, audio format). When the frontmost app is a
supported browser and yt-dlp can handle the page, it fills the URL in on its
own.

Read `AGENTS.md` first. It covers the DroppyKit build loop and the rules every
droplet must follow.

## Decisions already made

| Topic | Decision |
| --- | --- |
| yt-dlp | Downloady downloads its own copy on first run, into `host.environment.containerDirectory/tools/`, using the `yt-dlp_macos.zip` onedir build (starts faster than the onefile build). It is checked against `SHA2-256SUMS`, and Downloady updates it itself. It is **never** placed inside the `.droplet` bundle: Droppy refuses a bundle whose files changed after the user approved it. |
| ffmpeg | Use the system copy first (`/opt/homebrew/bin`, `/usr/local/bin`, `PATH`). If there is none, download a static build for the running architecture into the same tools folder. The user can set a custom path in Settings. |
| Surfaces | `shelf-widget` (quick form, 420×150 solo and 210 paired), `expanded-surface` (detail takeover, opened from the widget), and `settings-pane`. |
| Pickers | Fixed presets. After `yt-dlp -J` runs, the entries the URL cannot satisfy are greyed out. The mapping to yt-dlp arguments is in `Model/DownloadOptions.swift`, which is done and has tests. |
| Text | A fourth picker, Off by default: **Subtitles** writes the site's own with yt-dlp (`--write-subs --write-auto-subs --convert-subs srt`), **Transcribe** makes one on this Mac with macOS 26's `SpeechAnalyzer`, after the download, in the background. Before macOS 26 the choice is greyed out and Settings says why; no whisper binary ships with the droplet. |
| Queue | Downloads never pin the shelf open. A started download becomes a job in `DownloadModel.jobs`, the form is free for the next page, and the notch shows progress. One download at a time, one transcript at a time, so a transcript runs beside the next download. |
| Browsers | Safari (including Technology Preview) and Chromium-family browsers (Chrome, Arc, Dia, Brave, Edge, Vivaldi, Opera, Chromium), read with AppleScript (`apple-events`). Firefox is not supported. |
| "Compatible site" | `yt-dlp -J` returns a dedicated extractor (not `Generic`), or it returns formats. |
| Capabilities | `expanded-surface`, `shelf-write` (keeps the shelf open during a download), `network-client`, `downloads`, `apple-events`. Keep `droplet.json` in sync if a ticket changes what is used. |

## Architecture

All code lives in **one target**, `Sources/Downloady/`. `droppykit build`
links only the `Downloady` module's own objects, so a second library target
would silently be left out of the bundle. Pure logic is tested in
`Tests/DownloadyTests` with `swift test`.

```
DownloadyDroplet.swift          principal, lifecycle, surface conformances
Model/DownloadOptions.swift    pickers -> yt-dlp args               (done, tested)
Model/MediaInfo.swift          `yt-dlp -J` subset, FormatAvailability (T2)
Model/DownloadModel.swift      shared ObservableObject state + intents (T1, T2, T3)
Tools/ToolManager.swift        find/install/update yt-dlp + ffmpeg   (T1)
Tools/YtDlpClient.swift        Process runner, ProgressParser        (T2)
Browser/BrowserURLProvider.swift  frontmost browser -> URL           (T3)
UI/DownloadForm.swift          URL bar + three pickers (shared)
UI/DownloadyWidget.swift        shelf widget
UI/DownloadyDetailView.swift    expanded surface
UI/DownloadySettingsView.swift  settings pane
```

Data flow: views call intents on `DownloadModel`. The model drives the
`ToolManaging`, `YtDlpRunning` and `BrowserURLProviding` protocols, and
publishes `phase`, `toolStatus` and `availability`. Everything the model
starts in `start(host:)` is stopped in `stop()`, which `deactivate()` calls.

Every unfinished part is marked `TODO(T<n>)` in the code:
`grep -rn "TODO(T" Sources`.

## Tickets

| # | Ticket | Depends on |
| --- | --- | --- |
| T1 | [Tool management: yt-dlp and ffmpeg](tickets/T1-tool-management.md) | none |
| T2 | [Metadata fetch and download pipeline](tickets/T2-download-pipeline.md) | T1 (can start in parallel by using a system yt-dlp through the custom path) |
| T3 | [Browser URL auto-detection](tickets/T3-browser-autofill.md) | T2 (needs `fetchInfo`) |
| T4 | [Polish, completion feedback and release readiness](tickets/T4-polish-release.md) | T1–T3 |
| T5 | [Text, and downloads that run in the background](tickets/T5-text-and-queue.md) | T1–T4 |

## Definition of done (every ticket)

- `swift test` passes, with new tests for any new pure logic.
- `droppykit build` and `droppykit validate` pass.
- `droppykit run -- --shots ./shots --report ./shots/report.json`: `problems`
  is empty, `activation.error` is null, and you have looked at the shots of
  every surface you touched (solo, paired, notch and island).
- Nothing blocks the main actor. Every `Process`, `Task` and observer stops in
  `deactivate()`.
- `droplet.json` still matches the code (surfaces and capabilities).
- The ticket's `TODO(T<n>)` markers are gone.

## Risks

- **Automation prompt**: the macOS Automation prompt for `apple-events` is
  shown on behalf of Droppy, so it depends on Droppy's own usage description
  and entitlement. Test in Droppy or Droppy Playground, not only in the
  harness.
- **Gatekeeper**: files downloaded with `URLSession` get no quarantine
  attribute, so the yt-dlp and ffmpeg binaries run. If a host ever adds one,
  remove `com.apple.quarantine` after installing.
- **Harness side effects**: the harness never touches the system, but
  `Process` and `NSAppleScript` still run there. Keep the network and
  process paths behind the protocols so the shots stay deterministic.
- **Store review**: a droplet that downloads and runs executables will get
  extra scrutiny. Checksum verification and HTTPS-only GitHub URLs are
  required.
