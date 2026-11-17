import AppKit
import AnnotateCore

/// 把 AnnotateCore 的筆畫畫到 CGContext（覆蓋層為翻轉座標，左上為原點）
@MainActor
enum StrokeRenderer {
    /// 文字工具與輸入框共用的字型
    static func font(size: CGFloat) -> NSFont {
        NSFont.systemFont(ofSize: size, weight: .semibold)
    }

    static func textAttributes(fontSize: CGFloat, color: RGBAColor) -> [NSAttributedString.Key: Any] {
        [.font: font(size: fontSize), .foregroundColor: color.nsColor]
    }

    /// 平滑化後的 CGPath
    static func smoothPath(_ points: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        for element in PathSmoothing.smoothedElements(points) {
            switch element {
            case .move(let p): path.move(to: p)
            case .line(let p): path.addLine(to: p)
            case .quadCurve(let to, let control): path.addQuadCurve(to: to, control: control)
            }
        }
        return path
    }

    static func draw(_ stroke: Stroke, in ctx: CGContext) {
        ctx.saveGState()
        defer { ctx.restoreGState() }

        let color = stroke.color.cgColor
        ctx.setStrokeColor(color)
        ctx.setFillColor(color)
        ctx.setLineWidth(stroke.lineWidth)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)

        switch stroke.kind {
        case .freehand, .highlighter:
            // 整筆是一條路徑、一次描邊，螢光筆自我重疊處不會加深
            guard !stroke.points.isEmpty else { return }
            ctx.addPath(smoothPath(stroke.points))
            ctx.strokePath()

        case .line:
            ctx.move(to: stroke.start)
            ctx.addLine(to: stroke.end)
            ctx.strokePath()

        case .arrow:
            guard let head = ArrowGeometry.head(from: stroke.start, to: stroke.end, lineWidth: stroke.lineWidth) else {
                return
            }
            ctx.move(to: stroke.start)
            ctx.addLine(to: head.base)
            ctx.strokePath()
            ctx.move(to: head.tip)
            ctx.addLine(to: head.left)
            ctx.addLine(to: head.right)
            ctx.closePath()
            ctx.fillPath()

        case .rectangle:
            ctx.addRect(Geometry.rect(from: stroke.start, to: stroke.end))
            ctx.strokePath()

        case .ellipse:
            ctx.addEllipse(in: Geometry.rect(from: stroke.start, to: stroke.end))
            ctx.strokePath()

        case .text:
            drawText(stroke)

        case .laser:
            drawLaser(stroke.points, width: stroke.lineWidth, alpha: 1, in: ctx)
        }
    }

    /// 文字：以 points[0] 為左上角
    static func drawText(_ stroke: Stroke) {
        let attributed = NSAttributedString(
            string: stroke.text,
            attributes: textAttributes(fontSize: stroke.fontSize, color: stroke.color)
        )
        let rect = CGRect(origin: stroke.start, size: CGSize(width: 100_000, height: 100_000))
        attributed.draw(with: rect, options: [.usesLineFragmentOrigin])
    }

    /// 雷射筆：紅色發光線條（外層模糊光暈＋內層亮芯）
    static func drawLaser(_ points: [CGPoint], width: CGFloat, alpha: CGFloat, in ctx: CGContext) {
        guard !points.isEmpty, alpha > 0 else { return }
        let path = smoothPath(points)
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)

        ctx.setShadow(offset: .zero, blur: 14, color: CGColor(srgbRed: 1, green: 0.1, blue: 0.1, alpha: alpha))
        ctx.setStrokeColor(CGColor(srgbRed: 1, green: 0.15, blue: 0.15, alpha: alpha))
        ctx.setLineWidth(width)
        ctx.addPath(path)
        ctx.strokePath()

        ctx.setShadow(offset: .zero, blur: 0, color: nil)
        ctx.setStrokeColor(CGColor(srgbRed: 1, green: 0.88, blue: 0.88, alpha: alpha))
        ctx.setLineWidth(max(1, width * 0.35))
        ctx.addPath(path)
        ctx.strokePath()
    }
}
