# Playlists expand into Jobs; live streams are Recordings stopped with SIGINT

A Playlist is never downloaded as one yt-dlp run. The Lookup lists it with `--flat-playlist` and every entry becomes its own Job, because the queue already gives a Job its own row, file, progress, Cancel and transcript. A single Job for a whole Playlist would need a "many files" version of all of these, and its Cancel deleted every entry that had already finished. Entries the Lookup marks as unavailable still become Jobs, created already failed with the reason, so the user sees why they are missing.

A Live stream becomes a Recording, which runs in its own Lane of one so it never blocks the download Lane for the length of a broadcast. Its only control is Stop, which keeps the file. Stop sends SIGINT to yt-dlp alone, not SIGTERM to its process tree (the way Cancel ends every other Job): on SIGINT, yt-dlp tells ffmpeg to quit and ffmpeg finishes the file, while SIGTERM to ffmpeg first leaves a `.part` file that the cleanup then deletes. `deactivate()` Stops Recordings for the same reason.

## Considered options

- Refusing Playlists and live streams altogether: small, but a live stream is exactly what a user wants to keep, and a Playlist is the fastest way to ask for many Jobs.
- `--live-from-start`: works on a few sites only, and can take a long time to catch up. Left out until someone asks for it.
- A Split control (keep recording into a new file): downloading the link again does the same thing with the same few-second gap.

## Consequences

- A Scheduled recording waits in memory and holds no Lane until its `release_timestamp`. The queue is not persisted, so a relaunch loses it.
- `trimHistory` must not trim failed rows, or the unavailable entries of a large Playlist would disappear as soon as they are queued.
