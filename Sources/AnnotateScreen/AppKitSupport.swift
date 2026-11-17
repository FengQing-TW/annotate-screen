import AppKit
import AnnotateCore

/// 各視窗的層級：覆蓋層 < 聚光燈 < 放大鏡 < 工具列 < toast < 範圍／視窗截圖選取 < 對話框
enum WindowLevels {
    static let overlay = NSWindow.Level.screenSaver
    static let spotlight = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
    static let magnifier = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 2)
    static let toolbar = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 3)
    static let toast = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 4)
    /// 範圍截圖的選取畫面要蓋住工具列與 toast
    static let selection = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 5)
    static let alert = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 6)

    /// 疊在全螢幕放映（獨立 Space）上方、所有 Space 都看得到
    static let overlayBehavior: NSWindow.CollectionBehavior = [
        .canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle,
    ]
}

extension NSScreen {
    /// 對應的 CGDirectDisplayID
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    /// 游標所在的螢幕
    static func underMouse() -> NSScreen? {
        let m = NSEvent.mouseLocation
        if let hit = screens.first(where: { NSMouseInRect(m, $0.frame, false) }) { return hit }
        if let near = screens.first(where: { $0.frame.insetBy(dx: -2, dy: -2).contains(m) }) { return near }
        return NSScreen.main ?? screens.first
    }
}

extension RGBAColor {
    var cgColor: CGColor {
        CGColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }

    var nsColor: NSColor {
        NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }
}

/// 建立透明、不搶前景的 NSPanel（工具列、toast、聚光燈、放大鏡共用）
@MainActor
func makeFloatingPanel(frame: NSRect, level: NSWindow.Level) -> NSPanel {
    let panel = NSPanel(
        contentRect: frame,
        styleMask: [.borderless, .nonactivatingPanel],
        backing: .buffered,
        defer: false
    )
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = false
    panel.level = level
    panel.collectionBehavior = WindowLevels.overlayBehavior
    panel.isReleasedWhenClosed = false
    panel.hidesOnDeactivate = false
    return panel
}
