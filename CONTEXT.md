# Downloady

A Droppy droplet that takes a web page's media link and saves the media (and optionally a text transcript) to a folder, through a queue.

## Language

### Links

**Lookup**:
The check that runs on a link before anything is queued: what it is, its title, what formats it offers.
_Avoid_: probe, fetch, info

**Playlist**:
A link that names several media rather than one (a playlist, a channel's videos). A Lookup on it lists entries; it is never downloaded as one piece.
_Avoid_: collection, list

**Live stream**:
A link whose media is being broadcast now, with no end known in advance.
_Avoid_: stream (alone), broadcast

### Queue

**Job**:
One media file the user asked for, from the moment it is queued until its file (and transcript) are on disk. A Playlist becomes one Job per entry.
_Avoid_: download, task, item

**Queue**:
The ordered Jobs, active and recently finished.

**Lane**:
A slot that runs one Job's step at a time. There is a download Lane and a transcription Lane, one Job each.
_Avoid_: worker, slot, thread

**Recording**:
A Job made from a Live stream: it grows until the user stops it or the broadcast ends, so it has elapsed time and size instead of a percentage. Recordings have their own Lane.
_Avoid_: live download, capture

**Scheduled recording**:
A Recording queued before its broadcast has begun. It holds no Lane while it waits; it takes the Recording Lane when the broadcast is due.
_Avoid_: upcoming, pending recording

**Stop**:
Ending a Recording and keeping what was recorded so far.
_Avoid_: finish, end

**Cancel**:
Ending a Job and discarding everything it wrote.
_Avoid_: abort, stop
