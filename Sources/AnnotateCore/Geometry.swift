import Foundation
import CoreGraphics

/// 基本幾何工具
public enum Geometry {
    public static func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        hypot(b.x - a.x, b.y - a.y)
    }

    /// 點到線段的最短距離
    public static func distance(from p: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x
        let dy = b.y - a.y
        let len2 = dx * dx + dy * dy
        if len2 == 0 { return distance(p, a) }
        var t = ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2
        t = max(0, min(1, t))
        return distance(p, CGPoint(x: a.x + t * dx, y: a.y + t * dy))
    }

    /// 點到折線的最短距離；空陣列回傳無限大
    public static func distance(from p: CGPoint, toPolyline points: [CGPoint]) -> CGFloat {
        guard let first = points.first else { return .infinity }
        if points.count == 1 { return distance(p, first) }
        var best = CGFloat.infinity
        for i in 1..<points.count {
            best = min(best, distance(from: p, toSegment: points[i - 1], points[i]))
        }
        return best
    }

    /// 由兩個對角點產生正規化矩形
    public static func rect(from a: CGPoint, to b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
    }

    /// 矩形外框（封閉折線）
    public static func rectOutline(_ r: CGRect) -> [CGPoint] {
        [
            CGPoint(x: r.minX, y: r.minY),
            CGPoint(x: r.maxX, y: r.minY),
            CGPoint(x: r.maxX, y: r.maxY),
            CGPoint(x: r.minX, y: r.maxY),
            CGPoint(x: r.minX, y: r.minY),
        ]
    }

    /// 橢圓外框的多邊形近似（封閉折線）
    public static func ellipseOutline(in r: CGRect, segments: Int = 72) -> [CGPoint] {
        let n = max(8, segments)
        let cx = r.midX, cy = r.midY
        let rx = r.width / 2, ry = r.height / 2
        return (0...n).map { i in
            let t = CGFloat(i) / CGFloat(n) * 2 * .pi
            return CGPoint(x: cx + rx * cos(t), y: cy + ry * sin(t))
        }
    }
}

/// Shift 約束：直線角度鎖定、正方形／正圓
public enum ShapeConstraint {
    /// 把終點鎖到 0°／45°／90°（含各象限）
    /// 水平與垂直時保持精確座標；斜 45° 時取兩軸位移平均
    public static func lockAngle(from start: CGPoint, to end: CGPoint) -> CGPoint {
        let dx = end.x - start.x
        let dy = end.y - start.y
        if dx == 0 && dy == 0 { return end }
        let degrees = atan2(abs(dy), abs(dx)) * 180 / .pi
        if degrees < 22.5 {
            return CGPoint(x: end.x, y: start.y)
        } else if degrees > 67.5 {
            return CGPoint(x: start.x, y: end.y)
        } else {
            let d = (abs(dx) + abs(dy)) / 2
            return CGPoint(x: start.x + sign(dx) * d, y: start.y + sign(dy) * d)
        }
    }

    /// 把終點調整成與起點構成正方形（取兩軸較大者）
    public static func square(from start: CGPoint, to end: CGPoint) -> CGPoint {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let d = max(abs(dx), abs(dy))
        return CGPoint(x: start.x + sign(dx) * d, y: start.y + sign(dy) * d)
    }

    private static func sign(_ v: CGFloat) -> CGFloat { v < 0 ? -1 : 1 }
}

/// 箭頭頭部的三個頂點與箭桿終點
public struct ArrowHead: Equatable {
    public var tip: CGPoint
    public var left: CGPoint
    public var right: CGPoint
    /// 箭桿應畫到的位置（頭部底邊中點）
    public var base: CGPoint
}

/// 箭頭幾何：頭部大小隨線寬等比
public enum ArrowGeometry {
    /// 頭部兩翼與箭桿的夾角（弧度，約 26°）
    public static let headAngle: CGFloat = .pi / 7

    /// 頭部長度：線寬 × 4，最小 10 點
    public static func headLength(for lineWidth: CGFloat) -> CGFloat {
        max(10, lineWidth * 4)
    }

    /// 計算頭部；起終點重合時回傳 nil。線太短時頭部長度不超過線長
    public static func head(from start: CGPoint, to end: CGPoint, lineWidth: CGFloat) -> ArrowHead? {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let len = hypot(dx, dy)
        guard len > 0.0001 else { return nil }
        let length = min(headLength(for: lineWidth), len)
        // 從尖端指回起點的單位向量
        let bx = -dx / len
        let by = -dy / len
        let c = cos(headAngle), s = sin(headAngle)
        let left = CGPoint(x: end.x + length * (bx * c - by * s), y: end.y + length * (bx * s + by * c))
        let right = CGPoint(x: end.x + length * (bx * c + by * s), y: end.y + length * (-bx * s + by * c))
        let base = CGPoint(x: end.x + bx * length * c, y: end.y + by * length * c)
        return ArrowHead(tip: end, left: left, right: right, base: base)
    }
}

/// 路徑元素（與繪圖框架無關）
public enum PathElement: Equatable {
    case move(CGPoint)
    case line(CGPoint)
    case quadCurve(to: CGPoint, control: CGPoint)
}

/// 自由線平滑化：二次曲線中點法
public enum PathSmoothing {
    /// 以相鄰取樣點的中點為曲線端點、取樣點為控制點，產生平滑路徑；
    /// 路徑會通過第一點與最後一點
    public static func smoothedElements(_ points: [CGPoint]) -> [PathElement] {
        guard let first = points.first else { return [] }
        var result: [PathElement] = [.move(first)]
        switch points.count {
        case 1:
            result.append(.line(first))
        case 2:
            result.append(.line(points[1]))
        default:
            result.append(.line(midpoint(points[0], points[1])))
            for i in 1..<(points.count - 1) {
                result.append(.quadCurve(to: midpoint(points[i], points[i + 1]), control: points[i]))
            }
            result.append(.line(points[points.count - 1]))
        }
        return result
    }

    static func midpoint(_ a: CGPoint, _ b: CGPoint) -> CGPoint {
        CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
    }
}
