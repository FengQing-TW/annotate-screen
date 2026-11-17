import Testing
import Foundation
import CoreGraphics
import AnnotateCore

// AnnotateCore 單元測試（2026-11-13）

private let red = Palette.color(at: 0)

private func line(_ a: CGPoint, _ b: CGPoint, width: CGFloat = 4) -> Stroke {
    Stroke(kind: .freehand, color: red, lineWidth: width, points: [a, b])
}

private func shape(_ kind: StrokeKind, _ a: CGPoint, _ b: CGPoint, width: CGFloat = 4) -> Stroke {
    Stroke(kind: kind, color: red, lineWidth: width, points: [a, b])
}

private func near(_ a: CGFloat, _ b: CGFloat, _ eps: CGFloat = 0.001) -> Bool { abs(a - b) <= eps }
private func near(_ a: CGPoint, _ b: CGPoint, _ eps: CGFloat = 0.001) -> Bool {
    near(a.x, b.x, eps) && near(a.y, b.y, eps)
}

@Suite("復原／重做／清除")
struct UndoRedoTests {
    @Test func 新增後可復原與重做() {
        let doc = AnnotationDocument()
        let s = line(CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 10))
        #expect(doc.add(s))
        #expect(doc.strokes.count == 1)
        #expect(doc.undo())
        #expect(doc.strokes.isEmpty)
        #expect(doc.redo())
        #expect(doc.strokes == [s])
        #expect(!doc.redo())
    }

    @Test func 清除可復原() {
        let doc = AnnotationDocument()
        doc.add(line(.zero, CGPoint(x: 5, y: 0)))
        doc.add(line(.zero, CGPoint(x: 0, y: 5)))
        #expect(doc.clear())
        #expect(doc.strokes.isEmpty)
        #expect(doc.undo())
        #expect(doc.strokes.count == 2)
    }

    @Test func 空白頁清除不產生復原步驟() {
        let doc = AnnotationDocument()
        #expect(!doc.clear())
        #expect(!doc.canUndo)
    }

    @Test func 新動作清掉重做堆疊() {
        let doc = AnnotationDocument()
        doc.add(line(.zero, CGPoint(x: 5, y: 0)))
        doc.undo()
        #expect(doc.canRedo)
        doc.add(line(.zero, CGPoint(x: 0, y: 5)))
        #expect(!doc.canRedo)
    }

    @Test func 雷射筆不進文件也不進堆疊() {
        let doc = AnnotationDocument()
        let laser = Stroke(kind: .laser, color: red, lineWidth: 6, points: [.zero, CGPoint(x: 9, y: 9)])
        #expect(!doc.add(laser))
        #expect(doc.strokes.isEmpty)
        #expect(!doc.canUndo)
    }

    @Test func 雷射工具不影響既有復原() {
        let doc = AnnotationDocument()
        let s = line(.zero, CGPoint(x: 5, y: 5))
        doc.add(s)
        doc.add(Stroke(kind: .laser, color: red, lineWidth: 6, points: [.zero]))
        #expect(doc.undo())
        #expect(doc.strokes.isEmpty)
        #expect(!doc.canUndo)
    }
}

