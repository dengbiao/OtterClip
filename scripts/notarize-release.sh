#!/bin/bash
# Explicit opt-in only. Credentials must already exist in a local notarytool profile.
set -euo pipefail
export LC_ALL=C
umask 077

CODESIGN=/usr/bin/codesign
SECURITY=/usr/bin/security
XCRUN=/usr/bin/xcrun
PLUTIL=/usr/bin/plutil
LIPO=/usr/bin/lipo
DITTO=/usr/bin/ditto
HDIUTIL=/usr/bin/hdiutil
SPCTL=/usr/sbin/spctl
SYSPOLICY=/usr/bin/syspolicy_check
SHASUM=/usr/bin/shasum

fail() { printf 'OtterClip notarization: %s\n' "$*" >&2; exit 1; }
usage() {
    cat <<'USAGE'
Usage: notarize-release.sh [--check-only|--dry-run|--submit] APP OUTPUT_DIRECTORY

The default is an offline, read-only preflight. Only --submit contacts Apple.
Required environment:
  CODE_SIGN_IDENTITY       Developer ID Application certificate name or SHA-1
  EXPECTED_TEAM_ID         The signing team's 10-character uppercase Team ID
  NOTARY_KEYCHAIN_PROFILE  Name of an existing notarytool credential profile
Optional environment:
  NOTARY_KEYCHAIN          Path to the keychain holding that profile
  NOTARIZE_TIMEOUT        notarytool wait timeout (default: 30m)

APP must already be signed with Developer ID, hardened runtime and a timestamp.
APP is never modified; a private copy is stapled. Use a separate output directory
for each architecture. Existing final assets or SHA256SUMS are never overwritten.
No keychains are imported, unlocked or modified, and no passwords are accepted.
USAGE
}

MODE=check
case "${1:-}" in
    --submit) MODE=submit; shift ;;
    --check-only|--dry-run) shift ;;
    --help|-h) usage; exit 0 ;;
    --*) usage >&2; fail "Unknown option: $1" ;;
