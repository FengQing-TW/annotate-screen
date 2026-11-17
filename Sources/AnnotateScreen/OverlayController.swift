import AppKit
import AnnotateCore

/// 每個螢幕一個的透明覆蓋層
/// - NSPanel［borderless, nonactivatingPanel］：畫圖時不搶 PowerPoint 的前景，又能收鍵盤
/// - sharingType 維持預設 .readOnly，不可設 .none（否則 Teams 看不到標註）
@MainActor
final class OverlayWindow: NSPanel {
    private(set) var canvas: CanvasView!
    private(set) var displayID: CGDirectDisplayID = 0

    static func make(screen: NSScreen, displayID: CGDirectDisplayID, pageSet: PageSet, app: AppController) -> OverlayWindow {
        let w = OverlayWindow(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        w.displayID = displayID
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.level = WindowLevels.overlay
        w.collectionBehavior = WindowLevels.overlayBehavior
        w.isReleasedWhenClosed = false
        w.hidesOnDeactivate = false
        w.becomesKeyOnlyIfNeeded = false
        w.ignoresMouseEvents = true
        w.acceptsMouseMovedEvents = true

        let canvas = CanvasView(
            frame: NSRect(origin: .zero, size: screen.frame.size),
            displayID: displayID,
            pageSet: pageSet
        )
        canvas.app = app
        canvas.autoresizingMask = [.width, .height]
        w.canvas = canvas
        w.contentView = canvas
        w.setFrame(screen.frame, display: false)
        return w
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// 不讓系統把無邊框視窗夾回可見區域（要蓋住選單列）
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

/// 管理所有螢幕的覆蓋層；螢幕插拔時重建，標註以 CGDirectDisplayID 對應保留
@MainActor
final class OverlayManager {
    private unowned let app: AppController
    private(set) var overlays: [CGDirectDisplayID: OverlayWindow] = [:]

    init(app: AppController) {
        self.app = app
    }

    var windowNumbers: [Int] { overlays.values.map(\.windowNumber) }

    /// 依目前螢幕重建覆蓋層（標註存在 AppController 的 PageSet，不會遺失）
    func rebuild() {
        for w in overlays.values {
            w.canvas.commitText()
            // 橡皮擦拖曳中被重建時，要結束復原群組，否則之後的操作會被併成同一步
            w.canvas.cancelInteraction()
            w.orderOut(nil)
            w.close()
        }
        overlays.removeAll()
        for screen in NSScreen.screens {
            guard let id = screen.displayID else { continue }
            let w = OverlayWindow.make(screen: screen, displayID: id, pageSet: app.pageSet(for: id), app: app)
            w.canvas.annotationsHidden = app.annotationsHidden
            w.ignoresMouseEvents = !app.isDrawing
            w.orderFrontRegardless()
            overlays[id] = w
        }
        if app.isDrawing {
            focus(on: NSScreen.underMouse())
        }
    }

    func canvas(for id: CGDirectDisplayID) -> CanvasView? {
        overlays[id]?.canvas
    }

    /// 切換畫圖／穿透
    func setDrawing(_ on: Bool, focus screen: NSScreen?) {
        for w in overlays.values {
            if !on {
                w.canvas.commitText()
                w.canvas.cancelInteraction()
            }
            w.ignoresMouseEvents = !on
        }
        if on {
            focus(on: screen)
            NSCursor.crosshair.set()
        } else {
            // 交還鍵盤：把成為 key 的覆蓋層暫時收起再顯示（不會啟用本程式）
            for w in overlays.values where w.isKeyWindow {
                w.orderOut(nil)
                w.orderFrontRegardless()
            }
            NSCursor.arrow.set()
        }
    }

    /// 讓指定螢幕的覆蓋層成為 key，接收鍵盤
    private func focus(on screen: NSScreen?) {
        var target: OverlayWindow?
        if let id = screen?.displayID { target = overlays[id] }
        guard let target = target ?? overlays.values.first else { return }
        target.makeKeyAndOrderFront(nil)
        target.makeFirstResponder(target.canvas)
    }

    func redisplay(_ id: CGDirectDisplayID? = nil) {
        if let id {
            overlays[id]?.canvas.needsDisplay = true
        } else {
            for w in overlays.values { w.canvas.needsDisplay = true }
        }
    }

    func setAnnotationsHidden(_ hidden: Bool) {
        for w in overlays.values { w.canvas.annotationsHidden = hidden }
    }

    func commitAllText() {
        for w in overlays.values { w.canvas.commitText() }
    }

    /// 立即重畫所有覆蓋層（截圖前呼叫，確保剛確定的文字已經畫上去）
    func displayAllNow() {
        for w in overlays.values { w.canvas.displayIfNeeded() }
    }

    func closeAll() {
        for w in overlays.values { w.close() }
        overlays.removeAll()
    }
}