@Suite("橡皮擦命中測試")
struct EraserTests {
    @Test func 點到自由線命中() {
        let s = line(CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0), width: 4)
        #expect(HitTester.hits(s, point: CGPoint(x: 50, y: 6), tolerance: 5))
    }

    @Test func 離線太遠未命中() {
        let s = line(CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0), width: 4)
        #expect(!HitTester.hits(s, point: CGPoint(x: 50, y: 20), tolerance: 5))
        // 線段端點外側也不算
        #expect(!HitTester.hits(s, point: CGPoint(x: 120, y: 0), tolerance: 5))
    }

    @Test func 方框只有邊框算命中() {
        let r = shape(.rectangle, CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 60))
        #expect(HitTester.hits(r, point: CGPoint(x: 100, y: 30), tolerance: 4))
        #expect(HitTester.hits(r, point: CGPoint(x: 50, y: 1), tolerance: 4))
        #expect(!HitTester.hits(r, point: CGPoint(x: 50, y: 30), tolerance: 4))
    }

    @Test func 橢圓邊框命中與中心未命中() {
        let e = shape(.ellipse, CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 100))
        #expect(HitTester.hits(e, point: CGPoint(x: 100, y: 50), tolerance: 4))
        #expect(HitTester.hits(e, point: CGPoint(x: 50, y: 0), tolerance: 4))
        #expect(!HitTester.hits(e, point: CGPoint(x: 50, y: 50), tolerance: 4))
    }

    @Test func 文字方框內命中() {
        let t = Stroke(kind: .text, color: red, lineWidth: 4, points: [CGPoint(x: 10, y: 10)],
                       text: "重點", fontSize: 24, textFrame: CGRect(x: 10, y: 10, width: 60, height: 30))
        #expect(HitTester.hits(t, point: CGPoint(x: 40, y: 25), tolerance: 3))
        #expect(HitTester.hits(t, point: CGPoint(x: 72, y: 25), tolerance: 3))
        #expect(!HitTester.hits(t, point: CGPoint(x: 90, y: 25), tolerance: 3))
    }

    @Test func 箭頭頭部算命中() {
        let a = shape(.arrow, CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0), width: 4)
        let head = ArrowGeometry.head(from: a.start, to: a.end, lineWidth: 4)!
        #expect(HitTester.hits(a, point: head.left, tolerance: 2))
        #expect(!HitTester.hits(a, point: CGPoint(x: 50, y: 30), tolerance: 2))
    }

    @Test func 拖過的路徑會刪除整筆且可復原() {
        let doc = AnnotationDocument()
        let vertical = line(CGPoint(x: 50, y: 0), CGPoint(x: 50, y: 100))
        let far = line(CGPoint(x: 300, y: 0), CGPoint(x: 300, y: 100))
        doc.add(vertical)
        doc.add(far)
        // 快速水平拖過：兩個端點都離線很遠，但中間經過
        #expect(doc.erase(from: CGPoint(x: 0, y: 50), to: CGPoint(x: 100, y: 50), tolerance: 6))
        #expect(doc.strokes == [far])
        #expect(doc.undo())
        #expect(doc.strokes.count == 2)
    }

    @Test func 一次拖曳刪多筆只算一步復原() {
        let doc = AnnotationDocument()
        let a = line(CGPoint(x: 10, y: 0), CGPoint(x: 10, y: 100))
        let b = line(CGPoint(x: 80, y: 0), CGPoint(x: 80, y: 100))
        doc.add(a)
        doc.add(b)
        doc.beginGroup()
        doc.erase(at: CGPoint(x: 10, y: 50), tolerance: 4)
        doc.erase(at: CGPoint(x: 80, y: 50), tolerance: 4)
        doc.endGroup()
        #expect(doc.strokes.isEmpty)
        #expect(doc.undo())
        #expect(doc.strokes.count == 2)
    }

    @Test func 未命中不產生復原步驟() {
        let doc = AnnotationDocument()
        doc.add(line(.zero, CGPoint(x: 10, y: 0)))
        doc.undo()
        doc.redo()
        #expect(!doc.erase(at: CGPoint(x: 500, y: 500), tolerance: 4))
        #expect(doc.strokes.count == 1)
    }
}

@Suite("Shift 約束")
struct ConstraintTests {
    @Test func 接近水平鎖到零度() {
        let p = ShapeConstraint.lockAngle(from: .zero, to: CGPoint(x: 100, y: 15))
        #expect(p == CGPoint(x: 100, y: 0))
    }

