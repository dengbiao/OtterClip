import AppKit
import ClipCore

@MainActor
final class HistoryPanelController: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate, NSSplitViewDelegate {
    private static let defaultListWidth: CGFloat = 360
    private static let minimumListWidth: CGFloat = 300
    private static let minimumPreviewWidth: CGFloat = 300
    var onQueryChanged: ((String, HistoryFilter) -> Void)?
    var onChoose: ((ClipboardItem, Bool) -> Void)?
    var onPin: ((UUID) -> Void)?
    var onDelete: ((UUID) -> Void)?
    var onOpenSettings: (() -> Void)?
    var onDismiss: (() -> Void)?
    var hotKeyTitle = "⌥⌘C" { didSet { shortcutBadge.shortcut = hotKeyTitle } }

    private let searchField = NSSearchField()
    private let shortcutBadge = ToolbarShortcutBadge("⌥⌘C")
    private let tableView = NSTableView()
    private let listScroll = NSScrollView()
    private let splitView = NSSplitView()
    private let listPane = NSView()
    private let previewHost = NSView()
    private let countLabel = NSTextField(labelWithString: "")
    private let emptyList = NSStackView()
    private let emptyTitle = NSTextField(labelWithString: "")
    private let emptyDetail = NSTextField(wrappingLabelWithString: "")
    private let copyButton = ToolbarActionButton(title: "复制", shortcut: "⌘↩", primary: false)
    private let pasteButton = ToolbarActionButton(title: "粘贴", shortcut: "↩", primary: true)
    private let footerHints = ToolbarHints()
    private let footerLabel = NSTextField(labelWithString: "")
    private var filterButtons: [FilterPill] = []
    private var items: [ClipboardItem] = []
    private var imageDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
    private var currentFilter: HistoryFilter = .all
    private var isShowing = false
    private var paused = false
    private var noticeTask: Task<Void, Never>?

    // Keep the existing autosave key when rebranding to OtterClip.
    init(frameAutosaveName: String = "ClipShelf.HistoryPanel.v2") {
        // Preserve native edge resizing, with the title bar integrated into search.
        let panel = ClipboardHistoryPanel(contentRect: NSRect(x: 0, y: 0, width: 720, height: 520), styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        panel.title = "OtterClip 剪贴板历史"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] { panel.standardWindowButton(type)?.isHidden = true }
        panel.contentMinSize = NSSize(width: 640, height: 460)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.appearance = NSAppearance(named: .aqua)
        panel.animationBehavior = .utilityWindow
        super.init(window: panel)
        panel.delegate = self
        panel.keyHandler = { [weak self] event in self?.handleKey(event) ?? false }
        buildUI()
        if !frameAutosaveName.isEmpty {
            panel.setFrameAutosaveName(frameAutosaveName)
            panel.setFrameUsingName(frameAutosaveName)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Reset the query without emitting a user-edit callback, retaining saved dimensions.
    func show(items: [ClipboardItem], imageDirectory: URL, isPaused: Bool) {
        noticeTask?.cancel()
        self.imageDirectory = imageDirectory
        paused = isPaused
        currentFilter = .all
        searchField.stringValue = ""
        updateFilterSelection()
        tableView.deselectAll(nil)
        self.items = items
        reload(selectedID: nil)
        resetFooter()
        if let panel = window {
            let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
            if let screen {
                let bounds = screen.visibleFrame
                let x = max(bounds.minX, bounds.midX - panel.frame.width / 2)
                let y = max(bounds.minY, min(bounds.maxY - panel.frame.height, bounds.midY - panel.frame.height / 2 + 35))
                panel.setFrameOrigin(NSPoint(x: x, y: y))
            }
            isShowing = true
            panel.makeKeyAndOrderFront(nil)
            panel.makeFirstResponder(searchField)
        }
    }

    func update(items: [ClipboardItem]) {
        let selectedID = selectedItem?.id
        self.items = items
        reload(selectedID: selectedID)
    }

    func showNotice(_ text: String) {
        noticeTask?.cancel()
        footerLabel.stringValue = text
        footerLabel.textColor = ShelfColors.primary
        footerLabel.toolTip = text
        footerLabel.isHidden = false
        footerHints.isHidden = true
        noticeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            guard !Task.isCancelled else { return }
            self?.resetFooter()
        }
    }

    func dismiss() {
        guard isShowing else { return }
        isShowing = false
        window?.orderOut(nil)
        onDismiss?()
    }

    func windowDidResignKey(_ notification: Notification) {
        guard isShowing else { return }
        isShowing = false
        window?.orderOut(nil)
    }

    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        let minimum = sender.frameRect(forContentRect: NSRect(x: 0, y: 0, width: 640, height: 460)).size
        return NSSize(width: max(frameSize.width, minimum.width), height: max(frameSize.height, minimum.height))
    }