esac
[[ $# == 2 ]] || { usage >&2; exit 2; }
[[ -n "${CODE_SIGN_IDENTITY:-}" && "$CODE_SIGN_IDENTITY" != - ]] || fail "Set CODE_SIGN_IDENTITY to a Developer ID Application identity; ad-hoc signing is not allowed."
[[ "${EXPECTED_TEAM_ID:-}" =~ ^[A-Z0-9]{10}$ ]] || fail "EXPECTED_TEAM_ID must contain exactly 10 uppercase letters or digits."
[[ -n "${NOTARY_KEYCHAIN_PROFILE:-}" ]] || fail "Set NOTARY_KEYCHAIN_PROFILE to an existing notarytool keychain profile."
NOTARIZE_TIMEOUT="${NOTARIZE_TIMEOUT:-30m}"
[[ "$NOTARIZE_TIMEOUT" =~ ^[1-9][0-9]*[smh]?$ ]] || fail "NOTARIZE_TIMEOUT must be a positive duration, for example 30m."
if [[ -n "${NOTARY_KEYCHAIN:-}" ]]; then
    [[ -f "$NOTARY_KEYCHAIN" ]] || fail "NOTARY_KEYCHAIN does not name an existing keychain file."
fi
for tool in "$CODESIGN" "$SECURITY" "$XCRUN" "$PLUTIL" "$LIPO" "$DITTO" "$HDIUTIL" "$SPCTL" "$SHASUM"; do
    [[ -x "$tool" ]] || fail "Required macOS tool is unavailable: $tool"
done
"$XCRUN" --find notarytool >/dev/null 2>&1 || fail "notarytool is unavailable; select a current Xcode command-line toolchain."
"$XCRUN" --find stapler >/dev/null 2>&1 || fail "stapler is unavailable; select a current Xcode command-line toolchain."

[[ -d "$1" && "${1%/}" == *.app ]] || fail "APP must be an existing .app bundle."
APP="$(cd "$1" && pwd -P)"
OUTPUT="$2"
[[ "$OUTPUT" != *$'\n'* ]] || fail "The output path must not contain a newline."
INFO="$APP/Contents/Info.plist"
read_plist() { "$PLUTIL" -extract "$2" raw -expect string -o - "$1" 2>/dev/null; }
VERSION="$(read_plist "$INFO" CFBundleShortVersionString)" || fail "The app has no valid version."
[[ "$VERSION" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] || fail "The app version must be a stable three-part version."
[[ "$(read_plist "$INFO" CFBundleIdentifier)" == app.clipshelf.mac ]] || fail "The input app has an unexpected bundle identifier."
[[ "$(read_plist "$INFO" CFBundleExecutable)" == OtterClip ]] || fail "The input app has an unexpected executable."
ARCH="$("$LIPO" -archs "$APP/Contents/MacOS/OtterClip" 2>/dev/null)" || fail "Cannot inspect the app architecture."
case "$ARCH" in arm64|x86_64) ;; *) fail "Build a separate arm64 or x86_64 app; the updater uses architecture-specific assets." ;; esac
REQUIREMENT="anchor apple generic and identifier \"app.clipshelf.mac\" and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = \"$EXPECTED_TEAM_ID\""

validate_app() {
    local candidate="$1" details actual_arch
    [[ "$(read_plist "$candidate/Contents/Info.plist" CFBundleIdentifier)" == app.clipshelf.mac &&
       "$(read_plist "$candidate/Contents/Info.plist" CFBundleShortVersionString)" == "$VERSION" &&
       "$(read_plist "$candidate/Contents/Info.plist" CFBundleExecutable)" == OtterClip ]] || fail "An app's identity or version differs from the selected release."
    [[ -x "$candidate/Contents/MacOS/OtterClip" ]] || fail "The app executable is missing or not executable."
    actual_arch="$("$LIPO" -archs "$candidate/Contents/MacOS/OtterClip" 2>/dev/null)" || fail "Cannot inspect a packaged app's architecture."
    [[ "$actual_arch" == "$ARCH" ]] || fail "An app's architecture differs from the selected release."
    "$CODESIGN" --verify --deep --strict --all-architectures -R "$REQUIREMENT" "$candidate" >/dev/null 2>&1 || fail "The app does not have a valid Developer ID signature for EXPECTED_TEAM_ID."
    details="$("$CODESIGN" --display --verbose=4 --arch "$ARCH" "$candidate" 2>&1)" || fail "Cannot read the app's signature metadata."
    printf '%s\n' "$details" | /usr/bin/grep -Fqx "TeamIdentifier=$EXPECTED_TEAM_ID" || fail "The app's Team ID is incorrect."
    printf '%s\n' "$details" | /usr/bin/grep -q '^Authority=Developer ID Application:' || fail "The app is not signed with Developer ID Application."
    printf '%s\n' "$details" | /usr/bin/grep -Eq '^CodeDirectory .*flags=.*\(.*runtime.*\)' || fail "The app's hardened runtime is disabled."
    printf '%s\n' "$details" | /usr/bin/grep -Eq '^Timestamp=.+$' || fail "The app has no secure signing timestamp."
}
validate_app "$APP"

# The identity listing contains public certificate metadata, never private keys.
IDENTITIES="$("$SECURITY" find-identity -v -p codesigning 2>/dev/null)" || fail "Cannot inspect available code-signing identities."
if [[ "$CODE_SIGN_IDENTITY" =~ ^[a-fA-F0-9]{40}$ ]]; then
    MATCH="$(printf '%s\n' "$IDENTITIES" | /usr/bin/awk -v wanted="$CODE_SIGN_IDENTITY" 'toupper($2) == toupper(wanted) { print }')"
else
    MATCH="$(printf '%s\n' "$IDENTITIES" | /usr/bin/awk -F '\"' -v wanted="$CODE_SIGN_IDENTITY" '$2 == wanted { print }')"
fi
[[ "$(printf '%s\n' "$MATCH" | /usr/bin/grep -c 'Developer ID Application:' || true)" == 1 ]] || fail "CODE_SIGN_IDENTITY does not select exactly one valid local Developer ID Application identity."
printf '%s\n' "$MATCH" | /usr/bin/grep -Fq "($EXPECTED_TEAM_ID)" || fail "CODE_SIGN_IDENTITY belongs to a different team."
unset IDENTITIES MATCH

if [[ "$MODE" == check ]]; then
    printf 'Offline preflight passed: OtterClip %s (%s), Developer ID, runtime and timestamp verified.\n' "$VERSION" "$ARCH"
    printf '%s\n' 'No app or output files were changed. The notary profile has not been authenticated with Apple; use --submit to authenticate and notarize.'
    exit 0
fi

# Resolve the nearest existing ancestor before creating directories, including
# symlinked ancestors. A destination inside APP must not modify APP even on failure.
OUTPUT_PARENT="$OUTPUT"
OUTPUT_SUFFIX=
while [[ ! -d "$OUTPUT_PARENT" ]]; do
    [[ ! -e "$OUTPUT_PARENT" && ! -L "$OUTPUT_PARENT" ]] || fail "The output path contains a non-directory."
    OUTPUT_COMPONENT="$(basename "$OUTPUT_PARENT")"
    case "$OUTPUT_COMPONENT" in ''|.|..) fail "The output path cannot be resolved safely." ;; esac
    OUTPUT_SUFFIX="/$OUTPUT_COMPONENT$OUTPUT_SUFFIX"
    OUTPUT_PARENT="$(dirname "$OUTPUT_PARENT")"
