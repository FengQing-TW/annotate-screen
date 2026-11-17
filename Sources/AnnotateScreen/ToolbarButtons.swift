import AppKit

/// 工具列按鈕：SF Symbol 圖示＋繁中 tooltip，選取時有底色
@MainActor
final class ToolbarButton: NSButton {
    static let side: CGFloat = 30

    private var handler: (() -> Void)?

    var isChosen = false {
        didSet { updateLook() }
    }

    /// 以 SF Symbol 建立；找不到圖示時改顯示 fallback 文字
    static func make(symbol: String, fallback: String, tooltip: String, handler: @escaping () -> Void) -> ToolbarButton {
        let b = ToolbarButton(frame: NSRect(x: 0, y: 0, width: side, height: side))
        b.configure(tooltip: tooltip, handler: handler)
        if let img = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip) {
            let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .medium)
            b.image = img.withSymbolConfiguration(config) ?? img
            b.imagePosition = .imageOnly
            b.title = ""
        } else {
            b.setText(fallback)
        }
        return b
    }

    /// 文字按鈕（例如粗細）
    static func makeText(_ text: String, tooltip: String, handler: @escaping () -> Void) -> ToolbarButton {
        let b = ToolbarButton(frame: NSRect(x: 0, y: 0, width: side, height: side))
        b.configure(tooltip: tooltip, handler: handler)
        b.setText(text)
        return b
    }

    private func configure(tooltip: String, handler: @escaping () -> Void) {
        self.handler = handler
        toolTip = tooltip
        isBordered = false
        setButtonType(.momentaryChange)
        contentTintColor = .white
        target = self
        action = #selector(fire)
        wantsLayer = true
        layer?.cornerRadius = 6
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.side),
            heightAnchor.constraint(equalToConstant: Self.side),
        ])
        updateLook()
    }

    func setText(_ text: String) {
        image = nil
        imagePosition = .noImage
        attributedTitle = NSAttributedString(string: text, attributes: [
            .foregroundColor: NSColor.white,
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
        ])
    }

    @objc private func fire() {
        handler?()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func updateLook() {
        layer?.backgroundColor = isChosen
            ? NSColor.controlAccentColor.withAlphaComponent(0.85).cgColor
            : NSColor.clear.cgColor
    }
}

/// 顏色按鈕：圓形色塊，選取時外圈白環
@MainActor
final class ColorSwatchButton: NSButton {
    private var handler: (() -> Void)?
    private var swatchColor: NSColor = .red

    var isChosen = false {
        didSet { needsDisplay = true }
    }

    static func make(color: NSColor, tooltip: String, handler: @escaping () -> Void) -> ColorSwatchButton {
        let side = ToolbarButton.side
        let b = ColorSwatchButton(frame: NSRect(x: 0, y: 0, width: side, height: side))
        b.swatchColor = color
        b.handler = handler
        b.toolTip = tooltip
        b.isBordered = false
        b.title = ""
        b.target = b
        b.action = #selector(ColorSwatchButton.fire)
        b.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            b.widthAnchor.constraint(equalToConstant: side),
            b.heightAnchor.constraint(equalToConstant: side),
        ])
        return b
    }

    @objc private func fire() {
        handler?()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        if isChosen {
            let ring = NSBezierPath(ovalIn: bounds.insetBy(dx: 2.5, dy: 2.5))
            ring.lineWidth = 2
            NSColor.white.setStroke()
            ring.stroke()
        }
        let dot = NSBezierPath(ovalIn: bounds.insetBy(dx: 7, dy: 7))
        swatchColor.setFill()
        dot.fill()
        NSColor(white: 0.55, alpha: 0.9).setStroke()
        dot.lineWidth = 1
        dot.stroke()
    }
}
