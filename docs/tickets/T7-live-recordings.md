# T7 — Live streams become Recordings

Today a live link passes the Lookup (`is_live: true`, `duration: nil`,
`m3u8_native` formats) and downloads like a video, with these problems:

- yt-dlp hands a live stream to ffmpeg, whose output goes to stderr, so no
  `downloady …` progress line ever arrives and the ring stays at 0 %.
- The Job holds the only download Lane until the broadcast ends, which for a
  24/7 stream is never.
- Cancel is the only way out: SIGTERM to the process tree, ffmpeg first, then
  `removeLeftovers` deletes the `.part` file. The whole recording is lost.

The decision and its reasons are in [ADR 0001](../adr/0001-playlists-expand-live-records.md).
The terms (Recording, Scheduled recording, Stop, Cancel, Lane) are defined in
[CONTEXT.md](../../CONTEXT.md).

## Behaviour

- **Lookup.** `MediaInfo` decodes `live_status` and `release_timestamp`:
  - `is_live` makes the Job a Recording;
  - `is_upcoming` makes it a Scheduled recording;
  - `post_live` and `was_live` are ordinary Jobs, and when yt-dlp fails (for
    example "still being processed") its message is shown as it is.
- **The Recording Lane.** It is a third Lane, next to download and
  transcription, and runs one Recording at a time. Downloads keep running
  beside it; a second Recording waits.
- **Recording state.** A Recording shows elapsed time and size instead of a
  percentage. Elapsed time is the wall clock since yt-dlp started; size is the
  announced file's `.part` on disk, read every few seconds off the main actor.
  Neither comes from stdout.
- **Stop** is the only control on a Recording's row. It sends **SIGINT to
  yt-dlp alone** (not `signalTree`, not SIGTERM). yt-dlp then sends ffmpeg
  `q`, the file is finished and the process exits 0, so `--print
  after_move:filepath` reports it and the Job ends `.finished` as usual.
  - SIGKILL follows only if yt-dlp is still running after a generous timeout.
  - `removeLeftovers` must not run after a Stop.
  - To keep recording after a Stop, the user downloads the link again; there is
    no Split.
- **The broadcast ends by itself.** yt-dlp exits 0 and the Job finishes like
  any other.
- **`deactivate()`** Stops every running Recording instead of cancelling it.
  Other Jobs are cancelled as today.
- **Scheduled recording.**
  - It waits in the queue and holds no Lane. At `release_timestamp` it asks for
    the Recording Lane and starts yt-dlp with `--wait-for-video 15-60`, so a
    late start is covered.
  - Without a `release_timestamp`, it takes the Recording Lane at once and
    yt-dlp waits.
  - Its row shows "Starts in 2 h 10 min" and its control is Cancel, because
    there is nothing to keep yet.
  - The queue is not persisted, so a relaunch loses a Scheduled recording.
    This is accepted.
- **Transcript.** The subtitles option is hidden for a Recording, because a
  live stream only has live chat. Local transcription runs on the file after
  Stop, with its duration read from the file (ffprobe, or `AVURLAsset`)
  because `job.duration` is nil.
- **The notch.** While a Recording runs, the live activity's trailing wing
  shows a **pulsing red record circle** (`record.circle.fill`, red, with a
  pulse effect) instead of the percentage. The leading wing keeps the download
  ring while a download runs beside it; with only a Recording running, it
  shows the plain glyph without a ring.
  - DroppyKit gives no guidance on a continuous animation in a wing. Check the
    live-activity shots on notch and island, and in the Playground, that the
    pulse does not replay the wing's compact-content transition.
- **HUD.** When a Recording finishes, the HUD's title reads "Recorded" instead
  of "Downloaded".

## Tests

- `MediaInfo` decodes `live_status` and `release_timestamp` (fixtures for live,
  upcoming and post-live).
- The Lanes: a Recording does not block `nextToDownload`, and a second
  Recording waits for the first.
- `QueueSummary` with a Recording leading.
- The scheduling rule, as a pure function: whether a Scheduled recording is due
  at a given time, and what happens without a timestamp.
- By hand, on a real 24/7 stream: Stop after 30 s leaves a playable file and no
  `.part`.

## Not done, on purpose

- No `--live-from-start`.
- No Split control.
- No persistence of Scheduled recordings across relaunches.

## Deviations

Found while implementing, against yt-dlp 2026.08.19 on a real 24/7 stream.

- **SIGINT works as the ADR says.** yt-dlp turns it into a KeyboardInterrupt,
  sends ffmpeg `q`, and for an `is_live` stream counts that as success
  (`ExternalFD.real_download`): exit 0 about 4 s later, `.part` renamed,
  `after_move:filepath` printed. SIGINT must not be ignored in yt-dlp: a
  shell's `cmd &` ignores it, Foundation's `Process` from Droppy does not.
- **`--no-hls-use-mpegts` for a Recording.** By default yt-dlp has ffmpeg
  write a live stream as MPEG-TS, and skips its MP4 fix-up
  (`FFmpegFixupM3u8PP`) whenever it merged video and audio, which is every
  `bv+ba` Recording. The result is an MPEG-TS `.mp4` that ffmpeg plays and
  QuickTime/AVFoundation refuse ("Cannot Open"), which also broke the
  transcript's `AVURLAsset` duration. As MP4, ffmpeg writes the index on `q`
  and the file opens everywhere. The cost: a Recording SIGKILLed after the
  30 s timeout leaves an MP4 with no index, which MPEG-TS would have survived.
- **`--ignore-no-formats-error` on the Lookup.** Without it, `-J` of a
  broadcast that has not begun fails ("This live event will begin in 10
  hours") and no Scheduled recording can be made. With it, yt-dlp's
  no-formats reasons (DRM, …) become warnings, so a Lookup with no formats
  that is not upcoming now fails with that warning as its message.
- **Only `is_upcoming` is scheduled.** An `is_live` stream also reports a
  `release_timestamp`, the moment it began.
- **`--wait-for-video 15-60` is passed to every Recording**, not only
  Scheduled ones: it does nothing for a stream that is on, and covers one
  with no `release_timestamp` that takes the Lane at once.
- **Stop before anything is written is Cancel.** A Recording still waiting
  for its broadcast in yt-dlp has nothing to keep, and yt-dlp would have no
  file to report after a SIGINT there (not tried).
