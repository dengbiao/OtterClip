import AppKit
import ServiceManagement

enum SettingsPane: String, CaseIterable {
    case general, capture, privacy

    var title: String {
        switch self {
        case .general: return "通用"
        case .capture: return "记录"
        case .privacy: return "隐私"
        }
    }

    var symbol: String {
        switch self {
        case .general: return "slider.horizontal.3"
        case .capture: return "doc.on.clipboard"
        case .privacy: return "hand.raised"
        }
    }

    var identifier: NSToolbarItem.Identifier { NSToolbarItem.Identifier("OtterClip.Settings.\(rawValue)") }

    var contentHeight: CGFloat {
        switch self {
        case .general: return 356
        case .capture: return 354
        case .privacy: return 326
        }
    }
}

@MainActor
final class SettingsWindowController: NSWindowController, NSToolbarDelegate, NSWindowDelegate {
    var onChanged: (() -> Void)?
    var onClearHistory: (() -> Void)?
    var onRestart: (() -> Void)?
    private(set) var selectedPane: SettingsPane = .general
    private let store: PreferencesStore
    private let directory: URL
    private let shortcut = NSPopUpButton()
    private let limit = NSPopUpButton()
    private let images = NSSwitch()
    private let files = NSSwitch()
    private let passwords = NSSwitch()
    private let login = NSSwitch()
    private let exclusions = NSTextView()
    private let accessibilityLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let permissionButton = NSButton()
    private var permissionTimer: Timer?
    private let paneContainer = NSView()
    private var panes: [SettingsPane: NSView] = [:]
    private let limits = [100, 300, 500, 1000]
    private let secondaryColor = NSColor(srgbRed: 0.48, green: 0.50, blue: 0.54, alpha: 1)

    init(store: PreferencesStore, directory: URL) {
        self.store = store
        self.directory = directory
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: SettingsPane.general.contentHeight), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "OtterClip 设置"
        window.titleVisibility = .hidden
        window.toolbarStyle = .preference
        window.appearance = NSAppearance(named: .aqua)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        NotificationCenter.default.addObserver(self, selector: #selector(applicationBecameActive(_:)), name: NSApplication.didBecomeActiveNotification, object: nil)
        buildUI()
        let toolbar = NSToolbar(identifier: "OtterClip.Settings")
        toolbar.delegate = self
        toolbar.displayMode = .iconAndLabel
        toolbar.allowsUserCustomization = false
        toolbar.autosavesConfiguration = false
        window.toolbar = toolbar
        toolbar.selectedItemIdentifier = SettingsPane.general.identifier
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show() {
        // Returning from System Settings must not replace edits that have not been saved.
        if window?.isVisible != true { loadValues() }
        refreshPermission()
        if permissionTimer == nil {
            permissionTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.window?.isVisible == true, self.selectedPane == .privacy else { return }
                    self.refreshPermission()
                }
            }
        }
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    func showPastePermissionSettings() {
        show()
        selectPane(.privacy)
        openAccessibility()
    }

    func windowDidBecomeKey(_ notification: Notification) { refreshPermission() }

    func windowWillClose(_ notification: Notification) {
        permissionTimer?.invalidate()
        permissionTimer = nil
    }

    @objc private func applicationBecameActive(_ notification: Notification) { refreshPermission() }

