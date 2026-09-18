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
   Turn that off in Settings if you would rather paste. By default it also
   looks the page up when you switch to your browser, so the link is ready
   before you open the shelf; **Check the tab in the background** in Settings
   narrows that to when the widget is on your shelf, or to nothing at all.
3. Choose the quality, the video container and the audio format. Anything the
   page cannot give you is greyed out. The choice applies to this download;
   the next one starts on the default you set in Settings.
4. Press **Download**. It runs in a queue you can leave: the live activity
   shows the progress when you look away, and a HUD says "Saved" when it is
   done, with **Show in Finder**. Cancelling a download takes its half-written
   files with it.

Files land in ~/Downloads unless you choose another folder in Settings.

## Quick actions

Downloady registers five global shortcuts, with no key bound by default. Bind
the ones you want in Droppy's Settings, Shortcuts:

- **Open Downloady**
- **Download this video** and **Download audio from this video**: the page
  in front of you in your browser
- **Download the pasted video** and **Download audio from the pasted video**:
  the link on the clipboard

Each one opens Downloady on the notch, which shows the download starting, or
why it could not.

## Text beside the video

The **Text** picker writes an `.srt` next to the media.

- **Subtitles** are the site's own, written by yt-dlp and converted to SubRip.
  Greyed out when the page has none.
- **Transcribe** makes one on this Mac with macOS 26's speech models, after
  the download, in the background. The audio never leaves the machine. It
  needs macOS 26, ffmpeg, and macOS's permission to recognise speech, which
  Downloady's settings ask for with **Grant**. Refuse it and Transcribe is
  greyed out, with the reason on the picker.

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

yt-dlp runs with `--ignore-config`, so a `yt-dlp` configuration file of your
own cannot change what Downloady asks for or the output it reads back.

Downloady asks for these capabilities and no others: `expanded-surface`,
`shelf-read`, `hud`, `network-client`, `downloads`, `apple-events` (reading
the front tab of a browser, which macOS also gates behind its own Automation
prompt), `speech-recognition` (transcribing on this Mac, which macOS gates
behind its own prompt too), `global-shortcuts` (the quick actions) and
`clipboard-read` (the link a "pasted video" quick action downloads, read only
when you press it).

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
