# Update contract (shared by every app)

- Framework: Sparkle 2.10.0. Swift apps use the Swift package `https://github.com/sparkle-project/Sparkle` at exact 2.10.0. Rust apps embed `vendor/Sparkle-2.10.0/Sparkle.framework` from this repo (sha256-verified tarball).
- Signing key: EdDSA, stored in the login Keychain under account `sdusteric-apps`. Public key for Info.plist `SUPublicEDKey`: `PMaW+8sZRzOkfIwy1KBGk0CHTVoN49FE9o8gUlNGdZc=`.
- Feed URL for app `<app>` (lowercase): `https://sdusteric.github.io/app-updates/<app>/appcast.xml` (GitHub Pages from the main branch root of the public repo sdusteric/app-updates).
- Archives: GitHub Release `<app>-v<short>-<build>` in sdusteric/app-updates, one asset `<Name>-<short>-<build>.zip` made with `ditto -c -k --sequesterRsrc --keepParent`.
- Versions: `CFBundleShortVersionString` from the repo's VERSION file (semver). `CFBundleVersion` is the UTC build time `YYYYMMDDHHMM`, always increasing.
- Info.plist keys: `SUFeedURL`, `SUPublicEDKey`, `SUEnableAutomaticChecks` true, `SUAutomaticallyUpdate` true, `SUScheduledCheckInterval` 86400.
- In app: a "Check for Updates…" menu item and a settings toggle for automatic updates. The updater never starts in shot mode, tests, CLIs or when the env var `<APP>_NO_UPDATES=1` is set.
- Publishing: `tools/publish.sh --app <app> --bundle <path/App.app> [--notes <file.md>] [--dry-run <dir>]`. Each app repo has `scripts/release.sh` that runs its check gates, builds the release bundle and calls publish.sh.
