import AppKit

/// 聚光燈畫面：整個螢幕變暗（黑 alpha 0.65），游標周圍留一個圓形亮區
@MainActor
final class SpotlightView: NSView {
    static let dimAlpha: CGFloat = 0.65

    /// 亮區圓心（視圖座標）；nil 表示整個變暗
    var holeCenter: CGPoint? {
        didSet {
            guard oldValue != holeCenter else { return }
            // 只重畫新舊亮區附近，避免 60Hz 全螢幕重畫
            if let old = oldValue { setNeedsDisplay(holeRect(old).insetBy(dx: -4, dy: -4)) }
            if let new = holeCenter { setNeedsDisplay(holeRect(new).insetBy(dx: -4, dy: -4)) }
        }
    }

    var radius: CGFloat = 150 {
        didSet { needsDisplay = true }
    }

    override var isOpaque: Bool { false }

    private func holeRect(_ c: CGPoint) -> CGRect {
        CGRect(x: c.x - radius, y: c.y - radius, width: radius * 2, height: radius * 2)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        // 先清掉重畫區域，避免局部重畫時暗度疊加
        ctx.clear(dirtyRect)
        ctx.setFillColor(CGColor(gray: 0, alpha: Self.dimAlpha))
        ctx.addRect(bounds)
        if let c = holeCenter {
            ctx.addEllipse(in: holeRect(c))
        }
        ctx.fillPath(using: .evenOdd)
    }
}

/// 聚光燈：每個螢幕一層變暗視窗，以 60Hz Timer 讀 NSEvent.mouseLocation（不需要輔助使用權限）
/// 視窗永遠穿透滑鼠，sharingType 維持預設，讓 Teams 與會者看得到
@MainActor
final class SpotlightController {
    private var panels: [NSPanel] = []
    private var views: [SpotlightView] = []
    private var timer: Timer?
    private var lastMouse = NSPoint(x: -100_000, y: -100_000)
    private(set) var isActive = false

    /// 截圖時要排除的視窗（截圖只留簡報＋標註，不要聚光燈的暗色遮罩）
    var windowNumbers: [Int] { panels.map(\.windowNumber).filter { $0 > 0 } }

    var radius: CGFloat {
        didSet {
            for v in views { v.radius = radius }
        }
    }

    init(radius: CGFloat) {
        self.radius = radius
    }

    func start() {
        guard !isActive else { return }
        isActive = true
        buildPanels()
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.tick()
            }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        tick()
    }

    func stop() {
        guard isActive else { return }
        isActive = false
        timer?.invalidate()
        timer = nil
        tearDown()
    }

    /// 螢幕插拔後重建
    func screensChanged() {
        guard isActive else { return }
        tearDown()
        buildPanels()
        tick()
    }

    private func buildPanels() {
        for screen in NSScreen.screens {
            let panel = makeFloatingPanel(frame: screen.frame, level: WindowLevels.spotlight)
            panel.ignoresMouseEvents = true
            let view = SpotlightView(frame: NSRect(origin: .zero, size: screen.frame.size))
            view.radius = radius
            view.autoresizingMask = [.width, .height]
            panel.contentView = view
            panel.setFrame(screen.frame, display: false)
            panel.orderFrontRegardless()
            panels.append(panel)
            views.append(view)
        }
        lastMouse = NSPoint(x: -100_000, y: -100_000)
    }

    private func tearDown() {
        for p in panels {
            p.orderOut(nil)
            p.close()
        }
        panels.removeAll()
        views.removeAll()
    }

    private func tick() {
        let m = NSEvent.mouseLocation
        guard m != lastMouse else { return }
        lastMouse = m
        // 圓心換算到各螢幕的視圖座標；跨螢幕邊緣時兩邊都會畫出一部分亮區
        for (panel, view) in zip(panels, views) {
            let f = panel.frame
            view.holeCenter = CGPoint(x: m.x - f.minX, y: m.y - f.minY)
        }
    }
}
