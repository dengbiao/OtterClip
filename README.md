# OtterClip

<img src="Assets/AppIcon.png" width="128" alt="OtterClip's otter holding two notes">

A small, native macOS clipboard history app. Keep copied text, images, and files close at hand, then find them with **⌥⌘C**. Runs independently of Alfred.

[简体中文](README.zh-CN.md) · [Download](https://github.com/dengbiao/OtterClip/releases/latest) · [Contributing](CONTRIBUTING.md)

![OtterClip clipboard history](Assets/preview.png)

## Install

Requires **macOS 13 or later**. Download the `OtterClip-1.3.0-arm64.dmg` (Apple Silicon) or `OtterClip-1.3.0-x86_64.dmg` (Intel) from [Releases](https://github.com/dengbiao/OtterClip/releases), open it, and drag **OtterClip** into Applications.

The current release uses an **ad-hoc signature**, without Developer ID notarization. macOS may require you to allow it in **System Settings → Privacy & Security → Open Anyway**. Keep the application in a fixed location before granting permissions. Rebuilding or changing its signature may require granting Accessibility permission again.

1. Open OtterClip. Its otter icon appears in the menu bar, and future copies are added to history. Left-click the icon to open settings; right-click it for the menu, including pause and quit.
2. Press **Option + Command + C** to open the window; type to search and use the arrow keys to select a result.
3. Press **⌘1–⌘9** or **⌘Return** to copy and dismiss. Press **Return** to copy, dismiss, and paste into the previous app.
4. Automatic paste needs Accessibility permission. If it is missing, a dialog confirms that the item is already copied: choose **前往授权** to open macOS Accessibility settings, or **稍后** to return to your app and paste manually with **⌘V**. You can also grant access from settings → **隐私** (Privacy).

To restart, open settings → **通用** (General) → **重新启动**. Pending settings are saved before the app restarts.

For future versions, use settings → **通用** → **检查更新** (Check for Updates). OtterClip checks the latest stable GitHub release for your architecture. Choose **更新并重启** to download, verify, install, and relaunch in place. Settings are saved before installation; history stays in its existing directory. Run the app from a writable Applications folder, rather than the DMG.

The previous app is kept until the replacement confirms startup. Installation or startup failure triggers recovery; if a replacement process cannot safely be stopped, its backup is retained in the adjacent hidden `.OtterClip-update-*` directory for recovery.

The interface is currently in Simplified Chinese. If macOS requests clipboard access, allow it as appropriate for your use.

## Features

- Text, image, and file/folder history with content previews.
- Search content, file paths, and source app names; filter by type or favorites.
- Deduplicate copies and pin favorites, which stay above other history and survive routine cleanup.
- Resize the window and drag the divider to adjust the list/preview balance; the window size is remembered.
- Choose a global shortcut, history capacity, image/file capture, excluded apps, and launch at login.
- Pause capture from the menu bar; skip recognized password managers and sensitive pasteboard markers.
- Local storage with atomic writes, image deduplication, unused-image cleanup, and recovery backups for damaged history.

| Shortcut | Action |
| --- | --- |
| ⌥⌘C | Open / dismiss history (configurable) |
| ↑ / ↓ | Select previous / next result |
| Return | Copy, dismiss, and attempt to paste into the previous app |
| ⌘Return | Copy and dismiss |
| ⌘1 … ⌘9 | Copy that numbered search result and dismiss |
| ⌘P | Toggle favorite |
| ⌘Delete | Delete selected history item |
| Esc | Dismiss and return to the previous app |

Arrow keys, Return, and Esc remain available to an input method while composing text.

## Privacy and limits

**No cloud sync or telemetry. Clipboard history is stored locally in plain form, without additional encryption.** Only manually checking or downloading an update contacts GitHub; clipboard content and history are never included in update requests. The data directory has mode `0700`; data files use `0600`. These file permissions do not replace encryption.

Data lives in `~/Library/Application Support/ClipShelf/`:

- `history.json`: text and metadata.
- `Images/`: saved images.
- `preferences.json`: settings.

Open the data folder from settings. Clearing non-favorites preserves favorites and the current system clipboard. Deletion cannot be undone. To remove all local data, quit the app and delete this directory. Recovery backups are not automatically removed.

By default, OtterClip retains 300 non-favorite items; choose 100, 300, 500, or 1,000 in settings. Favorites do not count toward that limit. Storage budgets are about 16 MiB for text/path metadata and 100 MiB for images, prioritizing favorites. Items over these capture limits are skipped: 2 MiB per text entry, 12 MiB / 40 megapixels per saved image (20 MiB raw input), and 1,000 paths per file list. File history stores paths, so the original files must remain available. Text is plain text; rich formatting, audio, video, and other custom clipboard formats are not retained.

Sensitive-marker filtering and app exclusions cover recognized cases, not every password or secret. Pause capture before copying sensitive content when needed. The source app is inferred from the foreground app at capture time and can be inaccurate after a quick app switch. Capture polls every 0.5 seconds; multiple copies within that interval may retain only the last one.

Automatic paste requires the target app to be running, focus to return successfully, and Accessibility/event-posting access. Some apps may reject simulated **⌘V**; the item remains on the clipboard for manual paste. Login launch is managed by macOS ServiceManagement and may need approval in System Settings.

## Upgrading from ClipShelf

**OtterClip 1.2.0** is the first release under the new name. It retains the bundle identifier `app.clipshelf.mac` and the `Application Support/ClipShelf` directory for compatibility with existing history and preferences. Quit ClipShelf first, move OtterClip into Applications, and remove the old ClipShelf app. Both share the same bundle identifier, so avoid running or keeping duplicate installed copies. macOS may require renewed permission after the app name, location, or signature changes; previous permission grants are not guaranteed to carry over.

## Build from source

Requires a modern Xcode or Apple Command Line Tools installation that includes the **macOS 15.4 SDK or newer** and its Swift toolchain. The app's minimum runtime remains **macOS 13**; the newer SDK is required to compile its clipboard-access checks. There are no third-party library dependencies. Build natively on Apple Silicon or Intel:

```bash
git clone https://github.com/dengbiao/OtterClip.git
cd OtterClip
./scripts/build-app.sh
open build/OtterClip.app
```

The default signature is ad-hoc. To use your Developer ID identity:

```bash
CODE_SIGN_IDENTITY='Developer ID Application: Your Name (TEAMID)' ./scripts/build-app.sh
```

Setting a signing identity does not perform notarization. To create the application, DMG, and source archive in `dist/`:

```bash
./scripts/package-release.sh
```

The script also creates an architecture-specific application ZIP and `SHA256SUMS`. Publish that ZIP alongside the DMG in a stable GitHub release tagged `vX.Y.Z`; the app version must match the tag. The updater verifies GitHub's SHA-256 asset digest, bundle identity, version, architecture, OS compatibility, and code-signature integrity before installation. Releases currently use ad-hoc signing, so this is not Developer ID publisher verification.

To build release assets for both architectures, run the packaging script separately with `ARCH=arm64` and `ARCH=x86_64`, using separate output directories.

Preview with isolated demo data and no background capture:

```bash
open build/OtterClip.app --args --demo --no-monitor --show --data-dir /tmp/otterclip-demo
```

## Test

```bash
./scripts/test-core.sh
swift build
.build/debug/OtterClip --self-test
.build/debug/OtterClip --self-test-ui
.build/debug/OtterClip --self-test-updates
.build/debug/OtterClip --self-test-update-installer
```

The standalone core checks run with Command Line Tools. Platform checks use a private named pasteboard and temporary data. UI checks exercise the app's own AppKit views and private pasteboards; they do not read/write the system clipboard or send keyboard/mouse events to other apps. These checks do not replace manual testing of cross-app hotkeys and paste with permissions granted.

XCTest is also available with a **full Xcode installation**:

```bash
swift test
```

The macOS CI workflow builds and runs the core, XCTest, platform, native UI, and update checks. Update fixtures use private network responses and temporary app bundles, without changing the installed application.

## License and artwork

[MIT](LICENSE) © 2026 dengbiao. The otter icon was generated using Codex's built-in image generation tool; its [generation prompt](Assets/AppIcon.prompt.txt) is included.