    @Test func 接近垂直鎖到九十度() {
        let p = ShapeConstraint.lockAngle(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 18, y: -90))
        #expect(p == CGPoint(x: 10, y: -90))
    }

    @Test func 接近斜線鎖到四十五度() {
        let p = ShapeConstraint.lockAngle(from: .zero, to: CGPoint(x: -100, y: 80))
        #expect(near(abs(p.x), abs(p.y)))
        #expect(p.x < 0 && p.y > 0)
    }

    @Test func 正方形約束取較大邊() {
        let p = ShapeConstraint.square(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 60, y: -20))
        #expect(p == CGPoint(x: 60, y: -40))
        let r = Geometry.rect(from: CGPoint(x: 10, y: 10), to: p)
        #expect(r.width == r.height)
    }
}

@Suite("箭頭幾何")
struct ArrowTests {
    @Test func 尖端在終點且左右對稱() {
        let head = ArrowGeometry.head(from: .zero, to: CGPoint(x: 100, y: 0), lineWidth: 4)!
        #expect(head.tip == CGPoint(x: 100, y: 0))
        #expect(near(head.left.y, -head.right.y))
        #expect(near(head.left.x, head.right.x))
        #expect(head.base.x < 100 && near(head.base.y, 0))
    }

    @Test func 頭部大小隨粗細等比() {
        let small = ArrowGeometry.head(from: .zero, to: CGPoint(x: 300, y: 0), lineWidth: 4)!
        let big = ArrowGeometry.head(from: .zero, to: CGPoint(x: 300, y: 0), lineWidth: 8)!
        let smallLen = Geometry.distance(small.tip, small.left)
        let bigLen = Geometry.distance(big.tip, big.left)
        #expect(near(bigLen / smallLen, 2))
    }

    @Test func 起終點重合沒有頭部() {
        #expect(ArrowGeometry.head(from: CGPoint(x: 5, y: 5), to: CGPoint(x: 5, y: 5), lineWidth: 4) == nil)
    }
}

@Suite("路徑平滑化")
struct SmoothingTests {
    @Test func 平滑路徑通過起點與終點() {
        let pts = [CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 10), CGPoint(x: 20, y: 0), CGPoint(x: 30, y: 10)]
        let elements = PathSmoothing.smoothedElements(pts)
        #expect(elements.first == .move(pts[0]))
        #expect(elements.last == .line(pts[3]))
        #expect(elements.contains { if case .quadCurve = $0 { return true } else { return false } })
    }

    @Test func 單點也產生可畫的路徑() {
        let elements = PathSmoothing.smoothedElements([CGPoint(x: 3, y: 3)])
        #expect(elements.count == 2)
    }
}

@Suite("截圖檔名")
struct NamingTests {
    private var sampleDate: Date {
        var c = DateComponents()
        c.year = 2026; c.month = 11; c.day = 13; c.hour = 9; c.minute = 5; c.second = 7
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal.date(from: c)!
    }

    @Test func 基本格式() {
        let name = ScreenshotNaming.fileName(for: sampleDate, timeZone: TimeZone(identifier: "UTC")!) { _ in false }
        #expect(name == "AnnotateScreen_20261113_090507.png")
    }

    @Test func 同秒重複加編號() {
        let utc = TimeZone(identifier: "UTC")!
        var existing: Set<String> = ["AnnotateScreen_20261113_090507.png"]
        let second = ScreenshotNaming.fileName(for: sampleDate, timeZone: utc) { existing.contains($0) }
        #expect(second == "AnnotateScreen_20261113_090507_2.png")
        existing.insert(second)
        let third = ScreenshotNaming.fileName(for: sampleDate, timeZone: utc) { existing.contains($0) }
        #expect(third == "AnnotateScreen_20261113_090507_3.png")
    }
}

@Suite("頁面獨立")
struct PageTests {
    @Test func 白板黑板螢幕互相獨立() {
        let pages = PageSet()
        pages.currentDocument.add(line(.zero, CGPoint(x: 1, y: 1)))
        pages.toggle(.whiteboard)
        #expect(pages.currentPage == .whiteboard)
        #expect(pages.currentDocument.strokes.isEmpty)
        pages.currentDocument.add(line(.zero, CGPoint(x: 2, y: 2)))
        pages.currentDocument.add(line(.zero, CGPoint(x: 3, y: 3)))
        pages.toggle(.blackboard)
        #expect(pages.currentPage == .blackboard)
        #expect(pages.currentDocument.strokes.isEmpty)
        pages.toggle(.blackboard)
        #expect(pages.currentPage == .screen)
        #expect(pages.currentDocument.strokes.count == 1)
        #expect(pages.document(for: .whiteboard).strokes.count == 2)
    }

