# T5 — Text, and downloads that run in the background

Downloady stops holding the shelf open while it works. A download becomes a
job in a queue, the form is free for the next page the moment one starts, and
the notch carries the progress. The fourth picker, Text, writes an `.srt`
beside the media: the site's own subtitles, or one made on this Mac.

## Done

- **The Text picker** (`TranscriptMode`), under the format pickers and in
  Settings' default format row. Off by default.
  - `subtitles` adds `--write-subs --write-auto-subs --sub-langs <lang>,-live_chat
    --convert-subs srt`. The language is the first of the user's own languages
    the media has, else its own language, else English (`MediaInfo.subtitleLanguage(preferring:)`).
    The entry is greyed out when `yt-dlp -J` reported no subtitle track.
  - `transcribe` runs after the download: ffmpeg writes 16 kHz mono PCM into a
    temporary file, macOS 26's `SpeechAnalyzer`/`SpeechTranscriber` reads it,
    and the cues are written as SubRip. Greyed out before macOS 26, without the
    `speech-recognition` capability, or without ffmpeg; Settings' Text card says
    which. The audio never leaves the Mac.
- **The queue** (`DownloadJob`, `DownloadModel.jobs`). Two lanes, one job each:
  downloads, and transcripts. `startDownload()` queues and returns; auto-fill
  keeps following the browser while jobs run.
- **No pinned shelf**: `setHoldsOpen` is gone, and with it the `shelf-write`
  capability.
- **The notch**: the live activity is published for the whole queue (ring,
  percentage, and the count when more than one job is left), and a HUD says
  when a file lands — the media, and again when a transcript follows it.
- **The queue surface** (`downloady-queue`), opened from the chip that appears
  in the form beside Download whenever something else is running: one row per
  job, with Cancel while it runs and Show in Finder when it is done.
- `DOWNLOADY_DEMO_QUEUE=1 droppykit run` fills the queue with jobs that are not
  running, for the shots.

## Not done, on purpose

- No whisper.cpp: one more binary to install, update and vouch for, for a
  language model macOS 26 already has.
- No second transcript format (`.txt`, `.vtt`): both paths leave the same
  `.srt`, which every player and editor reads.