done
OUTPUT="$(cd "$OUTPUT_PARENT" && pwd -P)$OUTPUT_SUFFIX"
case "$OUTPUT/" in "$APP/"*) fail "The output directory must be outside the input app." ;; esac
mkdir -p "$OUTPUT"
BASE="OtterClip-$VERSION-$ARCH"
for name in "$BASE.zip" "$BASE.dmg" SHA256SUMS; do
    [[ ! -e "$OUTPUT/$name" && ! -L "$OUTPUT/$name" ]] || fail "Refusing to overwrite an existing final artifact: $name"
done
PRIVATE="$OUTPUT/private/notarization"
[[ ! -L "$OUTPUT/private" && ! -L "$PRIVATE" ]] || fail "Private diagnostics directories must not be symbolic links."
mkdir -p "$PRIVATE"
chmod 700 "$OUTPUT/private" "$PRIVATE"
LOGDIR="$(mktemp -d "$PRIVATE/run.XXXXXX")"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/OtterClip-notarize.XXXXXX")"
MOUNTED=0
cleanup() {
    local result=$?
    trap - EXIT
    if [[ "$MOUNTED" == 1 ]]; then "$HDIUTIL" detach "$WORK/mount" >>"$LOGDIR/validation.log" 2>&1 || true; fi
    rm -rf "$WORK"
    if [[ "$result" != 0 ]]; then printf 'Release stopped; no new SHA256SUMS was published. Private diagnostics: %s\n' "$LOGDIR" >&2; fi
    exit "$result"
}
trap cleanup EXIT
AUTH=(--keychain-profile "$NOTARY_KEYCHAIN_PROFILE")
if [[ -n "${NOTARY_KEYCHAIN:-}" ]]; then AUTH+=(--keychain "$NOTARY_KEYCHAIN"); fi