    @Test func 各頁復原堆疊獨立() {
        let pages = PageSet()
        pages.document(for: .screen).add(line(.zero, CGPoint(x: 1, y: 1)))
        pages.document(for: .whiteboard).add(line(.zero, CGPoint(x: 2, y: 2)))
        #expect(pages.document(for: .whiteboard).undo())
        #expect(pages.document(for: .screen).strokes.count == 1)
        #expect(!pages.document(for: .blackboard).canUndo)
    }
}

@Suite("工具設定")
struct ToolSettingsTests {
    @Test func 按鍵對應工具() {
        #expect(Tool.tool(forKey: "P") == .pen)
        #expect(Tool.tool(forKey: "g") == .laser)
        #expect(Tool.tool(forKey: "z") == nil)
    }

    @Test func 螢光筆半透明且較寬() {
        let s = ToolSettings(tool: .highlighter, colorIndex: 2, widthLevel: .medium)
        #expect(s.strokeColor.alpha == ToolSettings.highlighterAlpha)
        #expect(s.lineWidth > ToolSettings(tool: .pen, colorIndex: 2, widthLevel: .medium).lineWidth)
    }

    @Test func 粗細到頭就停() {
        #expect(WidthLevel.thin.stepped(-1) == .thin)
        #expect(WidthLevel.extraThick.stepped(1) == .extraThick)
        #expect(WidthLevel.medium.stepped(1) == .thick)
    }
}

@Suite("範圍截圖選取")
struct RegionSelectionTests {
    private let bounds = CGRect(x: 0, y: 0, width: 1000, height: 800)
    private let expected = CGRect(x: 100, y: 200, width: 300, height: 150)

    @Test func 四個拖曳方向都得到同一個矩形() {
        let tl = CGPoint(x: 100, y: 200), br = CGPoint(x: 400, y: 350)
        let tr = CGPoint(x: 400, y: 200), bl = CGPoint(x: 100, y: 350)
        #expect(RegionSelection.rect(from: tl, to: br, clampedTo: bounds) == expected)
        #expect(RegionSelection.rect(from: br, to: tl, clampedTo: bounds) == expected)
        #expect(RegionSelection.rect(from: tr, to: bl, clampedTo: bounds) == expected)
        #expect(RegionSelection.rect(from: bl, to: tr, clampedTo: bounds) == expected)
    }

    @Test func 超出邊界被夾住() {
        let r = RegionSelection.rect(from: CGPoint(x: 900, y: 700), to: CGPoint(x: 1500, y: -300), clampedTo: bounds)
        #expect(r == CGRect(x: 900, y: 0, width: 100, height: 700))
        // 邊界不在原點（例如副螢幕）
        let other = CGRect(x: -1920, y: 100, width: 1920, height: 1080)
        let r2 = RegionSelection.rect(from: CGPoint(x: -2000, y: 50), to: CGPoint(x: -1000, y: 500), clampedTo: other)
        #expect(r2 == CGRect(x: -1920, y: 100, width: 920, height: 400))
    }

    @Test func 太小視為無效() {
        #expect(RegionSelection.isTooSmall(CGRect(x: 0, y: 0, width: 4.9, height: 100)))
        #expect(RegionSelection.isTooSmall(CGRect(x: 0, y: 0, width: 100, height: 3)))
        #expect(RegionSelection.isTooSmall(.zero))
        #expect(!RegionSelection.isTooSmall(CGRect(x: 0, y: 0, width: 5, height: 5)))
        #expect(!RegionSelection.isTooSmall(expected))
    }

