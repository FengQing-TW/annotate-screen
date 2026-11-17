import AppKit
import AnnotateCore

/// 浮動工具列：NSPanel，可拖曳、記住位置；sharingType = .none，截圖時也明確排除
/// 不能成為 key，點按鈕不會搶走覆蓋層或 PowerPoint 的鍵盤焦點
@MainActor
final class ToolbarController: NSObject, NSWindowDelegate {
    private unowned let app: AppController
    let panel: NSPanel

    private var toolButtons: [Tool: ToolbarButton] = [:]
    private var colorButtons: [ColorSwatchButton] = []
    private var modeButton: ToolbarButton!
    private var widthButton: ToolbarButton!
    private var spotlightButton: ToolbarButton!
    private var magnifierButton: ToolbarButton!
    private var whiteboardButton: ToolbarButton!
    private var blackboardButton: ToolbarButton!
    private var hideButton: ToolbarButton!

    init(app: AppController) {
        self.app = app
        panel = makeFloatingPanel(frame: NSRect(x: 0, y: 0, width: 400, height: 80), level: WindowLevels.toolbar)
        super.init()
        panel.sharingType = .none
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        buildContent()
        restorePosition()
        panel.delegate = self
    }

    var isVisible: Bool { panel.isVisible }

    func show() {
        ensureOnScreen()
        panel.orderFrontRegardless()
    }

    func hide() {
        panel.orderOut(nil)
    }

    func toggle() {
        isVisible ? hide() : show()
    }

    // MARK: - 版面

