import Foundation
import CoreGraphics

/// 像素尺寸（寬 × 高）
public struct PixelSize: Equatable {
    public var width: Int
    public var height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }
}

/// 範圍截圖的選取邏輯（2026-11-13）：拖曳兩點產生矩形、夾在螢幕內、太小視為取消、換算像素
public enum RegionSelection {
    /// 寬或高小於這個點數視為取消
    public static let minimumSize: CGFloat = 5

    /// 把點夾在邊界內
    public static func clamp(_ p: CGPoint, to bounds: CGRect) -> CGPoint {
        CGPoint(
            x: min(max(p.x, bounds.minX), bounds.maxX),
            y: min(max(p.y, bounds.minY), bounds.maxY)
        )
    }

    /// 由拖曳的起點與目前點產生正規化矩形（任意拖曳方向），兩點都先夾在邊界內
    public static func rect(from a: CGPoint, to b: CGPoint, clampedTo bounds: CGRect) -> CGRect {
        Geometry.rect(from: clamp(a, to: bounds), to: clamp(b, to: bounds))
    }

    /// 寬或高小於最小尺寸
    public static func isTooSmall(_ r: CGRect, minimum: CGFloat = minimumSize) -> Bool {
        r.width < minimum || r.height < minimum
    }

    /// 點數矩形換算成像素尺寸（乘 scale、四捨五入）
    public static func pixelSize(of r: CGRect, scale: CGFloat) -> PixelSize {
        PixelSize(
            width: Int((r.width * scale).rounded()),
            height: Int((r.height * scale).rounded())
        )
    }

    /// 左下原點（AppKit 視圖座標）與左上原點（ScreenCaptureKit sourceRect）互換；height 為容器高度
    public static func flipped(_ r: CGRect, height: CGFloat) -> CGRect {
        CGRect(x: r.minX, y: height - r.maxY, width: r.width, height: r.height)
    }
}
