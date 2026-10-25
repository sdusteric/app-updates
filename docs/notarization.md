# Notarization: one-time steps

The release scripts of Tidy, Reel, Snap and Booth are ready for Developer ID signing and notarization. Do these three things once. After that, `scripts/release.sh` signs with Developer ID, uses the hardened runtime, notarizes, staples and publishes, with no other change.

## 1. Create the certificate

In Xcode: Settings, Accounts, select team 8N9KUZLT8N, Manage Certificates, add "Developer ID Application". It lands in the login keychain. Check with:

```sh
security find-identity -v -p codesigning | grep "Developer ID Application"
```

`scripts/bundle.sh` then picks it by itself (team 8N9KUZLT8N). `SIGN_ID=<sha-1>` still overrides.

## 2. Store the notary credentials

Create an app-specific password at account.apple.com (Sign-In and Security), then:

```sh
xcrun notarytool store-credentials sdusteric-notary --apple-id <your apple id> --team-id 8N9KUZLT8N
```

Paste the app-specific password when asked. The profile name must be `sdusteric-notary`.

## 3. Re-approve permissions once

A permission grant is tied to the app's signing identity. The first build signed with Developer ID is a different identity from the Apple Development builds, so macOS asks again:

- Snap: Screen Recording and Microphone.
- Booth: Microphone and Camera.
- Tidy and Reel: folder access prompts (Documents, Desktop, Downloads, removable volumes).

After this, grants survive updates, because every later build uses the same Developer ID certificate.

## What the scripts do

- `bundle.sh` signs inside out with `--options runtime`: Sparkle's helpers, the framework, then the app with `resources/<App>.entitlements`. Developer ID builds use `--timestamp`; the Apple Development fallback uses `--timestamp=none`.
- `scripts/check-signing.sh` (called by `check.sh` or `release.sh`) asserts the hardened runtime flag, that the entitlements equal the checked-in file, and that every nested Mach-O has the same team.
- `release.sh` calls `tools/notarize.sh`: ditto zip, `notarytool submit --wait` (the notary log is printed on failure), `stapler staple`, `spctl` must say "Notarized Developer ID", then a new zip of the stapled app is passed to `publish.sh --zip`, so the Sparkle EdDSA signature covers the final file.
- With a Developer ID build but no profile, `release.sh` stops with a message. With the Apple Development fallback it prints a warning (the build will not open on other Macs) and goes on.
- `release.sh --dry-run <dir>` runs every step except the submit and prints the commands it would run.
