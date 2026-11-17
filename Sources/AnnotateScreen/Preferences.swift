import AppKit
import AnnotateCore

/// UserDefaults 記住：顏色、粗細、工具、工具列位置、放大倍率、聚光燈半徑
@MainActor
final class Preferences {
    static let zoomRange: ClosedRange<CGFloat> = 1.5...4
    static let radiusRange: ClosedRange<CGFloat> = 60...400

    private let defaults = UserDefaults.standard

    private enum Key {
        static let colorIndex = "colorIndex"
        static let widthLevel = "widthLevel"
        static let tool = "tool"
        static let toolbarOrigin = "toolbarOrigin"
        static let magnifierZoom = "magnifierZoom"
        static let spotlightRadius = "spotlightRadius"
        static let magnifierFullDisplay = "magnifierFullDisplay"
    }

    /// 放大鏡退路（2026-11-13）：true 時擷取整張螢幕、永不更新擷取範圍（舊做法）；預設 false。
    /// 介面上沒有開關，出問題時用 `defaults write tw.fengqing.AnnotateScreen magnifierFullDisplay -bool true`，
    /// 下次開啟放大鏡生效，不必重新建置
    var magnifierFullDisplay: Bool {
        get { defaults.bool(forKey: Key.magnifierFullDisplay) }
        set { defaults.set(newValue, forKey: Key.magnifierFullDisplay) }
    }

    var colorIndex: Int {
        get { Palette.clampIndex(defaults.object(forKey: Key.colorIndex) as? Int ?? 0) }
        set { defaults.set(Palette.clampIndex(newValue), forKey: Key.colorIndex) }
    }

    var widthLevel: WidthLevel {
        get { WidthLevel(rawValue: defaults.object(forKey: Key.widthLevel) as? Int ?? 1) ?? .medium }
        set { defaults.set(newValue.rawValue, forKey: Key.widthLevel) }
    }

    var tool: Tool {
        get { Tool(rawValue: defaults.string(forKey: Key.tool) ?? "") ?? .pen }
        set { defaults.set(newValue.rawValue, forKey: Key.tool) }
    }

    var toolbarOrigin: NSPoint? {
        get {
            guard let s = defaults.string(forKey: Key.toolbarOrigin) else { return nil }
            return NSPointFromString(s)
        }
        set {
            if let p = newValue {
                defaults.set(NSStringFromPoint(p), forKey: Key.toolbarOrigin)
            } else {
                defaults.removeObject(forKey: Key.toolbarOrigin)
            }
        }
    }

    var magnifierZoom: CGFloat {
        get {
            let stored = defaults.object(forKey: Key.magnifierZoom) as? Double ?? 2.0
            return Self.clamped(CGFloat(stored), Self.zoomRange)
        }
        set { defaults.set(Double(Self.clamped(newValue, Self.zoomRange)), forKey: Key.magnifierZoom) }
    }

    var spotlightRadius: CGFloat {
        get {
            let stored = defaults.object(forKey: Key.spotlightRadius) as? Double ?? 150.0
            return Self.clamped(CGFloat(stored), Self.radiusRange)
        }
        set { defaults.set(Double(Self.clamped(newValue, Self.radiusRange)), forKey: Key.spotlightRadius) }
    }

    static func clamped(_ v: CGFloat, _ r: ClosedRange<CGFloat>) -> CGFloat {
        min(r.upperBound, max(r.lowerBound, v))
    }
}
