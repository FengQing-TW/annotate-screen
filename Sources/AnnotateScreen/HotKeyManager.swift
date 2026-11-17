import AppKit
import Carbon

/// 全域快捷鍵：Carbon RegisterEventHotKey（不需要輔助使用權限）
@MainActor
final class HotKeyManager {
    /// 'ANST'
    private static let signature: OSType = 0x414E_5354

    private struct Entry {
        let ref: EventHotKeyRef
        let action: () -> Void
    }

    private var entries: [UInt32: Entry] = [:]
    private var nextID: UInt32 = 1
    private var handlerRef: EventHandlerRef?

    /// 事件處理器是否安裝成功（失敗時註冊的熱鍵不會有反應）
    var isHandlerInstalled: Bool { handlerRef != nil }

    init() {
        installHandler()
    }

    private func installHandler() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let userData = Unmanaged.passUnretained(self).toOpaque()
        let status = InstallEventHandler(GetApplicationEventTarget(), hotKeyEventHandler, 1, &spec, userData, &handlerRef)
        if status != noErr {
            NSLog("AnnotateScreen：安裝熱鍵處理器失敗 \(status)")
        }
    }

    /// 註冊熱鍵；失敗（例如被其他程式佔用）回傳 nil
    @discardableResult
    func register(keyCode: Int, modifiers: Int, action: @escaping () -> Void) -> UInt32? {
        let id = nextID
        nextID += 1
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: id)
        let status = RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), hotKeyID, GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else { return nil }
        entries[id] = Entry(ref: ref, action: action)
        return id
    }

    func unregister(_ id: UInt32) {
        guard let entry = entries.removeValue(forKey: id) else { return }
        UnregisterEventHotKey(entry.ref)
    }

    func unregisterAll() {
        for id in Array(entries.keys) { unregister(id) }
    }

    fileprivate func handle(id: UInt32) {
        entries[id]?.action()
    }
}

/// Carbon 事件回呼（C 函式指標，不能捕捉環境）；在主執行緒上被呼叫
private func hotKeyEventHandler(
    _ next: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let event, let userData else { return OSStatus(eventNotHandledErr) }
    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotKeyID
    )
    guard status == noErr else { return status }
    let id = hotKeyID.id
    let manager = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()
    MainActor.assumeIsolated {
        manager.handle(id: id)
    }
    return noErr
}
