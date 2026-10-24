# Contributing to OtterClip

Bug reports, focused fixes, and interface improvements are welcome. For larger changes, open an issue first to discuss the intended behavior.

## Development

Use a modern Xcode or Apple Command Line Tools installation with the **macOS 15.4 SDK or newer** and its Swift toolchain. The app supports macOS 13+ at runtime, but its clipboard-access checks require the newer SDK to compile. Full Xcode is needed for XCTest. No third-party dependencies are required.

```bash
swift build
./scripts/test-core.sh
.build/debug/OtterClip --self-test
.build/debug/OtterClip --self-test-ui
.build/debug/OtterClip --self-test-updates
.build/debug/OtterClip --self-test-update-installer
swift test
```

Run the checks relevant to your change. If full Xcode is unavailable, run the standalone core checks and mention that XCTest was not run. For UI changes, verify the minimum window size and both narrow and wide layouts. Automatic paste and the global shortcut also need manual testing in another app with the appropriate macOS permissions.

To run a preview without monitoring your clipboard:

```bash
./scripts/build-app.sh
open build/OtterClip.app --args --demo --no-monitor --show --data-dir /tmp/otterclip-demo
```

## Pull requests and issues

- Describe the user-visible problem, resulting behavior, and checks performed.
- Keep changes focused; include screenshots for interface changes.
- Include your macOS version and CPU architecture when reporting a bug.
- Use disposable example content. Do not attach personal clipboard history, preferences, recovery backups, credentials, or unredacted screenshots.
- Keep `app.clipshelf.mac` and `Application Support/ClipShelf` compatible unless a deliberate data migration is included.

By contributing, you agree to license your contributions under the project's [MIT license](LICENSE).