    func windowDidResize(_ notification: Notification) {
        guard let window, !window.frameAutosaveName.isEmpty else { return }
        window.saveFrame(usingName: window.frameAutosaveName)
    }

    private var selectedItem: ClipboardItem? {
        let row = tableView.selectedRow
        return items.indices.contains(row) ? items[row] : nil
    }

    private func buildUI() {
        guard let window else { return }
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 720, height: 520))
        root.wantsLayer = true
        root.layer?.backgroundColor = ShelfColors.surface.cgColor
        root.layer?.cornerRadius = 12
        root.layer?.masksToBounds = true
        window.contentView = root

        let searchIcon = symbolImage("magnifyingglass", size: 18, color: ShelfColors.secondary)
        searchField.cell = CenteredSearchFieldCell(textCell: "")
        searchField.placeholderString = "搜索剪贴板…"
        searchField.font = .systemFont(ofSize: 16, weight: .regular)
        searchField.placeholderAttributedString = NSAttributedString(string: "搜索剪贴板…", attributes: [.font: NSFont.systemFont(ofSize: 16, weight: .regular), .foregroundColor: ShelfColors.tertiary])
        searchField.isEditable = true
        searchField.isSelectable = true
        (searchField.cell as? NSTextFieldCell)?.usesSingleLineMode = true
        (searchField.cell as? NSTextFieldCell)?.isScrollable = true
        searchField.isBordered = false
        searchField.drawsBackground = false
        searchField.focusRingType = .none
        searchField.sendsSearchStringImmediately = true
        searchField.sendsWholeSearchString = false
        searchField.delegate = self
        searchField.textColor = ShelfColors.primary
        (searchField.cell as? NSSearchFieldCell)?.searchButtonCell = nil
        (searchField.cell as? NSSearchFieldCell)?.cancelButtonCell = nil
        searchField.setAccessibilityLabel("搜索剪贴板历史")
        shortcutBadge.toolTip = "显示 / 隐藏剪贴板历史"
        let close = ToolbarIconButton(symbol: "xmark", title: "关闭 · Esc", target: self, action: #selector(closePanel))
        let searchDivider = divider(), contentDivider = divider(), footerDivider = divider()
        let pillRow = NSStackView()
        pillRow.orientation = .horizontal
        pillRow.spacing = 4
        for (index, title) in ["全部", "文本", "图片", "文件", "收藏"].enumerated() {
            let button = FilterPill(title: title, target: self, action: #selector(filterChanged(_:)))
            button.tag = index
            button.setAccessibilityLabel("筛选：\(title)")
            filterButtons.append(button)
            pillRow.addArrangedSubview(button)
            button.widthAnchor.constraint(equalToConstant: 46).isActive = true
            button.heightAnchor.constraint(equalToConstant: 25).isActive = true
        }
        updateFilterSelection()
        let privacyIcon = symbolImage("lock", size: 10, color: ShelfColors.tertiary)
        let privacyRow = NSStackView(views: [privacyIcon, label("仅存本机", size: 10.5, color: ShelfColors.tertiary)])
        privacyRow.orientation = .horizontal
        privacyRow.spacing = 4
        privacyIcon.widthAnchor.constraint(equalToConstant: 11).isActive = true
        privacyIcon.heightAnchor.constraint(equalToConstant: 12).isActive = true

        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.delegate = self
        splitView.setAccessibilityLabel("拖动分隔线调整历史列表和内容预览宽度")
        listPane.frame = NSRect(x: 0, y: 0, width: Self.defaultListWidth, height: 376)
        previewHost.frame = NSRect(x: Self.defaultListWidth + 1, y: 0, width: 720 - Self.defaultListWidth - 1, height: 376)
        previewHost.wantsLayer = true
        previewHost.layer?.backgroundColor = ShelfColors.preview.cgColor
        splitView.addSubview(listPane)
        splitView.addSubview(previewHost)

        let settings = ToolbarIconButton(symbol: "gearshape", title: "设置 · ⌘,", target: self, action: #selector(openSettings))
        let footerSeparator = divider()
        footerLabel.font = .systemFont(ofSize: 11)
        footerLabel.textColor = ShelfColors.tertiary
        footerLabel.lineBreakMode = .byTruncatingTail
        footerLabel.maximumNumberOfLines = 1
        footerLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        footerLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        copyButton.target = self
        copyButton.action = #selector(copySelected)
        copyButton.toolTip = "复制所选内容 · ⌘↩"
        copyButton.setAccessibilityLabel("复制所选内容")
        pasteButton.target = self
        pasteButton.action = #selector(pasteSelected)
        pasteButton.toolTip = "粘贴所选内容 · ↩"
        pasteButton.setAccessibilityLabel("粘贴所选内容")
        let resizeHint = symbolImage("arrow.down.right.and.arrow.up.left", size: 8, color: ShelfColors.tertiary.withAlphaComponent(0.6))
        resizeHint.toolTip = "拖动窗口边缘调整大小；拖动中间分隔线调整列宽"
        [searchIcon, searchField, shortcutBadge, close, searchDivider, pillRow, privacyRow, contentDivider, splitView, footerDivider, settings, footerSeparator, footerHints, footerLabel, copyButton, pasteButton, resizeHint].forEach { add($0, to: root) }
        NSLayoutConstraint.activate([
            searchIcon.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 23), searchIcon.topAnchor.constraint(equalTo: root.topAnchor, constant: 22),
            searchIcon.widthAnchor.constraint(equalToConstant: 18), searchIcon.heightAnchor.constraint(equalToConstant: 18),
            searchField.leadingAnchor.constraint(equalTo: searchIcon.trailingAnchor, constant: 12), searchField.centerYAnchor.constraint(equalTo: searchIcon.centerYAnchor),
            searchField.heightAnchor.constraint(equalToConstant: 32), searchField.trailingAnchor.constraint(equalTo: shortcutBadge.leadingAnchor, constant: -18),
            shortcutBadge.trailingAnchor.constraint(equalTo: close.leadingAnchor, constant: -14), shortcutBadge.centerYAnchor.constraint(equalTo: searchIcon.centerYAnchor),
            shortcutBadge.heightAnchor.constraint(equalToConstant: 22),
            close.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -19), close.centerYAnchor.constraint(equalTo: searchIcon.centerYAnchor),
            close.widthAnchor.constraint(equalToConstant: 28), close.heightAnchor.constraint(equalToConstant: 28),
            searchDivider.topAnchor.constraint(equalTo: root.topAnchor, constant: 61), searchDivider.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            searchDivider.trailingAnchor.constraint(equalTo: root.trailingAnchor), searchDivider.heightAnchor.constraint(equalToConstant: 1),
            pillRow.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 19), pillRow.topAnchor.constraint(equalTo: searchDivider.bottomAnchor, constant: 7),
            privacyRow.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -22), privacyRow.centerYAnchor.constraint(equalTo: pillRow.centerYAnchor),
            contentDivider.leadingAnchor.constraint(equalTo: root.leadingAnchor), contentDivider.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            contentDivider.topAnchor.constraint(equalTo: searchDivider.bottomAnchor, constant: 39), contentDivider.heightAnchor.constraint(equalToConstant: 1),
            splitView.topAnchor.constraint(equalTo: contentDivider.bottomAnchor), splitView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            splitView.trailingAnchor.constraint(equalTo: root.trailingAnchor), splitView.bottomAnchor.constraint(equalTo: footerDivider.topAnchor),
            footerDivider.leadingAnchor.constraint(equalTo: root.leadingAnchor), footerDivider.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            footerDivider.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -48), footerDivider.heightAnchor.constraint(equalToConstant: 1),
            settings.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16), settings.centerYAnchor.constraint(equalTo: pasteButton.centerYAnchor),
            settings.widthAnchor.constraint(equalToConstant: 28), settings.heightAnchor.constraint(equalToConstant: 28),
            footerSeparator.leadingAnchor.constraint(equalTo: settings.trailingAnchor, constant: 10), footerSeparator.centerYAnchor.constraint(equalTo: settings.centerYAnchor), footerSeparator.widthAnchor.constraint(equalToConstant: 1), footerSeparator.heightAnchor.constraint(equalToConstant: 14),
            footerHints.leadingAnchor.constraint(equalTo: footerSeparator.trailingAnchor, constant: 14), footerHints.centerYAnchor.constraint(equalTo: settings.centerYAnchor), footerHints.heightAnchor.constraint(equalToConstant: 26), footerHints.widthAnchor.constraint(equalToConstant: 160),
            footerLabel.leadingAnchor.constraint(equalTo: footerHints.leadingAnchor), footerLabel.centerYAnchor.constraint(equalTo: pasteButton.centerYAnchor),
            footerLabel.trailingAnchor.constraint(equalTo: copyButton.leadingAnchor, constant: -16), footerLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 0),
            copyButton.trailingAnchor.constraint(equalTo: pasteButton.leadingAnchor, constant: -8), copyButton.centerYAnchor.constraint(equalTo: pasteButton.centerYAnchor),
            copyButton.widthAnchor.constraint(equalToConstant: 104), copyButton.heightAnchor.constraint(equalToConstant: 32),
            pasteButton.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20), pasteButton.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -8),
            pasteButton.widthAnchor.constraint(equalToConstant: 104), pasteButton.heightAnchor.constraint(equalToConstant: 32),
            resizeHint.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -4), resizeHint.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -3),
            resizeHint.widthAnchor.constraint(equalToConstant: 8), resizeHint.heightAnchor.constraint(equalToConstant: 8)
        ])
        buildList()
        root.layoutSubtreeIfNeeded()
        splitView.setPosition(Self.defaultListWidth, ofDividerAt: 0)
    }

    private func buildList() {
        countLabel.font = .systemFont(ofSize: 10.5, weight: .medium)
        countLabel.textColor = ShelfColors.tertiary
        [countLabel, listScroll, emptyList].forEach { add($0, to: listPane) }
        NSLayoutConstraint.activate([
            countLabel.leadingAnchor.constraint(equalTo: listPane.leadingAnchor, constant: 20), countLabel.topAnchor.constraint(equalTo: listPane.topAnchor, constant: 12),
            countLabel.trailingAnchor.constraint(lessThanOrEqualTo: listPane.trailingAnchor, constant: -12),
            listScroll.leadingAnchor.constraint(equalTo: listPane.leadingAnchor, constant: 8), listScroll.trailingAnchor.constraint(equalTo: listPane.trailingAnchor, constant: -7),
            listScroll.topAnchor.constraint(equalTo: countLabel.bottomAnchor, constant: 8), listScroll.bottomAnchor.constraint(equalTo: listPane.bottomAnchor, constant: -6),
            emptyList.centerXAnchor.constraint(equalTo: listPane.centerXAnchor), emptyList.centerYAnchor.constraint(equalTo: listPane.centerYAnchor),
            emptyList.leadingAnchor.constraint(equalTo: listPane.leadingAnchor, constant: 20), emptyList.trailingAnchor.constraint(equalTo: listPane.trailingAnchor, constant: -20)
        ])
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("history"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = 52
        tableView.intercellSpacing = NSSize(width: 0, height: 2)
        tableView.backgroundColor = .clear
        tableView.selectionHighlightStyle = .regular
        tableView.focusRingType = .none
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(pasteSelected)
        tableView.setAccessibilityLabel("剪贴板历史记录")
        listScroll.documentView = tableView
        listScroll.drawsBackground = false
        listScroll.hasVerticalScroller = true
        listScroll.hasHorizontalScroller = false
        listScroll.autohidesScrollers = true
        listScroll.horizontalScrollElasticity = .none
        let emptyIcon = symbolImage("tray", size: 27, color: ShelfColors.tertiary.withAlphaComponent(0.6))
        emptyTitle.font = .systemFont(ofSize: 13, weight: .medium)
        emptyTitle.textColor = ShelfColors.primary
        emptyTitle.alignment = .center
        emptyTitle.lineBreakMode = .byTruncatingTail
        emptyDetail.font = .systemFont(ofSize: 11)
        emptyDetail.textColor = ShelfColors.secondary
        emptyDetail.alignment = .center
        emptyList.orientation = .vertical
        emptyList.alignment = .centerX
        emptyList.spacing = 9
        [emptyIcon, emptyTitle, emptyDetail].forEach { emptyList.addArrangedSubview($0) }
        emptyIcon.heightAnchor.constraint(equalToConstant: 32).isActive = true
        emptyDetail.widthAnchor.constraint(equalTo: emptyList.widthAnchor).isActive = true
        emptyTitle.widthAnchor.constraint(lessThanOrEqualTo: emptyList.widthAnchor).isActive = true
    }

    // Preserve a useful list width as the window changes, including after divider drags.
    func splitView(_ splitView: NSSplitView, resizeSubviewsWithOldSize oldSize: NSSize) {
        guard splitView.subviews.count == 2 else { return }
        let available = max(0, splitView.bounds.width - splitView.dividerThickness)
        let left = min(max(splitView.subviews[0].frame.width, Self.minimumListWidth), max(Self.minimumListWidth, available - Self.minimumPreviewWidth))
        splitView.subviews[0].frame = NSRect(x: 0, y: 0, width: left, height: splitView.bounds.height)
        splitView.subviews[1].frame = NSRect(x: left + splitView.dividerThickness, y: 0, width: max(0, available - left), height: splitView.bounds.height)
    }
    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat { Self.minimumListWidth }
    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat { max(Self.minimumListWidth, splitView.bounds.width - splitView.dividerThickness - Self.minimumPreviewWidth) }
    func splitView(_ splitView: NSSplitView, canCollapseSubview subview: NSView) -> Bool { false }

    private func reload(selectedID: UUID?) {
        tableView.reloadData()
        countLabel.stringValue = paused ? "记录已暂停" : "\(items.count) 条记录"
        countLabel.textColor = paused ? .systemOrange : ShelfColors.tertiary
        let empty = items.isEmpty
        emptyList.isHidden = !empty
        listScroll.isHidden = empty
        let searching = !searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if searching {
            emptyTitle.stringValue = "没有匹配的记录"
            emptyDetail.stringValue = "试试其他关键词或分类。"
        } else if currentFilter == .pinned {
            emptyTitle.stringValue = "还没有收藏"
            emptyDetail.stringValue = "选中常用内容，按 ⌘P 收藏。"
        } else if currentFilter != .all {
            emptyTitle.stringValue = "这个分类还是空的"
            emptyDetail.stringValue = "复制相关内容后会显示在这里。"
        } else {
            emptyTitle.stringValue = "从一次复制开始"
            emptyDetail.stringValue = paused ? "记录已暂停，可在菜单栏中恢复。" : "复制文字、图片或文件，\n历史会自动保存在这里。"
        }
        if !empty {
            let row = selectedID.flatMap { id in items.firstIndex { $0.id == id } } ?? 0
            tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            tableView.scrollRowToVisible(row)
        } else { tableView.deselectAll(nil) }
        renderPreview()
    }
    func numberOfRows(in tableView: NSTableView) -> Int { items.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = HistoryCellView()
        cell.configure(item: items[row], position: row)
        return cell
    }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { HistoryRowView() }
    func tableViewSelectionDidChange(_ notification: Notification) { renderPreview() }
    func controlTextDidChange(_ obj: Notification) { emitQuery() }
    @objc private func filterChanged(_ sender: NSButton) {
        let values: [HistoryFilter] = [.all, .text, .images, .files, .pinned]
        currentFilter = values[max(0, min(sender.tag, values.count - 1))]
        updateFilterSelection()
        emitQuery()
    }
    private func updateFilterSelection() {
        let values: [HistoryFilter] = [.all, .text, .images, .files, .pinned]
        for (index, button) in filterButtons.enumerated() { button.setSelected(values[index] == currentFilter) }
    }
    private func emitQuery() { onQueryChanged?(searchField.stringValue, currentFilter) }

    private func renderPreview() {
        previewHost.subviews.forEach { $0.removeFromSuperview() }
        copyButton.isEnabled = selectedItem != nil
        pasteButton.isEnabled = selectedItem != nil
        guard let item = selectedItem else {
            let icon = symbolImage("doc.on.clipboard", size: 36, color: ShelfColors.tertiary.withAlphaComponent(0.35))
            let text = label("内容预览", size: 12, color: ShelfColors.tertiary)
            add(icon, to: previewHost); add(text, to: previewHost)
            NSLayoutConstraint.activate([
                icon.centerXAnchor.constraint(equalTo: previewHost.centerXAnchor), icon.centerYAnchor.constraint(equalTo: previewHost.centerYAnchor, constant: -16),
                icon.heightAnchor.constraint(equalToConstant: 45), text.centerXAnchor.constraint(equalTo: icon.centerXAnchor), text.topAnchor.constraint(equalTo: icon.bottomAnchor, constant: 10)
            ])
            return
        }
        let typeIcon = symbolImage(kindSymbol(item.kind), size: 12, color: ShelfColors.secondary)
        let captionText: String
        switch item.kind {
        case .text: captionText = "文本  ·  \(item.text.count) 个字符"
        case .files: captionText = "文件  ·  \(item.filePaths.count) 个文件"
        case .image: captionText = "图片"
        }
        let caption = label(captionText, size: 11, weight: .medium, color: ShelfColors.secondary)
        caption.lineBreakMode = .byTruncatingTail
        let pin = symbolButton(item.isPinned ? "pin.fill" : "pin", tooltip: item.isPinned ? "取消收藏 · ⌘P" : "收藏 · ⌘P", action: #selector(pinSelected))
        pin.contentTintColor = item.isPinned ? ShelfColors.accent : ShelfColors.tertiary
        let body = makePreviewBody(item)
        let metadata = NSStackView()
        metadata.orientation = .vertical
        metadata.alignment = .leading
        metadata.spacing = 7
        for row in [metadataRow("来源应用  \(sourceName(item))", "最近  \(formattedDate(item.lastCopiedAt))"), metadataRow("已复制  \(item.copyCount) 次", "保存位置  本机")] {
            metadata.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: metadata.widthAnchor).isActive = true
        }
        [typeIcon, caption, pin, body, metadata].forEach { add($0, to: previewHost) }
        NSLayoutConstraint.activate([
            typeIcon.leadingAnchor.constraint(equalTo: previewHost.leadingAnchor, constant: 20), typeIcon.topAnchor.constraint(equalTo: previewHost.topAnchor, constant: 17),
            typeIcon.widthAnchor.constraint(equalToConstant: 14), typeIcon.heightAnchor.constraint(equalToConstant: 14),
            caption.leadingAnchor.constraint(equalTo: typeIcon.trailingAnchor, constant: 7), caption.centerYAnchor.constraint(equalTo: typeIcon.centerYAnchor),
            caption.trailingAnchor.constraint(lessThanOrEqualTo: pin.leadingAnchor, constant: -8),
            pin.trailingAnchor.constraint(equalTo: previewHost.trailingAnchor, constant: -16), pin.centerYAnchor.constraint(equalTo: caption.centerYAnchor),
            pin.widthAnchor.constraint(equalToConstant: 23), pin.heightAnchor.constraint(equalToConstant: 23),
            body.leadingAnchor.constraint(equalTo: previewHost.leadingAnchor, constant: 18), body.trailingAnchor.constraint(equalTo: previewHost.trailingAnchor, constant: -18),
            body.topAnchor.constraint(equalTo: typeIcon.bottomAnchor, constant: 14), body.bottomAnchor.constraint(equalTo: metadata.topAnchor, constant: -16),
            metadata.leadingAnchor.constraint(equalTo: previewHost.leadingAnchor, constant: 21), metadata.trailingAnchor.constraint(equalTo: previewHost.trailingAnchor, constant: -21),
            metadata.bottomAnchor.constraint(equalTo: previewHost.bottomAnchor, constant: -17)
        ])
    }

    private func metadataRow(_ leftText: String, _ rightText: String) -> NSStackView {
        let left = label(leftText, size: 10, color: ShelfColors.tertiary), right = label(rightText, size: 10, color: ShelfColors.tertiary)
        for field in [left, right] {
            field.lineBreakMode = .byTruncatingMiddle
            field.maximumNumberOfLines = 1
            field.toolTip = field.stringValue
            field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        let row = NSStackView(views: [left, right])
        row.orientation = .horizontal
        row.spacing = 12
        row.distribution = .fillEqually
        return row
    }

    private func makePreviewBody(_ item: ClipboardItem) -> NSView {
        let card = NSView()
        card.wantsLayer = true
        card.layer?.backgroundColor = NSColor.white.cgColor
        card.layer?.cornerRadius = 10
        card.layer?.borderWidth = 1
        card.layer?.borderColor = ShelfColors.line.withAlphaComponent(0.7).cgColor
        card.layer?.masksToBounds = true
        if item.kind == .image, let name = item.imageFile, let image = NSImage(contentsOf: imageDirectory.appendingPathComponent(name)) {
            let imageView = NSImageView(image: image)
            imageView.imageScaling = .scaleProportionallyUpOrDown
            imageView.setAccessibilityLabel("剪贴板图片预览")
            add(imageView, to: card)
            constrainInset(imageView, to: card, by: 16)
            return card
        }
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.horizontalScrollElasticity = .none
        add(scroll, to: card)
        constrainInset(scroll, to: card, by: 16)
        if item.kind == .files {
            let stack = NSStackView()
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 6
            stack.translatesAutoresizingMaskIntoConstraints = false
            scroll.documentView = stack
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor), stack.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
                stack.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor)
            ])
            for path in item.filePaths {
                let row = FilePreviewRow(path: path)
                stack.addArrangedSubview(row)
                row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
                row.heightAnchor.constraint(equalToConstant: 52).isActive = true
            }
            return card
        }
        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 350, height: 100))
        text.isEditable = false
        text.isSelectable = true
        text.isRichText = false
        text.drawsBackground = false
        text.textColor = ShelfColors.primary
        text.font = .systemFont(ofSize: 14)
        text.textContainerInset = NSSize(width: 0, height: 1)
        text.isHorizontallyResizable = false
        text.isVerticallyResizable = true
        text.minSize = NSSize(width: 0, height: 0)
        text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        text.autoresizingMask = [.width]
        text.textContainer?.lineFragmentPadding = 0
        text.textContainer?.containerSize = NSSize(width: 350, height: CGFloat.greatestFiniteMagnitude)
        text.textContainer?.widthTracksTextView = true
        text.string = item.kind == .image ? "图片预览暂不可用" : item.text
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 5
        paragraph.lineBreakMode = .byWordWrapping
        text.textStorage?.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: (text.string as NSString).length))
        text.setAccessibilityLabel("剪贴板完整内容")
        scroll.documentView = text
        return card
    }
    private func resetFooter() {
        footerLabel.stringValue = ""
        footerLabel.textColor = ShelfColors.tertiary
        footerLabel.toolTip = nil
        footerLabel.isHidden = true
        footerHints.isHidden = false
    }
    private func handleKey(_ event: NSEvent) -> Bool {
        if let editor = window?.firstResponder as? NSTextView, editor.hasMarkedText() { return false }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let command = modifiers.contains(.command)
        if command, let digit = Int(event.charactersIgnoringModifiers ?? ""), (1...9).contains(digit), items.indices.contains(digit - 1) {
            onChoose?(items[digit - 1], true)
            return true
        }
        if command, event.charactersIgnoringModifiers?.lowercased() == "p" { pinSelected(); return true }
        if command, event.charactersIgnoringModifiers == "," { openSettings(); return true }
        if command, event.keyCode == 51 || event.keyCode == 117 { deleteSelected(); return true }
        switch event.keyCode {
        case 53: dismiss(); return true
        case 36, 76: command ? copySelected() : pasteSelected(); return true
        case 125: moveSelection(by: 1); return true
        case 126: moveSelection(by: -1); return true
        default: return false
        }
    }
    private func moveSelection(by amount: Int) {
        guard !items.isEmpty else { return }
        let row = min(items.count - 1, max(0, tableView.selectedRow + amount))
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        tableView.scrollRowToVisible(row)
    }
    @objc private func pasteSelected() { if let item = selectedItem { onChoose?(item, false) } }
    @objc private func copySelected() { if let item = selectedItem { onChoose?(item, true) } }
    @objc private func pinSelected() { if let item = selectedItem { onPin?(item.id) } }
    @objc private func deleteSelected() { if let item = selectedItem { onDelete?(item.id) } }
    @objc private func closePanel() { dismiss() }
    @objc private func openSettings() { onOpenSettings?() }
    private func symbolButton(_ symbol: String, tooltip: String, action: Selector) -> NSButton {
        let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip) ?? NSImage(), target: self, action: action)
        button.isBordered = false
        button.contentTintColor = ShelfColors.tertiary
        button.toolTip = tooltip
        button.setAccessibilityLabel(tooltip)
        return button
    }
}

