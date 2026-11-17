import AppKit
import AnnotateCore

/// 選取模式：.region 拖曳選矩形（範圍截圖）；.window 點選視窗（視窗截圖，2026-11-13 新增）
enum RegionSelectionMode {
    case region
    case window

    /// 介面文字用的名稱
    var title: String {
        switch self {
        case .region: return "範圍截圖"
        case .window: return "視窗截圖"
        }
    }
}

/// 範圍截圖／視窗截圖的選取結果
struct RegionSelectionResult {
    let mode: RegionSelectionMode
    let screen: NSScreen
    let displayID: CGDirectDisplayID
    /// 螢幕內座標、左上原點、單位為點（直接給 SCStreamConfiguration.sourceRect）
    let rect: CGRect
    /// 選取 panel 的視窗編號（截圖時一併排除，雙重保險）
    let windowNumbers: Set<Int>
    /// 選取當下的螢幕大小與倍率：擷取前比對，變了就取消（螢幕在這之間插拔或改設定）
    let screenSize: CGSize
    let screenScale: CGFloat
}

/// 範圍截圖／視窗截圖的選取畫面：每個螢幕一個蓋滿的 panel
/// - .region：拖曳選矩形；.window：游標下的視窗高亮、點一下選那個視窗在這個螢幕上的範圍
/// - borderless＋nonactivatingPanel：可成為 key 收 Esc，但不啟用本程式（PowerPoint 放映不會跳出）
/// - sharingType = .none，截圖時也會明確排除
@MainActor
final class RegionSelectionController {
    private var panels: [RegionSelectionPanel] = []
    private var onFinish: ((RegionSelectionResult?) -> Void)?
    private var mode: RegionSelectionMode = .region

    /// 選取中，或選取完成後等待截圖（panel 已收起、尚未關閉）
    var isActive: Bool { !panels.isEmpty }

    /// 開始選取；onFinish 在完成時帶結果、取消時帶 nil（呼叫時選取 panel 都已收起）
    @discardableResult
    func begin(mode: RegionSelectionMode, onFinish: @escaping (RegionSelectionResult?) -> Void) -> Bool {
        guard !isActive else { return false }
        self.mode = mode
        // 主螢幕＝AppKit 全域座標原點所在的螢幕（screens.first），CG 全域座標也以它的左上為原點
        let mainHeight = NSScreen.screens.first?.frame.height ?? 0
        // 視窗模式：進入時查一次畫面上的視窗（前到後），之後滑鼠移動都用這份清單
        let windows = mode == .window ? Self.onScreenWindows() : []
        for screen in NSScreen.screens {
            guard let id = screen.displayID else { continue }
            let panel = RegionSelectionPanel.make(screen: screen, displayID: id, mode: mode, controller: self)
            if mode == .window {
                panel.selectionView.configureWindowPicking(
                    windows: windows,
                    screenCGFrame: WindowPicking.screenCGFrame(appKitFrame: screen.frame, mainScreenHeight: mainHeight)
                )
            }
            panel.orderFrontRegardless()
            panels.append(panel)
        }
        guard !panels.isEmpty else { return false }
        self.onFinish = onFinish

        // 游標所在螢幕的 panel 成為 key，讓 Esc 收得到
        let underMouse = NSScreen.underMouse()?.displayID
        let keyPanel = panels.first(where: { $0.displayID == underMouse }) ?? panels[0]
        keyPanel.takeKeyFocus()
        (mode == .window ? NSCursor.arrow : NSCursor.crosshair).set()
        // 視窗模式：游標還沒動也先高亮游標下的視窗（只在游標所在螢幕）
        if mode == .window {
            let p = WindowPicking.cgPoint(fromAppKit: NSEvent.mouseLocation, mainScreenHeight: mainHeight)
            keyPanel.selectionView.updateHighlight(globalPoint: p)
        }
        return true
    }

