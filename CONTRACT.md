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

Shelf (`shelf`, feed as above) is the menu bar panel for Haul, Tidy, Reel, Snap, Booth and Dolly. Haul is private and has no feed: Shelf shows its local version only and never requests a Haul feed.

### Actions: `SDShelfActions`

- Each app registers its URL scheme (`haul`, `tidy`, `reel`, `snap`, `booth`, `dolly`) only for its installed bundle id, never for test or screenshot bundles.
- Info.plist key `SDShelfActions`: an array of the action names the build answers. Shelf shows a quick action only when the installed build lists it, so an older build simply hides it.
- Actions are a fixed allowlist with no parameters, with two exceptions: Haul's existing `add?url=`, and `open-item?id=<id>` with optional `&t=<seconds>` (a decimal, 0 or more) for a Recall search result. For `open-item` the app checks that `id` matches `[A-Za-z0-9-]{1,64}`, ignores unknown parameters, and opens its library or history plainly when the id is unknown. Anything else is ignored. Every action is safe to trigger by accident: it opens a window, starts a selection or starts a read-only scan, and nothing deletes, uploads or records without a further confirmation in the app.
- Every app also answers and lists `check-for-updates` (it shows its own Sparkle check). Shelf uses it as the update fallback and never shows it as a quick action.
- Dolly's `record` opens its Record bar; recording starts only from the bar's Record button. During a recording it stops and saves the take, as Dolly's own shortcut does.
- An app with Recall entries (Snap, Booth) lists `open-item`. Shelf never shows it as a quick action; without it, a search result opens the app plainly.

| App | `SDShelfActions` |
|---|---|
| Haul | `paste`, `check-for-updates` |
| Tidy | `checkup`, `check-for-updates` |
| Reel | `open-recent`, `check-for-updates` |
| Snap | `capture-area`, `capture-window`, `open-item`, `check-for-updates` |
| Booth | `new-episode`, `open-item`, `check-for-updates` |
| Dolly | `record`, `open-latest`, `check-for-updates` |

### Live status

- File: each app writes one JSON file, `~/Library/Application Support/Shelf/status/<scheme>.json`. The app creates the folder if it is missing. Mode 0600, 16 KB at most. Shelf only reads these files and never writes or deletes them.
- Common fields: `schema` (1), `app` (the scheme), `app_version`, `updated_at`. Optional `expires_at`: after that time Shelf treats the file as stale. Unknown fields are ignored. A `schema` higher than Shelf knows is treated as a missing file.
- Every timestamp (`updated_at`, `expires_at`, `last_check_at`, `taken_at`, `exported_at`) is a UTC ISO 8601 string such as `2026-10-23T14:02:11Z`. Byte counts are JSON integers.
- Every app-specific field is optional. Shelf drops a field with the wrong type on its own and keeps the rest of the file.

| App | Fields | Written when |
|---|---|---|
| Haul | `downloading_count`, `bytes_left`, `bytes_total`, `paused` | On change, at most once a second while downloading, once more when the queue empties (`downloading_count` 0). `expires_at` is 30 seconds ahead while downloading. |
| Tidy | `reclaimable_bytes`, `last_check_at` | When a check up finishes. No `expires_at`. |
| Reel | `resume_title`, `remaining_seconds`, `position_fraction`, optional `poster` | When playback pauses, stops or the app quits, and on resume. |
| Snap | `captures`: up to 3 of `{taken_at, preview}` | After each capture. |
| Booth | `episode_number`, `episode_title`, `script`, `recording`, `editing` (each `done` or `pending`) | When a stage changes. A field Booth has no source for is left out; `editing` is `done` only after export. |
| Dolly | `latest`: `{title, length_seconds, exported_shapes, exported_at}` for the most recently exported take (`exported_shapes` such as `["16:9"]`, `length_seconds` a decimal), optional `poster` | At launch and after each export. `latest` is left out until a take has been exported. |

