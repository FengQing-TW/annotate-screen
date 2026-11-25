import AppKit
import Carbon
import ScreenCaptureKit
import AnnotateCore

/// 中央控制：持有各螢幕標註、模式狀態，並協調覆蓋層、工具列、選單、熱鍵、聚光燈、放大鏡、截圖
@MainActor
final class AppController {
    let prefs: Preferences
    private(set) var isDrawing = false
    private(set) var annotationsHidden = false
    /// 註冊失敗的全域快捷鍵（顯示在選單）
    private(set) var failedHotKeys: [String] = []

    /// 各螢幕的標註（以 CGDirectDisplayID 對應；螢幕拔掉也保留，插回來還在）
    private var pages: [CGDirectDisplayID: PageSet] = [:]

    private var overlays: OverlayManager!
    private var toolbar: ToolbarController!
    private var statusMenu: StatusMenu!
    private var spotlight: SpotlightController!
    private var magnifier: MagnifierController!
    private let hotKeys: HotKeyManager
    private var assistHotKeyIDs: [UInt32] = []
    private let screenshot: ScreenshotService
    private let regionSelection: RegionSelectionController
    private let toast: Toast
    private var screenObserver: NSObjectProtocol?
    private var isCapturing = false

    init() {
        prefs = Preferences()
        hotKeys = HotKeyManager()
        screenshot = ScreenshotService()
        regionSelection = RegionSelectionController()
        toast = Toast()
    }

    // MARK: - 啟動／結束

