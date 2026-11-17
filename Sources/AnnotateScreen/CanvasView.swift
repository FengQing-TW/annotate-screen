import AppKit
import AnnotateCore

/// 雷射筆軌跡：只存在畫面上，不進文件與復原堆疊
struct LaserTrail {
    var points: [CGPoint]
    var width: CGFloat
    var releasedAt: TimeInterval?
}

/// 覆蓋層內容：畫底色（白板／黑板）、筆畫、進行中的筆畫與雷射；處理畫圖模式的滑鼠與鍵盤
@MainActor
final class CanvasView: NSView {
    static let eraserTolerance: CGFloat = 6
    /// 雷射放開後先停留、再淡出，合計約 1.5 秒
    static let laserHold: TimeInterval = 0.75
    static let laserFade: TimeInterval = 0.75
    static let blackboardColor = CGColor(srgbRed: 0x1E / 255.0, green: 0x2A / 255.0, blue: 0x23 / 255.0, alpha: 1)

    weak var app: AppController?
    let displayID: CGDirectDisplayID
    let pageSet: PageSet

    var annotationsHidden = false {
        didSet { needsDisplay = true }
    }

    private var current: Stroke?
    private var activeTool: Tool?
    private var shapeAnchor: CGPoint = .zero
    private var shapeRawEnd: CGPoint = .zero
    private var eraserDocument: AnnotationDocument?
    private var lastEraserPoint: CGPoint = .zero
    private var lasers: [LaserTrail] = []
    private var laserTimer: Timer?
    private var textSession: TextEditSession?

    init(frame: NSRect, displayID: CGDirectDisplayID, pageSet: PageSet) {
        self.displayID = displayID
        self.pageSet = pageSet
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) {
        fatalError("不支援 init(coder:)")
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    var isEditingText: Bool { textSession != nil }

    // MARK: - 游標

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.cursorUpdate, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }

    override func cursorUpdate(with event: NSEvent) {
        NSCursor.crosshair.set()
    }