    /// 畫面上的一般視窗（前到後），排除本程式；需要螢幕錄製權限才拿得到視窗標題
    private static func onScreenWindows() -> [WindowCandidate] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let info = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return [] }
        return WindowPicking.candidates(from: info, excludingPID: getpid())
    }

    /// 取消選取（Esc、右鍵、螢幕插拔）
    func cancel() {
        guard isActive else { return }
        let callback = onFinish
        tearDown()
        callback?(nil)
    }

    /// 關閉所有選取 panel（截圖完成後由 AppController 呼叫；可重複呼叫）
    func tearDown() {
        onFinish = nil
        let old = panels
        panels.removeAll()
        for p in old { p.orderOut(nil) }
        // 可能正在某個 panel 的事件處理中，延到下一輪再關閉，避免視窗在處理事件時被釋放
        Task { @MainActor in
            for p in old { p.close() }
        }
    }

    /// 選取完成：rect 為該 panel 視圖座標（左下原點）
    fileprivate func complete(panel: RegionSelectionPanel, rect: CGRect) {
        guard let callback = onFinish else { return }
        if RegionSelection.isTooSmall(rect) {
            cancel()
            return
        }
        guard let screen = panel.targetScreen else {
            cancel()
            return
        }
        let height = panel.contentView?.bounds.height ?? screen.frame.height
        let region = RegionSelection.flipped(rect, height: height)
        let numbers = Set(panels.map(\.windowNumber).filter { $0 > 0 })
        // 先收起（不關閉），讓截圖前畫面更新；關閉由截圖完成後的 tearDown 負責
        onFinish = nil
        for p in panels { p.orderOut(nil) }
        callback(RegionSelectionResult(mode: mode, screen: screen, displayID: panel.displayID, rect: region, windowNumbers: numbers,
                                       screenSize: screen.frame.size, screenScale: screen.backingScaleFactor))
    }

    /// 是否有其他 panel 正在拖曳或按住（只允許在按下的那個螢幕選）
    fileprivate func isDragging(otherThan panel: RegionSelectionPanel) -> Bool {
        panels.contains { $0 !== panel && $0.selectionView.isDragging }
    }
}

/// 單一螢幕的選取 panel
@MainActor
final class RegionSelectionPanel: NSPanel {
    private(set) var displayID: CGDirectDisplayID = 0
    private(set) var selectionView: RegionSelectionView!
    private(set) weak var targetScreen: NSScreen?

    static func make(screen: NSScreen, displayID: CGDirectDisplayID, mode: RegionSelectionMode,
                     controller: RegionSelectionController) -> RegionSelectionPanel {
        let p = RegionSelectionPanel(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.displayID = displayID
        p.targetScreen = screen
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.level = WindowLevels.selection
        p.collectionBehavior = WindowLevels.overlayBehavior
        p.sharingType = .none
        p.isReleasedWhenClosed = false
        p.hidesOnDeactivate = false
        p.becomesKeyOnlyIfNeeded = false
        p.ignoresMouseEvents = false
        p.acceptsMouseMovedEvents = true

        let view = RegionSelectionView(
            frame: NSRect(origin: .zero, size: screen.frame.size),
            scale: screen.backingScaleFactor,
            mode: mode
        )
        view.controller = controller
        view.autoresizingMask = [.width, .height]
        p.selectionView = view
        p.contentView = view
        p.setFrame(screen.frame, display: false)
        return p
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// 不讓系統把無邊框視窗夾回可見區域（要蓋住選單列）
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }

    /// 成為 key（不啟用本程式）並讓視圖接收鍵盤
    func takeKeyFocus() {
        makeKeyAndOrderFront(nil)
        makeFirstResponder(selectionView)
    }
}

/// 視窗模式下目前高亮的視窗
private struct WindowHighlight: Equatable {
    let windowID: CGWindowID
    let ownerName: String
    /// 視窗在這個螢幕上的部分，視圖座標（左下原點）
    let rect: CGRect
}

/// 選取畫面：整片黑色 alpha 0.3
/// - .region：選取中的矩形挖空、白色 1pt 邊框，旁邊顯示像素尺寸
/// - .window：高亮視窗的範圍挖空、系統藍 3pt 邊框，左上角顯示「App 名稱　寬 × 高」
@MainActor
final class RegionSelectionView: NSView {
    weak var controller: RegionSelectionController?
    let mode: RegionSelectionMode
    private let scale: CGFloat
    private var anchor: CGPoint?
    private var selection: CGRect?
    private var trackingArea: NSTrackingArea?

    // 視窗模式
    private var windows: [WindowCandidate] = []
    private var screenCGFrame: CGRect = .zero
    private var highlight: WindowHighlight?
    /// 按下時游標下的視窗（放開時要是同一個才算選取）
    private var pressedWindowID: CGWindowID?
    private var isPressing = false

    var isDragging: Bool { anchor != nil || isPressing }

