import AppKit

/// Keep placeholder, drawn text and the field editor on the same typographic line.
@MainActor
final class CenteredSearchFieldCell: NSSearchFieldCell {
    private func textRect(_ bounds: NSRect) -> NSRect {
        let currentFont = font ?? .systemFont(ofSize: 16)
        let height = ceil(currentFont.ascender - currentFont.descender + currentFont.leading)
        return NSRect(x: bounds.minX, y: (bounds.midY - height / 2).rounded(), width: bounds.width, height: height)
    }

    override func drawingRect(forBounds rect: NSRect) -> NSRect { textRect(rect) }
    override func titleRect(forBounds rect: NSRect) -> NSRect { textRect(rect) }
    override func searchTextRect(forBounds rect: NSRect) -> NSRect { textRect(rect) }
    override func edit(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText, delegate: Any?, event: NSEvent?) {
        super.edit(withFrame: textRect(rect), in: controlView, editor: textObj, delegate: delegate, event: event)
    }
    override func select(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText, delegate: Any?, start selStart: Int, length selLength: Int) {
        super.select(withFrame: textRect(rect), in: controlView, editor: textObj, delegate: delegate, start: selStart, length: selLength)
    }
}

@MainActor
final class ToolbarShortcutBadge: NSView {
    var shortcut: String { didSet { invalidateIntrinsicContentSize(); needsDisplay = true; setAccessibilityLabel("唤起快捷键 \(shortcut)") } }
    init(_ shortcut: String) {
        self.shortcut = shortcut
        super.init(frame: .zero)
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel("唤起快捷键 \(shortcut)")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    private var tokens: [String] {
        let modifiers: Set<Character> = ["⌃", "⌥", "⇧", "⌘"]
        let prefix = shortcut.filter { modifiers.contains($0) }.map(String.init)
        let key = shortcut.filter { !modifiers.contains($0) }
        return prefix + (key.isEmpty ? [] : [key])
    }
    override var intrinsicContentSize: NSSize {
        NSSize(width: tokens.reduce(0) { $0 + max(21, toolbarTextWidth($1, font: ToolbarStyle.keyFont) + 12) } + CGFloat(max(0, tokens.count - 1)) * 3, height: 22)
    }
    override func draw(_ dirtyRect: NSRect) {
        var x: CGFloat = 0
        for token in tokens {
            let width = max(21, toolbarTextWidth(token, font: ToolbarStyle.keyFont) + 12)
            toolbarKeyCap(token, rect: NSRect(x: x, y: (bounds.height - 22) / 2, width: width, height: 22))
            x += width + 3
        }
    }
}

@MainActor
class ToolbarHoverButton: NSButton {
    private var hoverArea: NSTrackingArea?
    private(set) var hovered = false
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false
        setButtonType(.momentaryChange)
        focusRingType = .none
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func updateTrackingAreas() {
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
        super.updateTrackingAreas()
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
    override var isEnabled: Bool { didSet { needsDisplay = true } }
}

@MainActor
final class ToolbarIconButton: ToolbarHoverButton {
    private let symbol: String
    init(symbol: String, title: String, target: AnyObject?, action: Selector) {
        self.symbol = symbol
        super.init(frame: .zero)
        self.target = target
        self.action = action
        toolTip = title
        setAccessibilityLabel(title)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func draw(_ dirtyRect: NSRect) {
        if hovered || isHighlighted {
            ToolbarStyle.hover.withAlphaComponent(isHighlighted ? 1 : 0.7).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 13, yRadius: 13).fill()
        }
        let config = NSImage.SymbolConfiguration(paletteColors: [ToolbarStyle.secondary])
        let icon = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(config)
        let size: CGFloat = symbol == "gearshape" ? 14 : 12
        icon?.draw(in: NSRect(x: (bounds.width - size) / 2, y: (bounds.height - size) / 2, width: size, height: size), from: .zero, operation: .sourceOver, fraction: isEnabled ? 1 : 0.4, respectFlipped: true, hints: nil)
    }
}

@MainActor
final class ToolbarActionButton: ToolbarHoverButton {
    private let shortcut: String
    private let primary: Bool
    init(title: String, shortcut: String, primary: Bool) {
        self.shortcut = shortcut
        self.primary = primary
        super.init(frame: .zero)
        self.title = title
        setAccessibilityLabel(title)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        if !isEnabled { NSGraphicsContext.current?.cgContext.setAlpha(0.4) }
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 7, yRadius: 7)
        let fill: NSColor = primary ? (isHighlighted ? ToolbarStyle.blue.blended(withFraction: 0.15, of: .black)! : ToolbarStyle.blue) : (hovered || isHighlighted ? ToolbarStyle.hover : .white)
        fill.setFill()
        shape.fill()
        (primary ? ToolbarStyle.blue : ToolbarStyle.border).setStroke()
        shape.lineWidth = 1
        shape.stroke()
        let foreground = primary ? NSColor.white : ToolbarStyle.primary
        toolbarText(title, in: NSRect(x: 13, y: 0, width: 31, height: bounds.height), font: .systemFont(ofSize: 12, weight: .medium), color: foreground, alignment: .left)
        let keyWidth = shortcut.count > 1 ? CGFloat(31) : 23
        toolbarKeyCap(shortcut, rect: NSRect(x: bounds.width - keyWidth - 9, y: (bounds.height - 21) / 2, width: keyWidth, height: 21), primary: primary)
    }
}

@MainActor
final class ToolbarHints: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel("方向键选择，Esc 关闭")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func draw(_ dirtyRect: NSRect) {
        toolbarKeyCap("↑↓", rect: NSRect(x: 0, y: (bounds.height - 20) / 2, width: 29, height: 20))
        toolbarText("选择", in: NSRect(x: 36, y: 0, width: 27, height: bounds.height), font: ToolbarStyle.hintFont, color: ToolbarStyle.secondary, alignment: .left)
        toolbarKeyCap("esc", rect: NSRect(x: 82, y: (bounds.height - 20) / 2, width: 28, height: 20))
        toolbarText("关闭", in: NSRect(x: 117, y: 0, width: 27, height: bounds.height), font: ToolbarStyle.hintFont, color: ToolbarStyle.secondary, alignment: .left)
    }
}