    @Test func 像素尺寸依縮放倍率計算() {
        #expect(RegionSelection.pixelSize(of: expected, scale: 2) == PixelSize(width: 600, height: 300))
        #expect(RegionSelection.pixelSize(of: expected, scale: 1) == PixelSize(width: 300, height: 150))
        // 半點座標：四捨五入
        let half = CGRect(x: 0, y: 0, width: 10.5, height: 20.25)
        #expect(RegionSelection.pixelSize(of: half, scale: 2) == PixelSize(width: 21, height: 41))
        #expect(RegionSelection.pixelSize(of: half, scale: 1) == PixelSize(width: 11, height: 20))
    }

    @Test func 左下原點轉左上原點() {
        let r = RegionSelection.flipped(CGRect(x: 10, y: 600, width: 100, height: 150), height: 800)
        #expect(r == CGRect(x: 10, y: 50, width: 100, height: 150))
        #expect(RegionSelection.flipped(r, height: 800) == CGRect(x: 10, y: 600, width: 100, height: 150))
    }
}

@Suite("視窗截圖選取")
struct WindowPickingTests {
    /// 主螢幕 1440×900；副螢幕 1920×1080 在左邊、頂端對齊（AppKit frame 的 y = 900 − 1080 = −180）
    private let mainHeight: CGFloat = 900
    private let mainAppKit = CGRect(x: 0, y: 0, width: 1440, height: 900)
    private let leftAppKit = CGRect(x: -1920, y: -180, width: 1920, height: 1080)
    /// 副螢幕在主螢幕上方
    private let aboveAppKit = CGRect(x: 0, y: 900, width: 1920, height: 1080)

    private func win(_ id: CGWindowID, _ r: CGRect, pid: Int32 = 100, owner: String = "App") -> WindowCandidate {
        WindowCandidate(windowID: id, pid: pid, ownerName: owner, title: "", bounds: r)
    }

    private func info(id: Int, pid: Int, layer: Int = 0, alpha: Double = 1, bounds: CGRect,
                      owner: String? = "App", name: String? = nil) -> [String: Any] {
        var d: [String: Any] = [
            kCGWindowNumber as String: id,
            kCGWindowOwnerPID as String: pid,
            kCGWindowLayer as String: layer,
            kCGWindowAlpha as String: alpha,
            kCGWindowBounds as String: bounds.dictionaryRepresentation as NSDictionary,
        ]
        if let owner { d[kCGWindowOwnerName as String] = owner }
        if let name { d[kCGWindowName as String] = name }
        return d
    }

    @Test func 篩選候選視窗() {
        let ok = CGRect(x: 10, y: 20, width: 300, height: 200)
        let list: [[String: Any]] = [
            info(id: 1, pid: 100, bounds: ok, owner: "Keynote", name: "簡報"),
            info(id: 2, pid: 100, layer: 25, bounds: ok),                              // 不是 layer 0
            info(id: 3, pid: 100, alpha: 0, bounds: ok),                               // 透明
            info(id: 4, pid: 100, bounds: CGRect(x: 0, y: 0, width: 39, height: 200)), // 太窄
            info(id: 5, pid: 100, bounds: CGRect(x: 0, y: 0, width: 200, height: 39)), // 太矮
            info(id: 6, pid: 999, bounds: ok),                                         // 本程式
            info(id: 7, pid: 200, bounds: CGRect(x: 0, y: 0, width: 40, height: 40), owner: nil),
        ]
        let result = WindowPicking.candidates(from: list, excludingPID: 999)
        #expect(result.map(\.windowID) == [1, 7])
        #expect(result[0] == WindowCandidate(windowID: 1, pid: 100, ownerName: "Keynote", title: "簡報", bounds: ok))
        #expect(result[1].ownerName == "")
        #expect(result[1].title == "")
    }