    // MARK: - 繪製

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        // 透明視窗：先清掉，避免殘影
        ctx.clear(dirtyRect)
        switch pageSet.currentPage {
        case .whiteboard:
            ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
            ctx.fill(bounds)
        case .blackboard:
            ctx.setFillColor(Self.blackboardColor)
            ctx.fill(bounds)
        case .screen:
            break
        }
        guard !annotationsHidden else { return }
        for stroke in pageSet.currentDocument.strokes {
            StrokeRenderer.draw(stroke, in: ctx)
        }
        if let current {
            StrokeRenderer.draw(current, in: ctx)
        }
        let now = ProcessInfo.processInfo.systemUptime
        for trail in lasers {
            StrokeRenderer.drawLaser(trail.points, width: trail.width, alpha: laserAlpha(trail, now: now), in: ctx)
        }
    }

    private func laserAlpha(_ trail: LaserTrail, now: TimeInterval) -> CGFloat {
        guard let released = trail.releasedAt else { return 1 }
        let elapsed = now - released
        if elapsed <= Self.laserHold { return 1 }
        return CGFloat(max(0, 1 - (elapsed - Self.laserHold) / Self.laserFade))
    }

    // MARK: - 滑鼠

    override func mouseDown(with event: NSEvent) {
        guard let app else { return }
        let p = convert(event.locationInWindow, from: nil)
        // 點在輸入框外：先確定文字，這一下不畫
        if textSession != nil {
            commitText()
            return
        }
        if annotationsHidden { app.setAnnotationsHidden(false) }
        app.noteActive(displayID)   // 工具列、選單的動作作用在最後畫過的螢幕
        window?.makeKey()
        window?.makeFirstResponder(self)

        let s = app.settings
        activeTool = s.tool
        switch s.tool {
        case .pen, .highlighter:
            current = Stroke(kind: s.tool.strokeKind!, color: s.strokeColor, lineWidth: s.lineWidth, points: [p])
        case .line, .arrow, .rectangle, .ellipse:
            shapeAnchor = p
            shapeRawEnd = p
            current = Stroke(kind: s.tool.strokeKind!, color: s.strokeColor, lineWidth: s.lineWidth, points: [p, p])
        case .text:
            activeTool = nil
            beginText(at: p, settings: s)
        case .laser:
            lasers.append(LaserTrail(points: [p], width: s.lineWidth, releasedAt: nil))
            startLaserTimer()
        case .eraser:
            let doc = pageSet.currentDocument
            doc.beginGroup()
            eraserDocument = doc
            lastEraserPoint = p
            if doc.erase(at: p, tolerance: Self.eraserTolerance) { app.documentDidChange(displayID) }
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let tool = activeTool else { return }
        let p = convert(event.locationInWindow, from: nil)
        switch tool {
        case .pen, .highlighter:
            if let last = current?.points.last, Geometry.distance(last, p) >= 1 {
                current?.points.append(p)
            }
        case .line, .arrow, .rectangle, .ellipse:
            shapeRawEnd = p
            updateShapeEnd(shift: event.modifierFlags.contains(.shift))
        case .laser:
            if !lasers.isEmpty { lasers[lasers.count - 1].points.append(p) }
        case .eraser:
            if let doc = eraserDocument {
                if doc.erase(from: lastEraserPoint, to: p, tolerance: Self.eraserTolerance) {
                    app?.documentDidChange(displayID)
                }
                lastEraserPoint = p
            }
        case .text:
            break
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let tool = activeTool else { return }
        // 放開位置不一定等於最後一次拖曳位置：先把放開點當成最後一次拖曳處理
        mouseDragged(with: event)
        switch tool {
        case .pen, .highlighter, .line, .arrow, .rectangle, .ellipse:
            if let stroke = current {
                // 形狀只點一下沒拖曳就不留下
                let tooSmall = tool.isShape && Geometry.distance(stroke.start, stroke.end) < 2
                if !tooSmall {
                    pageSet.currentDocument.add(stroke)
                    app?.documentDidChange(displayID)
                }
            }
            current = nil
        case .laser:
            if !lasers.isEmpty { lasers[lasers.count - 1].releasedAt = ProcessInfo.processInfo.systemUptime }
        case .eraser:
            eraserDocument?.endGroup()
            eraserDocument = nil
        case .text:
            break
        }
        activeTool = nil
        needsDisplay = true
    }

    override func flagsChanged(with event: NSEvent) {
        if let tool = activeTool, tool.isShape, current != nil {
            updateShapeEnd(shift: event.modifierFlags.contains(.shift))
            needsDisplay = true
        }
        super.flagsChanged(with: event)
    }

    /// 依 Shift 狀態套用角度鎖定或正方形／正圓約束
    private func updateShapeEnd(shift: Bool) {
        guard var stroke = current else { return }
        var end = shapeRawEnd
        if shift {
            switch stroke.kind {
            case .line, .arrow: end = ShapeConstraint.lockAngle(from: shapeAnchor, to: end)
            case .rectangle, .ellipse: end = ShapeConstraint.square(from: shapeAnchor, to: end)
            default: break
            }
        }
        stroke.points = [shapeAnchor, end]
        current = stroke
    }

    /// 中斷進行中的操作（切換模式、切頁時）
    func cancelInteraction() {
        current = nil
        activeTool = nil
        eraserDocument?.endGroup()
        eraserDocument = nil
        // 2026-11-13：按住雷射時被中斷，mouseUp 不會來，軌跡會一直停在畫面上、Timer 也不會停；
        // 當成「現在放開」，照正常流程淡出
        let now = ProcessInfo.processInfo.systemUptime
        for i in lasers.indices where lasers[i].releasedAt == nil {
            lasers[i].releasedAt = now
        }
        needsDisplay = true
    }

    // MARK: - 雷射

    private func startLaserTimer() {
        guard laserTimer == nil else { return }
        // 2026-11-13：螢幕重建後舊的 CanvasView 被釋放，Timer 仍掛在 RunLoop 上空跑；self 不在了就自己停掉
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] t in
            MainActor.assumeIsolated {
                guard let self else {
                    t.invalidate()
                    return
                }
                self.laserTick()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        laserTimer = timer
    }

    private func laserTick() {
        let now = ProcessInfo.processInfo.systemUptime
        let total = Self.laserHold + Self.laserFade
        lasers.removeAll { trail in
            guard let released = trail.releasedAt else { return false }
            return now - released > total
        }
        if lasers.isEmpty {
            laserTimer?.invalidate()
            laserTimer = nil
        }
        needsDisplay = true
    }

    // MARK: - 文字

    private func beginText(at p: CGPoint, settings: ToolSettings) {
        let session = TextEditSession(origin: p, fontSize: settings.fontSize, color: settings.color)
        session.view.onCommit = { [weak self] in self?.commitText() }
        session.view.onCancel = { [weak self] in self?.cancelText() }
        textSession = session
        addSubview(session.view)
        session.resize()
        window?.makeKey()
        window?.makeFirstResponder(session.view)
    }

    /// 確定文字輸入
    func commitText() {
        guard let session = textSession else { return }
        textSession = nil
        let stroke = session.makeStroke()
        session.view.removeFromSuperview()
        if let stroke {
            pageSet.currentDocument.add(stroke)
            app?.documentDidChange(displayID)
        }
        window?.makeFirstResponder(self)
        needsDisplay = true
    }

    /// 取消文字輸入
    func cancelText() {
        guard let session = textSession else { return }
        textSession = nil
        session.view.removeFromSuperview()
        window?.makeFirstResponder(self)
        needsDisplay = true
    }

    // MARK: - 鍵盤（畫圖模式）

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // ⌘4：清除所有螢幕的標註並回到滑鼠控制（穿透模式）。2026-11-17 使用者要求。
        // 正常情況由 AppController 的全域熱鍵先處理（toggleQuickMode）；這裡是全域註冊失敗時的備援，
        // 只在畫圖模式（這個覆蓋層是 key）才會收到，所以只做「清除並回滑鼠」這一半。
        // 用 keyCode 判斷（21＝數字 4），注音輸入法下也認得；文字輸入中也有效（文字會先確定再清，可復原）。
        if window?.isKeyWindow == true, let app, event.keyCode == 21,
           event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command {
            app.clearAllAndExitDrawing()
            return true
        }
        guard textSession == nil, window?.isKeyWindow == true, let app else {
            return super.performKeyEquivalent(with: event)
        }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command), event.charactersIgnoringModifiers?.lowercased() == "z" {
            if flags.contains(.shift) {
                app.redo(displayID: displayID)
            } else {
                app.undo(displayID: displayID)
            }
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        guard let app else { return }
        switch event.keyCode {
        case 53: // Esc：結束畫圖
            app.setDrawing(false)
            return
        case 51, 117: // ⌫、⌦：清除目前畫面
            app.clear(displayID: displayID)
            return
        default:
            break
        }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if !flags.intersection([.command, .control, .option]).isEmpty { return }
        guard let ch = event.charactersIgnoringModifiers?.lowercased().first else { return }
        if let tool = Tool.tool(forKey: ch) {
            app.selectTool(tool)
        } else if let n = ch.wholeNumberValue, (1...Palette.colors.count).contains(n) {
            app.selectColor(n - 1)
        } else if ch == "[" {
            app.adjustWidth(-1)
        } else if ch == "]" {
            app.adjustWidth(1)
        }
    }
}