@MainActor
private final class ClipboardHistoryPanel: NSPanel {
    var keyHandler: ((NSEvent) -> Bool)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, keyHandler?(event) == true { return }
        super.sendEvent(event)
    }
}

@MainActor
private final class FilterPill: NSButton {
    override init(frame frameRect: NSRect) { super.init(frame: frameRect) }
    convenience init(title: String, target: AnyObject?, action: Selector?) {
        self.init(frame: .zero)
        self.title = title
        self.target = target
        self.action = action
        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = 6
        font = .systemFont(ofSize: 11.5, weight: .medium)
        focusRingType = .none
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func setSelected(_ selected: Bool) {
        layer?.backgroundColor = (selected ? ShelfColors.selection : .clear).cgColor
        attributedTitle = NSAttributedString(string: title, attributes: [.font: NSFont.systemFont(ofSize: 11.5, weight: selected ? .medium : .regular), .foregroundColor: selected ? ShelfColors.accent : ShelfColors.secondary])
        setAccessibilityValue(selected ? 1 : 0)
    }
}

@MainActor
private final class HistoryRowView: NSTableRowView {
    override var isEmphasized: Bool { get { true } set {} }
    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }
    override func drawSelection(in dirtyRect: NSRect) {
        ShelfColors.selection.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 0), xRadius: 7, yRadius: 7).fill()
    }
}