notarize() {
    local archive="$1" label="$2" summary identifier status log issue_type count index severity warnings=0 submit_result=0
    summary="$LOGDIR/$label-submit.json"
    log="$LOGDIR/$label-apple-log.json"
    printf 'Submitting %s to Apple; waiting up to %s.\n' "$label" "$NOTARIZE_TIMEOUT"
    "$XCRUN" notarytool submit "$archive" "${AUTH[@]}" --wait --timeout "$NOTARIZE_TIMEOUT" --output-format json >"$summary" 2>"$LOGDIR/$label-submit.stderr" || submit_result=$?
    identifier="$(read_plist "$summary" id)" || fail "Apple did not return a submission ID. Check the private diagnostics; confirm the notary keychain profile is available and authorized."
    [[ "$identifier" =~ ^[a-fA-F0-9]{8}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{12}$ ]] || fail "Apple returned an invalid submission ID."
    status="$(read_plist "$summary" status)" || status=Unknown
    "$XCRUN" notarytool log "$identifier" "${AUTH[@]}" "$log" >"$LOGDIR/$label-log.stdout" 2>"$LOGDIR/$label-log.stderr" || fail "Could not obtain Apple's notarization log for $label."
    chmod 600 "$LOGDIR"/*
    [[ "$submit_result" == 0 && "$status" == Accepted && "$(read_plist "$log" status)" == Accepted ]] || fail "Apple did not accept $label (status: $status). Review the private Apple log."
    [[ "$(read_plist "$log" jobId)" == "$identifier" ]] || fail "Apple's log does not match the submission ID."
    issue_type="$("$PLUTIL" -type issues "$log" 2>/dev/null)" || fail "Apple's log is missing its issues field."
    case "$issue_type" in
        '(any)'|null) ;; # plutil represents JSON null as '(any)'.
        array)
            count="$("$PLUTIL" -extract issues raw -expect array -o - "$log" 2>/dev/null)" || fail "Cannot read Apple's log issues."
            [[ "$count" =~ ^[0-9]+$ ]] || fail "Apple's log has an invalid issues array."
            for ((index=0; index<count; index++)); do
                severity="$(read_plist "$log" "issues.$index.severity")" || fail "Apple's log contains an issue without severity."
                case "$severity" in
                    warning) warnings=$((warnings + 1)) ;;
                    *) fail "Apple's log contains a non-warning issue for $label; review private diagnostics." ;;
                esac
            done ;;
        *) fail "Apple's log has an unexpected issues type." ;;
    esac
    printf 'Apple accepted %s (%s); warnings: %s.\n' "$label" "$identifier" "$warnings"
}

gatekeeper_app() {
    local candidate="$1"
    "$XCRUN" stapler validate "$candidate" >>"$LOGDIR/validation.log" 2>&1 || fail "A packaged app has no valid stapled ticket."
    validate_app "$candidate"
    if [[ -x "$SYSPOLICY" ]]; then
        "$SYSPOLICY" distribution "$candidate" >>"$LOGDIR/validation.log" 2>&1 || fail "The app failed Gatekeeper distribution checks."
    else
        "$SPCTL" --assess --type execute --verbose=4 "$candidate" >>"$LOGDIR/validation.log" 2>&1 || fail "The app failed Gatekeeper assessment."
    fi
}

"$DITTO" "$APP" "$WORK/OtterClip.app"
validate_app "$WORK/OtterClip.app"
"$DITTO" --norsrc --noextattr -c -k --keepParent "$WORK/OtterClip.app" "$WORK/submission.zip"
notarize "$WORK/submission.zip" app
"$XCRUN" stapler staple "$WORK/OtterClip.app" >>"$LOGDIR/validation.log" 2>&1 || fail "Could not staple the app's notarization ticket."
gatekeeper_app "$WORK/OtterClip.app"

# A ZIP cannot itself be stapled. Regenerate it after stapling the enclosed app.
"$DITTO" --norsrc --noextattr -c -k --keepParent "$WORK/OtterClip.app" "$WORK/$BASE.zip"
mkdir "$WORK/unpacked"
"$DITTO" -x -k "$WORK/$BASE.zip" "$WORK/unpacked"
gatekeeper_app "$WORK/unpacked/OtterClip.app"

mkdir "$WORK/disk"
"$DITTO" "$WORK/OtterClip.app" "$WORK/disk/OtterClip.app"
ln -s /Applications "$WORK/disk/Applications"
"$HDIUTIL" create -volname OtterClip -srcfolder "$WORK/disk" -format UDZO -ov "$WORK/$BASE.dmg" >>"$LOGDIR/validation.log" 2>&1
"$CODESIGN" --force --sign "$CODE_SIGN_IDENTITY" --timestamp --identifier app.clipshelf.mac.dmg "$WORK/$BASE.dmg" >>"$LOGDIR/validation.log" 2>&1 || fail "Could not sign the disk image with Developer ID."
DMG_REQUIREMENT="anchor apple generic and identifier \"app.clipshelf.mac.dmg\" and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = \"$EXPECTED_TEAM_ID\""
"$CODESIGN" --verify --strict -R "$DMG_REQUIREMENT" "$WORK/$BASE.dmg" >>"$LOGDIR/validation.log" 2>&1 || fail "The disk image's signature is invalid."
notarize "$WORK/$BASE.dmg" dmg
"$XCRUN" stapler staple "$WORK/$BASE.dmg" >>"$LOGDIR/validation.log" 2>&1 || fail "Could not staple the disk image's ticket."
"$XCRUN" stapler validate "$WORK/$BASE.dmg" >>"$LOGDIR/validation.log" 2>&1 || fail "The disk image's stapled ticket is invalid."
"$CODESIGN" --verify --strict -R "$DMG_REQUIREMENT" "$WORK/$BASE.dmg" >>"$LOGDIR/validation.log" 2>&1 || fail "The stapled disk image's signature is invalid."
"$HDIUTIL" verify "$WORK/$BASE.dmg" >>"$LOGDIR/validation.log" 2>&1 || fail "The disk image is corrupt."
"$SPCTL" --assess --type open --verbose=4 --context context:primary-signature "$WORK/$BASE.dmg" >>"$LOGDIR/validation.log" 2>&1 || fail "The disk image failed Gatekeeper assessment."
mkdir "$WORK/mount"
MOUNTED=1
"$HDIUTIL" attach -readonly -nobrowse -mountpoint "$WORK/mount" "$WORK/$BASE.dmg" >>"$LOGDIR/validation.log" 2>&1
gatekeeper_app "$WORK/mount/OtterClip.app"
"$HDIUTIL" detach "$WORK/mount" >>"$LOGDIR/validation.log" 2>&1 || fail "Could not detach the verification disk image."
MOUNTED=0

(
    cd "$WORK"
    "$SHASUM" -a 256 "$BASE.dmg" "$BASE.zip" > SHA256SUMS
)
chmod 644 "$WORK/$BASE.zip" "$WORK/$BASE.dmg" "$WORK/SHA256SUMS"
mv "$WORK/$BASE.zip" "$OUTPUT/$BASE.zip"
mv "$WORK/$BASE.dmg" "$OUTPUT/$BASE.dmg"
# This is the last publication step, after all signatures, tickets and containers pass.
mv "$WORK/SHA256SUMS" "$OUTPUT/SHA256SUMS"
chmod 600 "$LOGDIR"/*
printf 'Signed and notarized release ready: %s\nPrivate Apple logs: %s\n' "$OUTPUT" "$LOGDIR"