@MainActor
private enum ToolbarStyle {
    static let primary = NSColor(srgbRed: 0.15, green: 0.19, blue: 0.24, alpha: 1)
    static let secondary = NSColor(srgbRed: 0.43, green: 0.48, blue: 0.55, alpha: 1)
    static let border = NSColor(srgbRed: 0.85, green: 0.88, blue: 0.91, alpha: 1)
    static let hover = NSColor(srgbRed: 0.94, green: 0.95, blue: 0.97, alpha: 1)
    static let blue = NSColor(srgbRed: 46 / 255, green: 107 / 255, blue: 225 / 255, alpha: 1)
    static let keyFont = NSFont.systemFont(ofSize: 10.5, weight: .medium)
    static let hintFont = NSFont.systemFont(ofSize: 11, weight: .regular)
}

@MainActor
private func toolbarTextWidth(_ text: String, font: NSFont) -> CGFloat { (text as NSString).size(withAttributes: [.font: font]).width }
@MainActor
private func toolbarText(_ text: String, in rect: NSRect, font: NSFont, color: NSColor, alignment: NSTextAlignment = .center) {
    let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
    let size = (text as NSString).size(withAttributes: attributes)
    let x = alignment == .left ? rect.minX : rect.midX - size.width / 2
    (text as NSString).draw(at: NSPoint(x: x.rounded(), y: (rect.midY - size.height / 2).rounded()), withAttributes: attributes)
}
@MainActor
private func toolbarKeyCap(_ text: String, rect: NSRect, primary: Bool = false) {
    let path = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 4, yRadius: 4)
    (primary ? NSColor.white.withAlphaComponent(0.13) : NSColor.white.withAlphaComponent(0.85)).setFill()
    path.fill()
    (primary ? NSColor.white.withAlphaComponent(0.23) : ToolbarStyle.border).setStroke()
    path.lineWidth = 1
    path.stroke()
    toolbarText(text, in: rect, font: ToolbarStyle.keyFont, color: primary ? .white : ToolbarStyle.secondary)
}
