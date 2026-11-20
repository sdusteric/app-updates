# app-updates

Shared Sparkle update publishing for the macOS apps (Haul, Tidy, Reel, Snap, Booth and future ones). The folder `kalos-safety-bench/` is separate: the public copy of the Kalos agent safety bench (its README says what it is), made in the Kalos repo with `main.py pack`. The fixed rules are in `CONTRACT.md`. This repo holds the publishing scripts, one `appcast.xml` per app, and the vendored Sparkle 2.10.0 tools (`vendor/`, not committed). Archives live in GitHub Releases of this repo. The appcasts are served by GitHub Pages from the root of `main`.

## Feed URL

```
https://sdusteric.github.io/app-updates/<app>/appcast.xml
```

`<app>` is the lowercase app name, for example `haul`. This is the value of `SUFeedURL` in the app's Info.plist.

## Publishing

From an app repo, `scripts/release.sh` runs the checks, builds the release bundle and calls:

```
tools/publish.sh --app <app> --bundle <path/App.app> [--notes <file.md>] [--dry-run <dir>] [--port <n>] [--channel beta] [--prefix <name>]
```

What it does:

1. Reads the version keys and `SUPublicEDKey` from the bundle and refuses if the key differs from the contract key, if `codesign --verify --deep --strict` fails, or if the build number is not greater than the newest item in `<app>/appcast.xml`.
2. Zips the bundle with `ditto`, signs the zip with `sign_update --account sdusteric-apps`, and adds a new item at the top of the appcast. Older items stay.
3. Makes the disk image for first installs with `tools/make-dmg.sh`: the app plus an Applications link, signed with the app's Developer ID certificate, notarized and stapled. This is a second notary submission, a few minutes more. A bundle not signed with Developer ID gets no disk image. Unless the release is `--channel beta`, it also writes `<app>/download/index.html`, which sends people to the newest disk image.
4. Creates the GitHub release `<app>-v<short>-<build>`, uploads the zip and the disk image, commits the appcast and the download page and pushes `main`.

Apps on R2 (the table at the top of `publish.sh`; today only `kalos`, bucket `kalos-updates`) skip step 4 and the download page. Instead publish.sh fetches the current appcast from the bucket with `pnpm dlx wrangler r2 object get ... --remote` (a missing one means a first release; any other error stops the publish), then uploads the zip, the disk image and the appcast last with `wrangler r2 object put ... --remote`. Enclosure URLs start with `KALOS_UPDATES_BASE` (default `https://updates.kalosbrowser.com`). `--prefix <name>` publishes to `<bucket>/<name>/` instead of `<bucket>/<app>/`, for an end-to-end test that leaves the real feed alone. It needs `pnpm dlx wrangler login` once.

`--notes` takes a markdown file (headings, bullets, paragraphs, bold, italic, code) and renders it as simple HTML in the item description.

Dry run: `--dry-run <dir>` writes the zip, the disk image (not signed or notarized), `download/index.html` and `appcast.xml` into `<dir>` with URLs of the form `http://127.0.0.1:<port>/<zip>` (default port 8765); an R2 app keeps its real R2 addresses and gets no download page. It does nothing on the network and does not touch this repo. Serve the directory with a local HTTP server to test an app's updater against it.

Check a result with:

```
tools/verify-appcast.sh <appcast.xml> <zip>
```

It checks that the XML parses, that the newest item's length matches the zip, and that `sign_update --verify` accepts the signature. It also confirms that the Keychain key matches the public key in `CONTRACT.md`.

Run the offline test with `tests/run.sh`. It builds a dummy app and uses dry-run mode, plus R2 publishes against a fake `wrangler` that keeps the bucket in a temp folder.

## Signing key backup

The private EdDSA key is in the login Keychain under account `sdusteric-apps`. If the Mac is lost without a backup, no existing install can ever be updated. Export it once and store the file in a password manager, then delete the file:

```
vendor/Sparkle-2.10.0/bin/generate_keys --account sdusteric-apps -x <file>
```

To restore on another Mac, import it with `generate_keys --account sdusteric-apps -f <file>`. Do not commit the file or paste its contents anywhere else.

## Installing for the first time

New users, and anyone on a version without Sparkle, do this once:

1. Open `https://sdusteric.github.io/app-updates/<app>/download/`. It downloads the newest `<Name>-<short>-<build>.dmg`. Releases from before the disk image have only the zip at `https://github.com/sdusteric/app-updates/releases`.
2. Open the disk image and drag the app to Applications, replacing the old copy (quit the app first). An app opened straight from Downloads may not be able to update itself.
3. Open it. From then on the app checks `appcast.xml` daily and installs updates by itself.

## Adding an app

See `docs/adding-an-app.md`.
