import AppKit
import Carbon
import ClipCore
import Foundation

/// Integration checks use a private named pasteboard and disposable app data only.
@MainActor
enum PlatformChecks {
    static func runUI() -> Int32 {
        let name = "OtterClip.LayoutChecks.\(UUID().uuidString)"
        defer { NSWindow.removeFrame(usingName: name) }
        let controller = HistoryPanelController(frameAutosaveName: name)
        guard let window = controller.window, let content = window.contentView else { return 1 }
        var failures = 0
        var total = 0
        func check(_ label: String, _ value: Bool) {
            total += 1
            if value { print("PASS \(label)") }
            else { failures += 1; fputs("FAIL \(label)\n", stderr) }
        }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        check("native window resizing is enabled", window.styleMask.contains(.resizable))
        check("default window is 720 points wide", abs(content.bounds.width - 720) < 1)
        content.layoutSubtreeIfNeeded()
        if let split = descendants(content).compactMap({ $0 as? NSSplitView }).first {
            check("default history list has a wider 360 point column", abs(split.subviews[0].frame.width - 360) < 2)
        }
        let constrained = controller.windowWillResize(window, to: NSSize(width: 100, height: 100))
        check("user resizing respects minimum usable dimensions", constrained.width >= 640 && constrained.height >= 460)
        window.setContentSize(NSSize(width: 760, height: 540))
        content.layoutSubtreeIfNeeded()
        window.saveFrame(usingName: name)
        window.setFrameAutosaveName("")
        let restored = HistoryPanelController(frameAutosaveName: name)
        check("window size is restored by a new controller", abs((restored.window?.contentView?.bounds.width ?? 0) - 760) < 1)
        window.setContentSize(NSSize(width: 640, height: 460))
        content.layoutSubtreeIfNeeded()
        if let split = descendants(content).compactMap({ $0 as? NSSplitView }).first, split.subviews.count == 2 {
            check("minimum window keeps both columns usable", split.subviews[0].frame.width >= 300 && split.subviews[1].frame.width >= 300)
            split.setPosition(330, ofDividerAt: 0)
            content.layoutSubtreeIfNeeded()
            check("split divider changes the list width", abs(split.subviews[0].frame.width - 330) < 2)
            window.setContentSize(NSSize(width: 960, height: 640))
            content.layoutSubtreeIfNeeded()
            check("expanded window gives remaining space to preview", split.subviews[1].frame.width > 600)
        } else { check("native split view exists", false) }
        var selectedFilter: HistoryFilter?
        controller.onQueryChanged = { _, filter in selectedFilter = filter }
        if let search = descendants(content).compactMap({ $0 as? NSSearchField }).first {
            let focused = window.makeFirstResponder(search)
            if let editor = window.firstResponder as? NSTextView {
                editor.insertText("对齐检查", replacementRange: NSRange(location: 0, length: (editor.string as NSString).length))
                check("search field remains editable and accepts input", focused && search.stringValue == "对齐检查")
            } else { check("search field creates its native field editor", false) }
            window.makeFirstResponder(nil)
        } else { check("native search field exists", false) }
        let buttons = descendants(content).compactMap { $0 as? NSButton }
        buttons.first { $0.title == "文本" }?.performClick(nil)
        check("filter buttons still dispatch their action", selectedFilter == .text)
        controller.update(items: [])
        let actions = buttons.filter { $0.title.hasPrefix("复制") || $0.title.hasPrefix("粘贴") }
        check("empty history disables copy and paste", actions.count == 2 && actions.allSatisfy { !$0.isEnabled })
        restored.window?.setFrameAutosaveName("")
        runQuickCopyUI(check: check)
        runPasteReadinessChecks(check: check)
        runPastePermissionPromptChecks(check: check)

        let settingsDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OtterClipSettingsChecks-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: settingsDirectory) }
        do {
            try FileManager.default.createDirectory(at: settingsDirectory, withIntermediateDirectories: true)
            let preferences = PreferencesStore(directory: settingsDirectory)
            let settings = SettingsWindowController(store: preferences, directory: settingsDirectory)
            settings.show()
            defer { settings.window?.close() }
            if let settingsWindow = settings.window, let settingsContent = settingsWindow.contentView {
                func visibleSettingsViews() -> [NSView] {
                    descendants(settingsContent).filter { !$0.isHiddenOrHasHiddenAncestor }
                }
                func popups() -> [NSPopUpButton] { visibleSettingsViews().compactMap { $0 as? NSPopUpButton } }
                func captureSwitches() -> [NSSwitch] { visibleSettingsViews().compactMap { $0 as? NSSwitch } }
                func excludedEditor() -> NSTextView? { visibleSettingsViews().compactMap { $0 as? NSTextView }.first }
                check("settings use a native three-pane toolbar", settingsWindow.toolbar != nil && SettingsPane.allCases.count == 3)
                let settingsTopEdge = settingsWindow.frame.maxY
                for pane in SettingsPane.allCases {
                    settings.selectPane(pane)
                    settingsContent.layoutSubtreeIfNeeded()
                    check("settings toolbar switches to \(pane.rawValue)", settings.selectedPane == pane)
                    check("settings \(pane.rawValue) keeps the toolbar top edge stationary", abs(settingsWindow.frame.maxY - settingsTopEdge) < 1)
                    let visibleControls = visibleSettingsViews().filter { $0 is NSControl || $0 is NSScrollView }
                    let fits = visibleControls.allSatisfy { view in
                        let rect = view.convert(view.bounds, to: settingsContent)
                        return rect.minX >= -1 && rect.maxX <= settingsContent.bounds.width + 1
                            && rect.minY >= -1 && rect.maxY <= settingsContent.bounds.height + 1
                    }
                    check("settings \(pane.rawValue) fits its compact content area",
                          abs(settingsContent.bounds.width - 540) < 1 && abs(settingsContent.bounds.height - pane.contentHeight) < 1 && fits)
                }

                settings.selectPane(.general)
                let shortcutTitles = GlobalHotKey.choices.map(\.title)
                let shortcutPopup = popups().first { $0.itemTitles == shortcutTitles }
                let historyPopup = popups().first { $0 !== shortcutPopup }
                shortcutPopup?.selectItem(at: 0)
                if let historyPopup { historyPopup.selectItem(at: historyPopup.numberOfItems - 1) }
                let expectedLimit = historyPopup?.titleOfSelectedItem.flatMap { Int($0.filter { $0.isNumber }) }
                check("general settings expose shortcut and capacity controls", shortcutPopup != nil && historyPopup != nil && expectedLimit != nil)

                settings.selectPane(.capture)
                let switches = captureSwitches()
                for control in switches { control.state = .off }
                check("capture settings expose the three independent switches", switches.count == 3)

                settings.selectPane(.privacy)
                let fixture = "com.example.Private\ncom.example.Editor"
                excludedEditor()?.string = fixture
                settings.selectPane(.general)
                check("unsaved general edits survive changing panes",
                      popups().first { $0.itemTitles == shortcutTitles }?.indexOfSelectedItem == 0
                      && popups().first { $0.itemTitles != shortcutTitles }?.titleOfSelectedItem == historyPopup?.titleOfSelectedItem)
                settings.selectPane(.capture)
                check("unsaved capture edits survive changing panes", captureSwitches().count == 3 && captureSwitches().allSatisfy { $0.state == .off })
                settings.selectPane(.privacy)
                check("unsaved privacy edits survive changing panes", excludedEditor()?.string == fixture)

                var savedNotifications = 0
                settings.onChanged = { savedNotifications += 1 }
                let save = visibleSettingsViews().compactMap { $0 as? NSButton }.first { $0.title == "保存设置" }
                save?.performClick(nil)
                let reloaded = PreferencesStore(directory: settingsDirectory)
                check("saving persists edits from all settings panes",
                      save != nil && savedNotifications == 1 && preferences.lastError == nil
                      && reloaded.value.hotKeyIndex == 0 && reloaded.value.historyLimit == expectedLimit
                      && !reloaded.value.captureImages && !reloaded.value.captureFiles
                      && !reloaded.value.ignorePasswordApps && reloaded.value.excludedApps == fixture)

                settings.selectPane(.general)
                shortcutPopup?.selectItem(at: 1)
                var restartCalls = 0
                var savedBeforeRestart = false
                settings.onRestart = {
                    restartCalls += 1
                    savedBeforeRestart = PreferencesStore(directory: settingsDirectory).value.hotKeyIndex == 1
                }
                let restart = visibleSettingsViews().compactMap { $0 as? NSButton }.first { $0.title == "重新启动" }
                restart?.performClick(nil)
                check("restart saves pending settings before requesting a relaunch",
                      restart != nil && restartCalls == 1 && savedBeforeRestart && preferences.lastError == nil)

                let preferencesFile = settingsDirectory.appendingPathComponent("preferences.json")
                try FileManager.default.removeItem(at: preferencesFile)
                try FileManager.default.createDirectory(at: preferencesFile, withIntermediateDirectories: false)
                shortcutPopup?.selectItem(at: 0)
                restart?.performClick(nil)
                check("a failed settings save keeps the app running instead of restarting",
                      restartCalls == 1 && preferences.lastError != nil && preferences.value.hotKeyIndex == 1)
            } else { check("settings create their compact native window", false) }
        } catch {
            check("settings checks create their disposable data directory", false)
            fputs("Settings check error: \(error.localizedDescription)\n", stderr)
        }
        print("\(total - failures)/\(total) UI component checks passed (own views only)")
        return failures == 0 ? 0 : 1
    }

    /// Send events only to this app's own window, with clipboard writes isolated
    /// to a private board. The callback deliberately never posts paste events or
    /// checks Accessibility permission, including when Return selects paste.
    private static func runQuickCopyUI(check: (String, Bool) -> Void) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OtterClipQuickCopyChecks-\(UUID().uuidString)", isDirectory: true)
        let board = NSPasteboard.withUniqueName()
        let controller = HistoryPanelController(frameAutosaveName: "")
        defer {
            controller.dismiss()
            controller.window?.close()
            board.releaseGlobally()
            try? FileManager.default.removeItem(at: directory)
        }
        guard let window = controller.window else {
            check("quick copy creates its own test window", false)
            return
        }
        do {
            let repository = try HistoryRepository(directory: directory)
            let fixtures = (1...10).map { index in
                ClipboardItem(kind: .text, text: "快捷复制测试 \(index)",
                              sourceApp: index.isMultiple(of: 3) ? "筛选应用" : "测试应用",
                              lastCopiedAt: Date(timeIntervalSince1970: Double(index)),
                              fingerprint: "quick-copy-\(index)")
            }
            for item in fixtures { repository.insert(item) }
            let all = repository.search(query: "", filter: .all)
            let filtered = repository.search(query: "筛选应用", filter: .text)
            guard all.count == 10, filtered.count == 3, repository.lastError == nil else {
                check("quick copy fixtures persist in the disposable repository", false)
                return
            }
            var choices: [(id: UUID, copyOnly: Bool)] = []
            var dismissals = 0
            var writeError: Error?
            controller.onDismiss = { dismissals += 1 }
            controller.onChoose = { [weak controller] item, copyOnly in
                guard let controller else { return }
                choices.append((item.id, copyOnly))
                do {
                    _ = try PasteController.write(item, repository: repository, pasteboard: board)
                    controller.dismiss()
                } catch {
                    writeError = error
                    controller.showNotice(error.localizedDescription)
                }
            }
            func show(_ items: [ClipboardItem]) {
                choices = []
                dismissals = 0
                writeError = nil
                controller.show(items: items, imageDirectory: directory.appendingPathComponent("Images"), isPaused: false)
            }
            func send(_ characters: String, keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> Bool {
                guard let event = NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: modifiers,
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                    context: nil, characters: characters, charactersIgnoringModifiers: characters,
                    isARepeat: false, keyCode: keyCode
                ) else { return false }
                window.sendEvent(event)
                return true
            }
            func copied(_ item: ClipboardItem) -> Bool {
                choices.count == 1 && choices.first?.id == item.id && choices.first?.copyOnly == true
                    && writeError == nil && board.string(forType: .string) == item.text
                    && dismissals == 1 && !window.isVisible
            }

            show(all)
            let sentFirst = send("1", keyCode: UInt16(kVK_ANSI_1), modifiers: .command)
            check("Command 1 copies the first visible result and closes the panel", sentFirst && copied(all[0]))

            show(all)
            let sentNinth = send("9", keyCode: UInt16(kVK_ANSI_9), modifiers: .command)
            check("Command 9 copies the ninth visible result and closes the panel", sentNinth && copied(all[8]))

            show(all)
            controller.update(items: filtered)
            let sentFiltered = send("1", keyCode: UInt16(kVK_ANSI_1), modifiers: .command)
            check("numeric quick copy follows the current filtered result order", sentFiltered && filtered.count == 3 && copied(filtered[0]) && filtered[0].id != all[0].id)

            show(filtered)
            let changeCount = board.changeCount
            let sentOutside = send("9", keyCode: UInt16(kVK_ANSI_9), modifiers: .command)
            check("out-of-range numeric shortcut leaves the panel and clipboard unchanged",
                  sentOutside && choices.isEmpty && dismissals == 0 && window.isVisible && board.changeCount == changeCount)

            show(filtered)
            let sentReturn = send("\r", keyCode: UInt16(kVK_Return), modifiers: [])
            check("Return dispatches the paste action for the selected result (no cross-app paste)",
                  sentReturn && choices.count == 1 && choices.first?.id == filtered[0].id && choices.first?.copyOnly == false)

            show(filtered)
            let sentCommandReturn = send("\r", keyCode: UInt16(kVK_Return), modifiers: .command)
            check("Command Return retains copy-only and closes after writing", sentCommandReturn && copied(filtered[0]))
        } catch {
            check("quick copy checks create their disposable history repository", false)
            fputs("Quick copy check error: \(error.localizedDescription)\n", stderr)
        }
    }

    /// Exercise the same readiness decision used by production paste without
    /// querying system permissions, reading the real clipboard, or posting events.
    private static func runPasteReadinessChecks(check: (String, Bool) -> Void) {
        let granted = PasteController.AccessStatus(accessibility: true, eventPosting: true)
        func step(currentChangeCount: Int = 41, targetTerminated: Bool = false,
                  isFrontmost: Bool = true, physicalModifiers: CGEventFlags = [],
                  access: PasteController.AccessStatus? = nil, attempt: Int = 0) -> PasteController.PasteStep {
            PasteController.nextStep(expectedChangeCount: 41, currentChangeCount: currentChangeCount,
                                     targetTerminated: targetTerminated, isFrontmost: isFrontmost,
                                     physicalModifiers: physicalModifiers, access: access ?? granted,
                                     attempt: attempt)
        }

        check("automatic paste requires Accessibility permission",
              step(access: .init(accessibility: false, eventPosting: true)) == .fail(.permissionRequired))
        check("automatic paste requires event-posting permission",
              step(access: .init(accessibility: true, eventPosting: false)) == .fail(.permissionRequired))
        check("automatic paste sends only when permissions, focus and released modifiers are ready", step() == .send)
        check("automatic paste waits for target focus to return", step(isFrontmost: false) == .wait)
        check("automatic paste reports target focus timeout",
              step(isFrontmost: false, attempt: 12) == .fail(.targetChanged))
        check("automatic paste waits for the physical Command key to be released", step(physicalModifiers: .maskCommand) == .wait)
        check("automatic paste reports a held shortcut modifier timeout",
              step(physicalModifiers: .maskCommand, attempt: 24) == .fail(.modifiersHeld))
        check("automatic paste cancels a changed clipboard immediately despite unsettled focus",
              step(currentChangeCount: 42, isFrontmost: false, physicalModifiers: .maskCommand) == .fail(.clipboardChanged))
        check("automatic paste cancels an exited target immediately",
              step(targetTerminated: true, isFrontmost: false, physicalModifiers: .maskCommand) == .fail(.targetUnavailable))
        check("automatic paste does not mistake Caps Lock for a held shortcut modifier",
              step(physicalModifiers: .maskAlphaShift) == .send)
    }

    /// Exercise the real alert configuration and response routing with an injected
    /// presenter. No dialog is displayed, no permission API is called, and the
    /// clipboard fixture is confined to a private named board.
    private static func runPastePermissionPromptChecks(check: (String, Bool) -> Void) {
        let alert = PastePermissionPrompt.makeAlert()
        let explanation = alert.messageText + " " + alert.informativeText
        check("paste permission alert explicitly explains the unfinished automatic paste",
              explanation.contains("粘贴")
              && ["失败", "未完成", "无法"].contains { explanation.contains($0) })
        check("paste permission alert explains the permission cause and preserved copy",
              explanation.contains("辅助功能") && explanation.contains("已复制")
              && ["权限", "授权"].contains { explanation.contains($0) })
        check("paste permission alert offers authorization and a later option",
              alert.buttons.map(\.title) == ["前往授权", "稍后"])

        var authorizeCalls = 0
        var laterCalls = 0
        var callbacksWhilePresenting = false
        let authorizePrompt = PastePermissionPrompt(present: { _ in
            callbacksWhilePresenting = authorizeCalls != 0 || laterCalls != 0
            return .alertFirstButtonReturn
        })
        authorizePrompt.show(onAuthorize: { authorizeCalls += 1 }, onLater: { laterCalls += 1 })
        check("presenting permission guidance never authorizes or opens settings before a choice",
              !callbacksWhilePresenting)
        check("choosing authorization invokes only the authorization callback",
              authorizeCalls == 1 && laterCalls == 0)

        for (label, response) in [
            ("later", NSApplication.ModalResponse.alertSecondButtonReturn),
            ("cancel", .cancel),
            ("close", .abort)
        ] {
            var authorizeCalls = 0
            var laterCalls = 0
            let prompt = PastePermissionPrompt(present: { _ in response })
            prompt.show(onAuthorize: { authorizeCalls += 1 }, onLater: { laterCalls += 1 })
            check("permission prompt \(label) invokes only the later callback",
                  authorizeCalls == 0 && laterCalls == 1)
        }

        var presentations = 0
        var reentrantAuthorizeCalls = 0
        var reentrantLaterCalls = 0
        var prompt: PastePermissionPrompt!
        prompt = PastePermissionPrompt(present: { _ in
            presentations += 1
            if presentations == 1 {
                prompt.show(onAuthorize: { reentrantAuthorizeCalls += 1 },
                            onLater: { reentrantLaterCalls += 1 })
            }
            return .alertSecondButtonReturn
        })
        prompt.show(onAuthorize: { reentrantAuthorizeCalls += 1 },
                    onLater: { reentrantLaterCalls += 1 })
        check("a reentrant paste request does not present a second permission alert",
              presentations == 1 && reentrantAuthorizeCalls == 0 && reentrantLaterCalls == 1)
        prompt.show(onAuthorize: { reentrantAuthorizeCalls += 1 },
                    onLater: { reentrantLaterCalls += 1 })
        check("a dismissed permission prompt can be presented on a later paste attempt",
              presentations == 2 && reentrantAuthorizeCalls == 0 && reentrantLaterCalls == 2)

        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.clearContents()
        let fixture = "权限未开启时保留的复制内容 😀"
        let wroteFixture = board.setString(fixture, forType: .string)
        let originalChangeCount = board.changeCount
        let cancelPrompt = PastePermissionPrompt(present: { _ in .alertSecondButtonReturn })
        cancelPrompt.show(onAuthorize: {}, onLater: {})
        check("showing and cancelling permission guidance preserves the private clipboard",
              wroteFixture && board.changeCount == originalChangeCount && board.string(forType: .string) == fixture)
    }

    static func run() -> Int32 {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OtterClipPlatformChecks-\(UUID().uuidString)", isDirectory: true)
        let pasteboard = NSPasteboard.withUniqueName()
        defer {
            pasteboard.releaseGlobally()
            try? FileManager.default.removeItem(at: directory)
        }

        var total = 0
        var failures = 0
        func check(_ label: String, _ condition: Bool) {
            total += 1
            if condition {
                print("PASS \(label)")
            } else {
                failures += 1
                fputs("FAIL \(label)\n", stderr)
            }
        }

        func writeText(_ text: String, marker: NSPasteboard.PasteboardType? = nil) -> Bool {
            pasteboard.clearContents()
            let value = NSPasteboardItem()
            guard value.setString(text, forType: .string) else { return false }
            if let marker, !value.setData(Data(), forType: marker) { return false }
            return pasteboard.writeObjects([value])
        }

        do {
            let repository = try HistoryRepository(directory: directory)
            let preferences = PreferencesStore(directory: directory)
            let monitor = ClipboardMonitor(
                repository: repository, preferences: preferences,
                pasteboard: pasteboard, sourceProvider: { nil }, synchronousImages: true
            )
            var notifications = 0
            var issues: [String] = []
            monitor.onChange = { notifications += 1 }
            monitor.onIssue = { issues.append($0) }

            let originalText = "  \n第一行\t中文 😀\nsecond line\n "
            check("private pasteboard accepts fixture", writeText(originalText))
            monitor.poll()
            let originalID = repository.items.first?.id
            check("text captured without trimming or changing contents",
                  repository.items.count == 1 && repository.items.first?.kind == .text && repository.items.first?.text == originalText)
            check("unknown injected source is supported",
                  repository.items.first?.sourceApp == "未知应用" && repository.items.first?.sourceBundleID == nil)

            _ = writeText(originalText)
            monitor.poll()
            check("duplicate capture preserves identity and increases count",
                  repository.items.count == 1 && repository.items.first?.id == originalID && repository.items.first?.copyCount == 2)
            let notificationsAfterDuplicate = notifications
            monitor.poll()
            check("unchanged pasteboard is not captured twice",
                  repository.items.first?.copyCount == 2 && notifications == notificationsAfterDuplicate)

            _ = writeText("  \n\t \r\n")
            monitor.poll()
            check("whitespace-only text is ignored", repository.items.count == 1 && notifications == notificationsAfterDuplicate)

            preferences.value.isPaused = true
            _ = writeText("paused fixture")
            monitor.poll()
            check("paused capture ignores changed pasteboard", repository.items.count == 1 && notifications == notificationsAfterDuplicate)
            preferences.value.isPaused = false
            monitor.poll()
            check("resuming waits for a new copy", repository.items.count == 1 && notifications == notificationsAfterDuplicate)

            let ignoredMarkers: [(String, NSPasteboard.PasteboardType)] = [
                ("concealed", NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")),
                ("transient", NSPasteboard.PasteboardType("org.nspasteboard.TransientType")),
                ("auto-generated", NSPasteboard.PasteboardType("org.nspasteboard.AutoGeneratedType")),
                ("internal", ClipboardMonitor.internalType),
                ("1Password marker", NSPasteboard.PasteboardType("com.agilebits.onepassword"))
            ]
            for (label, marker) in ignoredMarkers {
                let wrote = writeText("private fixture \(label)", marker: marker)
                monitor.poll()
                check("\(label) clipboard value is ignored",
                      wrote && repository.items.count == 1 && notifications == notificationsAfterDuplicate)
            }

            guard let bitmap = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                isPlanar: false, colorSpaceName: .deviceRGB,
                bytesPerRow: 8, bitsPerPixel: 32
            ) else {
                throw NSError(domain: "OtterClip.PlatformChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not make image fixture"])
            }
            for y in 0..<2 {
                for x in 0..<2 {
                    bitmap.setColor(NSColor(calibratedRed: 0.2, green: 0.4, blue: 0.8, alpha: 1), atX: x, y: y)
                }
            }
            guard let png = bitmap.representation(using: .png, properties: [:]) else {
                throw NSError(domain: "OtterClip.PlatformChecks", code: 2, userInfo: [NSLocalizedDescriptionKey: "Could not encode image fixture"])
            }
            pasteboard.clearContents()
            let wroteImage = pasteboard.setData(png, forType: .png)
            monitor.poll()
            let image = repository.items.first { $0.kind == .image }
            let capturedImageData = try image.flatMap { repository.imageURL(for: $0) }.map { try Data(contentsOf: $0) }
            let capturedBitmap = capturedImageData.flatMap { NSBitmapImageRep(data: $0) }
            check("PNG image is captured with a persisted bitmap",
                  wroteImage && repository.items.count == 2 && image?.text == "2 × 2" && capturedBitmap?.pixelsWide == 2 && capturedBitmap?.pixelsHigh == 2)

            preferences.value.captureImages = false
            pasteboard.clearContents()
            let disabledImage = NSPasteboardItem()
            disabledImage.setData(png, forType: .png)
            disabledImage.setString("image textual fallback fixture", forType: .string)
            let wroteDisabledImage = pasteboard.writeObjects([disabledImage])
            monitor.poll()
            check("disabled images are ignored including their text fallback",
                  wroteDisabledImage && repository.items.count == 2 && repository.items.first { $0.kind == .image }?.copyCount == 1)
            preferences.value.captureImages = true
            pasteboard.clearContents()
            pasteboard.setData(png, forType: .png)
            monitor.poll()
            check("repeated PNG uses the existing image history entry",
                  repository.items.count == 2 && repository.items.first { $0.kind == .image }?.copyCount == 2)

            let firstFile = directory.appendingPathComponent("fixture 中文 file.txt")
            let secondFile = directory.appendingPathComponent("fixture-second.txt")
            try Data("first".utf8).write(to: firstFile)
            try Data("second".utf8).write(to: secondFile)
            pasteboard.clearContents()
            let wroteFiles = pasteboard.writeObjects([firstFile as NSURL, secondFile as NSURL])
            monitor.poll()
            let files = repository.items.first { $0.kind == .files }
            check("multiple file URLs are captured as original file paths",
                  wroteFiles && repository.items.count == 3 && files?.filePaths == [firstFile.path, secondFile.path])

            preferences.value.captureFiles = false
            pasteboard.clearContents()
            let disabledFile = NSPasteboardItem()
            disabledFile.setString(firstFile.absoluteString, forType: .fileURL)
            disabledFile.setString("file textual fallback fixture", forType: .string)
            let wroteDisabledFile = pasteboard.writeObjects([disabledFile])
            monitor.poll()
            check("disabled files are ignored including their text fallback",
                  wroteDisabledFile && repository.items.count == 3 && repository.items.first { $0.kind == .files }?.copyCount == 1)
            preferences.value.captureFiles = true

            var privacy = AppPreferences()
            privacy.excludedApps = ""
            check("known password apps are excluded by default",
                  !AppPreferences.passwordApps.isEmpty && AppPreferences.passwordApps.allSatisfy { privacy.excludes($0) })
            check("ordinary and unknown source apps remain eligible",
                  !privacy.excludes("com.apple.Safari") && !privacy.excludes(nil))
            privacy.ignorePasswordApps = false
            check("password app filtering follows the preference",
                  AppPreferences.passwordApps.allSatisfy { !privacy.excludes($0) })
            privacy.excludedApps = "  com.example.Private \n\n com.apple.Safari\n"
            check("additional excluded bundle IDs accept whitespace and newlines",
                  privacy.excludes("com.example.Private") && privacy.excludes("com.apple.Safari"))
            check("excluded bundle IDs use exact matching",
                  !privacy.excludes("com.example.Private.Other") && !privacy.excludes("com.example"))

            preferences.value = privacy
            preferences.save()
            let reloaded = PreferencesStore(directory: directory)
            check("privacy preferences persist in the disposable directory",
                  preferences.lastError == nil && !reloaded.value.ignorePasswordApps && reloaded.value.excludes("com.example.Private"))
            let defaults = AppPreferences()
            let defaultHotKey = GlobalHotKey.choices[defaults.hotKeyIndex]
            check("default shortcut is Option Command C",
                  defaultHotKey.title == "⌥⌘C" && defaultHotKey.keyCode == UInt32(kVK_ANSI_C) && defaultHotKey.modifiers == UInt32(optionKey | cmdKey))

            let migrationDirectory = directory.appendingPathComponent("shortcut-migration")
            try FileManager.default.createDirectory(at: migrationDirectory, withIntermediateDirectories: true)
            let migrationURL = migrationDirectory.appendingPathComponent("preferences.json")
            var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(AppPreferences())) as! [String: Any]
            legacy.removeValue(forKey: "shortcutSchemaVersion")
            legacy["hotKeyIndex"] = 0
            legacy["historyLimit"] = 500
            try JSONSerialization.data(withJSONObject: legacy).write(to: migrationURL)
            let migrated = PreferencesStore(directory: migrationDirectory)
            check("existing preferences migrate to the requested shortcut without losing history settings",
                  migrated.value.hotKeyIndex == 4 && migrated.value.historyLimit == 500 && migrated.value.shortcutSchemaVersion == 2 && migrated.lastError == nil)
            migrated.value.hotKeyIndex = 1
            migrated.save()
            let customShortcut = PreferencesStore(directory: migrationDirectory)
            check("later shortcut customizations survive relaunch", customShortcut.value.hotKeyIndex == 1)
            check("capture and persistence complete without issues", issues.isEmpty && repository.lastError == nil)

            // Exercise the actual background conversion path without the system clipboard.
            let asyncRepository = try HistoryRepository(directory: directory.appendingPathComponent("async"))
            let asyncPreferences = PreferencesStore(directory: directory.appendingPathComponent("async"))
            let asyncMonitor = ClipboardMonitor(repository: asyncRepository, preferences: asyncPreferences, pasteboard: pasteboard, sourceProvider: { nil })
            pasteboard.clearContents()
            pasteboard.setData(png, forType: .png)
            asyncMonitor.poll()
            let deadline = Date().addingTimeInterval(3)
            while asyncRepository.items.isEmpty && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
            check("background image processing commits captured PNG", asyncRepository.items.first?.kind == .image)
            let imageCountBeforeCancellation = asyncRepository.items.first?.copyCount
            pasteboard.clearContents()
            pasteboard.setData(png, forType: .png)
            asyncMonitor.poll()
            asyncMonitor.ignoreCurrentChange()
            RunLoop.current.run(until: Date().addingTimeInterval(0.15))
            check("cancelled image work cannot repopulate cleared or paused history", asyncRepository.items.first?.copyCount == imageCountBeforeCancellation)
        } catch {
            check("platform check setup and execution", false)
            fputs("Platform check error: \(error.localizedDescription)\n", stderr)
        }

        print("\(total - failures)/\(total) platform checks passed (private named pasteboard only)")
        return failures == 0 ? 0 : 1
    }
}
