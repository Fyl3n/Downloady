# T4: Polish, completion feedback and release readiness

**Depends on:** T1–T3 · **Files:** the UI, `droplet.json`, `Downloady.icon`,
`Assets/Creator.png`, `README.md`.

## Goal

Downloady looks native on both the notch and the island, tells the user when a
download ends, and passes review.

## Scope

1. Layout pass, using the shots as the reference:
   - In the Dynamic Island composition of the base scaffold, the leftmost
     characters of the header glyph and the status line are clipped by the
     clip corner. Fix it with the host's `context.contentInsets` and layout
     that stays inside the rectangle, not with extra padding.
   - Check the paired composition (210 wide). The height should be exactly
     what the content needs; re-declare `contentHeight` if needed.
   - Check the detail view on a notch and on the island, and size it in
     `expandedSurfaceSize` from its content.
   - Follow `DesignGuidelines.md`: sentence case, `AdaptiveColors`,
     `DroppySpacing`, and `DroppyTransition.element`/`.compactContent` for
     swapped content. Add no custom animations.
2. Completion feedback: add the `hud` capability and `HUDPresenting`
   conformance (update the `surfaces` and `capabilities` fields in
   `droplet.json`). Present a strip ("Downloaded" plus the file name) when a
   download finishes while the shelf is closed; its card has a Show in Finder
   button. Optionally add a `live-activity` showing progress while the shelf
   is closed, following the seat rules in `LiveActivities.md`, and yield it
   once the download is done.
3. Global shortcut (optional, `global-shortcuts`): "Download current tab"
   with the current options. Drop it if it adds review risk.
4. Remove any capability that ended up unused.
5. Release assets: a real `Downloady.icon` (Icon Composer, readable at 28pt),
   the creator avatar, `droplet.json` `creator.url` and `source.repository`,
   and a README with usage, the tools policy (what is downloaded, from where,
   and how it is verified) and credits (yt-dlp: Unlicense; ffmpeg: LGPL/GPL
   depending on the build — link the source).
6. Install into Droppy Playground (`droppykit_install`) and run a complete
   pass: install tools, auto-fill, download video, download audio, cancel,
   disable the droplet mid-download.

## Acceptance

- `droppykit validate` says "Ready to submit". The report has no problems.
- The shots of every declared surface have been reviewed on both the notch
  and the island.
- The Playground Store row shows the droplet loaded and switched on.
- The full manual pass above succeeds.
