import AppKit
import Carbon

@MainActor
final class GlobalHotKey {
    struct Choice {
        let title: String
        let keyCode: UInt32
        let modifiers: UInt32
    }
    static let choices = [
        Choice(title: "⇧⌘V", keyCode: UInt32(kVK_ANSI_V), modifiers: UInt32(cmdKey | shiftKey)),
        Choice(title: "⌥⌘V", keyCode: UInt32(kVK_ANSI_V), modifiers: UInt32(cmdKey | optionKey)),
        Choice(title: "⌃⌥V", keyCode: UInt32(kVK_ANSI_V), modifiers: UInt32(controlKey | optionKey)),
        Choice(title: "⇧⌘Space", keyCode: UInt32(kVK_Space), modifiers: UInt32(cmdKey | shiftKey)),
        Choice(title: "⌥⌘C", keyCode: UInt32(kVK_ANSI_C), modifiers: UInt32(cmdKey | optionKey))
    ]
    var onTrigger: (() -> Void)?
    private var reference: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var handlerInstalled = false

    init() {
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, _, context in
            guard let context else { return OSStatus(eventNotHandledErr) }
            let owner = Unmanaged<GlobalHotKey>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { owner.onTrigger?() }
            return noErr
        }, 1, &type, Unmanaged.passUnretained(self).toOpaque(), &handler)
        handlerInstalled = status == noErr
    }

    @discardableResult
    func register(index: Int) -> Bool {
        guard handlerInstalled else { return false }
        if let reference { UnregisterEventHotKey(reference) }
        reference = nil
        let choice = Self.choices[min(max(index, 0), Self.choices.count - 1)]
        let id = EventHotKeyID(signature: OSType(0x434C4950), id: 1)
        return RegisterEventHotKey(choice.keyCode, choice.modifiers, id, GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive), &reference) == noErr
    }

    func invalidate() {
        if let reference { UnregisterEventHotKey(reference) }
        if let handler { RemoveEventHandler(handler) }
        reference = nil
        handler = nil
        handlerInstalled = false
    }
}
