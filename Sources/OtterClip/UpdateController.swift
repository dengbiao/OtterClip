import AppKit

@MainActor
final class UpdateController {
    private let client: GitHubUpdateClient
    private let status: (String, Bool, Bool) -> Void
    private let saveSettings: () -> Bool
    private let willInstall: () -> Void
    private var task: Task<Void, Never>?

    init(client: GitHubUpdateClient = GitHubUpdateClient(),
         status: @escaping (String, Bool, Bool) -> Void,
         saveSettings: @escaping () -> Bool,
         willInstall: @escaping () -> Void) {
        self.client = client
        self.status = status
        self.saveSettings = saveSettings
        self.willInstall = willInstall
    }

    func checkForUpdates() {
        if let task {
            task.cancel()
            return
        }
        task = Task { [weak self] in
            guard let self else { return }
            defer { self.task = nil }
            var downloadDirectory: URL?
            var prepared: PreparedUpdate?
            defer {
                if let downloadDirectory { try? FileManager.default.removeItem(at: downloadDirectory) }
                if let prepared { UpdateInstaller.discard(prepared) }
            }
            self.status("正在检查 GitHub 最新版本…", true, true)
            do {
                guard let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
                      UpdateVersion(version) != nil else {
                    self.status("请从已安装的 OtterClip 应用中检查更新。", false, false)
                    return
                }
                let availableRelease = try await self.client.check(currentVersion: version)
                try Task.checkCancellation()
                guard let release = availableRelease else {
                    self.status("当前已是最新版本 \(version)", false, false)
                    return
                }
                try Task.checkCancellation()
                self.status("发现新版本 \(release.version)", true, true)
                guard Self.confirmInstallation(release, currentVersion: version) else {
                    self.status("已暂缓更新 · 当前版本 \(version)", false, false)
                    return
                }
                try Task.checkCancellation()
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent("OtterClip-download-\(UUID().uuidString)", isDirectory: true)
                downloadDirectory = directory
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                        attributes: [.posixPermissions: 0o700])
                self.status("正在下载 \(release.version)…", true, true)
                let archive = try await self.client.download(release, to: directory)
                try Task.checkCancellation()
                self.status("正在校验并准备安装…", true, true)
                prepared = try await Task.detached(priority: .userInitiated) {
                    try UpdateInstaller.prepare(archiveURL: archive, version: release.version)
                }.value
                try Task.checkCancellation()
                guard self.saveSettings() else {
                    self.status("设置保存失败，更新尚未安装。", false, false)
                    return
                }
                self.status("正在安装，即将重新启动…", true, false)
                guard let installation = prepared else { return }
                try UpdateInstaller.scheduleInstall(installation)
                prepared = nil // The installer now owns its staging directory.
                self.willInstall()
                NSApp.terminate(nil)
            } catch {
                if Task.isCancelled {
                    self.status("已取消更新", false, false)
                } else {
                    self.status("更新失败：\(error.localizedDescription)", false, false)
                }
            }
        }
    }

    private static func confirmInstallation(_ release: UpdateRelease, currentVersion: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = "发现新版本 \(release.version)"
        var detail = "当前版本 \(currentVersion)。更新完成后，OtterClip 会自动重启。"
        if !release.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            detail += "\n\n" + String(release.notes.prefix(600))
        }
        detail += "\n\nmacOS 可能要求重新授予辅助功能权限。"
        alert.informativeText = detail
        alert.addButton(withTitle: "更新并重启")
        alert.addButton(withTitle: "稍后").keyEquivalent = "\u{1b}"
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }
}