    @Test func 重疊視窗取最前面() {
        let front = win(1, CGRect(x: 100, y: 100, width: 400, height: 300))
        let back = win(2, CGRect(x: 0, y: 0, width: 1000, height: 800))
        let windows = [front, back]
        #expect(WindowPicking.topmost(at: CGPoint(x: 200, y: 200), in: windows) == front)
        // 只有後面的視窗包含這個點
        #expect(WindowPicking.topmost(at: CGPoint(x: 50, y: 50), in: windows) == back)
    }

    @Test func 點在桌面回傳nil() {
        let windows = [win(1, CGRect(x: 100, y: 100, width: 400, height: 300))]
        #expect(WindowPicking.topmost(at: CGPoint(x: 800, y: 600), in: windows) == nil)
        #expect(WindowPicking.topmost(at: CGPoint(x: 10, y: 10), in: []) == nil)
    }

    @Test func 主螢幕的CG座標不變() {
        #expect(WindowPicking.screenCGFrame(appKitFrame: mainAppKit, mainScreenHeight: mainHeight) == mainAppKit)
    }

    @Test func 副螢幕在左邊為負x() {
        let cg = WindowPicking.screenCGFrame(appKitFrame: leftAppKit, mainScreenHeight: mainHeight)
        #expect(cg == CGRect(x: -1920, y: 0, width: 1920, height: 1080))
        // 底端對齊：AppKit y = 0 → CG y = 900 − 1080 = −180
        let bottomAligned = CGRect(x: -1920, y: 0, width: 1920, height: 1080)
        #expect(WindowPicking.screenCGFrame(appKitFrame: bottomAligned, mainScreenHeight: mainHeight)
                == CGRect(x: -1920, y: -180, width: 1920, height: 1080))
        // 副螢幕上的視窗轉成該螢幕內左上原點
        let local = WindowPicking.localRect(of: CGRect(x: -1000, y: 100, width: 800, height: 600), inScreenCGFrame: cg)
        #expect(local == CGRect(x: 920, y: 100, width: 800, height: 600))
    }

    @Test func 副螢幕在上方為負y() {
        let cg = WindowPicking.screenCGFrame(appKitFrame: aboveAppKit, mainScreenHeight: mainHeight)
        #expect(cg == CGRect(x: 0, y: -1080, width: 1920, height: 1080))
        let local = WindowPicking.localRect(of: CGRect(x: 100, y: -1000, width: 500, height: 400), inScreenCGFrame: cg)
        #expect(local == CGRect(x: 100, y: 80, width: 500, height: 400))
    }

    @Test func 視窗跨兩個螢幕只取該螢幕的部分() {
        let mainCG = WindowPicking.screenCGFrame(appKitFrame: mainAppKit, mainScreenHeight: mainHeight)
        let leftCG = WindowPicking.screenCGFrame(appKitFrame: leftAppKit, mainScreenHeight: mainHeight)
        let w = CGRect(x: -200, y: 100, width: 600, height: 400)
        #expect(WindowPicking.localRect(of: w, inScreenCGFrame: mainCG) == CGRect(x: 0, y: 100, width: 400, height: 400))
        #expect(WindowPicking.localRect(of: w, inScreenCGFrame: leftCG) == CGRect(x: 1720, y: 100, width: 200, height: 400))
    }

    @Test func 沒有交集回傳nil() {
        let mainCG = WindowPicking.screenCGFrame(appKitFrame: mainAppKit, mainScreenHeight: mainHeight)
        #expect(WindowPicking.localRect(of: CGRect(x: 2000, y: 0, width: 300, height: 300), inScreenCGFrame: mainCG) == nil)
        // 只碰到邊（寬度 0）也算沒有交集
        #expect(WindowPicking.localRect(of: CGRect(x: 1440, y: 0, width: 300, height: 300), inScreenCGFrame: mainCG) == nil)
    }

    @Test func 點的座標換算() {
        // AppKit 全域 → CG 全域
        #expect(WindowPicking.cgPoint(fromAppKit: CGPoint(x: -1000, y: 500), mainScreenHeight: mainHeight) == CGPoint(x: -1000, y: 400))
        // 副螢幕（左邊）視圖座標（左下原點）→ CG 全域：視圖 (920, 380) 是 CG 螢幕內 (920, 1080 − 380 = 700)
        let leftCG = WindowPicking.screenCGFrame(appKitFrame: leftAppKit, mainScreenHeight: mainHeight)
        #expect(WindowPicking.globalPoint(fromLocal: CGPoint(x: 920, y: 380), screenCGFrame: leftCG) == CGPoint(x: -1000, y: 700))
        // 兩條路徑一致：視圖點 + 螢幕 AppKit 原點 = AppKit 全域點
        let viaAppKit = WindowPicking.cgPoint(fromAppKit: CGPoint(x: -1920 + 920, y: -180 + 380), mainScreenHeight: mainHeight)
        #expect(viaAppKit == CGPoint(x: -1000, y: 700))
    }

    @Test func 螢幕內左上原點翻回視圖座標() {
        // 副螢幕上的視窗：螢幕內左上原點 (920, 100, 800, 600) → 視圖左下原點 y = 1080 − 700 = 380
        let local = CGRect(x: 920, y: 100, width: 800, height: 600)
        let view = RegionSelection.flipped(local, height: 1080)
        #expect(view == CGRect(x: 920, y: 380, width: 800, height: 600))
        // 完成時再翻一次就回到 sourceRect（與範圍截圖同一條路徑）
        #expect(RegionSelection.flipped(view, height: 1080) == local)
    }
}

