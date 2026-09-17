# T3: Browser URL auto-detection

**Depends on:** T2 (uses `DownloadModel.fetchInfo`) · **Files:**
`Browser/BrowserURLProvider.swift`, `Model/DownloadModel.swift`,
`UI/DroploadSettingsView.swift`, `UI/DroploadWidget.swift`.

## Goal

When the user opens the shelf while a supported browser is showing a page
yt-dlp can handle, the URL bar already contains that page's URL.

## Scope

1. `BrowserURLProvider`:
   - Observe `NSWorkspace.shared.notificationCenter`
     `didActivateApplicationNotification`. Remember the most recent
     frontmost app that is a `SupportedBrowser` (matched by bundle ID).
     Opening Droppy's shelf does not activate Droppy, but handle it if it
     does.
   - `currentURL()`: run `SupportedBrowser.script` with `NSAppleScript` on a
     background queue for the remembered browser, and only if that browser is
     still running. Accept only `http` and `https`. Map error `-1743` to a
     published "not authorised" state, and `-600` (not running) to `nil`.
   - `start(onChange:)` / `stop()`: add and remove the observer. Throttle so
     each activation produces at most one read.
2. `DownloadModel`:
   - In `start(host:)`, start the provider only when `autoFillFromBrowser` is
     on **and** `host.isGranted(.appleEvents)`. Restart or stop it when the
     setting changes.
   - When the widget or detail view appears (`onAppear`), ask the provider for
     `currentURL()` so the value is fresh at the moment the shelf opens.
   - `browserDidReport`: skip it if the user typed a URL, or if the URL equals
     the current one. Otherwise set the text marked as **auto-filled**, run
     `fetchInfo()`, and if the result is `.unsupported`, restore the previous
     text silently (no warning glyph for auto-filled URLs). Cache verdicts
     per URL, keeping the last 50 in memory.
   - Clearing the field, or a finished download, resets `urlWasTyped` so
     auto-fill resumes.
3. Permissions:
   - Request Automation through `host.permissions.request(.appleEvents)` only
     from Settings (the "Allow" button), never at activation.
   - Settings card: the auto-fill toggle (already present), a permission row
     showing its status, with "Open System Settings" when it is denied, and a
     row listing the supported browsers.
4. Widget: a small browser glyph in the URL bar when the URL was auto-filled
   (`help`: "From Safari", for example).

## Acceptance

- With Safari on a YouTube video, opening the shelf fills the URL and the
  pickers refresh. The same works in Chrome and Arc.
- With Safari on `https://example.com`, the URL bar stays as it was.
- A URL the user typed is never replaced.
- With Firefox, or with the toggle off, nothing happens and no AppleScript
  runs (check with `log stream` on the `droplets` category).
- Unit tests: bundle-ID matching, the http(s) filter, and the auto-fill
  decision logic (extract it into a pure function).
- The Definition of done in `docs/PLAN.md` is met. Test auto-fill in Droppy
  Playground, because the harness does not show the Automation prompt.
