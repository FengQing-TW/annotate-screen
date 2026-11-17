// 產生 AnnotateScreen 的 App icon（1024×1024 PNG）（2026-11-13）
// 用法：swift tools/make_icon.swift <輸出.png>
// 設計：macOS 圓角方形底（靛藍→紫漸層，象徵簡報舞台），中間一張白色投影片，
//      上面一道黃色螢光筆、一個紅色手繪圈，右下角一支畫筆筆尖
import AppKit
import CoreGraphics

let size: CGFloat = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon_1024.png"

let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
                    space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
// 左上為原點，方便照設計稿座標
ctx.translateBy(x: 0, y: size)
ctx.scaleBy(x: 1, y: -1)

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

// ── 1. 底板：Apple icon 格線，內容 824×824 置中，圓角約 185 ──
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let bodyPath = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: 12), blur: 28, color: rgb(0x000000, 0.35))
ctx.addPath(bodyPath)
ctx.setFillColor(rgb(0x2B2F8F))
ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(bodyPath)
ctx.clip()
let bg = CGGradient(colorsSpace: cs, colors: [rgb(0x3B4BDB), rgb(0x5B2FB8), rgb(0x2A1A6E)] as CFArray,
                    locations: [0, 0.55, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: 100, y: 100), end: CGPoint(x: 924, y: 924), options: [])
// 上緣一點高光
let gloss = CGGradient(colorsSpace: cs, colors: [rgb(0xFFFFFF, 0.18), rgb(0xFFFFFF, 0)] as CFArray,
                       locations: [0, 1])!
ctx.drawLinearGradient(gloss, start: CGPoint(x: 512, y: 100), end: CGPoint(x: 512, y: 420), options: [])
ctx.restoreGState()

// ── 2. 投影片 ──
let slide = CGRect(x: 205, y: 250, width: 614, height: 430)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: 14), blur: 30, color: rgb(0x0A0530, 0.45))
ctx.addPath(CGPath(roundedRect: slide, cornerWidth: 34, cornerHeight: 34, transform: nil))
ctx.setFillColor(rgb(0xFFFFFF))
ctx.fillPath()
ctx.restoreGState()

// 標題列與內文線（灰）
func bar(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ c: CGColor) {
    ctx.addPath(CGPath(roundedRect: CGRect(x: x, y: y, width: w, height: h), cornerWidth: h / 2, cornerHeight: h / 2, transform: nil))
    ctx.setFillColor(c)
    ctx.fillPath()
}
bar(255, 300, 300, 40, rgb(0x2B2F8F))          // 標題
bar(255, 400, 470, 24, rgb(0xC9CCE0))
bar(255, 470, 400, 24, rgb(0xC9CCE0))
bar(255, 540, 440, 24, rgb(0xC9CCE0))
bar(255, 610, 260, 24, rgb(0xC9CCE0))

// ── 3. 黃色螢光筆：蓋在第二行內文上（半透明、圓頭、略傾斜）──
ctx.saveGState()
ctx.setLineCap(.round)
ctx.setLineWidth(52)
ctx.setStrokeColor(rgb(0xFFD400, 0.72))
ctx.move(to: CGPoint(x: 245, y: 486))
ctx.addCurve(to: CGPoint(x: 668, y: 478), control1: CGPoint(x: 380, y: 476), control2: CGPoint(x: 540, y: 490))
ctx.strokePath()
ctx.restoreGState()

// ── 4. 紅色手繪圈：圈住標題，起筆與收筆交錯，像手畫的 ──
ctx.saveGState()
ctx.setLineCap(.round)
ctx.setLineJoin(.round)
ctx.setLineWidth(20)
ctx.setStrokeColor(rgb(0xF03A3A))
let circle = CGMutablePath()
circle.move(to: CGPoint(x: 560, y: 286))
circle.addCurve(to: CGPoint(x: 236, y: 316), control1: CGPoint(x: 470, y: 248), control2: CGPoint(x: 252, y: 262))
circle.addCurve(to: CGPoint(x: 420, y: 372), control1: CGPoint(x: 222, y: 364), control2: CGPoint(x: 330, y: 378))
circle.addCurve(to: CGPoint(x: 590, y: 318), control1: CGPoint(x: 520, y: 366), control2: CGPoint(x: 600, y: 350))
circle.addCurve(to: CGPoint(x: 500, y: 262), control1: CGPoint(x: 584, y: 290), control2: CGPoint(x: 548, y: 268))
ctx.addPath(circle)
ctx.strokePath()
ctx.restoreGState()

// ── 5. 畫筆：從右下往左上斜放，筆尖落在投影片右下角 ──
ctx.saveGState()
ctx.translateBy(x: 690, y: 630)
ctx.rotate(by: .pi / 4)      // 翻轉座標下正角度為順時針：筆身朝右下
ctx.setShadow(offset: CGSize(width: 6, height: 10), blur: 18, color: rgb(0x0A0530, 0.5))
// 筆身（以筆尖為原點，往 +x 延伸）
let barrel = CGPath(roundedRect: CGRect(x: 92, y: -38, width: 200, height: 76), cornerWidth: 24, cornerHeight: 24, transform: nil)
ctx.addPath(barrel)
ctx.setFillColor(rgb(0xF03A3A))
ctx.fillPath()
ctx.setShadow(offset: .zero, blur: 0, color: nil)
// 筆身高光
ctx.addPath(CGPath(roundedRect: CGRect(x: 104, y: -30, width: 176, height: 20), cornerWidth: 10, cornerHeight: 10, transform: nil))
ctx.setFillColor(rgb(0xFFFFFF, 0.28))
ctx.fillPath()
// 筆夾環
ctx.addRect(CGRect(x: 92, y: -38, width: 26, height: 76))
ctx.setFillColor(rgb(0xB71F2A))
ctx.fillPath()
// 木頭錐形
let cone = CGMutablePath()
cone.move(to: CGPoint(x: 92, y: -38))
cone.addLine(to: CGPoint(x: 0, y: 0))
cone.addLine(to: CGPoint(x: 92, y: 38))
cone.closeSubpath()
ctx.addPath(cone)
ctx.setFillColor(rgb(0xF6D7A7))
ctx.fillPath()
// 筆芯尖端
let tip = CGMutablePath()
tip.move(to: CGPoint(x: 34, y: -14))
tip.addLine(to: CGPoint(x: 0, y: 0))
tip.addLine(to: CGPoint(x: 34, y: 14))
tip.closeSubpath()
ctx.addPath(tip)
ctx.setFillColor(rgb(0xF03A3A))
ctx.fillPath()
ctx.restoreGState()

// ── 輸出 ──
let image = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: image)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("已輸出 \(out)")