@Suite("放大鏡擷取範圍")
struct MagnifierRegionTests {
    private let size = CGSize(width: 3008, height: 1692)
    /// 副螢幕：全域 CG 原點 x = 2560
    private let display = CGRect(x: 2560, y: 0, width: 3008, height: 1692)
    private let margin: CGFloat = 48
    private let cropSide: CGFloat = 110

    private func crop(_ cx: CGFloat, _ cy: CGFloat) -> CGRect {
        CGRect(x: cx - cropSide / 2, y: cy - cropSide / 2, width: cropSide, height: cropSide)
    }

    @Test func 一般情況以游標為中心() {
        #expect(MagnifierRegion.region(centeredAt: CGPoint(x: 1500, y: 800), displaySize: size, side: 800)
                == CGRect(x: 1100, y: 400, width: 800, height: 800))
        // 原點取 floor
        #expect(MagnifierRegion.region(centeredAt: CGPoint(x: 1500.7, y: 800.3), displaySize: size, side: 800)
                == CGRect(x: 1100, y: 400, width: 800, height: 800))
    }

    @Test func 四個角落夾進顯示器() {
        #expect(MagnifierRegion.region(centeredAt: CGPoint(x: 10, y: 10), displaySize: size, side: 800)
                == CGRect(x: 0, y: 0, width: 800, height: 800))
        #expect(MagnifierRegion.region(centeredAt: CGPoint(x: 3000, y: 10), displaySize: size, side: 800)
                == CGRect(x: 2208, y: 0, width: 800, height: 800))
        #expect(MagnifierRegion.region(centeredAt: CGPoint(x: 10, y: 1690), displaySize: size, side: 800)
                == CGRect(x: 0, y: 892, width: 800, height: 800))
        #expect(MagnifierRegion.region(centeredAt: CGPoint(x: 3000, y: 1690), displaySize: size, side: 800)
                == CGRect(x: 2208, y: 892, width: 800, height: 800))
        // 中心在顯示器外也夾得回來
        #expect(MagnifierRegion.region(centeredAt: CGPoint(x: -500, y: 5000), displaySize: size, side: 800)
                == CGRect(x: 0, y: 892, width: 800, height: 800))
    }

    @Test func 顯示器比邊長小就用顯示器大小() {
        let small = CGSize(width: 600, height: 1000)
        #expect(MagnifierRegion.region(centeredAt: CGPoint(x: 300, y: 900), displaySize: small, side: 800)
                == CGRect(x: 0, y: 200, width: 600, height: 800))
        // 無限大邊長＝整張螢幕（magnifierFullDisplay 退路）
        #expect(MagnifierRegion.region(centeredAt: CGPoint(x: 1500, y: 800), displaySize: size, side: .infinity)
                == CGRect(x: 0, y: 0, width: 3008, height: 1692))
    }

    @Test func 游標在中間不更新() {
        let frame = CGRect(x: 3660, y: 400, width: 800, height: 800)
        #expect(!MagnifierRegion.needsRecenter(frameRect: frame, crop: crop(4060, 800), displayFrame: display, margin: margin))
    }

    @Test func 靠近擷取範圍邊緣要更新() {
        let frame = CGRect(x: 3660, y: 400, width: 800, height: 800)
        // 右：crop.maxX 4435 > 4460 − 48
        #expect(MagnifierRegion.needsRecenter(frameRect: frame, crop: crop(4380, 800), displayFrame: display, margin: margin))
        // 左：crop.minX 3665 < 3660 + 48
        #expect(MagnifierRegion.needsRecenter(frameRect: frame, crop: crop(3720, 800), displayFrame: display, margin: margin))
        // 下：crop.maxY 1185 > 1200 − 48
        #expect(MagnifierRegion.needsRecenter(frameRect: frame, crop: crop(4060, 1130), displayFrame: display, margin: margin))
        // 完全移出擷取範圍
        #expect(MagnifierRegion.needsRecenter(frameRect: frame, crop: crop(5000, 1500), displayFrame: display, margin: margin))
    }

    @Test func 貼著螢幕邊的那一邊不內縮() {
        // 左上角：擷取範圍貼著顯示器左、上邊
        let topLeft = CGRect(x: 2560, y: 0, width: 800, height: 800)
        #expect(!MagnifierRegion.needsRecenter(frameRect: topLeft, crop: crop(2580, 20), displayFrame: display, margin: margin))
        // 同一個 crop，擷取範圍沒貼邊就要更新
        let notAtEdge = CGRect(x: 2600, y: 40, width: 800, height: 800)
        #expect(MagnifierRegion.needsRecenter(frameRect: notAtEdge, crop: crop(2580, 20), displayFrame: display, margin: margin))
        // 右下角
        let bottomRight = CGRect(x: 4768, y: 892, width: 800, height: 800)
        #expect(!MagnifierRegion.needsRecenter(frameRect: bottomRight, crop: crop(5560, 1685), displayFrame: display, margin: margin))
        // 貼邊的那一邊不內縮，另一邊照樣內縮
        #expect(MagnifierRegion.needsRecenter(frameRect: topLeft, crop: crop(3300, 20), displayFrame: display, margin: margin))
    }

    @Test func crop在顯示器外不更新() {
        let frame = CGRect(x: 3660, y: 400, width: 800, height: 800)
        #expect(!MagnifierRegion.needsRecenter(frameRect: frame, crop: crop(1000, 800), displayFrame: display, margin: margin))
    }

    @Test func 裁切矩形y軸翻轉() {
        // 影格拍到全域 (2660,100,800,800)、2 倍；中心在影格頂端下方 200 點 → 距底部 600 點
        let frame = CGRect(x: 2660, y: 100, width: 800, height: 800)
        #expect(MagnifierRegion.cropInFrame(frameRect: frame, center: CGPoint(x: 2760, y: 300), side: 110, scale: 2)
                == CGRect(x: 90, y: 1090, width: 220, height: 220))
        // 中心在影格左上角：一半超出左邊與上邊
        #expect(MagnifierRegion.cropInFrame(frameRect: frame, center: CGPoint(x: 2660, y: 100), side: 110, scale: 2)
                == CGRect(x: -110, y: 1490, width: 220, height: 220))
        // 1 倍
        #expect(MagnifierRegion.cropInFrame(frameRect: frame, center: CGPoint(x: 3060, y: 500), side: 100, scale: 1)
                == CGRect(x: 350, y: 350, width: 100, height: 100))
    }
}