    private func buildContent() {
        let a = app
        modeButton = ToolbarButton.make(symbol: "hand.draw", fallback: "畫", tooltip: "畫圖模式（⌃⌥A）") { a.toggleDrawing() }

        var row1: [NSView] = [modeButton, spacer()]
        let toolSymbols: [Tool: (String, String)] = [
            .pen: ("pencil.tip", "筆"),
            .highlighter: ("highlighter", "螢"),
            .line: ("line.diagonal", "線"),
            .arrow: ("arrow.up.right", "箭"),
            .rectangle: ("rectangle", "框"),
            .ellipse: ("circle", "圓"),
            // textformat 在繁中系統會本地化成「格式」字樣，改用不會本地化的 t.square
            .text: ("t.square", "字"),
            .laser: ("rays", "雷"),
            .eraser: ("eraser", "擦"),
        ]
        for tool in Tool.allCases {
            let (symbol, fallback) = toolSymbols[tool] ?? ("questionmark", "?")
            let key = String(tool.keyCharacter).uppercased()
            let b = ToolbarButton.make(symbol: symbol, fallback: fallback, tooltip: "\(tool.displayName)（\(key)）") {
                a.selectTool(tool)
            }
            toolButtons[tool] = b
            row1.append(b)
        }
        widthButton = ToolbarButton.makeText("中", tooltip: "粗細（[ ] 調整，點一下切換）") { a.cycleWidth() }
        let undoButton = ToolbarButton.make(symbol: "arrow.uturn.backward", fallback: "復", tooltip: "復原（⌘Z／⌃⌥Z）") { a.undo() }
        let redoButton = ToolbarButton.make(symbol: "arrow.uturn.forward", fallback: "重", tooltip: "重做（⇧⌘Z）") { a.redo() }
        let clearButton = ToolbarButton.make(symbol: "trash", fallback: "清", tooltip: "清除所有螢幕的標註（⌃⌥X 只清游標所在螢幕）") { a.clearAll() }
        row1.append(contentsOf: [spacer(), widthButton, undoButton, redoButton, clearButton])

        var row2: [NSView] = []
        for (i, color) in Palette.colors.enumerated() {
            let b = ColorSwatchButton.make(color: color.nsColor, tooltip: "\(Palette.names[i])（\(i + 1)）") {
                a.selectColor(i)
            }
            colorButtons.append(b)
            row2.append(b)
        }
        spotlightButton = ToolbarButton.make(symbol: "flashlight.on.fill", fallback: "燈", tooltip: "聚光燈（⌃⌥F）") { a.toggleSpotlight() }
        magnifierButton = ToolbarButton.make(symbol: "plus.magnifyingglass", fallback: "鏡", tooltip: "放大鏡（⌃⌥M）") { a.toggleMagnifier() }
        whiteboardButton = ToolbarButton.make(symbol: "square", fallback: "白", tooltip: "白板（⌃⌥W）") { a.toggleBoard(.whiteboard) }
        blackboardButton = ToolbarButton.make(symbol: "square.fill", fallback: "黑", tooltip: "黑板（⌃⌥B）") { a.toggleBoard(.blackboard) }
        hideButton = ToolbarButton.make(symbol: "eye.slash", fallback: "隱", tooltip: "隱藏／顯示標註（⌃⌥H）") { a.toggleAnnotationsHidden() }
        let shotButton = ToolbarButton.make(symbol: "camera.viewfinder", fallback: "截", tooltip: "截圖（⌃⌥S）") { a.takeScreenshot() }
        let regionShotButton = ToolbarButton.make(symbol: "rectangle.dashed", fallback: "範", tooltip: "範圍截圖（⌃⌥R）") { a.takeRegionScreenshot() }
        let windowShotButton = ToolbarButton.make(symbol: "macwindow", fallback: "窗", tooltip: "視窗截圖（⌃⌥E）") { a.takeWindowScreenshot() }
        let closeButton = ToolbarButton.make(symbol: "xmark", fallback: "×", tooltip: "隱藏工具列（⌃⌥T）") { a.toggleToolbar() }
        row2.append(contentsOf: [
            spacer(),
            spotlightButton,
            magnifierButton,
            whiteboardButton,
            blackboardButton,
            hideButton,
            shotButton,
            regionShotButton,
            windowShotButton,
            closeButton,
        ])

        let column = NSStackView(views: [makeRow(row1), makeRow(row2)])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 4
        column.edgeInsets = NSEdgeInsets(top: 6, left: 8, bottom: 6, right: 8)
        column.translatesAutoresizingMaskIntoConstraints = false

        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.appearance = NSAppearance(named: .darkAqua)
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 10
        effect.layer?.masksToBounds = true
        effect.addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            column.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            column.topAnchor.constraint(equalTo: effect.topAnchor),
            column.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])
        panel.contentView = effect
        effect.layoutSubtreeIfNeeded()
        panel.setContentSize(column.fittingSize)
    }

    private func makeRow(_ views: [NSView]) -> NSStackView {
        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.spacing = 2
        return row
    }

    /// 分隔用的空白（也是可以拖曳工具列的地方）
    private func spacer() -> NSView {
        let v = NSView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.widthAnchor.constraint(equalToConstant: 8).isActive = true
        v.heightAnchor.constraint(equalToConstant: ToolbarButton.side).isActive = true
        return v
    }

    // MARK: - 狀態

    /// 依目前狀態更新選取外觀
    func update() {
        let s = app.settings
        for (tool, b) in toolButtons { b.isChosen = (tool == s.tool) }
        for (i, b) in colorButtons.enumerated() { b.isChosen = (i == s.colorIndex) }
        widthButton.setText(s.widthLevel.displayName)
        modeButton.isChosen = app.isDrawing
        spotlightButton.isChosen = app.spotlightActive
        magnifierButton.isChosen = app.magnifierActive
        let page = app.pageUnderMouse
        whiteboardButton.isChosen = (page == .whiteboard)
        blackboardButton.isChosen = (page == .blackboard)
        hideButton.isChosen = app.annotationsHidden
    }

    // MARK: - 位置

    private func restorePosition() {
        if let origin = app.prefs.toolbarOrigin,
           NSScreen.screens.contains(where: { $0.frame.contains(origin) }) {
            panel.setFrameOrigin(origin)
        } else {
            placeDefault()
        }
    }

    private func placeDefault() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let size = panel.frame.size
        let vf = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(x: vf.midX - size.width / 2, y: vf.maxY - size.height - 12))
    }

    /// 螢幕拔掉後工具列可能跑到看不見的地方，拉回主螢幕
    func ensureOnScreen() {
        let f = panel.frame
        let visible = NSScreen.screens.contains { $0.frame.intersects(f.insetBy(dx: 20, dy: 10)) }
        if !visible { placeDefault() }
    }

    func windowDidMove(_ notification: Notification) {
        app.prefs.toolbarOrigin = panel.frame.origin
    }
}