@MainActor
private final class HistoryCellView: NSTableCellView {
    func configure(item: ClipboardItem, position: Int) {
        let icon = symbolImage(kindSymbol(item.kind), size: 18, color: ShelfColors.secondary)
        let title = label(item.title.isEmpty ? "空白内容" : item.title, size: 13, color: ShelfColors.primary)
        title.maximumNumberOfLines = 1
        title.lineBreakMode = .byTruncatingTail
        let metadata = label("\(sourceName(item)) · \(relativeDate(item.lastCopiedAt))", size: 10.5, color: ShelfColors.tertiary)
        metadata.lineBreakMode = .byTruncatingTail
        let trailing = label(item.isPinned ? "" : (position < 9 ? "⌘\(position + 1)" : ""), size: 10, color: ShelfColors.tertiary)
        if position < 9 { trailing.toolTip = "复制并关闭 · ⌘\(position + 1)" }
        let pin = symbolImage("pin.fill", size: 10, color: ShelfColors.accent)
        pin.isHidden = !item.isPinned
        [icon, title, metadata, trailing, pin].forEach { add($0, to: self) }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 11), icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 22), icon.heightAnchor.constraint(equalToConstant: 22),
            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10), title.topAnchor.constraint(equalTo: topAnchor, constant: 9),
            title.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -35),
            metadata.leadingAnchor.constraint(equalTo: title.leadingAnchor), metadata.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 4), metadata.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            trailing.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10), trailing.centerYAnchor.constraint(equalTo: centerYAnchor),
            pin.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -11), pin.centerYAnchor.constraint(equalTo: centerYAnchor), pin.widthAnchor.constraint(equalToConstant: 10), pin.heightAnchor.constraint(equalToConstant: 12)
        ])
        setAccessibilityLabel("\(item.title)，\(metadata.stringValue)\(item.isPinned ? "，已收藏" : "")")
    }
}

