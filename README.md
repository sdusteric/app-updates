# app-updates

Shared Sparkle update publishing for the macOS apps (Haul, Tidy, Reel, Snap, Booth and future ones). The fixed rules are in `CONTRACT.md`. This repo holds the publishing scripts, one `appcast.xml` per app, and the vendored Sparkle 2.10.0 tools (`vendor/`, not committed). Archives live in GitHub Releases of this repo. The appcasts are served by GitHub Pages from the root of `main`.

## Feed URL

```
https://sdusteric.github.io/app-updates/<app>/appcast.xml
```

`<app>` is the lowercase app name, for example `haul`. This is the value of `SUFeedURL` in the app's Info.plist.

## Publishing

From an app repo, `scripts/release.sh` runs the checks, builds the release bundle and calls:

```
tools/publish.sh --app <app> --bundle <path/App.app> [--notes <file.md>] [--dry-run <dir>] [--port <n>] [--channel beta]
```

What it does:

1. Reads the version keys and `SUPublicEDKey` from the bundle and refuses if the key differs from the contract key, if `codesign --verify --deep --strict` fails, or if the build number is not greater than the newest item in `<app>/appcast.xml`.
2. Zips the bundle with `ditto`, signs the zip with `sign_update --account sdusteric-apps`, and adds a new item at the top of the appcast. Older items stay.
3. Creates the GitHub release `<app>-v<short>-<build>`, uploads the zip, commits the appcast and pushes `main`.

`--notes` takes a markdown file (headings, bullets, paragraphs, bold, italic, code) and renders it as simple HTML in the item description.

Dry run: `--dry-run <dir>` writes the zip and `appcast.xml` into `<dir>` with enclosure URLs of the form `http://127.0.0.1:<port>/<zip>` (default port 8765). It does nothing on the network and does not touch this repo. Serve the directory with a local HTTP server to test an app's updater against it.

Check a result with:

```
tools/verify-appcast.sh <appcast.xml> <zip>
```

It checks that the XML parses, that the newest item's length matches the zip, and that `sign_update --verify` accepts the signature. It also confirms that the Keychain key matches the public key in `CONTRACT.md`.

Run the offline test with `tests/run.sh`. It builds a dummy app and only uses dry-run mode.

## Signing key backup

The private EdDSA key is in the login Keychain under account `sdusteric-apps`. If the Mac is lost without a backup, no existing install can ever be updated. Export it once and store the file in a password manager, then delete the file:

```
vendor/Sparkle-2.10.0/bin/generate_keys --account sdusteric-apps -x <file>
```

To restore on another Mac, import it with `generate_keys --account sdusteric-apps -f <file>`. Do not commit the file or paste its contents anywhere else.

## Installing for the first time (not on Sparkle yet)

An installed version without Sparkle cannot update itself. Such a user does this once:

1. Download the latest `<Name>-<short>-<build>.zip` from the app's newest release at `https://github.com/sdusteric/app-updates/releases`.
2. Unzip it and drag the app to `/Applications`, replacing the old copy (quit the app first).
3. Open it. From then on the app checks `appcast.xml` daily and installs updates by itself.

## Adding an app

See `docs/adding-an-app.md`.