    init(frame: NSRect, scale: CGFloat, mode: RegionSelectionMode) {
        self.scale = scale
        self.mode = mode
        super.init(frame: frame)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { false }
    /// 本程式不在前景，第一下點擊就要開始選取
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: - 游標

    private var cursor: NSCursor { mode == .window ? .arrow : .crosshair }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited, .mouseMoved, .cursorUpdate],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func cursorUpdate(with event: NSEvent) {
        cursor.set()
    }

    override func mouseMoved(with event: NSEvent) {
        cursor.set()
        if mode == .window { updateHighlight(globalPoint: globalPoint(event)) }
    }

    /// 游標移到這個螢幕時改由這個 panel 收鍵盤（拖曳中不換）
    override func mouseEntered(with event: NSEvent) {
        cursor.set()
        if mode == .window && !isPressing { updateHighlight(globalPoint: globalPoint(event)) }
        guard let panel = window as? RegionSelectionPanel, !panel.isKeyWindow else { return }
        if controller?.isDragging(otherThan: panel) == true { return }
        panel.takeKeyFocus()
    }

    /// 游標離開這個螢幕：視窗模式取消這個螢幕上的高亮
    override func mouseExited(with event: NSEvent) {
        if mode == .window && !isPressing { updateHighlight(globalPoint: nil) }
    }

    // MARK: - 視窗模式

    /// 設定視窗清單（前到後）與這個螢幕的 CG frame
    func configureWindowPicking(windows: [WindowCandidate], screenCGFrame: CGRect) {
        self.windows = windows
        self.screenCGFrame = screenCGFrame
    }

    /// 依全域 CG 點更新高亮；nil 表示不高亮
    func updateHighlight(globalPoint: CGPoint?) {
        let new = globalPoint.flatMap { pick(at: $0) }
        if new != highlight {
            highlight = new
            needsDisplay = true
        }
    }

    /// 全域 CG 點下最前面的視窗，取它在這個螢幕上的部分；沒有視窗或部分太小回 nil
    private func pick(at p: CGPoint) -> WindowHighlight? {
        guard let w = WindowPicking.topmost(at: p, in: windows),
              let local = WindowPicking.localRect(of: w.bounds, inScreenCGFrame: screenCGFrame),
              !RegionSelection.isTooSmall(local) else { return nil }
        return WindowHighlight(
            windowID: w.windowID,
            ownerName: w.ownerName,
            rect: RegionSelection.flipped(local, height: bounds.height)
        )
    }

    private func globalPoint(_ event: NSEvent) -> CGPoint {
        WindowPicking.globalPoint(fromLocal: convert(event.locationInWindow, from: nil), screenCGFrame: screenCGFrame)
    }

    // MARK: - 選取

    private func clampedPoint(_ event: NSEvent) -> CGPoint {
        RegionSelection.clamp(convert(event.locationInWindow, from: nil), to: bounds)
    }

    override func mouseDown(with event: NSEvent) {
        guard let panel = window as? RegionSelectionPanel else { return }
        if controller?.isDragging(otherThan: panel) == true { return }
        if !panel.isKeyWindow { panel.takeKeyFocus() }
        cursor.set()
        switch mode {
        case .region:
            let p = clampedPoint(event)
            anchor = p
            selection = CGRect(origin: p, size: .zero)
            needsDisplay = true
        case .window:
            updateHighlight(globalPoint: globalPoint(event))
            pressedWindowID = highlight?.windowID
            isPressing = true
        }
    }

    override func mouseDragged(with event: NSEvent) {
        switch mode {
        case .region:
            guard let anchor else { return }
            // 拖到螢幕外時事件仍送到這個視窗，座標夾在本螢幕邊界內
            selection = RegionSelection.rect(from: anchor, to: convert(event.locationInWindow, from: nil), clampedTo: bounds)
            cursor.set()
            needsDisplay = true
        case .window:
            guard isPressing else { return }
            updateHighlight(globalPoint: globalPoint(event))
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard let panel = window as? RegionSelectionPanel else { return }
        switch mode {
        case .region:
            guard let anchor else { return }
            let r = RegionSelection.rect(from: anchor, to: convert(event.locationInWindow, from: nil), clampedTo: bounds)
            self.anchor = nil
            selection = nil
            needsDisplay = true
            controller?.complete(panel: panel, rect: r)
        case .window:
            guard isPressing else { return }
            isPressing = false
            let pressed = pressedWindowID
            pressedWindowID = nil
            updateHighlight(globalPoint: globalPoint(event))
            // 按下與放開要在同一個視窗上；在空白處（沒有視窗）點擊不做事、也不取消
            guard let h = highlight, let pressed, h.windowID == pressed else { return }
            highlight = nil
            needsDisplay = true
            controller?.complete(panel: panel, rect: h.rect)
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        controller?.cancel()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // Esc
            controller?.cancel()
        } else {
            super.keyDown(with: event)
        }
    }

    override func cancelOperation(_ sender: Any?) {
        controller?.cancel()
    }

    // MARK: - 繪製

    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.set()
        dirtyRect.fill(using: .copy)
        switch mode {
        case .region: drawRegion()
        case .window: drawWindowHighlight()
        }
    }

