# Developer ID signing and Apple notarization

The public 1.3.0 release uses an ad-hoc signature and has not been notarized. The formal pipeline below requires an authorized Apple Developer identity. It never falls back to an ad-hoc signature when a certificate, credential profile, Apple acceptance, or distribution check is missing.

## Prerequisites

Use a valid **Developer ID Application** certificate and its private key belonging to the developer or organization authorized to publish OtterClip. The existing app identity remains `app.clipshelf.mac`, so history and preferences keep their existing locations. An installer certificate is not needed for the DMG/ZIP format.

Check available public identity metadata:

```sh
security find-identity -v -p codesigning
```

Configure a notarytool credential profile in Keychain with your own account. Omit the password argument so notarytool prompts for the app-specific password instead of putting it in shell history:

```sh
xcrun notarytool store-credentials OtterClip-notary \
  --apple-id YOUR_APPLE_ID \
  --team-id YOURTEAMID
```

A CI runner can provide a preconfigured keychain and profile through its protected secret mechanism. Only use credentials approved for this project. Do not copy another application's project token, certificate, private key, or notarization account into this repository or release assets. The scripts do not import, unlock, or modify keychains.

## Build and notarize

Select the exact certificate name or SHA-1 fingerprint shown by `security find-identity`. Replace the example values with your authorized identity:

```sh
export RELEASE_SIGNING=formal
export CODE_SIGN_IDENTITY='Developer ID Application: Your Name (YOURTEAMID)'
export EXPECTED_TEAM_ID=YOURTEAMID
export NOTARY_KEYCHAIN_PROFILE=OtterClip-notary

ARCH=arm64 ./scripts/package-release.sh "$PWD/dist/formal/arm64"
ARCH=x86_64 ./scripts/package-release.sh "$PWD/dist/formal/x86_64"
```

Use fresh, separate output directories and run architecture builds sequentially. `NOTARY_KEYCHAIN` optionally selects the keychain containing the profile. `NOTARIZE_TIMEOUT` defaults to `30m` per Apple submission.

The formal pipeline:

1. Builds a clean app, signs with Developer ID, Hardened Runtime and a secure timestamp, and verifies the expected team and application identity.
2. Submits an app ZIP to Apple and requires `Accepted`. It downloads the matching Apple log and rejects non-warning issues.
3. Staples the app's ticket and validates it. Recreates the updater ZIP and verifies the app extracted from that final ZIP.
4. Creates and signs the DMG, submits it to Apple, staples it, and validates the mounted app and Gatekeeper assessment.
5. Writes final ZIP, DMG and `SHA256SUMS` only after distribution checks succeed. The original input app is not modified by the notarization script.

Private Apple diagnostics are saved under each output directory's `private/notarization/run.*`, with private filesystem permissions. Publish only the four final DMG/ZIP assets and the combined checksum file, never private diagnostics. Combine checksums after both architectures succeed:

```sh
cat dist/formal/arm64/SHA256SUMS dist/formal/x86_64/SHA256SUMS \
  > dist/formal/SHA256SUMS
```

Keep the existing `OtterClip-VERSION-arm64.zip` / `OtterClip-VERSION-x86_64.zip` names and matching `vVERSION` release tag for the updater. Increment the application version before publishing a new release. Do not rebuild or re-sign an artifact after notarization.

## Offline preflight and tests

For an already Developer ID-signed app, this command performs local checks without changing the input or contacting Apple:

```sh
./scripts/notarize-release.sh --check-only build/OtterClip.app dist/formal/check
```

The profile is authenticated only when submission starts. Direct submission requires `--submit`; the formal packaging command supplies that flag:

```sh
./scripts/notarize-release.sh --submit build/OtterClip.app dist/formal/arm64
```

These tests use mocked signing/notary tools or temporary ad-hoc fixture apps. They do not use a real signing identity or submit to Apple:

```sh
./scripts/test-signing-preflight.sh
./scripts/test-notarize-release.sh
.build/debug/OtterClip --self-test-update-installer
```

A development-signed installation can migrate to its first Developer ID release. Once OtterClip runs with a valid Developer ID identity, future updates must retain the same Apple Developer team, bundle identifier, and valid Developer ID Application certificate chain. Changing publisher team requires a deliberate migration. macOS may require renewed Accessibility permission when moving from ad-hoc to Developer ID signing.

Apple references: [Customizing the notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow), [Packaging Mac software for distribution](https://developer.apple.com/documentation/xcode/packaging-mac-software-for-distribution), and [Inside Code Signing: Requirements](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements).
