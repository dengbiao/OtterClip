#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
DESTINATION="${1:-$PWD/dist}"
mkdir -p "$DESTINATION"
DESTINATION="$(cd "$DESTINATION" && pwd)"
ARCH="${ARCH:-$(uname -m)}"
export ARCH
if [[ "${RELEASE_SIGNING:-development}" == formal && -z "${NOTARY_KEYCHAIN_PROFILE:-}" ]]; then
  printf '%s\n' 'Formal release requires NOTARY_KEYCHAIN_PROFILE. No development-signed fallback is allowed.' >&2
  exit 1
fi
./scripts/build-app.sh
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' build/OtterClip.app/Contents/Info.plist)"
STAGING="$(mktemp -d "${TMPDIR:-/tmp}/OtterClip-release.XXXXXX")"
trap 'rm -rf "$STAGING"' EXIT

if [[ "${RELEASE_SIGNING:-development}" == formal ]]; then
  ./scripts/notarize-release.sh --submit build/OtterClip.app "$DESTINATION"
else
  rm -rf "$DESTINATION/OtterClip.app"
  ditto build/OtterClip.app "$DESTINATION/OtterClip.app"
  mkdir -p "$STAGING/disk"
  ditto build/OtterClip.app "$STAGING/disk/OtterClip.app"
  ln -s /Applications "$STAGING/disk/Applications"
  hdiutil create -volname OtterClip -srcfolder "$STAGING/disk" -format UDZO -ov "$DESTINATION/OtterClip-$VERSION-$ARCH.dmg"
  # This development-signed archive is consumed by the in-app GitHub updater.
  ditto --norsrc --noextattr -c -k --keepParent build/OtterClip.app "$DESTINATION/OtterClip-$VERSION-$ARCH.zip"
  (
    cd "$DESTINATION"
    shasum -a256 "OtterClip-$VERSION-$ARCH.dmg" "OtterClip-$VERSION-$ARCH.zip" > SHA256SUMS
  )
fi

# Package only reviewed project paths; never include local data, Git state, or build caches.
SOURCE_ROOT="$STAGING/source/OtterClip"
mkdir -p "$SOURCE_ROOT"
cp Package.swift README.md .gitignore "$SOURCE_ROOT/"
cp -R Sources Tests scripts Assets "$SOURCE_ROOT/"
if [[ -d docs ]]; then cp -R docs "$SOURCE_ROOT/"; fi
for file in LICENSE README.zh-CN.md CONTRIBUTING.md CHANGELOG.md; do
  if [[ -f "$file" ]]; then cp "$file" "$SOURCE_ROOT/"; fi
done
if [[ -d .github ]]; then cp -R .github "$SOURCE_ROOT/"; fi
ditto --norsrc --noextattr -c -k --keepParent "$SOURCE_ROOT" "$DESTINATION/OtterClip-source.zip"
printf '%s\n' "Release files: $DESTINATION"