@MainActor
private final class FilePreviewRow: NSView {
    init(path: String) {
        super.init(frame: .zero)
        let icon = NSImageView(image: NSWorkspace.shared.icon(forFile: path))
        let name = label(URL(fileURLWithPath: path).lastPathComponent, size: 12, color: ShelfColors.primary)
        name.lineBreakMode = .byTruncatingMiddle
        name.isSelectable = true
        let location = label((path as NSString).deletingLastPathComponent, size: 10, color: ShelfColors.tertiary)
        location.lineBreakMode = .byTruncatingMiddle
        location.isSelectable = true
        [icon, name, location].forEach { add($0, to: self) }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor), icon.centerYAnchor.constraint(equalTo: centerYAnchor), icon.widthAnchor.constraint(equalToConstant: 27), icon.heightAnchor.constraint(equalToConstant: 27),
            name.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 9), name.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2), name.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            location.leadingAnchor.constraint(equalTo: name.leadingAnchor), location.trailingAnchor.constraint(equalTo: name.trailingAnchor), location.topAnchor.constraint(equalTo: name.bottomAnchor, constant: 4)
        ])
        toolTip = path
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

@MainActor
private enum ShelfColors {
    static let surface = NSColor(calibratedRed: 251 / 255, green: 252 / 255, blue: 253 / 255, alpha: 1)
    static let preview = NSColor(calibratedRed: 245 / 255, green: 246 / 255, blue: 248 / 255, alpha: 1)
    static let primary = NSColor(calibratedRed: 38 / 255, green: 48 / 255, blue: 61 / 255, alpha: 1)
    static let secondary = NSColor(calibratedRed: 89 / 255, green: 101 / 255, blue: 119 / 255, alpha: 1)
    static let tertiary = NSColor(calibratedRed: 104 / 255, green: 116 / 255, blue: 132 / 255, alpha: 1)
    static let accent = NSColor(calibratedRed: 46 / 255, green: 107 / 255, blue: 225 / 255, alpha: 1)
    static let selection = NSColor(calibratedRed: 230 / 255, green: 239 / 255, blue: 255 / 255, alpha: 1)
    static let line = NSColor(calibratedRed: 225 / 255, green: 229 / 255, blue: 235 / 255, alpha: 1)
    static let keycap = NSColor(calibratedRed: 238 / 255, green: 241 / 255, blue: 245 / 255, alpha: 1)
}

