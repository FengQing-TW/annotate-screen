import Foundation
import CoreGraphics

/// 放大鏡只擷取游標附近一塊的純邏輯（2026-11-13）
///
/// 座標系（同 WindowPicking）：
/// - 全域 CG：主螢幕左上為原點、y 向下、單位為點（SCStreamFrameInfo.screenRect 即此座標）
/// - 顯示器內左上原點、單位為點（SCStreamConfiguration.sourceRect）
/// - CIImage：影格左下為原點、單位為像素
public enum MagnifierRegion {
    /// 擷取範圍：以 center（顯示器內左上原點）為中心、邊長 side 的正方形，整塊平移夾進顯示器內
    /// 顯示器某一邊比 side 小（或 side 為無限大），那一邊就用顯示器的大小。原點取 floor，大小不變
    public static func region(centeredAt center: CGPoint, displaySize: CGSize, side: CGFloat) -> CGRect {
        let w = min(side, displaySize.width)
        let h = min(side, displaySize.height)
        let x = min(max(center.x - w / 2, 0), displaySize.width - w)
        let y = min(max(center.y - h / 2, 0), displaySize.height - h)
        return CGRect(x: floor(x), y: floor(y), width: w, height: h)
    }

    /// 是否該更新擷取範圍（三個矩形都是全域 CG 座標）
    /// crop ∩ displayFrame 沒有被「frameRect 向內縮 margin」完整包住就回 true；
    /// frameRect 貼著 displayFrame 的那一邊不內縮（已經到螢幕邊緣，再更新也沒用）。交集為空回 false
    public static func needsRecenter(frameRect: CGRect, crop: CGRect, displayFrame: CGRect, margin: CGFloat) -> Bool {
        let c = crop.intersection(displayFrame)
        guard !c.isNull, c.width > 0, c.height > 0 else { return false }
        // 「貼著」容許 0.5 點誤差（screenRect 可能有小數）
        let tolerance: CGFloat = 0.5
        let left = abs(frameRect.minX - displayFrame.minX) <= tolerance ? 0 : margin
        let right = abs(frameRect.maxX - displayFrame.maxX) <= tolerance ? 0 : margin
        let top = abs(frameRect.minY - displayFrame.minY) <= tolerance ? 0 : margin
        let bottom = abs(frameRect.maxY - displayFrame.maxY) <= tolerance ? 0 : margin
        let contained = c.minX >= frameRect.minX + left
            && c.maxX <= frameRect.maxX - right
            && c.minY >= frameRect.minY + top
            && c.maxY <= frameRect.maxY - bottom
        return !contained
    }

    /// 全域 CG 的中心點與邊長（點）→ 影格內的裁切矩形（CIImage 座標：左下原點、像素）
    /// frameRect 是這張影格拍到的範圍（全域 CG），scale 是每點幾像素
    public static func cropInFrame(frameRect: CGRect, center: CGPoint, side: CGFloat, scale: CGFloat) -> CGRect {
        CGRect(
            x: (center.x - frameRect.minX - side / 2) * scale,
            y: (frameRect.maxY - center.y - side / 2) * scale,
            width: side * scale,
            height: side * scale
        )
    }
}
