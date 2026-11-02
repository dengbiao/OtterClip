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
    var showMenuBarIcon = true

    private enum CodingKeys: String, CodingKey {
        case historyLimit, isPaused, captureImages, captureFiles, ignorePasswordApps
        case hotKeyIndex, shortcutSchemaVersion, excludedApps, showMenuBarIcon
    }

    init() {}

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        historyLimit = try values.decode(Int.self, forKey: .historyLimit)
        isPaused = try values.decode(Bool.self, forKey: .isPaused)
        captureImages = try values.decode(Bool.self, forKey: .captureImages)
        captureFiles = try values.decode(Bool.self, forKey: .captureFiles)
        ignorePasswordApps = try values.decode(Bool.self, forKey: .ignorePasswordApps)
        hotKeyIndex = try values.decode(Int.self, forKey: .hotKeyIndex)
        shortcutSchemaVersion = try values.decodeIfPresent(Int.self, forKey: .shortcutSchemaVersion)
        excludedApps = try values.decode(String.self, forKey: .excludedApps)
        // Keep existing installations visible without resetting any older preferences.
        showMenuBarIcon = try values.decodeIfPresent(Bool.self, forKey: .showMenuBarIcon) ?? true
    }

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
