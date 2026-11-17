import Foundation
import CoreGraphics

/// 視窗截圖的候選視窗（2026-11-13）
public struct WindowCandidate: Equatable {
    public var windowID: CGWindowID
    public var pid: Int32
    public var ownerName: String
    public var title: String
    /// 全域 CG 座標：主螢幕左上為原點、y 向下、單位為點（即 kCGWindowBounds）
    public var bounds: CGRect

    public init(windowID: CGWindowID, pid: Int32, ownerName: String, title: String, bounds: CGRect) {
        self.windowID = windowID
        self.pid = pid
        self.ownerName = ownerName
        self.title = title
        self.bounds = bounds
    }
}

/// 視窗截圖的選取邏輯（2026-11-13）：篩選視窗清單、找游標下最前面的視窗、座標換算
///
/// 座標系：
/// - AppKit 全域（NSScreen.frame、NSEvent.mouseLocation）：主螢幕左下為原點、y 向上
/// - CG 全域（kCGWindowBounds）：主螢幕左上為原點、y 向下
/// - 螢幕內左上原點（SCStreamConfiguration.sourceRect、RegionSelectionResult.rect）
/// 「主螢幕」指 NSScreen.screens.first（有選單列、AppKit 原點所在的那個），不是 NSScreen.main
public enum WindowPicking {
    /// 寬或高小於這個點數的視窗不列入候選
    public static let minimumSize: CGFloat = 40

    /// 把 CGWindowListCopyWindowInfo 的結果轉成候選清單（保持原順序，即前到後）
    /// 只留：layer 0、alpha > 0、寬高都 ≥ minimumSize、不是本程式（excludingPID）的視窗
    public static func candidates(from infoList: [[String: Any]], excludingPID ownPID: Int32) -> [WindowCandidate] {
        infoList.compactMap { candidate(from: $0, excludingPID: ownPID) }
    }

    /// 單一視窗資訊；不符合條件回 nil
    public static func candidate(from info: [String: Any], excludingPID ownPID: Int32) -> WindowCandidate? {
        guard let layer = number(info, kCGWindowLayer)?.intValue, layer == 0 else { return nil }
        // alpha 一定會有；萬一缺就當成不透明
        let alpha = number(info, kCGWindowAlpha)?.doubleValue ?? 1
        guard alpha > 0 else { return nil }
        guard let pid = number(info, kCGWindowOwnerPID)?.int32Value, pid != ownPID else { return nil }
        guard let windowID = number(info, kCGWindowNumber)?.uint32Value else { return nil }
        guard let dict = info[kCGWindowBounds as String] as? NSDictionary,
              let bounds = CGRect(dictionaryRepresentation: dict as CFDictionary) else { return nil }
        guard bounds.width >= minimumSize, bounds.height >= minimumSize else { return nil }
        return WindowCandidate(
            windowID: windowID,
            pid: pid,
            ownerName: info[kCGWindowOwnerName as String] as? String ?? "",
            title: info[kCGWindowName as String] as? String ?? "",
            bounds: bounds
        )
    }

    private static func number(_ info: [String: Any], _ key: CFString) -> NSNumber? {
        info[key as String] as? NSNumber
    }

    /// 全域 CG 點落在哪個視窗：清單已是前到後，取第一個包含的；落在桌面（沒有視窗）回 nil
    public static func topmost(at point: CGPoint, in windows: [WindowCandidate]) -> WindowCandidate? {
        windows.first { $0.bounds.contains(point) }
    }

    /// 螢幕的 CG frame：x 不變，y = 主螢幕高 − AppKit frame 的頂邊（maxY）
    public static func screenCGFrame(appKitFrame f: CGRect, mainScreenHeight: CGFloat) -> CGRect {
        CGRect(x: f.minX, y: mainScreenHeight - f.maxY, width: f.width, height: f.height)
    }

    /// AppKit 全域點（例如 NSEvent.mouseLocation）轉 CG 全域點
    public static func cgPoint(fromAppKit p: CGPoint, mainScreenHeight: CGFloat) -> CGPoint {
        CGPoint(x: p.x, y: mainScreenHeight - p.y)
    }

    /// 螢幕內 AppKit 視圖座標（左下原點）的點轉 CG 全域點
    public static func globalPoint(fromLocal p: CGPoint, screenCGFrame s: CGRect) -> CGPoint {
        CGPoint(x: s.minX + p.x, y: s.minY + (s.height - p.y))
    }

    /// 視窗矩形 ∩ 螢幕，轉成該螢幕內左上原點的點數矩形；沒有交集回 nil
    public static func localRect(of windowBounds: CGRect, inScreenCGFrame s: CGRect) -> CGRect? {
        let i = windowBounds.intersection(s)
        guard !i.isNull, i.width > 0, i.height > 0 else { return nil }
        return i.offsetBy(dx: -s.minX, dy: -s.minY)
    }
}