    func start() {
        overlays = OverlayManager(app: self)
        overlays.rebuild()
        spotlight = SpotlightController(radius: prefs.spotlightRadius)
        magnifier = MagnifierController(zoom: prefs.magnifierZoom)
        // 放大鏡串流啟動失敗或中途停止：放大鏡會自行關閉，這裡提示並同步介面與 [ ] 熱鍵
        magnifier.onError = { [weak self] message in
            guard let self else { return }
            self.toast.show(message, on: NSScreen.underMouse())
            self.updateAssistHotKeys()
            self.refreshUI()
        }
        toolbar = ToolbarController(app: self)
        toolbar.show()
        // 放大鏡自我測試時不註冊全域熱鍵（正式版可能同時在執行）
        let magnifierSelfTest = ProcessInfo.processInfo.environment["ANNOTATE_SELFTEST_MAGNIFIER"] == "1"
        if !magnifierSelfTest {
            registerHotKeys()
        }
        statusMenu = StatusMenu(app: self)
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.screensChanged()
            }
        }
        refreshUI()
        if ProcessInfo.processInfo.environment["ANNOTATE_SELFTEST"] == "1" {
            runSelfTest()
        }
        if magnifierSelfTest {
            runMagnifierSelfTest()
        }
    }

    /// 自我測試（只在環境變數 ANNOTATE_SELFTEST=1 時執行）：
    /// 在主螢幕畫出每一種筆畫，並讓工具列暫時可被截圖，方便用系統 screencapture 檢查繪製結果
    private func runSelfTest() {
        guard let screen = NSScreen.screens.first, let id = screen.displayID else { return }
        toolbar.panel.sharingType = .readOnly
        let doc = pageSet(for: id).currentDocument
        let c = Palette.colors
        let wave = (0..<60).map { i in CGPoint(x: 200 + Double(i) * 8, y: 300 + sin(Double(i) / 5) * 40) }
        doc.add(Stroke(kind: .freehand, color: c[0], lineWidth: 4, points: wave))
        doc.add(Stroke(kind: .highlighter, color: c[2].withAlpha(0.35), lineWidth: 24,
                       points: [CGPoint(x: 200, y: 420), CGPoint(x: 700, y: 420), CGPoint(x: 680, y: 430)]))
        doc.add(Stroke(kind: .line, color: c[3], lineWidth: 4, points: [CGPoint(x: 200, y: 500), CGPoint(x: 700, y: 500)]))
        doc.add(Stroke(kind: .arrow, color: c[4], lineWidth: 6, points: [CGPoint(x: 200, y: 580), CGPoint(x: 700, y: 640)]))
        doc.add(Stroke(kind: .rectangle, color: c[5], lineWidth: 4, points: [CGPoint(x: 800, y: 280), CGPoint(x: 1100, y: 450)]))
        doc.add(Stroke(kind: .ellipse, color: c[1], lineWidth: 4, points: [CGPoint(x: 800, y: 500), CGPoint(x: 1100, y: 650)]))
        doc.add(Stroke(kind: .text, color: c[0], lineWidth: 4, points: [CGPoint(x: 1200, y: 300)],
                       text: "自我測試 Self-test 重點", fontSize: 36,
                       textFrame: CGRect(x: 1200, y: 300, width: 500, height: 50)))
        overlays.redisplay(id)

        // 有指定輸出目錄時，把覆蓋層與工具列離屏繪製成 PNG（螢幕鎖定時也能檢查）
        if let dir = ProcessInfo.processInfo.environment["ANNOTATE_SELFTEST_OUT"] {
            let targets: [(String, NSView?)] = [
                ("overlay.png", overlays.canvas(for: id)),
                ("toolbar.png", toolbar.panel.contentView),
            ]
            for (name, view) in targets {
                guard let view, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
                view.cacheDisplay(in: view.bounds, to: rep)
                let url = URL(fileURLWithPath: dir).appendingPathComponent(name)
                try? rep.representation(using: .png, properties: [:])?.write(to: url)
            }
        }
    }

    // MARK: - 放大鏡自我測試（2026-11-13）

    /// 只在環境變數 ANNOTATE_SELFTEST_MAGNIFIER=1 時執行；不畫筆畫、不註冊全域熱鍵。
    /// 在面積最大的螢幕上依序把放大鏡移到 6 個點，每個點存放大鏡畫面 mag_N.png 與對照截圖 ref_N.png，
    /// 最後寫 magnifier_selftest.txt 並結束程式。輸出目錄取 ANNOTATE_SELFTEST_OUT（沒設就用暫存目錄）
    private func runMagnifierSelfTest() {
        let env = ProcessInfo.processInfo.environment
        let outDir = URL(fileURLWithPath: env["ANNOTATE_SELFTEST_OUT"] ?? NSTemporaryDirectory(), isDirectory: true)
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let reportURL = outDir.appendingPathComponent("magnifier_selftest.txt")

        guard CGPreflightScreenCaptureAccess() else {
            Self.writeReport(["沒有螢幕錄製權限（CGPreflightScreenCaptureAccess() == false），未執行放大鏡自我測試"], to: reportURL)
            NSApp.terminate(nil)
            return
        }
        guard let screen = NSScreen.screens.max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }),
              let displayID = screen.displayID else {
            Self.writeReport(["找不到螢幕，未執行放大鏡自我測試"], to: reportURL)
            NSApp.terminate(nil)
            return
        }

        let f = screen.frame
        let inner = f.insetBy(dx: 30, dy: 30)
        func clamped(_ p: NSPoint) -> NSPoint {
            NSPoint(x: min(max(p.x, inner.minX), inner.maxX), y: min(max(p.y, inner.minY), inner.maxY))
        }
        // AppKit 全域座標（y 向上）：①中心 ②右移 600 ③左上角內 30 ④右下角內 30 ⑤下移 500 ⑥回中心
        let points: [NSPoint] = [
            NSPoint(x: f.midX, y: f.midY),
            NSPoint(x: f.midX + 600, y: f.midY),
            NSPoint(x: f.minX + 30, y: f.maxY - 30),
            NSPoint(x: f.maxX - 30, y: f.minY + 30),
            NSPoint(x: f.midX, y: f.midY - 500),
            NSPoint(x: f.midX, y: f.midY),
        ].map(clamped)

        magnifier.fullDisplay = prefs.magnifierFullDisplay
        magnifier.mouseOverride = points[0]
        magnifier.start()

        Task { @MainActor in
            let mainHeight = NSScreen.screens.first?.frame.height ?? f.height
            let side = MagnifierController.diameter / self.magnifier.zoom
            var lines: [String] = [
                "# 放大鏡自我測試 2026-11-13",
                "# 螢幕 displayID=\(displayID) AppKit frame=\(Self.fmt(f)) scale=\(screen.backingScaleFactor) "
                    + "zoom=\(self.magnifier.zoom) 放大區邊長=\(side) 點 fullDisplay=\(self.magnifier.fullDisplay)",
                "# 欄位：序號 AppKit點 CG點 影格screenRect 影格像素 mag圖 ref圖（ref 的 sourceRect 已夾進顯示器，超出部分 mag 圖為透明）",
            ]

            // 等第一張影格（串流啟動要查 SCShareableContent，可能超過 0.7 秒），最多 3 秒
            var waited = 0
            while self.magnifier.isActive && self.magnifier.latestFrameInfo == nil && waited < 30 {
                try? await Task.sleep(nanoseconds: 100_000_000)
                waited += 1
            }
            lines.append("# 第一張影格等了約 \(waited * 100) ms")

            for (i, p) in points.enumerated() {
                let n = i + 1
                guard self.magnifier.isActive else {
                    lines.append("\(n)\t放大鏡已關閉（串流失敗或停止），中止")
                    break
                }
                self.magnifier.mouseOverride = p
                try? await Task.sleep(nanoseconds: 700_000_000)

                let cg = WindowPicking.cgPoint(fromAppKit: p, mainScreenHeight: mainHeight)
                let info = self.magnifier.latestFrameInfo
                var magSaved = false
                if let image = self.magnifier.currentImage {
                    magSaved = Self.writePNG(image, to: outDir.appendingPathComponent("mag_\(n).png"))
                }
                let ref = await self.captureMagnifierReference(
                    displayID: displayID, screen: screen, point: p, side: side,
                    to: outDir.appendingPathComponent("ref_\(n).png")
                )
                let frameText = info.map { "screenRect=\(Self.fmt($0.screenRect))\tpixels=\(Int($0.pixelSize.width))x\(Int($0.pixelSize.height))" }
                    ?? "screenRect=無\tpixels=無"
                lines.append("\(n)\tAppKit=\(Self.fmt(p))\tCG=\(Self.fmt(cg))\t\(frameText)\tmag=\(magSaved ? "yes" : "no")\tref=\(ref)")
            }

            lines.append("updateConfiguration=\(self.magnifier.updateConfigurationCount) restarts=\(self.magnifier.timeoutRestartCount)")
            Self.writeReport(lines, to: reportURL)
            self.magnifier.mouseOverride = nil
            self.magnifier.stop()
            // 讓 stopCapture 有機會跑完再結束
            try? await Task.sleep(nanoseconds: 300_000_000)
            NSApp.terminate(nil)
        }
    }

    /// 對照截圖：同一個顯示器、排除本程式所有視窗，以 point 為中心、邊長 side 點的正方形（夾進顯示器內）
    /// 回傳寫進報告的說明
    private func captureMagnifierReference(
        displayID: CGDirectDisplayID, screen: NSScreen, point: NSPoint, side: CGFloat, to url: URL
    ) async -> String {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
                return "no（找不到顯示器）"
            }
            let pid = ProcessInfo.processInfo.processIdentifier
            let ownWindows = content.windows.filter { $0.owningApplication?.processID == pid }
            let filter = SCContentFilter(display: display, excludingWindows: ownWindows)
            let scale = filter.pointPixelScale > 0 ? CGFloat(filter.pointPixelScale) : screen.backingScaleFactor

            // 顯示器內左上原點
            let f = screen.frame
            let local = CGPoint(x: point.x - f.minX, y: f.maxY - point.y)
            let square = CGRect(x: local.x - side / 2, y: local.y - side / 2, width: side, height: side)
            let rect = square.intersection(CGRect(origin: .zero, size: f.size))
            guard !rect.isNull, rect.width > 0, rect.height > 0 else { return "no（範圍在顯示器外）" }

            let config = SCStreamConfiguration()
            config.sourceRect = rect
            config.width = max(1, Int((rect.width * scale).rounded()))
            config.height = max(1, Int((rect.height * scale).rounded()))
            config.showsCursor = false
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            let ok = Self.writePNG(image, to: url)
            return "\(ok ? "yes" : "no（PNG 寫入失敗）") sourceRect=\(Self.fmt(rect)) pixels=\(image.width)x\(image.height)"
        } catch {
            return "no（\(error.localizedDescription)）"
        }
    }

    private static func writePNG(_ image: CGImage, to url: URL) -> Bool {
        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .png, properties: [:]) else { return false }
        do {
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    private static func writeReport(_ lines: [String], to url: URL) {
        let text = lines.joined(separator: "\n") + "\n"
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            NSLog("AnnotateScreen：放大鏡自我測試報告寫入失敗 \(error.localizedDescription)")
        }
    }

    private static func fmt(_ p: CGPoint) -> String {
        String(format: "(%.1f,%.1f)", Double(p.x), Double(p.y))
    }

    private static func fmt(_ r: CGRect) -> String {
        String(format: "(%.1f,%.1f,%.1f,%.1f)", Double(r.minX), Double(r.minY), Double(r.width), Double(r.height))
    }

    func shutdown() {
        hotKeys.unregisterAll()
        spotlight?.stop()
        magnifier?.stop()
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
    }

    private func registerHotKeys() {
        let mods = controlKey | optionKey
        // 熱鍵事件處理器沒裝成功時，註冊了也不會有反應，全部標示為失敗
        let handlerOK = hotKeys.isHandlerInstalled
        let table: [(Int, String, String, () -> Void)] = [
            (kVK_ANSI_A, "A", "切換畫圖／穿透", { [unowned self] in self.toggleDrawing() }),
            (kVK_ANSI_S, "S", "截圖", { [unowned self] in self.takeScreenshot() }),
            (kVK_ANSI_R, "R", "範圍截圖", { [unowned self] in self.takeRegionScreenshot() }),
            (kVK_ANSI_E, "E", "視窗截圖", { [unowned self] in self.takeWindowScreenshot() }),
            (kVK_ANSI_X, "X", "清除標註", { [unowned self] in self.clear() }),
            (kVK_ANSI_Z, "Z", "復原", { [unowned self] in self.undo() }),
            (kVK_ANSI_F, "F", "聚光燈", { [unowned self] in self.toggleSpotlight() }),
            (kVK_ANSI_M, "M", "放大鏡", { [unowned self] in self.toggleMagnifier() }),
            (kVK_ANSI_W, "W", "白板", { [unowned self] in self.toggleBoard(.whiteboard) }),
            (kVK_ANSI_B, "B", "黑板", { [unowned self] in self.toggleBoard(.blackboard) }),
            (kVK_ANSI_H, "H", "隱藏／顯示標註", { [unowned self] in self.toggleAnnotationsHidden() }),
            (kVK_ANSI_T, "T", "顯示／隱藏工具列", { [unowned self] in self.toggleToolbar() }),
        ]
        for (code, letter, title, action) in table {
            let wrapped: () -> Void = { [unowned self] in self.runFromHotKey(action) }
            if !handlerOK || hotKeys.register(keyCode: code, modifiers: mods, action: wrapped) == nil {
                failedHotKeys.append("⌃⌥\(letter) \(title)")
            }
        }
        // ⌘4：畫筆 ↔ 滑鼠 來回切換（2026-11-17 使用者要求，見 toggleQuickMode）。常駐的全域熱鍵：
        // 要能從滑鼠模式按回畫筆，就不能只在畫圖時註冊；代價是其他程式的 ⌘4 會失效（使用者知情並選擇）
        let quick: () -> Void = { [unowned self] in self.runFromHotKey { self.toggleQuickMode() } }
        if !handlerOK || hotKeys.register(keyCode: kVK_ANSI_4, modifiers: cmdKey, action: quick) == nil {
            failedHotKeys.append("⌘4 畫筆／滑鼠切換")
        }
        // ⌘3：畫筆 ↔ 滑鼠 來回切換，但不清除、只隱藏標註（2026-11-25 使用者要求，見 toggleQuickHideMode）。
        // 同 ⌘4 常駐註冊；代價是其他程式的 ⌘3 會失效
        let quickHide: () -> Void = { [unowned self] in self.runFromHotKey { self.toggleQuickHideMode() } }
        if !handlerOK || hotKeys.register(keyCode: kVK_ANSI_3, modifiers: cmdKey, action: quickHide) == nil {
            failedHotKeys.append("⌘3 畫筆／滑鼠切換（隱藏標註）")
        }
    }

    /// 聚光燈／放大鏡開啟時，暫時註冊不帶修飾鍵的 [ ]（覆蓋層此時穿透、收不到鍵盤）
    private func updateAssistHotKeys() {
        let needed = spotlight.isActive || magnifier.isActive
        if needed && assistHotKeyIDs.isEmpty {
            let pairs: [(Int, Int)] = [(kVK_ANSI_LeftBracket, -1), (kVK_ANSI_RightBracket, 1)]
            for (code, delta) in pairs {
                if let id = hotKeys.register(keyCode: code, modifiers: 0, action: { [unowned self] in self.adjustAssist(delta) }) {
                    assistHotKeyIDs.append(id)
                }
            }
            // 被其他程式佔用時提示一次（選單裡仍可調半徑與倍率）
            if assistHotKeyIDs.count < pairs.count {
                toast.show("[ ] 快捷鍵被佔用，請從選單調整半徑／倍率", on: NSScreen.underMouse())
            }
        } else if !needed && !assistHotKeyIDs.isEmpty {
            for id in assistHotKeyIDs { hotKeys.unregister(id) }
            assistHotKeyIDs.removeAll()
        }
    }

    /// 聚光燈與放大鏡
    private enum Assist { case spotlight, magnifier }
    /// 最後開啟的是哪一個；兩個都開著時 [ ] 調這一個（2026-11-13）
    private var lastOpenedAssist: Assist = .spotlight

    private func adjustAssist(_ delta: Int) {
        let target: Assist
        switch (spotlight.isActive, magnifier.isActive) {
        case (true, true): target = lastOpenedAssist
        case (true, false): target = .spotlight
        case (false, true): target = .magnifier
        case (false, false): return
        }
        switch target {
        case .spotlight: setSpotlightRadius(prefs.spotlightRadius + CGFloat(delta) * 20)
        case .magnifier: setMagnifierZoom(prefs.magnifierZoom + CGFloat(delta) * 0.5)
        }
    }

    private func screensChanged() {
        // 選取中螢幕插拔：選取 panel 的位置已不對，直接取消
        if regionSelection.isActive && !isCapturing { regionSelection.cancel() }
        overlays.rebuild()
        spotlight.screensChanged()
        magnifier.screensChanged()
        toolbar.ensureOnScreen()
        refreshUI()
    }

    // MARK: - 狀態查詢

    var settings: ToolSettings {
        ToolSettings(tool: prefs.tool, colorIndex: prefs.colorIndex, widthLevel: prefs.widthLevel)
    }

    var spotlightActive: Bool { spotlight?.isActive ?? false }
    var magnifierActive: Bool { magnifier?.isActive ?? false }
    var toolbarVisible: Bool { toolbar?.isVisible ?? false }

    func pageSet(for id: CGDirectDisplayID) -> PageSet {
        if let p = pages[id] { return p }
        let p = PageSet()
        pages[id] = p
        return p
    }

    /// 目標螢幕目前的頁面（工具列用來顯示白板／黑板狀態）
    var pageUnderMouse: Page {
        guard let id = targetScreen()?.displayID else { return .screen }
        return pageSet(for: id).currentPage
    }

    // MARK: - 動作作用在哪個螢幕（2026-11-13 使用者回報修正）
    // 原本一律是「游標所在螢幕」。但按工具列或選單時，游標在工具列／選單列那台螢幕上；
    // 工具列和繪圖不在同一台時，按「清除」清的是工具列那台（沒東西），看起來沒反應。
    // 現在：快捷鍵 → 游標所在螢幕（並記成最後使用的螢幕）；工具列、選單 → 最後畫過或用過快捷鍵的螢幕。

    /// 最後畫過，或最後按快捷鍵時游標所在的螢幕
    private(set) var lastActiveDisplayID: CGDirectDisplayID?
    private var hotKeyInProgress = false

    /// 在某個螢幕的覆蓋層上開始畫（CanvasView 通知）
    func noteActive(_ id: CGDirectDisplayID) {
        lastActiveDisplayID = id
        clearedAll = []   // 畫了新的東西，「全部清除」的一鍵復原就不再適用
    }

    /// 上一次「清除所有螢幕」清到的螢幕與被清的那份文件；緊接著按復原時一次全部還原
    /// 2026-11-13：記文件本身，清除後切到白板／黑板再復原，才不會退到錯的頁面
    private var clearedAll: [(displayID: CGDirectDisplayID, document: AnnotationDocument)] = []

    private func runFromHotKey(_ action: () -> Void) {
        if let id = NSScreen.underMouse()?.displayID { lastActiveDisplayID = id }
        hotKeyInProgress = true
        defer { hotKeyInProgress = false }
        action()
    }

    /// 動作要作用的螢幕
    func targetScreen() -> NSScreen? {
        let underMouse = NSScreen.underMouse()
        if hotKeyInProgress { return underMouse }
        if let id = lastActiveDisplayID, let s = NSScreen.screens.first(where: { $0.displayID == id }) { return s }
        return underMouse
    }

    private func targetDisplayID(_ id: CGDirectDisplayID?) -> CGDirectDisplayID? {
        id ?? targetScreen()?.displayID
    }

    func refreshUI() {
        toolbar?.update()
        statusMenu?.updateIcon()
    }

    /// 文件內容改變（由覆蓋層通知）
    func documentDidChange(_ id: CGDirectDisplayID) {
        overlays.redisplay(id)
    }

    // MARK: - 模式

    func toggleDrawing() {
        setDrawing(!isDrawing)
    }

    func setDrawing(_ on: Bool) {
        if on {
            // 規格：聚光燈、放大鏡開啟時覆蓋層維持穿透，所以進畫圖模式就關掉它們
            spotlight.stop()
            magnifier.stop()
            updateAssistHotKeys()
            if annotationsHidden { setAnnotationsHidden(false) }
        }
        isDrawing = on
        overlays.setDrawing(on, focus: targetScreen())
        refreshUI()
    }

    // MARK: - 工具、顏色、粗細

    /// 選工具；從工具列或選單選工具時順便進入畫圖模式
    func selectTool(_ tool: Tool) {
        overlays.commitAllText()
        prefs.tool = tool
        if !isDrawing { setDrawing(true) }
        refreshUI()
    }

    func selectColor(_ index: Int) {
        prefs.colorIndex = index
        refreshUI()
    }

    func setWidth(_ level: WidthLevel) {
        prefs.widthLevel = level
        refreshUI()
    }

    func adjustWidth(_ delta: Int) {
        setWidth(prefs.widthLevel.stepped(delta))
    }

    /// 工具列的粗細按鈕：細→中→粗→特粗→細
    func cycleWidth() {
        let next = WidthLevel(rawValue: prefs.widthLevel.rawValue + 1) ?? .thin
        setWidth(next)
    }

    // MARK: - 編輯

    func undo(displayID: CGDirectDisplayID? = nil) {
        // 剛按過「清除所有螢幕」：工具列、選單或 ⌃⌥Z 的復原一次把那幾台都還原（2026-11-13 使用者回報要按多次）
        if displayID == nil, !clearedAll.isEmpty {
            for entry in clearedAll where entry.document.undo() { overlays.redisplay(entry.displayID) }
            clearedAll = []
            return
        }
        guard let id = targetDisplayID(displayID) else { return }
        clearedAll.removeAll { $0.displayID == id }   // 這台已經單獨復原過，之後的「全部還原」不要再退它一步
        overlays.canvas(for: id)?.commitText()
        if pageSet(for: id).currentDocument.undo() {
            overlays.redisplay(id)
        } else {
            // 2026-11-13：沒東西可復原時給個提示，不然看起來像沒反應
            toast.show("沒有可以復原的動作", on: screenFor(id))
        }
    }

    func redo(displayID: CGDirectDisplayID? = nil) {
        guard let id = targetDisplayID(displayID) else { return }
        if pageSet(for: id).currentDocument.redo() {
            overlays.redisplay(id)
        } else {
            toast.show("沒有可以重做的動作", on: screenFor(id))
        }
    }

    /// 以 displayID 找螢幕（給 toast 用；找不到時 toast 會退回主螢幕）
    private func screenFor(_ id: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first(where: { $0.displayID == id })
    }

    /// 清除所有螢幕目前的頁面（工具列、選單用；可一鍵復原）
    /// 2026-11-13 使用者回報：雙螢幕時工具列的清除一次只清一台，要按很多次
    func clearAll() {
        clearedAll = []
        for screen in NSScreen.screens {
            guard let id = screen.displayID else { continue }
            // 2026-11-13：還沒按 Enter 的文字先確定進文件再清，復原時會一起回來（原本直接丟掉）
            overlays.canvas(for: id)?.commitText()
            overlays.canvas(for: id)?.cancelInteraction()
            let doc = pageSet(for: id).currentDocument
            if doc.clear() {
                overlays.redisplay(id)
                clearedAll.append((displayID: id, document: doc))
            }
        }
    }

    /// ⌘4：畫筆 ↔ 滑鼠 來回切換（2026-11-17 使用者要求）
    /// - 正在畫圖 → 清除所有螢幕的標註，回到穿透模式讓滑鼠操作底下的程式
    /// - 不在畫圖 → 回到畫圖模式（沿用目前的工具與顏色）；畫面上原有的標註不動
    func toggleQuickMode() {
        if isDrawing { clearAllAndExitDrawing() } else { setDrawing(true) }
    }

    /// ⌘3：畫筆 ↔ 滑鼠 來回切換，不清除標註（2026-11-25 使用者要求）
    /// - 正在畫圖 → 隱藏所有螢幕的標註，回到穿透模式；標註仍保留在文件裡
    /// - 不在畫圖 → 回到畫圖模式，setDrawing(true) 會把隱藏的標註重新顯示
    func toggleQuickHideMode() {
        if isDrawing { hideAllAndExitDrawing() } else { setDrawing(true) }
    }

    /// 隱藏所有螢幕的標註並回到穿透模式（不清除；⌘3、⌃⌥H 或再進畫圖模式就會重新顯示）
    func hideAllAndExitDrawing() {
        overlays.commitAllText()   // 還沒按 Enter 的文字先確定，免得隱藏時被丟掉
        setAnnotationsHidden(true)
        setDrawing(false)
    }

    /// 清除所有螢幕的標註並回到穿透模式；清掉的內容可以用 ⌃⌥Z 或工具列的復原一次全部還原
    func clearAllAndExitDrawing() {
        clearAll()
        setDrawing(false)
    }

    /// 清除一個螢幕目前的頁面（可復原）：快捷鍵 ⌃⌥X＝游標所在螢幕、畫圖模式的 ⌫＝那個覆蓋層
    func clear(displayID: CGDirectDisplayID? = nil) {
        clearedAll = []
        guard let id = targetDisplayID(displayID) else { return }
        // 2026-11-13：還沒按 Enter 的文字先確定進文件再清，復原時會一起回來
        overlays.canvas(for: id)?.commitText()
        overlays.canvas(for: id)?.cancelInteraction()
        if pageSet(for: id).currentDocument.clear() { overlays.redisplay(id) }
    }

    func setAnnotationsHidden(_ hidden: Bool) {
        annotationsHidden = hidden
        overlays.setAnnotationsHidden(hidden)
        refreshUI()
    }

    func toggleAnnotationsHidden() {
        if !annotationsHidden { overlays.commitAllText() }
        setAnnotationsHidden(!annotationsHidden)
    }

    // MARK: - 簡報輔助

    func toggleSpotlight() {
        if spotlight.isActive {
            spotlight.stop()
        } else {
            if isDrawing { setDrawing(false) }
            spotlight.start()
            lastOpenedAssist = .spotlight
        }
        updateAssistHotKeys()
        refreshUI()
    }

    func setSpotlightRadius(_ r: CGFloat) {
        prefs.spotlightRadius = r
        spotlight.radius = prefs.spotlightRadius
    }

    func toggleMagnifier() {
        if magnifier.isActive {
            magnifier.stop()
        } else {
            guard Alerts.ensureScreenCaptureAccess() else { return }
            if isDrawing { setDrawing(false) }
            magnifier.fullDisplay = prefs.magnifierFullDisplay
            magnifier.start()
            lastOpenedAssist = .magnifier
        }
        updateAssistHotKeys()
        refreshUI()
    }

    func setMagnifierZoom(_ z: CGFloat) {
        prefs.magnifierZoom = z
        magnifier.zoom = prefs.magnifierZoom
    }

    /// 白板／黑板開關（游標所在螢幕）；打開時順便進入畫圖模式
    func toggleBoard(_ page: Page) {
        guard let id = targetScreen()?.displayID else { return }
        overlays.canvas(for: id)?.commitText()
        overlays.canvas(for: id)?.cancelInteraction()
        let set = pageSet(for: id)
        set.toggle(page)
        overlays.redisplay(id)
        if set.currentPage != .screen && !isDrawing {
            setDrawing(true)
        }
        refreshUI()
    }

    // MARK: - 截圖

    func takeScreenshot() {
        // 範圍／視窗選取中不做全螢幕截圖（否則會拍到選取遮罩；兩種選取共用 regionSelection）
        guard !isCapturing, !regionSelection.isActive else { return }
        guard Alerts.ensureScreenCaptureAccess() else { return }
        guard let screen = targetScreen(), let id = screen.displayID else { return }
        overlays.commitAllText()
        overlays.displayAllNow()
        let excluded = captureExclusions()
        isCapturing = true
        Task { @MainActor in
            defer { self.isCapturing = false }
            do {
                let url = try await self.screenshot.capture(screen: screen, displayID: id, excludingWindowNumbers: excluded)
                self.toast.show("已存檔：\(url.lastPathComponent)（已複製到剪貼簿）", on: screen)
            } catch {
                self.toast.show("截圖失敗：\(error.localizedDescription)", on: screen)
            }
        }
    }

    /// 範圍截圖：拖曳選一塊矩形，只截那一塊；存檔與剪貼簿同全螢幕截圖
    /// 選取期間不動聚光燈、放大鏡、標註；選取中或截圖中重複觸發一律忽略
    func takeRegionScreenshot() {
        beginSelection(.region)
    }

    /// 視窗截圖（2026-11-13）：游標下的視窗高亮、點一下截那個視窗在螢幕上的範圍（含覆蓋層上的標註、被擋住的部分照實截）
    /// 擷取走範圍截圖同一條 sourceRect 路徑；其餘行為與範圍截圖相同
    func takeWindowScreenshot() {
        beginSelection(.window)
    }

    private func beginSelection(_ mode: RegionSelectionMode) {
        guard !isCapturing, !regionSelection.isActive else { return }
        guard Alerts.ensureScreenCaptureAccess() else { return }
        // 選取 panel 會搶走 key，先把輸入中的文字確定下來
        overlays.commitAllText()
        regionSelection.begin(mode: mode) { [weak self] result in
            guard let self else { return }
            self.restoreFocusAfterRegionSelection()
            if let result { self.captureRegion(result) }
        }
    }

    /// 選取結束（完成或取消）：原本是畫圖模式就讓覆蓋層重新成為 key
    /// 不呼叫 setDrawing(true)：它會順便取消「隱藏標註」，違反選取期間不改動標註
    private func restoreFocusAfterRegionSelection() {
        if isDrawing {
            overlays.setDrawing(true, focus: NSScreen.underMouse())
        } else {
            NSCursor.arrow.set()
        }
    }

    private func captureRegion(_ selection: RegionSelectionResult) {
        let screen = selection.screen
        overlays.commitAllText()
        overlays.displayAllNow()
        var excluded = captureExclusions()
        excluded.formUnion(selection.windowNumbers)
        excluded.remove(0)
        isCapturing = true
        Task { @MainActor in
            defer {
                self.isCapturing = false
                self.regionSelection.tearDown()
            }
            do {
                // 選取 panel 已收起，等畫面更新後再擷取，避免拍到暗色遮罩
                // （panel 也會在 ScreenshotService 裡明確排除；2026-11-13 初審 #2 修正後才真的有效）
                try await Task.sleep(nanoseconds: 100_000_000)
                // 放開滑鼠到真正擷取之間螢幕插拔、改解析度或縮放 → 選取範圍已經不對，取消（初審 #3）
                guard let now = NSScreen.screens.first(where: { $0.displayID == selection.displayID }),
                      now.frame.size == selection.screenSize,
                      now.backingScaleFactor == selection.screenScale else {
                    self.toast.show("螢幕設定剛剛變了，\(selection.mode.title)已取消，請重新選取", on: NSScreen.underMouse() ?? NSScreen.main ?? screen)
                    return
                }
                let url = try await self.screenshot.capture(
                    screen: screen,
                    displayID: selection.displayID,
                    region: selection.rect,
                    excludingWindowNumbers: excluded
                )
                self.toast.show("已存檔：\(url.lastPathComponent)（已複製到剪貼簿）", on: screen)
            } catch {
                self.toast.show("截圖失敗：\(error.localizedDescription)", on: screen)
            }
        }
    }

    /// 截圖一律排除：工具列、toast、聚光燈、放大鏡（截圖只留簡報＋標註；2026-11-13 初審 #1）
    private func captureExclusions() -> Set<Int> {
        var s: Set<Int> = [toolbar.panel.windowNumber, toast.windowNumber]
        s.formUnion(spotlight.windowNumbers)
        if let m = magnifier.windowNumber { s.insert(m) }
        s.remove(0)
        return s
    }

    func openScreenshotFolder() {
        let folder = ScreenshotService.folderURL
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(folder)
    }

    // MARK: - 介面

    func toggleToolbar() {
        toolbar.toggle()
        refreshUI()
    }

    func showShortcutHelp() {
        Alerts.showShortcutHelp(failed: failedHotKeys)
    }
}
