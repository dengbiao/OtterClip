import AppKit
import ClipCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var repository: HistoryRepository!
    private var preferences: PreferencesStore!
    private var monitor: ClipboardMonitor!
    private var panel: HistoryPanelController!
    private var settings: SettingsWindowController!
    private var hotKey: GlobalHotKey!
    private var statusItem: NSStatusItem!
    private var statusMenu: NSMenu!
    private var pauseItem: NSMenuItem!
    private var countItem: NSMenuItem!
    private var historyItem: NSMenuItem!
    private var directory: URL!
    private var activationObserver: NSObjectProtocol?
    private var previousApplication: NSRunningApplication?
    private var lastExternalApplication: NSRunningApplication?
    private var currentQuery = ""
    private var currentFilter = HistoryFilter.all
    private var suppressRestore = false
    private var hotKeyRegistered = false
    private var showObserver: NSObjectProtocol?
    private var pendingIssue: String?
    private let pastePermissionPrompt = PastePermissionPrompt()

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            let arguments = ProcessInfo.processInfo.arguments
            if !arguments.contains("--demo"), let bundleID = Bundle.main.bundleIdentifier,
               NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).contains(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
                // Keep the pre-rename notification so existing installs can hand off to OtterClip.
                DistributedNotificationCenter.default().postNotificationName(Notification.Name("app.clipshelf.show"), object: nil, userInfo: nil, deliverImmediately: true)
                NSApp.terminate(nil)
                return
            }
            if let index = arguments.firstIndex(of: "--data-dir"), arguments.count > index + 1 {
                directory = URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
            } else {
                // Retain the ClipShelf data directory across the OtterClip rename.
                directory = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("ClipShelf", isDirectory: true)
            }
            preferences = PreferencesStore(directory: directory)
            repository = try HistoryRepository(directory: directory, limit: preferences.value.historyLimit)
            // Preserve the existing saved window size and divider position.
            panel = HistoryPanelController(frameAutosaveName: arguments.contains("--demo") ? "" : "ClipShelf.HistoryPanel.v2")
            if arguments.contains("--demo") {
                panel.window?.setFrameAutosaveName("")
                panel.window?.setContentSize(NSSize(width: 720, height: 520))
            }
            settings = SettingsWindowController(store: preferences, directory: directory)
            monitor = ClipboardMonitor(repository: repository, preferences: preferences)
            hotKey = GlobalHotKey()
            configureCallbacks()
            showObserver = DistributedNotificationCenter.default().addObserver(forName: Notification.Name("app.clipshelf.show"), object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.showHistory() }
            }
            buildMenus()
            hotKeyRegistered = arguments.contains("--demo") || hotKey.register(index: preferences.value.hotKeyIndex)
            updateMenu()
            lastExternalApplication = NSWorkspace.shared.frontmostApplication
            activationObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] notification in
                guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
                MainActor.assumeIsolated { self?.lastExternalApplication = app }
            }
            if arguments.contains("--demo") { try seedDemo() }
            if !arguments.contains("--no-monitor") { monitor.start() }
            if arguments.contains("--show-paste-permissions") {
                openSettings()
                settings.selectPane(.privacy)
            }
            else if arguments.contains("--show-settings") { openSettings() }
            else if arguments.contains("--show") { showHistory() }
            else if !UserDefaults.standard.bool(forKey: "hasLaunched") {
                UserDefaults.standard.set(true, forKey: "hasLaunched")
                showHistory()
                panel.showNotice("从下一次复制开始记录 · \(shortcutTitle) 随时唤起")
            }
            if let error = repository.lastError { panel.showNotice("历史恢复提示：\(error.localizedDescription)") }
            // Render only this application's own views for development review; no desktop capture.
            if let index = arguments.firstIndex(of: "--render-preview"), arguments.count > index + 1 {
                let destination = URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                    self?.renderPreviews(to: destination)
                }
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "OtterClip 无法启动"
            alert.informativeText = error.localizedDescription
            alert.runModal()
            NSApp.terminate(nil)
        }
    }

    private var shortcutTitle: String { GlobalHotKey.choices[min(max(preferences.value.hotKeyIndex, 0), GlobalHotKey.choices.count - 1)].title }

    private func configureCallbacks() {
        hotKey.onTrigger = { [weak self] in
            guard let self else { return }
            if self.panel.window?.isVisible == true { self.panel.dismiss() } else { self.showHistory() }
        }
        panel.onQueryChanged = { [weak self] query, filter in
            self?.currentQuery = query
            self?.currentFilter = filter
            self?.refreshHistory()
        }
        panel.onChoose = { [weak self] item, copyOnly in self?.choose(item, copyOnly: copyOnly) }
        panel.onPin = { [weak self] id in
            self?.repository.togglePin(id: id)
            self?.refreshHistory()
            self?.reportStorageError()
        }
        panel.onDelete = { [weak self] id in
            self?.repository.remove(id: id)
            self?.refreshHistory()
            self?.reportStorageError()
        }
        panel.onDismiss = { [weak self] in
            guard let self, !self.suppressRestore else { return }
            self.previousApplication?.activate(options: [.activateIgnoringOtherApps])
        }
        panel.onOpenSettings = { [weak self] in self?.openSettings() }
        monitor.onChange = { [weak self] in
            guard let self else { return }
            if self.repository.lastError == nil { self.pendingIssue = nil }
            self.refreshHistory()
            self.updateMenu()
        }
        monitor.onIssue = { [weak self] issue in
            self?.pendingIssue = issue
            self?.statusItem.button?.toolTip = "OtterClip · \(issue)"
            if self?.panel.window?.isVisible == true { self?.panel.showNotice(issue) }
        }
        settings.onChanged = { [weak self] in
            guard let self else { return }
            self.monitor.ignoreCurrentChange()
            self.repository.setLimit(self.preferences.value.historyLimit)
            self.hotKeyRegistered = self.hotKey.register(index: self.preferences.value.hotKeyIndex)
            self.updateMenu()
            self.refreshHistory()
            if !self.hotKeyRegistered { self.settings.showStatus("快捷键已被占用，请选择另一个快捷键。菜单栏入口仍可使用。") }
            if let error = self.repository.lastError { self.settings.showStatus("保存历史失败：\(error.localizedDescription)") }
        }
        settings.onClearHistory = { [weak self] in self?.clearHistory() }
    }

    private func buildMenus() {
        let mainMenu = NSMenu()
        let appMenu = NSMenu()
        let appItem = NSMenuItem()
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)
        appMenu.addItem(withTitle: "关于 OtterClip", action: #selector(about), keyEquivalent: "")
        appMenu.addItem(withTitle: "设置…", action: #selector(openSettings), keyEquivalent: ",")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出 OtterClip", action: #selector(quit), keyEquivalent: "q")
        let edit = NSMenu(title: "编辑")
        for (title, action, key) in [("剪切", #selector(NSText.cut(_:)), "x"), ("复制", #selector(NSText.copy(_:)), "c"), ("粘贴", #selector(NSText.paste(_:)), "v"), ("全选", #selector(NSText.selectAll(_:)), "a")] {
            edit.addItem(withTitle: title, action: action, keyEquivalent: key)
        }
        let editItem = NSMenuItem()
        editItem.submenu = edit
        mainMenu.addItem(editItem)
        NSApp.mainMenu = mainMenu

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        // Preserve the existing menu bar position across the OtterClip rename.
        statusItem.autosaveName = "ClipShelf.SettingsStatusItem"
        statusItem.isVisible = true
        let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns")
        let appIcon: NSImage? = iconURL.flatMap { NSImage(contentsOf: $0) } ?? NSApp.applicationIconImage
        if let image = appIcon?.copy() as? NSImage {
            image.isTemplate = false
            image.size = NSSize(width: 18, height: 18)
            statusItem.button?.image = image
        } else { statusItem.button?.title = "OC" }
        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusItemClicked(_:))
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusItem.button?.setAccessibilityLabel("OtterClip 设置")
        statusItem.button?.toolTip = "OtterClip 设置 · 左键打开，右键菜单"
        let menu = NSMenu()
        let heading = NSMenuItem(title: "OtterClip", action: nil, keyEquivalent: "")
        heading.isEnabled = false
        menu.addItem(heading)
        historyItem = NSMenuItem(title: "打开历史记录", action: #selector(showHistory), keyEquivalent: "")
        historyItem.target = self
        menu.addItem(historyItem)
        countItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        menu.addItem(countItem)
        menu.addItem(.separator())
        pauseItem = NSMenuItem(title: "暂停记录", action: #selector(togglePause), keyEquivalent: "")
        pauseItem.target = self
        menu.addItem(pauseItem)
        menu.addItem(withTitle: "设置…", action: #selector(openSettings), keyEquivalent: ",").target = self
        menu.addItem(withTitle: "清空未收藏历史…", action: #selector(clearHistory), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "关于 OtterClip", action: #selector(about), keyEquivalent: "").target = self
        menu.addItem(withTitle: "退出 OtterClip", action: #selector(quit), keyEquivalent: "q").target = self
        statusMenu = menu
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            let lowerEdge = sender.isFlipped ? sender.bounds.maxY : sender.bounds.minY
            statusMenu.popUp(positioning: nil, at: NSPoint(x: sender.bounds.minX, y: lowerEdge), in: sender)
        } else { openSettings() }
    }

    private func updateMenu() {
        pauseItem.title = preferences.value.isPaused ? "继续记录" : "暂停记录"
        pauseItem.state = preferences.value.isPaused ? .on : .off
        countItem.title = "\(repository.items.count) 条历史 · \(repository.items.filter(\.isPinned).count) 条收藏"
        countItem.isEnabled = false
        historyItem.title = "打开历史记录    \(shortcutTitle)\(hotKeyRegistered ? "" : "（快捷键冲突）")"
        statusItem.button?.appearsDisabled = preferences.value.isPaused
    }

    @objc private func showHistory() {
        let front = NSWorkspace.shared.frontmostApplication
        previousApplication = front?.processIdentifier != ProcessInfo.processInfo.processIdentifier ? front : lastExternalApplication
        currentQuery = ""
        currentFilter = .all
        panel.hotKeyTitle = shortcutTitle
        NSApp.activate(ignoringOtherApps: true)
        panel.show(items: repository.search(query: "", filter: .all), imageDirectory: directory.appendingPathComponent("Images"), isPaused: preferences.value.isPaused)
        if pendingIssue == PasteController.PasteFailure.permissionRequired.message, PasteController.accessStatus.canPaste {
            pendingIssue = nil
            statusItem.button?.toolTip = "OtterClip 设置 · 左键打开，右键菜单"
        }
        if !hotKeyRegistered { panel.showNotice("\(shortcutTitle) 已被其他应用占用，请在设置中更换快捷键。") }
        else if let pendingIssue { panel.showNotice(pendingIssue) }
        else if #available(macOS 15.4, *), NSPasteboard.general.accessBehavior == .alwaysDeny {
            panel.showNotice("系统已关闭剪贴板访问，请在系统设置中允许 OtterClip 后继续复制。")
        }
    }

    private func refreshHistory() {
        guard panel.window?.isVisible == true else { return }
        panel.update(items: repository.search(query: currentQuery, filter: currentFilter))
        updateMenu()
    }

    private func reportStorageError() {
        if let error = repository.lastError { panel.showNotice("保存失败：\(error.localizedDescription)") }
    }

    private func choose(_ item: ClipboardItem, copyOnly: Bool) {
        do {
            let writtenChangeCount = try PasteController.write(item, repository: repository)
            monitor.ignoreCurrentChange()
            var used = item
            used.lastCopiedAt = Date()
            repository.insert(used)
            updateMenu()
            let target = previousApplication
            // Restore the destination only after hiding history, including paste fallbacks.
            suppressRestore = true
            panel.dismiss()
            suppressRestore = false
            if copyOnly { target?.activate(options: [.activateIgnoringOtherApps]) }
            else {
                PasteController.paste(into: target, expectedChangeCount: writtenChangeCount) { [weak self] failure in
                    guard let self else { return }
                    self.pendingIssue = failure.message
                    self.statusItem.button?.toolTip = "OtterClip · \(failure.message)"
                    if case .permissionRequired = failure {
                        self.pastePermissionPrompt.show(onAuthorize: { [weak self] in
                            self?.settings.showPastePermissionSettings()
                        }, onLater: {
                            target?.activate(options: [.activateIgnoringOtherApps])
                        })
                    } else {
                        NSSound.beep()
                    }
                }
            }
        } catch { panel.showNotice(error.localizedDescription) }
    }

    @objc private func togglePause() {
        preferences.value.isPaused.toggle()
        monitor.ignoreCurrentChange()
        preferences.save()
        if let error = preferences.lastError {
            preferences.value.isPaused.toggle()
            pendingIssue = "暂停状态保存失败：\(error.localizedDescription)"
        }
        updateMenu()
        if panel.window?.isVisible == true { panel.dismiss(); showHistory() }
    }

    @objc private func openSettings() {
        suppressRestore = true
        panel.dismiss()
        suppressRestore = false
        settings.show()
    }

    @objc private func clearHistory() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "清空所有未收藏的历史？"
        alert.informativeText = "收藏会保留。已删除的历史无法恢复，当前系统剪贴板不会被清空。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "取消")
        alert.addButton(withTitle: "清空历史")
        if alert.runModal() == .alertSecondButtonReturn {
            monitor.ignoreCurrentChange()
            repository.clearUnpinned()
            refreshHistory()
            updateMenu()
            reportStorageError()
        }
    }

    @objc private func about() {
        NSApp.orderFrontStandardAboutPanel(options: [.applicationName: "OtterClip", .applicationVersion: "1.2.1", .credits: NSAttributedString(string: "本地保存 · 文本 / 图片 / 文件\n默认快捷键 ⌥⌘C")])
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func quit() { NSApp.terminate(nil) }

    func applicationWillTerminate(_ notification: Notification) {
        monitor?.stop()
        hotKey?.invalidate()
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
        if let showObserver { DistributedNotificationCenter.default().removeObserver(showObserver) }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if panel != nil { showHistory() }
        return true
    }

    private func renderPreviews(to destination: URL) {
        do {
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            if let window = panel.window, let view = window.contentView {
                let initialSize = view.bounds.size
                try render(view, to: destination.appendingPathComponent("history.png"))
                if window.styleMask.contains(.resizable) {
                    window.setContentSize(NSSize(width: 640, height: 460))
                    try render(view, to: destination.appendingPathComponent("history-minimum.png"))
                    window.setContentSize(NSSize(width: 960, height: 640))
                    try render(view, to: destination.appendingPathComponent("history-large.png"))
                    window.setContentSize(initialSize)
                    print("UI render: resizable window checked at 640×460, \(Int(initialSize.width))×\(Int(initialSize.height)), 960×640")
                } else { fputs("UI render: window is missing resizable style\n", stderr) }
            }
            settings.show()
            renderSettingsPreviews(to: destination)
        } catch { fputs("Preview render failed: \(error)\n", stderr); NSApp.terminate(nil) }
    }

    private func renderSettingsPreviews(to destination: URL, index: Int = 0) {
        guard index < SettingsPane.allCases.count else { NSApp.terminate(nil); return }
        let pane = SettingsPane.allCases[index]
        settings.selectPane(pane)
        // Native toolbar selection appearance is committed on the next display cycle.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self else { return }
            do {
                if let window = self.settings.window, let view = window.contentView?.superview {
                    window.displayIfNeeded()
                    try self.render(view, to: destination.appendingPathComponent("settings-\(pane.rawValue).png"))
                    if pane == .general { try self.render(view, to: destination.appendingPathComponent("settings.png")) }
                }
                self.renderSettingsPreviews(to: destination, index: index + 1)
            } catch { fputs("Settings render failed: \(error)\n", stderr); NSApp.terminate(nil) }
        }
    }

    private func render(_ view: NSView, to url: URL) throws {
        view.layoutSubtreeIfNeeded()
        guard let representation = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw CocoaError(.fileWriteUnknown) }
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            view.cacheDisplay(in: view.bounds, to: representation)
        }
        let canvas = NSImage(size: view.bounds.size)
        canvas.lockFocus()
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            let isDark = view.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            NSColor(calibratedWhite: isDark ? 0.12 : 0.96, alpha: 1).setFill()
            view.bounds.fill()
            let rendered = NSImage(size: view.bounds.size)
            rendered.addRepresentation(representation)
            rendered.draw(in: view.bounds, from: .zero, operation: .sourceOver, fraction: 1)
        }
        canvas.unlockFocus()
        guard let tiff = canvas.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        try png.write(to: url)
    }

    private func seedDemo() throws {
        guard repository.items.isEmpty else { return }
        let entries = [
            ("把复杂留给工具，把专注留给自己。", "备忘录", false),
            ("https://developer.apple.com/design/human-interface-guidelines", "Safari", false),
            ("swift build --configuration release", "终端", false),
            ("会议时间调整到周三下午 3:00，\n议题和材料已更新到共享文档。", "邮件", false),
            ("git switch -c feature/clipboard-history", "终端", false),
            ("下周发布前，再检查一次键盘操作和空状态。", "备忘录", false),
            ("产品评审 · 讨论要点\n\n01  让搜索成为第一入口\n      打开就能输入，常用内容触手可及。\n\n02  为内容留出更多空间\n      保留清晰的层次，减少视觉干扰。\n\n03  操作保持轻快\n      选择、回车，继续手头的工作。", "备忘录", true)
        ]
        for (index, entry) in entries.enumerated() {
            var item = ClipboardMonitor.makeItem(kind: .text, text: entry.0, source: entry.1, fingerprint: ClipboardMonitor.digest(Data(entry.0.utf8), kind: .text))
            item.lastCopiedAt = Date().addingTimeInterval(Double(index - entries.count) * 170)
            item.createdAt = item.lastCopiedAt
            repository.insert(item)
            if entry.2 { repository.togglePin(id: item.id) }
        }
    }
}
