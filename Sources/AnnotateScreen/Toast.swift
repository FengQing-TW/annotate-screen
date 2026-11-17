import AppKit

/// 螢幕下方的短暫提示；sharingType = .none，截圖時也會明確排除
@MainActor
final class Toast {
    private let panel: NSPanel
    private let label: NSTextField
    private var hideTimer: Timer?

    init() {
        panel = makeFloatingPanel(frame: NSRect(x: 0, y: 0, width: 300, height: 44), level: WindowLevels.toast)
        panel.ignoresMouseEvents = true
        panel.sharingType = .none
        panel.hasShadow = true

        let background = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 44))
        background.wantsLayer = true
        background.layer?.backgroundColor = NSColor(white: 0, alpha: 0.82).cgColor
        background.layer?.cornerRadius = 10
        background.autoresizingMask = [.width, .height]

        label = NSTextField(labelWithString: "")
        label.textColor = .white
        label.font = NSFont.systemFont(ofSize: 15, weight: .medium)
        label.alignment = .center
        background.addSubview(label)
        panel.contentView = background
    }

    var windowNumber: Int { panel.windowNumber }

    /// 在指定螢幕下方中央顯示訊息，預設 1.5 秒後消失
    func show(_ message: String, on screen: NSScreen?, duration: TimeInterval = 1.5) {
        guard let screen = screen ?? NSScreen.main else { return }
        label.stringValue = message
        label.sizeToFit()
        let size = NSSize(width: ceil(label.frame.width) + 40, height: ceil(label.frame.height) + 24)
        label.setFrameOrigin(NSPoint(x: 20, y: 12))
        let origin = NSPoint(x: screen.frame.midX - size.width / 2, y: screen.frame.minY + 100)
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        panel.orderFrontRegardless()

        hideTimer?.invalidate()
        let t = Timer(timeInterval: duration, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.hide()
            }
        }
        RunLoop.main.add(t, forMode: .common)
        hideTimer = t
    }

    func hide() {
        hideTimer?.invalidate()
        hideTimer = nil
        panel.orderOut(nil)
    }
}
