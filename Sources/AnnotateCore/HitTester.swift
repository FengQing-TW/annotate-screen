import Foundation
import CoreGraphics

/// 物件橡皮擦的命中測試：點到線段距離 ≤ 容差（再加上線寬一半）
public enum HitTester {
    /// 點是否碰到這一筆
    public static func hits(_ stroke: Stroke, point p: CGPoint, tolerance: CGFloat) -> Bool {
        let reach = tolerance + stroke.lineWidth / 2
        switch stroke.kind {
        case .freehand, .highlighter, .laser, .line:
            return Geometry.distance(from: p, toPolyline: stroke.points) <= reach
        case .arrow:
            if Geometry.distance(from: p, toSegment: stroke.start, stroke.end) <= reach { return true }
            guard let head = ArrowGeometry.head(from: stroke.start, to: stroke.end, lineWidth: stroke.lineWidth) else {
                return Geometry.distance(p, stroke.start) <= reach
            }
            let outline = [head.left, head.tip, head.right, head.left]
            return Geometry.distance(from: p, toPolyline: outline) <= reach
        case .rectangle:
            let r = Geometry.rect(from: stroke.start, to: stroke.end)
            return Geometry.distance(from: p, toPolyline: Geometry.rectOutline(r)) <= reach
        case .ellipse:
            let r = Geometry.rect(from: stroke.start, to: stroke.end)
            return Geometry.distance(from: p, toPolyline: Geometry.ellipseOutline(in: r)) <= reach
        case .text:
            return stroke.textFrame.insetBy(dx: -tolerance, dy: -tolerance).contains(p)
        }
    }

    /// 拖曳中的一段（a→b）是否碰到這一筆：沿線段取樣，避免快速拖過時漏掉
    public static func hits(_ stroke: Stroke, along a: CGPoint, to b: CGPoint, tolerance: CGFloat) -> Bool {
        let len = Geometry.distance(a, b)
        let step = max(1, tolerance * 0.5)
        let n = max(1, Int((len / step).rounded(.up)))
        for i in 0...n {
            let t = CGFloat(i) / CGFloat(n)
            let p = CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
            if hits(stroke, point: p, tolerance: tolerance) { return true }
        }
        return false
    }
}
