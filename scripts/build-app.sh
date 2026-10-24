#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

ARCH="${ARCH:-$(uname -m)}"
case "$ARCH" in arm64|x86_64) ;; *) printf '%s\n' "Unsupported architecture: $ARCH" >&2; exit 1 ;; esac
SIGNING_MODE="${RELEASE_SIGNING:-development}"
SIGN_IDENTITY="${CODE_SIGN_IDENTITY:--}"
SIGN_TEAM="${EXPECTED_TEAM_ID:-}"
if [[ "$SIGN_IDENTITY" =~ ^[A-Fa-f0-9]{40}$ ]]; then
  SIGN_IDENTITY="$(printf '%s' "$SIGN_IDENTITY" | tr '[:lower:]' '[:upper:]')"
fi
case "$SIGNING_MODE" in development|formal) ;; *) printf '%s\n' 'RELEASE_SIGNING must be development or formal.' >&2; exit 1 ;; esac
if [[ "$SIGNING_MODE" == formal ]]; then
  if [[ "$SIGN_IDENTITY" == - || ! "$SIGN_TEAM" =~ ^[A-Z0-9]{10}$ ]]; then
    printf '%s\n' 'Formal signing requires CODE_SIGN_IDENTITY and a ten-character EXPECTED_TEAM_ID.' >&2
    exit 1
  fi
  identities="$(security find-identity -v -p codesigning)"
  identity_pattern='^[[:space:]]*[0-9]+\)[[:space:]]+([0-9A-Fa-f]{40})[[:space:]]+"(Developer ID Application:.* \(([A-Z0-9]{10})\))"'
  matches=0
  selected_identity=''
  while IFS= read -r line; do
    if [[ "$line" =~ $identity_pattern ]]; then
      hash="${BASH_REMATCH[1]}"
      name="${BASH_REMATCH[2]}"
      team="${BASH_REMATCH[3]}"
      if [[ ( "$SIGN_IDENTITY" == "$hash" || "$SIGN_IDENTITY" == "$name" ) && "$SIGN_TEAM" == "$team" ]]; then
        selected_identity="$hash"
        matches=$((matches + 1))
      fi
    fi
  done <<< "$identities"
  if [[ "$matches" != 1 ]]; then
    printf '%s\n' 'No unique valid Developer ID Application identity matches CODE_SIGN_IDENTITY and EXPECTED_TEAM_ID in the keychain search list.' >&2
    exit 1
  fi
  SIGN_IDENTITY="$selected_identity"
fi
swift build --configuration release --arch "$ARCH" --product OtterClip
BIN_DIR="$(swift build --configuration release --arch "$ARCH" --show-bin-path)"
APP="$PWD/build/OtterClip.app"
# A prior release may contain a stapled ticket or stale signed resources.
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/OtterClip" "$APP/Contents/MacOS/OtterClip"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <!-- Preserve the app identity across the OtterClip rename. -->
  <key>CFBundleIdentifier</key><string>app.clipshelf.mac</string>
  <key>CFBundleName</key><string>OtterClip</string>
  <key>CFBundleDisplayName</key><string>OtterClip</string>
  <key>CFBundleExecutable</key><string>OtterClip</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.3.0</string>
  <key>CFBundleVersion</key><string>14</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSHumanReadableCopyright</key><string>OtterClip · Local clipboard history</string>
</dict></plist>
PLIST
swift scripts/make-icon.swift "$PWD/build/AppIcon.iconset"
iconutil -c icns "$PWD/build/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"
if [[ "$SIGNING_MODE" == formal ]]; then
  codesign --force --sign "$SIGN_IDENTITY" --options runtime --timestamp "$APP"
  requirement="anchor apple generic and identifier \"app.clipshelf.mac\" and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = \"$SIGN_TEAM\""
  codesign --verify --deep --strict -R "$requirement" "$APP"
else
  codesign --force --sign "$SIGN_IDENTITY" --options runtime "$APP"
fi
codesign --verify --deep --strict "$APP"
printf '%s\n' "Built: $APP"
