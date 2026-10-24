import AppKit

@MainActor
final class PastePermissionPrompt {
    private let present: @MainActor (NSAlert) -> NSApplication.ModalResponse
    private var isPresenting = false

    init(present: @escaping @MainActor (NSAlert) -> NSApplication.ModalResponse = { alert in
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal()
    }) {
        self.present = present
    }

    static func makeAlert() -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "自动粘贴未完成"
        alert.informativeText = "内容已复制到剪贴板，但 OtterClip 尚未获得辅助功能或发送按键权限，无法自动粘贴到原应用。\n\n点击“前往授权”，在 macOS「系统设置 → 隐私与安全性 → 辅助功能」中允许 OtterClip。你也可以返回原输入框，按 ⌘V 手动粘贴。"
        alert.addButton(withTitle: "前往授权")
        alert.addButton(withTitle: "稍后").keyEquivalent = "\u{1b}"
        return alert
    }

    func show(onAuthorize: () -> Void, onLater: () -> Void) {
        guard !isPresenting else { return }
        isPresenting = true
        defer { isPresenting = false }

        let response = present(Self.makeAlert())
        if response == .alertFirstButtonReturn {
            onAuthorize()
        } else {
            onLater()
        }
    }
}
