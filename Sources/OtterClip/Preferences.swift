import Foundation

struct AppPreferences: Codable {
    var historyLimit = 300
    var isPaused = false
    var captureImages = true
    var captureFiles = true
    var ignorePasswordApps = true
    var hotKeyIndex = 4
    var shortcutSchemaVersion: Int? = 2
    var excludedApps = "com.apple.ScreenSharing\ncom.apple.RemoteDesktop"

    static let passwordApps: Set<String> = [
        "com.agilebits.onepassword7", "com.1password.1password", "com.agilebits.onepassword-osx",
        "com.bitwarden.desktop", "com.lastpass.LastPass", "com.dashlane.Dashlane",
        "com.apple.keychainaccess", "com.apple.Passwords", "org.keepassxc.keepassxc"
    ]

    func excludes(_ bundleID: String?) -> Bool {
        guard let id = bundleID else { return false }
        if ignorePasswordApps && Self.passwordApps.contains(id) { return true }
        return excludedApps.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }.contains(id)
    }
}

@MainActor
final class PreferencesStore {
    private let url: URL
    var value: AppPreferences
    private(set) var lastError: Error?

    init(directory: URL) {
        url = directory.appendingPathComponent("preferences.json")
        if let data = try? Data(contentsOf: url), var saved = try? JSONDecoder().decode(AppPreferences.self, from: data) {
            let needsShortcutMigration = saved.shortcutSchemaVersion == nil
            if needsShortcutMigration {
                saved.hotKeyIndex = 4
                saved.shortcutSchemaVersion = 2
            }
            value = saved
            if needsShortcutMigration { save() }
        } else { value = AppPreferences() }
    }

    func save() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(value).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            lastError = nil
        } catch { lastError = error }
    }
}
