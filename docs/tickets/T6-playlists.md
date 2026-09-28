# T6 — Playlists become one Job per entry

Today a playlist-only link (`/playlist?list=…`, `@channel/videos`) goes
through as if it were one video. `--no-playlist` has nothing to fall back to,
so `yt-dlp -J` resolves every entry: a 54-entry playlist took 67 s and returned
40 MB of JSON. Download then fetches all of them in one Job:

- the progress ring goes back to 0 at each entry;
- `job.file` is only the last entry, and so is the transcript;
- Cancel runs `removeLeftovers` on every file announced during the run, which
  deletes the entries that had already finished.

The decision and its reasons are in [ADR 0001](../adr/0001-playlists-expand-live-records.md).
The terms (Lookup, Playlist, Job, Lane) are defined in [CONTEXT.md](../../CONTEXT.md).

## Behaviour

- **Lookup.** `YtDlpCommand.fetchInfo` adds `--flat-playlist`. A single video
  is unaffected; a playlist comes back in seconds with `_type: "playlist"` and
  `entries[]`. Each entry has `url`, `title`, `duration`, `availability` and
  `live_status` (checked against yt-dlp 2026.08.19).
- **`MediaInfo`** decodes `_type`, `playlist_count` and `entries` (url, title,
  duration, availability, live_status). A playlist has no `formats`, so
  `fetchInfo`'s "no formats and Generic, so unsupported" check has to let
  `_type == "playlist"` through.
- **The form.** For a Playlist it shows "Playlist · N videos" instead of the
  single-media preview. One set of options (quality, audio only, transcript)
  applies to every entry. Availability stays `.unrestricted`, because the
  entries' formats are unknown and yt-dlp falls back on its own. The button
  reads **Download N videos**, where N counts only the entries that can be
  downloaded. The subtitles option is offered, and each entry that has none
  writes none.
- **Queueing.** `startDownload()` queues one Job per entry, in playlist order:
  - The Job's `url` is the entry's `url`, its title the entry's title, its
    duration the entry's duration.
  - Its folder is a subfolder of the download folder named after the Playlist's
    title (sanitised for the file system, created when queued).
  - Each Job's `subtitleLanguage` falls back to the user's first preferred
    language, because no entry has its own Lookup.
- **Unavailable entries.** When `availability` is `private`, `premium_only`,
  `subscriber_only` or `needs_auth`, or the title is YouTube's
  `[Private video]` / `[Deleted video]`, the entry is still queued, but as a
  Job already in `.failed(reason)` with the reason in words ("Private video").
  yt-dlp never runs for it. An entry that is live or upcoming (`live_status`)
  is queued failed with "Live stream: open it on its own to record it".
- **History.** `trimHistory()` trims `.finished` rows only. Failed rows stay
  until **Clear finished**, or a large Playlist's unavailable entries would
  disappear as soon as they were queued.
- **Quick actions.** `downloadFrontTab` and `downloadPasted` on a Playlist open
  the form with the count instead of queueing.
- **Mixed links.** `watch?v=X&list=Y` still downloads video X only
  (`--no-playlist` stays).
- **Queue surface.** A **Cancel waiting** button next to **Clear finished**
  removes every `.waiting` Job. It is shown only when at least one Job is
  waiting.
- The download Lane stays at one Job, so entries download one at a time.

## Tests

- `MediaInfo` decodes a flat-playlist document (a trimmed real fixture), and a
  single video still decodes as before.
- The pure function that turns a Playlist into Jobs: order, folder, and failed
  Jobs for unavailable and live entries.
- `trimHistory` keeps failed rows.
- `YtDlpCommand.fetchInfo` contains `--flat-playlist`; `download` does not.

## Not done, on purpose

- No per-entry picker and no limit on N: the count on the button is the
  confirmation.
- No "whole playlist" option for `watch?v=X&list=Y` links.
- No parallel downloads: they are limited by bandwidth, not CPU, and YouTube
  throttles several at once.

## Deviations

- The paired widget's button reads **N videos** instead of **Download N
  videos**: at 210 pt the full label was cut to "Download…", which hid the
  count that serves as the confirmation. Solo and the takeover read
  **Download N videos**.
