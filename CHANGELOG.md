# Changelog

## 1.3.0

- Check for stable GitHub updates directly from General settings, with cancellation, clear status, and an update-and-restart action.
- Verify release ZIP digests and app identity, version, architecture, OS compatibility, and signature integrity before preparing an in-place update. Keep the previous application until the replacement confirms startup, with rollback on installation or startup failure.
- Publish application ZIPs for in-app updates alongside Apple Silicon and Intel DMGs. Clipboard history stays local; only manual update requests contact GitHub.

## 1.2.2

- Add Restart to General settings. Pending changes are saved before restarting; a failed save leaves the app running and shows the error.
- Wait for the current process to exit before relaunching the installed app and reopening settings.

## 1.2.1

- Explain a failed automatic paste with a permission alert before opening settings. The alert confirms that the content is already copied and offers a direct authorization action or a manual-paste fallback.
- Choosing Later keeps the copied content and returns to the previous app. Repeated paste attempts cannot open overlapping permission alerts.

## 1.2.0

First public release under the OtterClip name, including the completed changes from development build 1.1.8.

- Use the otter application icon in the macOS menu bar. Left-click opens settings; right-click opens the history, pause, and quit menu.
- Return copies the selected result, hides history, and attempts to paste into the previous app. Command-Return and Command-1 through Command-9 copy and dismiss.
- Refresh paste permission status automatically and show a direct settings entry when automatic paste lacks permission.
- Wait for target focus and physical shortcut modifiers before posting paste events, with clear failure states and cancellation when the clipboard changes.
- Widen the default history list to 360 points, retain native window resizing, and organize settings into General, Capture, and Privacy panes.
- Preserve existing application identity, history storage, and window preferences across the rename from ClipShelf.
- Publish the source under MIT with English and Chinese documentation and macOS CI.
