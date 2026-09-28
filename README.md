# Downloady

Download the video in front of you, from [Droppy](https://getdroppy.app)'s shelf.

Paste a link, or open the shelf while a video plays in your browser. Downloady
hands it to [yt-dlp](https://github.com/yt-dlp/yt-dlp) and tells you when the
file has landed.

A Droplet built with [DroppyKit](https://getdroppy.app/docs/droppykit).

## What it does

- **Picks up the link for you.** Opening the shelf over a video page in Safari
  or a Chromium browser fills the URL bar in. Or paste one.
- **You choose the format.** Quality, video container and audio format.
  Anything the page cannot give you is greyed out.
- **A queue you can walk away from.** The live activity shows progress, a HUD
  says "Saved" with **Show in Finder**. Cancelling removes the half-written files.
- **Subtitles or a transcript.** Write the site's subtitles as `.srt`, or
  transcribe the audio on this Mac with macOS 26's speech models. The audio
  never leaves the machine.
- **Playlists and live streams.** One download per playlist entry; live
  streams record until you stop them.
- **Quick actions.** Five global shortcuts, unbound by default. Bind them in
  Droppy's Settings, Shortcuts.

| Shortcut | Downloads |
| --- | --- |
| Open Downloady | — |
| Download this video / audio from this video | The page in front of you in your browser |
| Download the pasted video / audio from the pasted video | The link on the clipboard |

Files land in `~/Downloads` unless you pick another folder in Settings.

## Requirements

- Droppy 15.3 or later
- macOS 26 and ffmpeg for **Transcribe**, plus macOS's speech recognition
  permission (Settings has a **Grant** button)
- macOS's Automation permission to read your browser's front tab

## Tools

yt-dlp is installed on first run, without a click. In Settings each tool can come
from **Downloady** (its own copy), **This Mac** (e.g. Homebrew) or a **Custom** path.
Downloady's own copies live in its container under `tools/`, never inside the bundle.

| Tool | Used for | Downloady's copy comes from | Verified against |
| --- | --- | --- | --- |
| yt-dlp | Downloading | [yt-dlp releases](https://github.com/yt-dlp/yt-dlp/releases) (`yt-dlp_macos.zip`) | `SHA2-256SUMS` |
| ffmpeg | Merging streams, transcribing | [ffmpeg.martin-riedl.de](https://ffmpeg.martin-riedl.de), only when the Mac has none | The published checksum |
| Deno | YouTube's JavaScript challenges | [Deno releases](https://github.com/denoland/deno/releases), only when the Mac has none | `.sha256sum` |

A download whose checksum does not match is thrown away. When Settings opens,
Downloady checks for newer releases and offers **Update** for its own copies; for
a copy on This Mac it shows the command to run (`brew upgrade`, `pipx upgrade`,
`deno upgrade`) and copies it for you, never touching the tool itself.

yt-dlp runs with `--ignore-config`, so your own yt-dlp config cannot change
what Downloady asks for.

## Privacy

- **Network:** the page you give it (through yt-dlp), that page's host for the
  thumbnail and favicon, and the tool sources above.
- **Clipboard:** read once when you press paste or a "pasted video" shortcut.
  Droppy's clipboard history is never read.
- **Browser:** the front tab's URL, when you open the shelf or switch to your
  browser. **Check the tab in the background** in Settings limits that to when
  the widget is on your shelf, or turns it off.
- **Capabilities:** `expanded-surface`, `shelf-read`, `hud`, `network-client`,
  `downloads`, `apple-events`, `clipboard-write`, `speech-recognition`,
  `global-shortcuts`. Nothing else.

## Credits and licences

| Component | Role | Licence |
| --- | --- | --- |
| [yt-dlp](https://github.com/yt-dlp/yt-dlp) | Downloading | [Unlicense](https://github.com/yt-dlp/yt-dlp/blob/master/LICENSE) |
| [ffmpeg](https://ffmpeg.org/download.html) | Merging streams | LGPL 2.1+, or GPL 2+ when the build enables a GPL component ([build scripts](https://github.com/martin-riedl/ffmpeg-build)) |
| [Deno](https://github.com/denoland/deno) | JavaScript challenges | [MIT](https://github.com/denoland/deno/blob/main/LICENSE.md) |
| Downloady | | MIT, see [LICENSE](LICENSE) |

Downloady is not affiliated with yt-dlp, ffmpeg, Deno or any site it downloads
from. Download only what you have the right to download.

## Developing

```bash
droppykit run        # open it in Droppy's Settings panel
droppykit build      # produce .build/Downloady.droplet
droppykit validate   # the checks a submission runs
swift test           # pure logic; DOWNLOADY_NETWORK_TESTS=1 adds network tests
```

Drop `.build/Downloady.droplet` on
[Droppy Playground](https://getdroppy.app/download/playground) to try it on the
real notch. `AGENTS.md` is the brief for coding agents.