- Previews: small JPEG files in `status/<scheme>/`, 240 px wide at most and 30 KB each: `poster.jpg` for Reel and Dolly, `1.jpg` to `3.jpg` for Snap. Reel's `poster` is the relative path `reel/poster.jpg` and Dolly's `dolly/poster.jpg`, each present only while the file exists. Each Snap capture's `preview` is the file name inside `status/snap/` (`1.jpg`), present only when previews are on. Shelf resolves preview paths against the status folder only and refuses any path with `..` or a leading `/`. An app writes previews only when its own "Show in Shelf" setting is on (default off) and deletes them when it is turned off.
- Writing: write `.<name>.tmp` in the same folder, `fsync`, then `rename(2)` over the target. Never write in place. At most one write per second per app.
- Never included: file paths, URLs (page, download or feed), clipboard contents, file names, hashes or IDs of user content, account names, tokens. Titles only where the user already sees them in the app (Reel's video title, Booth's episode title, Dolly's take name), cut to 80 characters.
- How Shelf reads: one file-system watcher on the `status` folder, no timers and no polling. It waits 300 ms after an event, then re-reads only files whose modification time changed. While the panel is closed it only marks the data stale; while it is open a change reaches the view at most once a second.
- Fallback: Shelf shows its static info and no live line, with no error text, when the file is missing, is not valid JSON, is over 16 KB, has an unknown schema or another app's name, is past its `expires_at`, or belongs to an app that is not installed. Values that only make sense while the app runs (Haul's queue) are dropped when the app is not running. At-rest values (Tidy's size, Booth's episode state) stay visible for up to 30 days, with their age in words.

### Search index (Recall)

Snap and Booth (phase 1) write what they extract from the owner's captures so Shelf can search it. Shelf only reads.

- Folder: `~/Library/Application Support/Shelf/recall/<scheme>/`, created by the app if missing, mode 0700. With a non-default `<APP>_HOME` the app uses its own folder next to its test status folder (Snap `ShelfRecall/`, Booth `shelf-recall/`).
- One file per item, `<id>.json`, mode 0600, at most 4 MB. `id` is the app's own id, `[A-Za-z0-9-]{1,64}`, and matches the file name. Write as status files are written: `.<name>.tmp` in the same folder, `fsync`, `rename(2)`.
- Fields: `schema` (1), `app` (the scheme), `id`, `kind` (`screenshot`, `take`), `title` (at most 120 characters), `created_at`, `updated_at` (UTC ISO 8601), optional `language` (BCP 47), optional `preview` (a file name in the same folder), optional `duration_seconds`, optional `context` (an object of display strings and numbers, at most 120 characters each), `segments` (an array of `{text}` with optional `start` and `end` in seconds and `speaker` (`host`, `guest`)).
- Preview: optional `<id>.jpg`, 480 px on the long side at most, 80 KB at most. Snap writes one only while its "Show previews in Shelf search" setting is on. Booth writes the episode artwork.
- The status file "Never included" list does not apply here. Entries carry ids, titles and extracted text by design; this section's own list below governs them.
- The app keeps the folder exact: it writes an entry when an item is captured or transcribed, rewrites it when the item changes, and deletes the entry and preview in the same step that removes the item (retention, Trash, discard, delete). At launch it reconciles the folder with its own data. Turning the app's search setting off deletes everything it wrote there.
- Never included: text the app identified as a likely secret (replaced with `[hidden]`), anything from an item the owner excluded, audio, full-size images, file paths, URLs, account names, tokens.
- Shelf reads with one watcher per app folder, a 300 ms debounce and modification-time checks, and keeps its own index in `$SHELF_HOME/recall.sqlite`, which it may delete and rebuild at any time. Shelf skips a file that is over 4 MB, not valid JSON, of an unknown schema, of another app, a symlink, or whose id does not match its name. It resolves `preview` inside that app's folder only and refuses `/` and `..`. Shelf never writes, creates or deletes anything under `recall/`.
- Status fields: Snap and Booth add optional `recall` (`on`, `off`, and for Booth `needs_model`) and `recall_pending` (an integer) to their status files.