@MainActor
private func add(_ view: NSView, to parent: NSView) {
    view.translatesAutoresizingMaskIntoConstraints = false
    parent.addSubview(view)
}
@MainActor
private func constrainInset(_ view: NSView, to parent: NSView, by inset: CGFloat) {
    NSLayoutConstraint.activate([
        view.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: inset), view.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -inset),
        view.topAnchor.constraint(equalTo: parent.topAnchor, constant: inset), view.bottomAnchor.constraint(equalTo: parent.bottomAnchor, constant: -inset)
    ])
}
@MainActor
private func label(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor = .labelColor) -> NSTextField {
    let field = NSTextField(labelWithString: text)
    field.font = .systemFont(ofSize: size, weight: weight)
    field.textColor = color
    return field
}
@MainActor
private func symbolImage(_ name: String, size: CGFloat, color: NSColor) -> NSImageView {
    let image = NSImageView(image: NSImage(systemSymbolName: name, accessibilityDescription: nil) ?? NSImage())
    image.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: size, weight: .regular)
    image.contentTintColor = color
    image.imageScaling = .scaleProportionallyDown
    return image
}
@MainActor
private func divider() -> NSView {
    let view = NSView()
    view.wantsLayer = true
    view.layer?.backgroundColor = ShelfColors.line.withAlphaComponent(0.7).cgColor
    return view
}
private func kindSymbol(_ kind: ClipKind) -> String {
    switch kind { case .text: return "text.alignleft"; case .image: return "photo"; case .files: return "folder" }
}
private func sourceName(_ item: ClipboardItem) -> String { item.sourceApp.isEmpty ? "剪贴板" : item.sourceApp }
private func relativeDate(_ date: Date) -> String {
    let seconds = max(0, Int(Date().timeIntervalSince(date)))
    if seconds < 60 { return "刚刚" }
    if seconds < 3_600 { return "\(seconds / 60) 分钟前" }
    if seconds < 86_400 { return "\(seconds / 3_600) 小时前" }
    if seconds < 604_800 { return "\(seconds / 86_400) 天前" }
    return formattedDate(date)
}
private func formattedDate(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "zh_CN")
    formatter.dateFormat = "M/d HH:mm"
    return formatter.string(from: date)
}