    /// 整片暗色遮罩，hole 內部挖空（evenOdd）
    private func fillDim(hole: CGRect?) {
        let dim = NSBezierPath(rect: bounds)
        if let hole, hole.width > 0, hole.height > 0 {
            dim.append(NSBezierPath(rect: hole))
            dim.windingRule = .evenOdd
        }
        NSColor(white: 0, alpha: 0.3).setFill()
        dim.fill()
    }

    private func drawRegion() {
        fillDim(hole: selection)

        guard let sel = selection, sel.width >= 1, sel.height >= 1 else { return }
        let border = NSBezierPath(rect: sel.insetBy(dx: 0.5, dy: 0.5))
        border.lineWidth = 1
        NSColor.white.setStroke()
        border.stroke()

        drawSizeLabel(for: sel)
    }

    private func drawWindowHighlight() {
        fillDim(hole: highlight?.rect)
        guard let h = highlight else { return }
        // 3pt 邊框畫在挖空範圍內側，不蓋到範圍外
        let border = NSBezierPath(rect: h.rect.insetBy(dx: 1.5, dy: 1.5))
        border.lineWidth = 3
        NSColor.systemBlue.setStroke()
        border.stroke()

        drawWindowLabel(for: h)
    }

    private var labelAttributes: [NSAttributedString.Key: Any] {
        [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
    }

    private static let labelPadX: CGFloat = 6
    private static let labelPadY: CGFloat = 3
    private static let labelGap: CGFloat = 6

    private func labelBoxSize(_ text: NSString) -> CGSize {
        let textSize = text.size(withAttributes: labelAttributes)
        return CGSize(width: ceil(textSize.width) + Self.labelPadX * 2, height: ceil(textSize.height) + Self.labelPadY * 2)
    }

    private func drawLabel(_ text: NSString, in box: CGRect) {
        NSColor(white: 0, alpha: 0.75).setFill()
        NSBezierPath(roundedRect: box, xRadius: 4, yRadius: 4).fill()
        text.draw(at: CGPoint(x: box.minX + Self.labelPadX, y: box.minY + Self.labelPadY), withAttributes: labelAttributes)
    }

    /// 矩形旁顯示實際像素尺寸「寬 × 高」：預設在矩形下方，放不下就放上方，再不行放在矩形內
    private func drawSizeLabel(for sel: CGRect) {
        let px = RegionSelection.pixelSize(of: sel, scale: scale)
        let text = "\(px.width) × \(px.height)" as NSString
        let boxSize = labelBoxSize(text)
        let gap = Self.labelGap

        var y = sel.minY - gap - boxSize.height
        if y < bounds.minY {
            y = sel.maxY + gap
            if y + boxSize.height > bounds.maxY { y = sel.minY + gap }
        }
        let x = min(max(sel.minX, bounds.minX), bounds.maxX - boxSize.width)
        drawLabel(text, in: CGRect(origin: CGPoint(x: x, y: y), size: boxSize))
    }

    /// 視窗左上角顯示「App 名稱　寬 × 高」（像素）：預設在視窗上緣外側，放不下（貼齊螢幕頂端）就放在視窗內左上角
    private func drawWindowLabel(for h: WindowHighlight) {
        let px = RegionSelection.pixelSize(of: h.rect, scale: scale)
        let size = "\(px.width) × \(px.height)"
        let text = (h.ownerName.isEmpty ? size : "\(h.ownerName)　\(size)") as NSString
        let boxSize = labelBoxSize(text)
        let gap = Self.labelGap
        let sel = h.rect

        var y = sel.maxY + gap
        if y + boxSize.height > bounds.maxY { y = sel.maxY - gap - boxSize.height }
        y = max(y, bounds.minY)
        let x = max(min(sel.minX, bounds.maxX - boxSize.width), bounds.minX)
        drawLabel(text, in: CGRect(origin: CGPoint(x: x, y: y), size: boxSize))
    }
}
