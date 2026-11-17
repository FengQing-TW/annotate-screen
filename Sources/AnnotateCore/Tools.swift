import Foundation
import CoreGraphics

/// 顏色：以 RGBA（sRGB，0～1）表示，不依賴 NSColor
public struct RGBAColor: Equatable, Hashable, Codable {
    public var red: CGFloat
    public var green: CGFloat
    public var blue: CGFloat
    public var alpha: CGFloat

    public init(red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    /// 回傳只改透明度的新顏色
    public func withAlpha(_ a: CGFloat) -> RGBAColor {
        RGBAColor(red: red, green: green, blue: blue, alpha: a)
    }
}

/// 調色盤：紅、橙、黃、綠、藍、紫、黑、白（數字鍵 1～8）
public enum Palette {
    public static let colors: [RGBAColor] = [
        RGBAColor(red: 0.92, green: 0.16, blue: 0.16),
        RGBAColor(red: 1.00, green: 0.55, blue: 0.00),
        RGBAColor(red: 1.00, green: 0.85, blue: 0.00),
        RGBAColor(red: 0.15, green: 0.70, blue: 0.25),
        RGBAColor(red: 0.10, green: 0.45, blue: 0.95),
        RGBAColor(red: 0.60, green: 0.25, blue: 0.85),
        RGBAColor(red: 0.00, green: 0.00, blue: 0.00),
        RGBAColor(red: 1.00, green: 1.00, blue: 1.00),
    ]
    public static let names: [String] = ["紅", "橙", "黃", "綠", "藍", "紫", "黑", "白"]

    /// 依索引取色，超出範圍時夾回合法範圍
    public static func color(at index: Int) -> RGBAColor {
        colors[clampIndex(index)]
    }

    public static func clampIndex(_ index: Int) -> Int {
        max(0, min(colors.count - 1, index))
    }
}

/// 粗細：細／中／粗／特粗
public enum WidthLevel: Int, CaseIterable, Codable {
    case thin = 0, medium, thick, extraThick

    public var displayName: String {
        switch self {
        case .thin: return "細"
        case .medium: return "中"
        case .thick: return "粗"
        case .extraThick: return "特粗"
        }
    }

    /// 基本線寬（點）
    public var baseWidth: CGFloat {
        switch self {
        case .thin: return 2
        case .medium: return 4
        case .thick: return 8
        case .extraThick: return 14
        }
    }

    /// 文字工具的字級（點），隨粗細變化
    public var fontSize: CGFloat {
        switch self {
        case .thin: return 18
        case .medium: return 24
        case .thick: return 34
        case .extraThick: return 48
        }
    }

    /// 加粗或變細一級（到頭就停）
    public func stepped(_ delta: Int) -> WidthLevel {
        let raw = max(0, min(WidthLevel.allCases.count - 1, rawValue + delta))
        return WidthLevel(rawValue: raw) ?? self
    }
}

/// 筆畫種類（存在文件裡的物件）
public enum StrokeKind: String, Codable {
    case freehand, highlighter, line, arrow, rectangle, ellipse, text, laser
}

/// 工具
public enum Tool: String, CaseIterable, Codable {
    case pen, highlighter, line, arrow, rectangle, ellipse, text, laser, eraser

    public var displayName: String {
        switch self {
        case .pen: return "畫筆"
        case .highlighter: return "螢光筆"
        case .line: return "直線"
        case .arrow: return "箭頭"
        case .rectangle: return "方框"
        case .ellipse: return "橢圓"
        case .text: return "文字"
        case .laser: return "雷射筆"
        case .eraser: return "橡皮擦"
        }
    }

    /// 畫圖模式內的單鍵快捷鍵（小寫）
    public var keyCharacter: Character {
        switch self {
        case .pen: return "p"
        case .highlighter: return "h"
        case .line: return "l"
        case .arrow: return "a"
        case .rectangle: return "r"
        case .ellipse: return "o"
        case .text: return "t"
        case .laser: return "g"
        case .eraser: return "e"
        }
    }

    /// 工具產生的筆畫種類；橡皮擦不產生筆畫
    public var strokeKind: StrokeKind? {
        switch self {
        case .pen: return .freehand
        case .highlighter: return .highlighter
        case .line: return .line
        case .arrow: return .arrow
        case .rectangle: return .rectangle
        case .ellipse: return .ellipse
        case .text: return .text
        case .laser: return .laser
        case .eraser: return nil
        }
    }

    /// 是否為以起點／終點決定的形狀工具
    public var isShape: Bool {
        switch self {
        case .line, .arrow, .rectangle, .ellipse: return true
        default: return false
        }
    }

    /// 由按鍵字元找工具（不分大小寫）
    public static func tool(forKey key: Character) -> Tool? {
        guard let lower = String(key).lowercased().first else { return nil }
        return allCases.first { $0.keyCharacter == lower }
    }
}

/// 目前的工具設定（工具＋顏色＋粗細）
public struct ToolSettings: Equatable {
    public static let highlighterAlpha: CGFloat = 0.35

    public var tool: Tool
    public var colorIndex: Int
    public var widthLevel: WidthLevel

    public init(tool: Tool = .pen, colorIndex: Int = 0, widthLevel: WidthLevel = .medium) {
        self.tool = tool
        self.colorIndex = Palette.clampIndex(colorIndex)
        self.widthLevel = widthLevel
    }

    public var color: RGBAColor { Palette.color(at: colorIndex) }

    /// 實際畫出的顏色：螢光筆半透明
    public var strokeColor: RGBAColor {
        tool == .highlighter ? color.withAlpha(Self.highlighterAlpha) : color
    }

    public var lineWidth: CGFloat { lineWidth(for: tool) }

    public var fontSize: CGFloat { widthLevel.fontSize }

    /// 各工具的實際線寬：螢光筆較寬，雷射筆略粗
    public func lineWidth(for tool: Tool) -> CGFloat {
        let base = widthLevel.baseWidth
        switch tool {
        case .highlighter: return base * 4 + 4
        case .laser: return base + 3
        default: return base
        }
    }
}
