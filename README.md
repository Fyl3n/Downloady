# Downloady

Download the video in front of you, from Droppy's shelf.

Downloady is a Droplet for [Droppy](https://getdroppy.app), the Dynamic Island
and shelf for Mac. It puts a URL bar and three pickers on the notch, hands the
link to [yt-dlp](https://github.com/yt-dlp/yt-dlp), and tells you when the file
has landed.

## Using it

1. Open the shelf and pick the Downloady widget. The first time, Downloady
   fetches its own copy of yt-dlp on its own (see below); the widget shows
   the progress.
2. Paste a link, or just open the shelf while a video page is in front of you
   in Safari or a Chromium browser — Downloady fills the bar in on its own.
   Turn that off in Settings if you would rather paste.
3. Choose the quality, the video container and the audio format. Anything the
   page cannot give you is greyed out. The choice applies to this download;
   the next one starts on the default you set in Settings.
4. Press **Download**. The shelf stays open while it runs, the live activity
   shows the progress when you look away, and a HUD says "Saved" when it is
   done, with **Show in Finder**.

Files land in ~/Downloads unless you choose another folder in Settings.

## The tools Downloady uses

Downloady never puts an executable inside its own bundle. Both tools live in
Droppy's container for this droplet, under `tools/`. In Settings each tool
has a source: **Downloady** (its own copy), **This Mac** (one you installed,
e.g. with Homebrew) or **Custom** (a path you choose). Picking This Mac when
none is installed switches to Custom and says so.

| Tool | Where it comes from | How it is checked |
| --- | --- | --- |
| yt-dlp | The `yt-dlp_macos.zip` onedir build from the latest [yt-dlp GitHub release](https://github.com/yt-dlp/yt-dlp/releases), over HTTPS. | Against the `SHA2-256SUMS` file published with that release. |
| ffmpeg | This Mac's by default: `/opt/homebrew/bin`, `/usr/local/bin`, `~/.local/bin`, then `PATH`. Only when the Mac has none, or you pick Downloady, a static build for the running architecture from [ffmpeg.martin-riedl.de](https://ffmpeg.martin-riedl.de), over HTTPS. | Against the checksum published beside that exact build. |

yt-dlp is installed on first run, without a click. A download whose checksum does
not match is discarded and nothing is written into place. Downloady checks
GitHub for a newer yt-dlp when the Settings pane opens and offers **Update**,
and leaves a yt-dlp from This Mac or a custom path alone.

Downloady asks for these capabilities and no others: `expanded-surface`,
`shelf-read`, `shelf-write`, `hud`, `network-client`, `downloads` and
`apple-events` (reading the front tab of a browser, which macOS also gates
behind its own Automation prompt).

## Credits and licences

- **yt-dlp** does the downloading. It is released into the public domain under
  the [Unlicense](https://github.com/yt-dlp/yt-dlp/blob/master/LICENSE).
- **ffmpeg** merges the video and audio streams. The builds Downloady downloads
  come from [ffmpeg.martin-riedl.de](https://ffmpeg.martin-riedl.de); the
  sources are at [ffmpeg.org](https://ffmpeg.org/download.html) and the build
  scripts at [github.com/martin-riedl/ffmpeg-build](https://github.com/martin-riedl/ffmpeg-build).
  ffmpeg is LGPL v2.1 or later, and GPL v2 or later when a build enables a GPL
  component, so which licence applies depends on the build in use. A Homebrew
  ffmpeg you already have is covered by whatever Homebrew built for you.
- Downloady itself is MIT.

Downloady is not affiliated with yt-dlp, ffmpeg or any site it downloads from.
Download only what you have the right to download.

## Developing

```bash
droppykit run        # open it in Droppy's Settings panel
droppykit build      # produce Downloady.droplet
droppykit validate   # the checks a submission runs
droppykit submit     # open the submission form, filled in from this checkout
```

`AGENTS.md` is the brief for a coding agent, `docs/PLAN.md` the plan, and
`docs/tickets/` the work. `swift test` covers the pure logic; the network
tests only run with `DOWNLOADY_NETWORK_TESTS=1`.

## Before submitting

- `creator.url` and `source.repository` in `droplet.json` are still
  placeholders: this checkout has no git remote. Point them at the real
  repository, push it, then run `droppykit submit`.
