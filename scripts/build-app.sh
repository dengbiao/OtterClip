#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

ARCH="${ARCH:-$(uname -m)}"
case "$ARCH" in arm64|x86_64) ;; *) printf '%s\n' "Unsupported architecture: $ARCH" >&2; exit 1 ;; esac
swift build --configuration release --arch "$ARCH" --product OtterClip
BIN_DIR="$(swift build --configuration release --arch "$ARCH" --show-bin-path)"
APP="$PWD/build/OtterClip.app"
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
codesign --force --sign "${CODE_SIGN_IDENTITY:--}" --options runtime "$APP"
codesign --verify --deep --strict "$APP"
printf '%s\n' "Built: $APP"
