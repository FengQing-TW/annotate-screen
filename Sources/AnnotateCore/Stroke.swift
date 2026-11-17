import Foundation
import CoreGraphics

/// 一筆標註（自由線、螢光筆、形狀、文字、雷射）
///
/// - 自由線／螢光筆／雷射：points 為取樣點
/// - 直線／箭頭／方框／橢圓：points = [起點, 終點]
/// - 文字：points = [左上角]，text、fontSize、textFrame 有值
/// 座標系由使用端決定（App 端用翻轉座標，左上為原點）
public struct Stroke: Identifiable, Equatable {
    public let id: UUID
    public var kind: StrokeKind
    public var color: RGBAColor
    public var lineWidth: CGFloat
    public var points: [CGPoint]
    public var text: String
    public var fontSize: CGFloat
    /// 文字方框（橡皮擦命中測試用）
    public var textFrame: CGRect

    public init(
        kind: StrokeKind,
        color: RGBAColor,
        lineWidth: CGFloat,
        points: [CGPoint],
        text: String = "",
        fontSize: CGFloat = 0,
        textFrame: CGRect = .zero,
        id: UUID = UUID()
    ) {
        self.id = id
        self.kind = kind
        self.color = color
        self.lineWidth = lineWidth
        self.points = points
        self.text = text
        self.fontSize = fontSize
        self.textFrame = textFrame
    }

    /// 形狀的起點
    public var start: CGPoint { points.first ?? .zero }
    /// 形狀的終點
    public var end: CGPoint { points.last ?? .zero }
}
