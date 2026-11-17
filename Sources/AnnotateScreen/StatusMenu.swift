import AppKit
import AnnotateCore

/// 帶閉包的選單項目
@MainActor
final class ClosureMenuItem: NSMenuItem {
    private var handler: (() -> Void)?

    convenience init(
        _ title: String,
        key: String = "",
        modifiers: NSEvent.ModifierFlags = [.control, .option],
        checked: Bool = false,
        handler: @escaping () -> Void
    ) {
        self.init(title: title, action: #selector(ClosureMenuItem.fire), keyEquivalent: key)
        self.handler = handler
        self.target = self
        self.keyEquivalentModifierMask = key.isEmpty ? [] : modifiers
        self.state = checked ? .on : .off
    }

    @objc private func fire() {
        handler?()
    }
}

/// 選單列圖示與選單；每次打開時依目前狀態重建
@MainActor
final class StatusMenu: NSObject, NSMenuDelegate {
    private unowned let app: AppController
    private let statusItem: NSStatusItem
    private let menu = NSMenu()

    init(app: AppController) {
        self.app = app
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        menu.delegate = self
        statusItem.menu = menu
        updateIcon()
    }

    /// 畫圖模式時改用實心圖示
    func updateIcon() {
        let name = app.isDrawing ? "pencil.tip.crop.circle.fill" : "pencil.tip.crop.circle"
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "AnnotateScreen")
            ?? NSImage(systemSymbolName: "pencil.tip.crop.circle", accessibilityDescription: "AnnotateScreen")
        image?.isTemplate = true
        statusItem.button?.image = image
        statusItem.button?.toolTip = "AnnotateScreen"
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuild()
    }

    private func rebuild() {
        menu.removeAllItems()
        let a = app
        let s = a.settings

        if !a.failedHotKeys.isEmpty {
            addDisabled("⚠︎ 以下快捷鍵被其他程式佔用：")
            for name in a.failedHotKeys { addDisabled("　" + name) }
            menu.addItem(.separator())
        }

        add(ClosureMenuItem(a.isDrawing ? "結束畫圖" : "開始畫圖", key: "a") { a.toggleDrawing() })
        menu.addItem(.separator())

        for tool in Tool.allCases {
            add(ClosureMenuItem(tool.displayName, checked: s.tool == tool) { a.selectTool(tool) })
        }

        let colorMenu = NSMenu()
        for (i, name) in Palette.names.enumerated() {
            let item = ClosureMenuItem("\(i + 1)　\(name)", checked: s.colorIndex == i) { a.selectColor(i) }
            item.image = swatchImage(Palette.colors[i].nsColor)
            colorMenu.addItem(item)
        }
        addSubmenu("顏色", colorMenu)

        let widthMenu = NSMenu()
        for level in WidthLevel.allCases {
            widthMenu.addItem(ClosureMenuItem(level.displayName, checked: s.widthLevel == level) { a.setWidth(level) })
        }
        addSubmenu("粗細", widthMenu)
        menu.addItem(.separator())

        add(ClosureMenuItem("復原", key: "z") { a.undo() })
        add(ClosureMenuItem("重做") { a.redo() })
        add(ClosureMenuItem("清除所有螢幕", key: "x") { a.clearAll() })
        menu.addItem(.separator())

        add(ClosureMenuItem("聚光燈", key: "f", checked: a.spotlightActive) { a.toggleSpotlight() })
        let radiusMenu = NSMenu()
        for (title, r) in [("小", 90), ("中", 150), ("大", 220), ("特大", 320)] as [(String, CGFloat)] {
            let checked = abs(a.prefs.spotlightRadius - r) < 1
            radiusMenu.addItem(ClosureMenuItem("\(title)（半徑 \(Int(r))）", checked: checked) { a.setSpotlightRadius(r) })
        }
        radiusMenu.addItem(.separator())
        radiusMenu.addItem(ClosureMenuItem("加大") { a.setSpotlightRadius(a.prefs.spotlightRadius + 20) })
        radiusMenu.addItem(ClosureMenuItem("縮小") { a.setSpotlightRadius(a.prefs.spotlightRadius - 20) })
        addSubmenu("聚光燈範圍", radiusMenu)

        add(ClosureMenuItem("放大鏡", key: "m", checked: a.magnifierActive) { a.toggleMagnifier() })
        let zoomMenu = NSMenu()
        for z in [1.5, 2.0, 2.5, 3.0, 4.0] as [CGFloat] {
            let checked = abs(a.prefs.magnifierZoom - z) < 0.01
            zoomMenu.addItem(ClosureMenuItem(String(format: "%.1f×", Double(z)), checked: checked) { a.setMagnifierZoom(z) })
        }
        addSubmenu("放大倍率", zoomMenu)

        let page = a.pageUnderMouse
        add(ClosureMenuItem("白板", key: "w", checked: page == .whiteboard) { a.toggleBoard(.whiteboard) })
        add(ClosureMenuItem("黑板", key: "b", checked: page == .blackboard) { a.toggleBoard(.blackboard) })
        menu.addItem(.separator())

        add(ClosureMenuItem("截圖", key: "s") { a.takeScreenshot() })
        add(ClosureMenuItem("範圍截圖", key: "r") { a.takeRegionScreenshot() })
        add(ClosureMenuItem("視窗截圖", key: "e") { a.takeWindowScreenshot() })
        add(ClosureMenuItem("開啟截圖資料夾") { a.openScreenshotFolder() })
        menu.addItem(.separator())

        add(ClosureMenuItem(a.toolbarVisible ? "隱藏工具列" : "顯示工具列", key: "t") { a.toggleToolbar() })
        add(ClosureMenuItem("隱藏標註", key: "h", checked: a.annotationsHidden) { a.toggleAnnotationsHidden() })
        add(ClosureMenuItem("快捷鍵說明…") { a.showShortcutHelp() })
        menu.addItem(.separator())
        add(ClosureMenuItem("結束 AnnotateScreen", key: "q", modifiers: [.command]) { NSApp.terminate(nil) })
    }

    private func add(_ item: NSMenuItem) {
        menu.addItem(item)
    }

    private func addDisabled(_ title: String) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        menu.addItem(item)
    }

    private func addSubmenu(_ title: String, _ submenu: NSMenu) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        menu.addItem(item)
    }

    private func swatchImage(_ color: NSColor) -> NSImage {
        NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            return true
        }
    }
}
