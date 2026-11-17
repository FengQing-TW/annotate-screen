import Foundation
import CoreGraphics

/// 一頁標註文件：筆畫清單＋復原／重做堆疊（以快照實作）
public final class AnnotationDocument {
    /// 復原堆疊上限
    public static let maxUndoDepth = 200

    public private(set) var strokes: [Stroke] = []
    private var undoStack: [[Stroke]] = []
    private var redoStack: [[Stroke]] = []

    // 群組：一次拖曳橡皮擦刪掉多筆只算一個復原步驟
    private var grouping = false
    private var groupRecorded = false

    public init() {}

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }
    public var isEmpty: Bool { strokes.isEmpty }

    /// 新增一筆；雷射筆不進文件也不進復原堆疊
    @discardableResult
    public func add(_ stroke: Stroke) -> Bool {
        guard stroke.kind != .laser else { return false }
        willChange()
        strokes.append(stroke)
        return true
    }

    /// 依 id 刪除
    @discardableResult
    public func remove(ids: Set<UUID>) -> Bool {
        guard strokes.contains(where: { ids.contains($0.id) }) else { return false }
        willChange()
        strokes.removeAll { ids.contains($0.id) }
        return true
    }

    /// 清除整頁（可復原）
    @discardableResult
    public func clear() -> Bool {
        guard !strokes.isEmpty else { return false }
        willChange()
        strokes.removeAll()
        return true
    }

    /// 橡皮擦：刪掉點到的整筆
    @discardableResult
    public func erase(at point: CGPoint, tolerance: CGFloat) -> Bool {
        let ids = Set(strokes.filter { HitTester.hits($0, point: point, tolerance: tolerance) }.map(\.id))
        return ids.isEmpty ? false : remove(ids: ids)
    }

    /// 橡皮擦：刪掉拖過（a→b）碰到的整筆
    @discardableResult
    public func erase(from a: CGPoint, to b: CGPoint, tolerance: CGFloat) -> Bool {
        let ids = Set(strokes.filter { HitTester.hits($0, along: a, to: b, tolerance: tolerance) }.map(\.id))
        return ids.isEmpty ? false : remove(ids: ids)
    }

    /// 開始群組：之後的變更合併成一個復原步驟
    public func beginGroup() {
        grouping = true
        groupRecorded = false
    }

    public func endGroup() {
        grouping = false
        groupRecorded = false
    }

    @discardableResult
    public func undo() -> Bool {
        guard let previous = undoStack.popLast() else { return false }
        redoStack.append(strokes)
        strokes = previous
        return true
    }

    @discardableResult
    public func redo() -> Bool {
        guard let next = redoStack.popLast() else { return false }
        undoStack.append(strokes)
        strokes = next
        return true
    }

    /// 變更前存快照；新動作會清掉重做堆疊
    private func willChange() {
        if grouping {
            if groupRecorded { return }
            groupRecorded = true
        }
        undoStack.append(strokes)
        if undoStack.count > Self.maxUndoDepth {
            undoStack.removeFirst(undoStack.count - Self.maxUndoDepth)
        }
        redoStack.removeAll()
    }
}

/// 頁面：螢幕標註、白板、黑板
public enum Page: String, CaseIterable {
    case screen, whiteboard, blackboard

    public var displayName: String {
        switch self {
        case .screen: return "螢幕"
        case .whiteboard: return "白板"
        case .blackboard: return "黑板"
        }
    }
}

/// 一個螢幕的三頁標註；每頁各自獨立（含各自的復原堆疊）
public final class PageSet {
    public private(set) var currentPage: Page = .screen
    private let documents: [Page: AnnotationDocument]

    public init() {
        var docs: [Page: AnnotationDocument] = [:]
        for page in Page.allCases { docs[page] = AnnotationDocument() }
        documents = docs
    }

    public func document(for page: Page) -> AnnotationDocument {
        documents[page]!
    }

    public var currentDocument: AnnotationDocument { document(for: currentPage) }

    public func setPage(_ page: Page) {
        currentPage = page
    }

    /// 白板／黑板開關：已在該頁就回到螢幕，否則切到該頁
    public func toggle(_ page: Page) {
        currentPage = (currentPage == page) ? .screen : page
    }
}
