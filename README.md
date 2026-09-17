# Dropload

Download the video in front of you, from Droppy's shelf.

Dropload is a Droplet for [Droppy](https://getdroppy.app), the Dynamic Island
and shelf for Mac. It puts a URL bar and three pickers on the notch, hands the
link to [yt-dlp](https://github.com/yt-dlp/yt-dlp), and tells you when the file
has landed.

## Using it

1. Open the shelf and pick the Dropload widget. The first time, press
   **Install**: Dropload fetches its own copy of yt-dlp (see below).
2. Paste a link, or just open the shelf while a video page is in front of you
   in Safari or a Chromium browser — Dropload fills the bar in on its own.
   Turn that off in Settings if you would rather paste.
3. Choose the quality, the video container and the audio format. Anything the
   page cannot give you is greyed out.
4. Press **Download**. The shelf stays open while it runs, the live activity
   shows the progress when you look away, and a HUD says "Saved" when it is
   done, with **Show in Finder**.

Files land in ~/Downloads unless you choose another folder in Settings.

## The tools Dropload uses

Dropload never puts an executable inside its own bundle. Both tools live in
Droppy's container for this droplet, under `tools/`, and you can point
Dropload at your own copies from Settings instead.

| Tool | Where it comes from | How it is checked |
| --- | --- | --- |
| yt-dlp | The `yt-dlp_macos.zip` onedir build from the latest [yt-dlp GitHub release](https://github.com/yt-dlp/yt-dlp/releases), over HTTPS. | Against the `SHA2-256SUMS` file published with that release. |
| ffmpeg | Your own first: `/opt/homebrew/bin`, `/usr/local/bin`, then `PATH`. Only when the Mac has none, a static build for the running architecture from [ffmpeg.martin-riedl.de](https://ffmpeg.martin-riedl.de), over HTTPS. | Against the checksum published beside that exact build. |

Nothing is downloaded until you press Install. A download whose checksum does
not match is discarded and nothing is written into place. Dropload checks
GitHub for a newer yt-dlp when you ask it to, from the Settings pane, and
leaves a yt-dlp you pointed it at yourself alone.

Dropload asks for these capabilities and no others: `expanded-surface`,
`shelf-read`, `shelf-write`, `hud`, `network-client`, `downloads` and
`apple-events` (reading the front tab of a browser, which macOS also gates
behind its own Automation prompt).

## Credits and licences

- **yt-dlp** does the downloading. It is released into the public domain under
  the [Unlicense](https://github.com/yt-dlp/yt-dlp/blob/master/LICENSE).
- **ffmpeg** merges the video and audio streams. The builds Dropload downloads
  come from [ffmpeg.martin-riedl.de](https://ffmpeg.martin-riedl.de); the
  sources are at [ffmpeg.org](https://ffmpeg.org/download.html) and the build
  scripts at [github.com/martin-riedl/ffmpeg-build](https://github.com/martin-riedl/ffmpeg-build).
  ffmpeg is LGPL v2.1 or later, and GPL v2 or later when a build enables a GPL
  component, so which licence applies depends on the build in use. A Homebrew
  ffmpeg you already have is covered by whatever Homebrew built for you.
- Dropload itself is MIT.

Dropload is not affiliated with yt-dlp, ffmpeg or any site it downloads from.
Download only what you have the right to download.

## Developing

```bash
droppykit run        # open it in Droppy's Settings panel
droppykit build      # produce Dropload.droplet
droppykit validate   # the checks a submission runs
droppykit submit     # open the submission form, filled in from this checkout
```

`AGENTS.md` is the brief for a coding agent, `docs/PLAN.md` the plan, and
`docs/tickets/` the work. `swift test` covers the pure logic; the network
tests only run with `DROPLOAD_NETWORK_TESTS=1`.

## Before submitting

- `creator.url` and `source.repository` in `droplet.json` are still
  placeholders: this checkout has no git remote. Point them at the real
  repository, push it, then run `droppykit submit`.
