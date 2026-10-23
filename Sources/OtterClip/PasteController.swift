import AppKit
import ApplicationServices
import Carbon
import ClipCore

@MainActor
enum PasteController {
    private static var generation: UInt64 = 0

    struct AccessStatus {
        let accessibility: Bool
        let eventPosting: Bool
        var canPaste: Bool { accessibility && eventPosting }
    }

    static var accessStatus: AccessStatus {
        AccessStatus(accessibility: AXIsProcessTrusted(), eventPosting: CGPreflightPostEventAccess())
    }

    static func requestAccess() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        if AXIsProcessTrusted(), !CGPreflightPostEventAccess() { _ = CGRequestPostEventAccess() }
    }

    enum PasteFailure: Error, Equatable {
        case permissionRequired, targetUnavailable, activationFailed, clipboardChanged, targetChanged, modifiersHeld, eventCreationFailed

        var message: String {
            switch self {
            case .permissionRequired: return "内容已复制，自动粘贴未获授权。请在辅助功能中允许当前这份 OtterClip。"
            case .targetUnavailable: return "内容已复制，原应用已不可用。请切换到输入框后按 ⌘V。"
            case .activationFailed: return "内容已复制，无法返回原应用。请切换到输入框后按 ⌘V。"
            case .clipboardChanged: return "剪贴板已变化，已取消自动粘贴，请重新选择。"
            case .targetChanged: return "内容已复制，原输入窗口未恢复焦点。请手动按 ⌘V。"
            case .modifiersHeld: return "内容已复制，快捷键尚未松开。请松开后按 ⌘V。"
            case .eventCreationFailed: return "内容已复制，无法生成粘贴按键。请手动按 ⌘V。"
            }
        }
    }

    enum PasteStep: Equatable {
        case wait, send, fail(PasteFailure)
    }

    static func nextStep(expectedChangeCount: Int, currentChangeCount: Int, targetTerminated: Bool, isFrontmost: Bool, physicalModifiers: CGEventFlags, access: AccessStatus, attempt: Int) -> PasteStep {
        guard currentChangeCount == expectedChangeCount else { return .fail(.clipboardChanged) }
        guard !targetTerminated else { return .fail(.targetUnavailable) }
        guard access.canPaste else { return .fail(.permissionRequired) }
        guard isFrontmost else { return attempt < 12 ? .wait : .fail(.targetChanged) }
        let held: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift]
        guard physicalModifiers.intersection(held).isEmpty else { return attempt < 24 ? .wait : .fail(.modifiersHeld) }
        return .send
    }

    static func write(_ item: ClipboardItem, repository: HistoryRepository, pasteboard: NSPasteboard = .general) throws -> Int {
        generation &+= 1
        let board = pasteboard
        // Validate every resource before replacing the current clipboard.
        var objects: [NSPasteboardWriting] = []
        switch item.kind {
        case .text:
            let object = NSPasteboardItem()
            object.setString(item.text, forType: .string)
            object.setString("1", forType: ClipboardMonitor.internalType)
            objects = [object]
        case .image:
            guard let url = repository.imageURL(for: item), let data = try? Data(contentsOf: url) else {
                throw PasteError.unavailable("这张图片已不可用，请删除这条记录。")
            }
            let object = NSPasteboardItem()
            object.setData(data, forType: .png)
            object.setString("1", forType: ClipboardMonitor.internalType)
            objects = [object]
        case .files:
            guard !item.filePaths.isEmpty, item.filePaths.allSatisfy({ FileManager.default.fileExists(atPath: $0) }) else {
                throw PasteError.unavailable("部分文件已被移动或删除，无法复制这条记录。")
            }
            objects = item.filePaths.map { URL(fileURLWithPath: $0) as NSURL }
        }
        board.clearContents()
        guard board.writeObjects(objects) else { throw PasteError.unavailable("写入剪贴板失败，请重试。") }
        return board.changeCount
    }

    static func paste(into target: NSRunningApplication?, expectedChangeCount: Int, onFailure: @escaping (PasteFailure) -> Void) {
        generation &+= 1
        let request = generation
        guard accessStatus.canPaste else { onFailure(.permissionRequired); return }
        guard let target, !target.isTerminated, target.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            onFailure(.targetUnavailable)
            return
        }
        if #available(macOS 14.0, *) { NSApp.yieldActivation(to: target) }
        guard target.activate(options: []) else {
            onFailure(.activationFailed)
            return
        }
        // Wait for physical shortcut modifiers to be released and focus to settle.
        sendWhenReady(target: target, expectedChangeCount: expectedChangeCount, request: request, attempt: 0, onFailure: onFailure)
    }

    private static func sendWhenReady(target: NSRunningApplication, expectedChangeCount: Int, request: UInt64, attempt: Int, onFailure: @escaping (PasteFailure) -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            guard request == generation else { return }
            let step = nextStep(
                expectedChangeCount: expectedChangeCount, currentChangeCount: NSPasteboard.general.changeCount,
                targetTerminated: target.isTerminated,
                isFrontmost: NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier,
                physicalModifiers: CGEventSource.flagsState(.hidSystemState), access: accessStatus, attempt: attempt
            )
            switch step {
            case .wait:
                sendWhenReady(target: target, expectedChangeCount: expectedChangeCount, request: request, attempt: attempt + 1, onFailure: onFailure)
                return
            case .fail(let failure): onFailure(failure); return
            case .send: break
            }
            guard let source = CGEventSource(stateID: .privateState),
                  let down = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false) else {
                onFailure(.eventCreationFailed)
                return
            }
            down.flags = .maskCommand
            up.flags = []
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
        }
    }

    enum PasteError: LocalizedError {
        case unavailable(String)
        var errorDescription: String? { switch self { case let .unavailable(message): return message } }
    }
}
