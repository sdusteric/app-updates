# Update contract (shared by every app)

- Framework: Sparkle 2.10.0. Swift apps use the Swift package `https://github.com/sparkle-project/Sparkle` at exact 2.10.0. Rust apps embed `vendor/Sparkle-2.10.0/Sparkle.framework` from this repo (sha256-verified tarball).
- Signing key: EdDSA, stored in the login Keychain under account `sdusteric-apps`. Public key for Info.plist `SUPublicEDKey`: `PMaW+8sZRzOkfIwy1KBGk0CHTVoN49FE9o8gUlNGdZc=`.
- Feed URL for app `<app>` (lowercase): `https://sdusteric.github.io/app-updates/<app>/appcast.xml` (GitHub Pages from the main branch root of the public repo sdusteric/app-updates).
- Archives: GitHub Release `<app>-v<short>-<build>` in sdusteric/app-updates, one asset `<Name>-<short>-<build>.zip` made with `ditto -c -k --sequesterRsrc --keepParent`.
- Versions: `CFBundleShortVersionString` from the repo's VERSION file (semver). `CFBundleVersion` is the UTC build time `YYYYMMDDHHMM`, always increasing.
- Info.plist keys: `SUFeedURL`, `SUPublicEDKey`, `SUEnableAutomaticChecks` true, `SUAutomaticallyUpdate` true, `SUScheduledCheckInterval` 86400.
- In app: a "Check for Updates…" menu item and a settings toggle for automatic updates. The updater never starts in shot mode, tests, CLIs or when the env var `<APP>_NO_UPDATES=1` is set.
- Publishing: `tools/publish.sh --app <app> --bundle <path/App.app> [--notes <file.md>] [--dry-run <dir>]`. Each app repo has `scripts/release.sh` that runs its check gates, builds the release bundle and calls publish.sh.

## Shelf (home base for the apps)

Shelf (`shelf`, feed as above) is the menu bar panel for Haul, Tidy, Reel, Snap and Booth. Haul is private and has no feed: Shelf shows its local version only and never requests a Haul feed.

### Actions: `SDShelfActions`

- Each app registers its URL scheme (`haul`, `tidy`, `reel`, `snap`, `booth`) only for its installed bundle id, never for test or screenshot bundles.
- Info.plist key `SDShelfActions`: an array of the action names the build answers. Shelf shows a quick action only when the installed build lists it, so an older build simply hides it.
- Actions are a fixed allowlist with no parameters (Haul's existing `add?url=` is the one exception). Anything else is ignored. Every action is safe to trigger by accident: it opens a window, starts a selection or starts a read-only scan, and nothing deletes, uploads or records without a further confirmation in the app.
- Every app also answers and lists `check-for-updates` (it shows its own Sparkle check). Shelf uses it as the update fallback and never shows it as a quick action.

| App | `SDShelfActions` |
|---|---|
| Haul | `paste`, `check-for-updates` |
| Tidy | `checkup`, `check-for-updates` |
| Reel | `open-recent`, `check-for-updates` |
| Snap | `capture-area`, `capture-window`, `check-for-updates` |
| Booth | `new-episode`, `check-for-updates` |

### Live status

- File: each app writes one JSON file, `~/Library/Application Support/Shelf/status/<scheme>.json`. The app creates the folder if it is missing. Mode 0600, 16 KB at most. Shelf only reads these files and never writes or deletes them.
- Common fields: `schema` (1), `app` (the scheme), `app_version`, `updated_at`. Optional `expires_at`: after that time Shelf treats the file as stale. Unknown fields are ignored. A `schema` higher than Shelf knows is treated as a missing file.
- Every timestamp (`updated_at`, `expires_at`, `last_check_at`, `taken_at`) is a UTC ISO 8601 string such as `2026-10-23T14:02:11Z`. Byte counts are JSON integers.
- Every app-specific field is optional. Shelf drops a field with the wrong type on its own and keeps the rest of the file.

| App | Fields | Written when |
|---|---|---|
| Haul | `downloading_count`, `bytes_left`, `bytes_total`, `paused` | On change, at most once a second while downloading, once more when the queue empties (`downloading_count` 0). `expires_at` is 30 seconds ahead while downloading. |
| Tidy | `reclaimable_bytes`, `last_check_at` | When a check up finishes. No `expires_at`. |
| Reel | `resume_title`, `remaining_seconds`, `position_fraction`, optional `poster` | When playback pauses, stops or the app quits, and on resume. |
| Snap | `captures`: up to 3 of `{taken_at, preview}` | After each capture. |
| Booth | `episode_number`, `episode_title`, `script`, `recording`, `editing` (each `done` or `pending`) | When a stage changes. A field Booth has no source for is left out; `editing` is `done` only after export. |

- Previews: small JPEG files in `status/<scheme>/`, 240 px wide at most and 30 KB each: `poster.jpg` for Reel, `1.jpg` to `3.jpg` for Snap. Reel's `poster` is the relative path `reel/poster.jpg`, present only while the file exists. Each Snap capture's `preview` is the file name inside `status/snap/` (`1.jpg`), present only when previews are on. Shelf resolves preview paths against the status folder only and refuses any path with `..` or a leading `/`. An app writes previews only when its own "Show in Shelf" setting is on (default off) and deletes them when it is turned off.
- Writing: write `.<name>.tmp` in the same folder, `fsync`, then `rename(2)` over the target. Never write in place. At most one write per second per app.
- Never included: file paths, URLs (page, download or feed), clipboard contents, file names, hashes or IDs of user content, account names, tokens. Titles only where the user already sees them in the app (Reel's video title, Booth's episode title), cut to 80 characters.
- How Shelf reads: one file-system watcher on the `status` folder, no timers and no polling. It waits 300 ms after an event, then re-reads only files whose modification time changed. While the panel is closed it only marks the data stale; while it is open a change reaches the view at most once a second.
- Fallback: Shelf shows its static info and no live line, with no error text, when the file is missing, is not valid JSON, is over 16 KB, has an unknown schema or another app's name, is past its `expires_at`, or belongs to an app that is not installed. Values that only make sense while the app runs (Haul's queue) are dropped when the app is not running. At-rest values (Tidy's size, Booth's episode state) stay visible for up to 30 days, with their age in words.
