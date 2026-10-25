# Adding an app

Follow these steps for each new app. `<app>` is the lowercase name, `<APP>` the same in capitals.

## 1. Info.plist keys

Set all of these in the app's Info.plist:

- `SUFeedURL`: `https://sdusteric.github.io/app-updates/<app>/appcast.xml`
- `SUPublicEDKey`: `PMaW+8sZRzOkfIwy1KBGk0CHTVoN49FE9o8gUlNGdZc=`
- `SUEnableAutomaticChecks`: true
- `SUAutomaticallyUpdate`: true
- `SUScheduledCheckInterval`: 86400
- `LSMinimumSystemVersion`, `CFBundleIdentifier`
- `CFBundleShortVersionString`: read from the repo's `VERSION` file (semver)
- `CFBundleVersion`: UTC build time `YYYYMMDDHHMM`, generated at build time so it always increases

## 2. Embed Sparkle

Swift apps add the package `https://github.com/sparkle-project/Sparkle` at exact version 2.10.0. Rust apps copy `vendor/Sparkle-2.10.0/Sparkle.framework` from this repo into `Contents/Frameworks`.

The framework must be inside the app at `Contents/Frameworks/Sparkle.framework`. Sign inside-out with the same identity, never with `--deep`:

1. `Sparkle.framework/Versions/B/XPCServices/Installer.xpc` and `Downloader.xpc` (skip Downloader.xpc if you removed it)
2. `Sparkle.framework/Versions/B/Autoupdate` and `Updater.app`
3. `Sparkle.framework` itself
4. The app bundle, last

Use `--options runtime` and a secure timestamp for release builds. The app must pass `codesign --verify --deep --strict`, because `publish.sh` checks it.

## 3. Menu item and settings toggle

- Add a "Check for Updates…" item to the app menu that calls the updater's check action.
- Add a settings toggle for automatic updates, bound to the updater's `automaticallyChecksForUpdates` and `automaticallyDownloadsUpdates`.

## 4. Where the updater must not run

Do not start the updater in shot mode (screenshot runs), in tests, in command line tools built from the same code, or when `<APP>_NO_UPDATES=1` is set. Decide this before creating the updater controller, so nothing is started and then stopped.

## 5. scripts/release.sh

Each app repo has `scripts/release.sh` that:

1. Runs the repo's check gates (build, tests, lint).
2. Reads `VERSION`, computes the build number with `date -u +%Y%m%d%H%M`, and builds the release bundle with those values.
3. Signs the bundle inside-out as above and checks it with `codesign --verify --deep --strict`.
4. Calls `tools/publish.sh --app <app> --bundle <path/App.app> --notes <notes.md>` from a checkout of this repo.

Run it with `--dry-run <dir>` first, then verify with `tools/verify-appcast.sh`.

## 6. First publish

1. Dry run and verify the result locally. Serve the dry-run directory and point a test build's `SUFeedURL` at `http://127.0.0.1:<port>/appcast.xml` if you want to see the updater work end to end.
2. Run `scripts/release.sh` for real. This creates the release `<app>-v<short>-<build>`, commits `<app>/appcast.xml` and pushes `main`.
3. Wait for GitHub Pages to deploy, then open the feed URL in a browser and confirm it loads.
4. Add the app to `index.html` in this repo if it is not listed.
5. Users on a version without Sparkle install the first Sparkle build by hand (see the README). Later releases arrive by themselves.