    func selectPane(_ pane: SettingsPane) {
        window?.makeFirstResponder(nil)
        selectedPane = pane
        window?.toolbar?.selectedItemIdentifier = pane.identifier
        paneContainer.subviews.forEach { $0.removeFromSuperview() }
        // Keep the toolbar still while fitting the window to the active page.
        if let window, let content = window.contentView {
            let delta = pane.contentHeight - content.bounds.height
            var frame = window.frame
            frame.origin.y -= delta
            frame.size.height += delta
            window.setFrame(frame, display: true)
        }
        guard let view = panes[pane] else { return }
        view.translatesAutoresizingMaskIntoConstraints = false
        paneContainer.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: paneContainer.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: paneContainer.trailingAnchor),
            view.topAnchor.constraint(equalTo: paneContainer.topAnchor),
            view.bottomAnchor.constraint(lessThanOrEqualTo: paneContainer.bottomAnchor)
        ])
        paneContainer.layoutSubtreeIfNeeded()
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        SettingsPane.allCases.map(\.identifier)
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        SettingsPane.allCases.map(\.identifier)
    }

    func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        SettingsPane.allCases.map(\.identifier)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard let pane = SettingsPane.allCases.first(where: { $0.identifier == itemIdentifier }) else { return nil }
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.label = pane.title
        item.paletteLabel = pane.title
        item.image = NSImage(systemSymbolName: pane.symbol, accessibilityDescription: pane.title)
        item.target = self
        item.action = #selector(changePane(_:))
        return item
    }

    @objc private func changePane(_ sender: NSToolbarItem) {
        guard let pane = SettingsPane.allCases.first(where: { $0.identifier == sender.itemIdentifier }) else { return }
        selectPane(pane)
    }

    private func buildUI() {
        guard let content = window?.contentView else { return }
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor(calibratedRed: 0.969, green: 0.969, blue: 0.976, alpha: 1).cgColor

        shortcut.addItems(withTitles: GlobalHotKey.choices.map(\.title))
        shortcut.setAccessibilityLabel("全局快捷键")
        limit.addItems(withTitles: limits.map { "最近 \($0) 条" })
        limit.setAccessibilityLabel("历史容量")
        for popup in [shortcut, limit] {
            popup.font = .systemFont(ofSize: 12)
            popup.controlSize = .regular
            popup.widthAnchor.constraint(equalToConstant: 138).isActive = true
        }
        for button in [images, files, passwords, login] {
            button.controlSize = .small
            button.setAccessibilityLabel(button === images ? "记录图片" : button === files ? "记录文件" : button === passwords ? "跳过密码管理器" : "登录启动")
        }
        login.target = self
        login.action = #selector(toggleLogin)

        panes[.general] = buildGeneralPane()
        panes[.capture] = buildCapturePane()
        panes[.privacy] = buildPrivacyPane()

        let footer = NSView()
        footer.wantsLayer = true
        footer.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.56).cgColor
        let line = separator()
        let save = actionButton("保存设置", action: #selector(saveSettings), width: 84)
        save.keyEquivalent = "\r"
        save.bezelColor = .controlAccentColor
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = secondaryColor
        statusLabel.maximumNumberOfLines = 2
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for view in [paneContainer, footer] { view.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(view) }
        for view in [line, statusLabel, save] { view.translatesAutoresizingMaskIntoConstraints = false; footer.addSubview(view) }
        NSLayoutConstraint.activate([
            paneContainer.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            paneContainer.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            paneContainer.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
            paneContainer.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -20),
            footer.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            footer.heightAnchor.constraint(equalToConstant: 58),
            line.leadingAnchor.constraint(equalTo: footer.leadingAnchor),
            line.trailingAnchor.constraint(equalTo: footer.trailingAnchor),
            line.topAnchor.constraint(equalTo: footer.topAnchor),
            save.trailingAnchor.constraint(equalTo: footer.trailingAnchor, constant: -24),
            save.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            statusLabel.leadingAnchor.constraint(equalTo: footer.leadingAnchor, constant: 24),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: save.leadingAnchor, constant: -16),
            statusLabel.centerYAnchor.constraint(equalTo: footer.centerYAnchor)
        ])
        selectPane(.general)
    }

    private func buildGeneralPane() -> NSView {
        let stack = verticalStack(spacing: 12)
        append(card(rows: [
            settingRow("全局快捷键", detail: "随时唤起剪贴板历史", control: shortcut),
            settingRow("历史容量", detail: "收藏内容不计入容量", control: limit),
            settingRow("登录时启动", detail: "登录后在菜单栏运行", control: login),
            settingRow("重新启动应用", detail: "会先保存当前设置", control: actionButton("重新启动", action: #selector(restartApplication), width: 86))
        ]), to: stack)
        let note = text("用快捷键打开，选择一条记录后按回车粘贴。", size: 11, color: secondaryColor)
        append(inset(note, horizontal: 2), to: stack)
        return stack
    }

    private func buildCapturePane() -> NSView {
        let stack = verticalStack(spacing: 20)
        append(card(rows: [
            settingRow("记录图片", detail: "单张图片最多 12 MB", control: images),
            settingRow("记录文件", detail: "保存文件路径，请保留原文件", control: files),
            settingRow("跳过密码管理器", detail: "不记录常见密码管理器复制的内容", control: passwords)
        ]), to: stack)

        let actions = NSStackView()
        actions.orientation = .horizontal
        actions.spacing = 8
        actions.addArrangedSubview(actionButton("数据文件夹", action: #selector(openDirectory), width: 86))
        actions.addArrangedSubview(actionButton("清空历史…", action: #selector(clearHistory), width: 86))
        append(card(rows: [settingRow("本地数据", detail: "清空时保留收藏", control: actions, height: 60)]), to: stack)
        return stack
    }

    private func buildPrivacyPane() -> NSView {
        let stack = verticalStack(spacing: 18)
        let actions = NSStackView()
        actions.orientation = .horizontal
        actions.spacing = 6
        configureButton(permissionButton, title: "前往授权", action: #selector(openAccessibility), width: 80)
        let refresh = ToolbarIconButton(symbol: "arrow.clockwise", title: "刷新授权状态", target: self, action: #selector(refreshPermission))
        refresh.widthAnchor.constraint(equalToConstant: 26).isActive = true
        refresh.heightAnchor.constraint(equalToConstant: 26).isActive = true
        actions.addArrangedSubview(permissionButton)
        actions.addArrangedSubview(refresh)

        let labels = verticalStack(spacing: 3)
        labels.addArrangedSubview(text("自动粘贴", size: 13))
        accessibilityLabel.font = .systemFont(ofSize: 11)
        accessibilityLabel.textColor = secondaryColor
        labels.addArrangedSubview(accessibilityLabel)
        append(card(rows: [alignedRow(labels: labels, control: actions, height: 60)]), to: stack)

        let excluded = verticalStack(spacing: 8)
        let heading = NSView()
        heading.heightAnchor.constraint(equalToConstant: 18).isActive = true
        let title = text("排除的应用", size: 12, weight: .medium)
        let hint = text("每行一个 Bundle ID", size: 11, color: secondaryColor)
        for label in [title, hint] { label.translatesAutoresizingMaskIntoConstraints = false; heading.addSubview(label) }
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: heading.leadingAnchor, constant: 2),
            title.centerYAnchor.constraint(equalTo: heading.centerYAnchor),
            hint.trailingAnchor.constraint(equalTo: heading.trailingAnchor, constant: -2),
            hint.firstBaselineAnchor.constraint(equalTo: title.firstBaselineAnchor)
        ])
        append(heading, to: excluded)

        let scroll = NSScrollView()
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.wantsLayer = true
        scroll.layer?.cornerRadius = 8
        scroll.layer?.borderWidth = 1
        scroll.layer?.borderColor = NSColor(calibratedWhite: 0.87, alpha: 1).cgColor
        scroll.backgroundColor = .white
        scroll.heightAnchor.constraint(equalToConstant: 88).isActive = true
        exclusions.isRichText = false
        exclusions.textColor = .labelColor
        exclusions.backgroundColor = .white
        exclusions.insertionPointColor = .labelColor
        exclusions.frame = NSRect(x: 0, y: 0, width: 490, height: 88)
        exclusions.minSize = NSSize(width: 0, height: 88)
        exclusions.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        exclusions.isVerticallyResizable = true
        exclusions.isHorizontallyResizable = false
        exclusions.textContainer?.containerSize = NSSize(width: 490, height: CGFloat.greatestFiniteMagnitude)
        exclusions.textContainer?.widthTracksTextView = true
        exclusions.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        exclusions.textContainerInset = NSSize(width: 10, height: 10)
        exclusions.autoresizingMask = [.width]
        exclusions.isAutomaticQuoteSubstitutionEnabled = false
        exclusions.isAutomaticDashSubstitutionEnabled = false
        exclusions.setAccessibilityLabel("排除的应用，每行一个 Bundle ID")
        scroll.documentView = exclusions
        append(scroll, to: excluded)
        append(excluded, to: stack)
        let note = NSTextField(wrappingLabelWithString: "历史仅保存在这台 Mac。标记为敏感或临时的内容会自动跳过。")
        note.font = .systemFont(ofSize: 11)
        note.textColor = secondaryColor
        note.maximumNumberOfLines = 2
        append(inset(note, horizontal: 2), to: stack)
        return stack
    }

    private func text(_ value: String, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor = .labelColor) -> NSTextField {
        let label = NSTextField(labelWithString: value)
        label.font = .systemFont(ofSize: size, weight: weight)
        label.textColor = color
        return label
    }

    private func verticalStack(spacing: CGFloat) -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = spacing
        return stack
    }

    private func append(_ view: NSView, to stack: NSStackView) {
        stack.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    private func inset(_ view: NSView, horizontal: CGFloat) -> NSView {
        let container = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: horizontal),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -horizontal),
            view.topAnchor.constraint(equalTo: container.topAnchor),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        return container
    }

    private func separator() -> NSView {
        let line = NSView()
        line.wantsLayer = true
        line.layer?.backgroundColor = NSColor(calibratedWhite: 0.89, alpha: 1).cgColor
        line.heightAnchor.constraint(equalToConstant: 0.5).isActive = true
        return line
    }

    private func actionButton(_ title: String, action: Selector, width: CGFloat) -> NSButton {
        let button = NSButton()
        configureButton(button, title: title, action: action, width: width)
        return button
    }

    private func configureButton(_ button: NSButton, title: String, action: Selector, width: CGFloat) {
        button.title = title
        button.target = self
        button.action = action
        button.bezelStyle = .rounded
        button.controlSize = .regular
        button.font = .systemFont(ofSize: 12)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: width).isActive = true
        button.heightAnchor.constraint(equalToConstant: 28).isActive = true
    }

    private func settingRow(_ title: String, detail: String, control: NSView, height: CGFloat = 56) -> NSView {
        let labels = verticalStack(spacing: 3)
        labels.addArrangedSubview(text(title, size: 13))
        labels.addArrangedSubview(text(detail, size: 11, color: secondaryColor))
        return alignedRow(labels: labels, control: control, height: height)
    }

    private func alignedRow(labels: NSView, control: NSView, height: CGFloat) -> NSView {
        let row = NSView()
        row.heightAnchor.constraint(equalToConstant: height).isActive = true
        labels.translatesAutoresizingMaskIntoConstraints = false
        control.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(labels)
        row.addSubview(control)
        NSLayoutConstraint.activate([
            labels.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 16),
            labels.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            labels.trailingAnchor.constraint(lessThanOrEqualTo: control.leadingAnchor, constant: -16),
            control.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -16),
            control.centerYAnchor.constraint(equalTo: row.centerYAnchor)
        ])
        return row
    }

    private func card(rows: [NSView]) -> NSView {
        let card = OtterClipSettingsCard()
        let rowsStack = verticalStack(spacing: 0)
        rowsStack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(rowsStack)
        for (index, row) in rows.enumerated() {
            append(row, to: rowsStack)
            if index < rows.count - 1 { append(inset(separator(), horizontal: 16), to: rowsStack) }
        }
        NSLayoutConstraint.activate([
            rowsStack.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            rowsStack.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            rowsStack.topAnchor.constraint(equalTo: card.topAnchor),
            rowsStack.bottomAnchor.constraint(equalTo: card.bottomAnchor)
        ])
        return card
    }

    private func loadValues() {
        shortcut.selectItem(at: min(max(store.value.hotKeyIndex, 0), GlobalHotKey.choices.count - 1))
        limit.selectItem(at: limits.firstIndex(of: store.value.historyLimit) ?? 1)
        images.state = store.value.captureImages ? .on : .off
        files.state = store.value.captureFiles ? .on : .off
        passwords.state = store.value.ignorePasswordApps ? .on : .off
        exclusions.string = store.value.excludedApps
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        statusLabel.stringValue = ""
        refreshPermission()
    }

    @objc private func saveSettings() { _ = persistSettings() }

    @objc private func restartApplication() {
        guard persistSettings() else { return }
        onRestart?()
    }

    private func persistSettings() -> Bool {
        window?.makeFirstResponder(nil)
        let previous = store.value
        store.value.hotKeyIndex = shortcut.indexOfSelectedItem
        store.value.historyLimit = limits[max(0, limit.indexOfSelectedItem)]
        store.value.captureImages = images.state == .on
        store.value.captureFiles = files.state == .on
        store.value.ignorePasswordApps = passwords.state == .on
        store.value.excludedApps = exclusions.string
        store.save()
        if let error = store.lastError {
            store.value = previous
            statusLabel.stringValue = "保存失败：\(error.localizedDescription)"
            return false
        }
        statusLabel.stringValue = "设置已保存"
        onChanged?()
        return true
    }

    func showStatus(_ text: String) { statusLabel.stringValue = text }

    @objc private func toggleLogin() {
        do {
            if login.state == .on { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            if SMAppService.mainApp.status == .requiresApproval {
                statusLabel.stringValue = "请在系统设置 → 通用 → 登录项中允许 OtterClip。"
                SMAppService.openSystemSettingsLoginItems()
            } else { statusLabel.stringValue = login.state == .on ? "已开启登录启动" : "已关闭登录启动" }
        } catch {
            login.state = SMAppService.mainApp.status == .enabled ? .on : .off
            statusLabel.stringValue = "登录启动设置失败：\(error.localizedDescription)"
        }
    }

    @objc private func refreshPermission() {
        let access = PasteController.accessStatus
        if access.canPaste {
            accessibilityLabel.stringValue = "辅助功能与发送按键权限已开启"
            if statusLabel.stringValue.contains("自动粘贴尚未授权") {
                statusLabel.stringValue = "授权已生效，可以返回输入框使用回车粘贴。"
            }
        } else {
            accessibilityLabel.stringValue = "辅助功能\(access.accessibility ? "已开启" : "未授权") · 发送按键\(access.eventPosting ? "已开启" : "未授权")"
        }
        permissionButton.title = access.canPaste ? "已授权" : "前往授权"
        permissionButton.isEnabled = !access.canPaste
    }

    @objc private func openAccessibility() {
        PasteController.requestAccess()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") { NSWorkspace.shared.open(url) }
    }

    @objc private func openDirectory() { NSWorkspace.shared.open(directory) }
    @objc private func clearHistory() { onClearHistory?() }
}

private final class OtterClipSettingsCard: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.white.cgColor
        layer?.cornerRadius = 9
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor(calibratedWhite: 0.87, alpha: 1).cgColor
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
