import AppKit
import AnnotateCore

/// 文字工具的輸入框：Enter 確定、Esc 取消、Shift+Enter 換行
/// 輸入法組字中（有 marked text）時，Enter／Esc 交給輸入法處理
@MainActor
final class TextInputView: NSTextView {
    var onCommit: (() -> Void)?
    var onCancel: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if hasMarkedText() {
            super.keyDown(with: event)
            return
        }
        switch event.keyCode {
        case 53: // Esc
            onCancel?()
        case 36, 76: // Return、數字鍵盤 Enter
            if event.modifierFlags.contains(.shift) {
                insertNewlineIgnoringFieldEditor(nil)
            } else {
                onCommit?()
            }
        default:
            super.keyDown(with: event)
        }
    }
}

/// 一次文字輸入的狀態；確定後轉成 Stroke
@MainActor
final class TextEditSession: NSObject, NSTextViewDelegate {
    let view: TextInputView
    let origin: CGPoint
    let fontSize: CGFloat
    let color: RGBAColor
    private let lineHeight: CGFloat

    init(origin: CGPoint, fontSize: CGFloat, color: RGBAColor) {
        self.origin = origin
        self.fontSize = fontSize
        self.color = color
        let font = StrokeRenderer.font(size: fontSize)
        lineHeight = ceil(NSLayoutManager().defaultLineHeight(for: font))

        let tv = TextInputView(frame: NSRect(x: origin.x, y: origin.y, width: fontSize, height: lineHeight))
        tv.isRichText = false
        tv.importsGraphics = false
        tv.allowsUndo = true
        tv.font = font
        tv.textColor = color.nsColor
        tv.insertionPointColor = color.nsColor
        tv.drawsBackground = true
        tv.backgroundColor = NSColor(white: 0.5, alpha: 0.18)
        tv.textContainerInset = .zero
        tv.isHorizontallyResizable = false
        tv.isVerticallyResizable = false
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.typingAttributes = StrokeRenderer.textAttributes(fontSize: fontSize, color: color)
        if let container = tv.textContainer {
            container.lineFragmentPadding = 0
            container.widthTracksTextView = false
            container.heightTracksTextView = false
            container.containerSize = NSSize(width: 100_000, height: 100_000)
        }
        view = tv
        super.init()
        tv.delegate = self
    }

    func textDidChange(_ notification: Notification) {
        resize()
    }

    /// 依內容調整輸入框大小（多留一點寬度給游標）
    func resize() {
        let used = usedSize()
        view.setFrameSize(NSSize(width: max(used.width + fontSize * 0.6, fontSize), height: max(used.height, lineHeight)))
        view.superview?.needsDisplay = true
    }

    private func usedSize() -> CGSize {
        guard let lm = view.layoutManager, let tc = view.textContainer else { return .zero }
        lm.ensureLayout(for: tc)
        let r = lm.usedRect(for: tc)
        return CGSize(width: ceil(r.width), height: ceil(r.height))
    }

    /// 轉成文字筆畫；空白內容回傳 nil
    func makeStroke() -> Stroke? {
        let text = view.string
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let size = usedSize()
        let frame = CGRect(origin: origin, size: CGSize(width: max(size.width, 1), height: max(size.height, lineHeight)))
        return Stroke(
            kind: .text,
            color: color,
            lineWidth: 0,
            points: [origin],
            text: text,
            fontSize: fontSize,
            textFrame: frame
        )
    }
}
