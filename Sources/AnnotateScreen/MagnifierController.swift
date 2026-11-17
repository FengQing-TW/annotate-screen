import AppKit
import CoreImage
import CoreMedia
import ScreenCaptureKit
import AnnotateCore

/// 接收 SCStream 畫面（背景佇列），只保留最新一張完整影格與它拍到的範圍
final class MagnifierFrameReceiver: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "tw.fengqing.AnnotateScreen.magnifier")
    private let lock = NSLock()
    private var latest: CIImage?
    /// latest 拍到的範圍（SCStreamFrameInfo.screenRect，全域 CG 座標、單位點）
    private var latestRect: CGRect = .null
    private var counter: Int = 0

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, CMSampleBufferIsValid(sampleBuffer) else { return }
        // 2026-11-13：只收 status == complete 的影格；沒有新畫面時送來的 idle 影格沒有 pixel buffer，忽略
        guard let attachmentsArray = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let attachments = attachmentsArray.first,
              let statusRaw = attachments[.status] as? Int,
              SCFrameStatus(rawValue: statusRaw) == .complete,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        // 讀不到 screenRect 就不知道這張拍的是哪一塊，丟掉
        guard let rectDict = attachments[.screenRect] as? NSDictionary,
              let screenRect = CGRect(dictionaryRepresentation: rectDict as CFDictionary),
              screenRect.width > 0, screenRect.height > 0 else { return }
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        lock.lock()
        latest = image
        latestRect = screenRect
        counter += 1
        lock.unlock()
    }

    /// 串流意外停止時通知（在主執行緒呼叫）
    var onStop: (@MainActor (String) -> Void)?

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        let message = error.localizedDescription
        NSLog("AnnotateScreen：放大鏡串流停止 \(message)")
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.onStop?(message)
            }
        }
    }

    /// 最新畫面、它拍到的範圍（全域 CG）與流水號（流水號用來判斷有沒有新畫面）
    func snapshot() -> (CIImage?, CGRect, Int) {
        lock.lock()
        defer { lock.unlock() }
        return (latest, latestRect, counter)
    }

    func reset() {
        lock.lock()
        latest = nil
        latestRect = .null
        lock.unlock()
    }
}

/// 放大鏡：游標旁的圓形放大視窗（預設 2×，1.5～4×）
/// 用 ScreenCaptureKit SCStream 擷取游標所在螢幕，排除本程式所有視窗，避免自己放大自己
/// 2026-11-13：只擷取游標附近 regionSide × regionSide 點（sourceRect），游標快移出這一塊時用 updateConfiguration 換位置；
/// 原本擷取整張螢幕（6016×3384 一張約 78 MB）
@MainActor
final class MagnifierController {
    static let diameter: CGFloat = 220
    static let cursorOffset: CGFloat = 28
    /// 擷取範圍邊長（點）
    static let regionSide: CGFloat = 800
    /// 放大的那一塊離擷取範圍邊緣小於這個點數就更新範圍
    static let recenterMargin: CGFloat = 48
    /// updateConfiguration 送出後多久還沒收到新範圍的影格，就重啟串流（秒）
    static let updateTimeout: TimeInterval = 0.5

    var zoom: CGFloat {
        didSet { forceRender = true }
    }
    var onError: ((String) -> Void)?
    /// true＝擷取整張螢幕、永不更新範圍（Preferences.magnifierFullDisplay 退路）；下次啟動串流時生效
    var fullDisplay = false
    /// 自我測試用：設了就取代 NSEvent.mouseLocation（AppKit 全域座標）
    var mouseOverride: NSPoint?
    private(set) var isActive = false

    // 統計（給自我測試用）
    /// 送出 updateConfiguration 的次數
    private(set) var updateConfigurationCount = 0
    /// 等不到新範圍而重啟串流的次數
    private(set) var timeoutRestartCount = 0
    /// 放大鏡目前顯示的畫面
    private(set) var currentImage: CGImage?

    private var panel: NSPanel?
    private let imageLayer = CALayer()
    private var timer: Timer?
    private let receiver = MagnifierFrameReceiver()
    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private var stream: SCStream?
    private var streamDisplayID: CGDirectDisplayID?
    /// 目前串流的 filter、每點像素數、擷取範圍邊長（更新範圍時沿用）
    private var streamFilter: SCContentFilter?
    private var streamScale: CGFloat = 2
    private var streamSide: CGFloat = 800
    private var attemptedDisplayID: CGDirectDisplayID?
    /// 找不到螢幕時，最早什麼時候再重試（systemUptime）；避免每秒 60 次重查（2026-11-13）
    private var retryNotBefore: TimeInterval = 0
    private var isStarting = false
    /// 等待中的範圍更新：要求的全域 CG 矩形與送出時間（systemUptime）
    private var pendingRect: CGRect?
    private var pendingSince: TimeInterval = 0
    private var lastMouse = NSPoint(x: -100_000, y: -100_000)
    private var lastFrameCounter = -1
    private var forceRender = true

    init(zoom: CGFloat) {
        self.zoom = zoom
        receiver.onStop = { [weak self] message in
            self?.fail("放大鏡已停止：\(message)")
        }
    }

    /// 串流啟動失敗或中途停止：關閉放大鏡並通知，避免停在空白或凍結的畫面
    private func fail(_ message: String) {
        guard isActive else { return }
        stop()
        onError?(message)
    }

    var windowNumber: Int? { panel?.windowNumber }

    /// 最新影格拍到的範圍（全域 CG）與像素大小；還沒有影格回 nil（自我測試用）
    var latestFrameInfo: (screenRect: CGRect, pixelSize: CGSize)? {
        let (image, rect, _) = receiver.snapshot()
        guard let image else { return nil }
        return (rect, image.extent.size)
    }

    func start() {
        guard !isActive else { return }
        isActive = true
        let p = panel ?? makePanel()
        panel = p
        p.orderFrontRegardless()
        forceRender = true
        lastMouse = NSPoint(x: -100_000, y: -100_000)
        imageLayer.contents = nil
        currentImage = nil
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.tick()
            }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        tick()
    }

    func stop() {
        guard isActive else { return }
        isActive = false
        timer?.invalidate()
        timer = nil
        panel?.orderOut(nil)
        attemptedDisplayID = nil
        pendingRect = nil
        Task { @MainActor in
            await self.stopStream()
        }
    }

    /// 螢幕插拔：下一次 tick 重新對應螢幕與串流
    func screensChanged() {
        guard isActive else { return }
        attemptedDisplayID = nil
        pendingRect = nil
    }

    private func makePanel() -> NSPanel {
        let d = Self.diameter
        let panel = makeFloatingPanel(frame: NSRect(x: 0, y: 0, width: d, height: d), level: WindowLevels.magnifier)
        panel.ignoresMouseEvents = true
        panel.hasShadow = true

        let view = NSView(frame: NSRect(x: 0, y: 0, width: d, height: d))
        view.wantsLayer = true
        if let layer = view.layer {
            layer.cornerRadius = d / 2
            layer.masksToBounds = true
            layer.borderWidth = 3
            layer.borderColor = NSColor.white.cgColor
            layer.backgroundColor = NSColor(white: 0.15, alpha: 1).cgColor
            imageLayer.frame = layer.bounds
            imageLayer.contentsGravity = .resize
            layer.addSublayer(imageLayer)
        }
        panel.contentView = view
        return panel
    }

    /// 游標位置（AppKit 全域）；自我測試時用 mouseOverride
    private func currentMouse() -> NSPoint {
        mouseOverride ?? NSEvent.mouseLocation
    }

    /// 包含這個點的螢幕；沒有設 mouseOverride 時與 NSScreen.underMouse() 相同
    private func screenContaining(_ p: NSPoint) -> NSScreen? {
        guard mouseOverride != nil else { return NSScreen.underMouse() }
        let screens = NSScreen.screens
        if let hit = screens.first(where: { NSMouseInRect(p, $0.frame, false) }) { return hit }
        if let near = screens.first(where: { $0.frame.insetBy(dx: -2, dy: -2).contains(p) }) { return near }
        return NSScreen.main ?? screens.first
    }

    /// 主螢幕（NSScreen.screens.first，AppKit 原點所在）的高度，用來換算全域 CG 座標
    private static func mainScreenHeight(fallback: NSScreen) -> CGFloat {
        NSScreen.screens.first?.frame.height ?? fallback.frame.height
    }

    private func tick() {
        let mouse = currentMouse()
        guard let screen = screenContaining(mouse), let id = screen.displayID else { return }

        if id != attemptedDisplayID && !isStarting
            && ProcessInfo.processInfo.systemUptime >= retryNotBefore {
            attemptedDisplayID = id
            pendingRect = nil
            startStream(displayID: id, screen: screen)
        }

        let moved = mouse != lastMouse
        if moved {
            lastMouse = mouse
            positionPanel(mouse: mouse, screen: screen)
        }

        let (image, frameRect, counter) = receiver.snapshot()
        guard let image, streamDisplayID == id, !frameRect.isNull else { return }

        let mainHeight = Self.mainScreenHeight(fallback: screen)
        let mouseCG = WindowPicking.cgPoint(fromAppKit: mouse, mainScreenHeight: mainHeight)
        let displayCG = WindowPicking.screenCGFrame(appKitFrame: screen.frame, mainScreenHeight: mainHeight)
        updateRegionIfNeeded(frameRect: frameRect, mouseCG: mouseCG, displayCG: displayCG)

        guard moved || counter != lastFrameCounter || forceRender else { return }
        lastFrameCounter = counter
        forceRender = false
        render(image: image, frameRect: frameRect, mouseCG: mouseCG)
    }

    /// 等待中的更新是否完成或逾時；沒有等待中的更新時，游標快移出擷取範圍就送出新範圍
    private func updateRegionIfNeeded(frameRect: CGRect, mouseCG: CGPoint, displayCG: CGRect) {
        let now = ProcessInfo.processInfo.systemUptime
        if let pending = pendingRect {
            if Self.roughlyEqual(frameRect, pending) {
                pendingRect = nil
            } else if now - pendingSince > Self.updateTimeout {
                // 等不到新範圍的影格：清掉等待狀態，讓 tick() 開頭的既有邏輯重啟串流
                NSLog("AnnotateScreen：放大鏡更新擷取範圍逾時，重啟串流")
                pendingRect = nil
                attemptedDisplayID = nil
                timeoutRestartCount += 1
            }
            return
        }
        guard !isStarting, let s = stream, streamSide.isFinite else { return }

        let side = Self.diameter / zoom
        let crop = CGRect(x: mouseCG.x - side / 2, y: mouseCG.y - side / 2, width: side, height: side)
        guard MagnifierRegion.needsRecenter(frameRect: frameRect, crop: crop, displayFrame: displayCG,
                                            margin: Self.recenterMargin) else { return }
        let local = CGPoint(x: mouseCG.x - displayCG.minX, y: mouseCG.y - displayCG.minY)
        let region = MagnifierRegion.region(centeredAt: local, displaySize: displayCG.size, side: streamSide)
        let requested = region.offsetBy(dx: displayCG.minX, dy: displayCG.minY)
        // 夾邊後範圍與目前相同就不送（避免每個 tick 重送）
        guard !Self.roughlyEqual(requested, frameRect) else { return }

        let config = Self.makeConfig(region: region, scale: streamScale)
        pendingRect = requested
        pendingSince = now
        updateConfigurationCount += 1
        Task { @MainActor in
            do {
                try await s.updateConfiguration(config)
            } catch {
                // 期間串流已換掉（重啟、關閉）就不必理會
                guard self.stream === s else { return }
                NSLog("AnnotateScreen：放大鏡更新擷取範圍失敗 \(error.localizedDescription)")
                self.fail("放大鏡無法更新擷取範圍：\(error.localizedDescription)")
            }
        }
    }

    /// 兩個矩形的原點與大小相差都小於 1 點
    private static func roughlyEqual(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) < 1 && abs(a.minY - b.minY) < 1
            && abs(a.width - b.width) < 1 && abs(a.height - b.height) < 1
    }

    /// 放在游標右下方；碰到螢幕邊緣就換邊
    private func positionPanel(mouse: NSPoint, screen: NSScreen) {
        guard let panel else { return }
        let d = Self.diameter
        let off = Self.cursorOffset
        let f = screen.frame
        var x = mouse.x + off
        var y = mouse.y - off - d
        if x + d > f.maxX { x = mouse.x - off - d }
        if y < f.minY { y = mouse.y + off }
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    /// 從影格裁出游標周圍一塊；一律用影格自己的 screenRect 換算（範圍更新中，影格可能還是舊範圍）
    /// 超出影格的部分是透明
    private func render(image: CIImage, frameRect: CGRect, mouseCG: CGPoint) {
        let extent = image.extent
        guard extent.width > 0, frameRect.width > 0 else { return }
        let scale = extent.width / frameRect.width
        let side = Self.diameter / zoom
        let rect = MagnifierRegion.cropInFrame(frameRect: frameRect, center: mouseCG, side: side, scale: scale)
            .offsetBy(dx: extent.minX, dy: extent.minY)
            .integral
        guard let cg = ciContext.createCGImage(image, from: rect) else { return }
        currentImage = cg
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.contents = cg
        CATransaction.commit()
    }

    /// 串流設定：sourceRect＝region（顯示器內左上原點、點），輸出像素＝region × scale
    private static func makeConfig(region: CGRect, scale: CGFloat) -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        config.sourceRect = region
        config.width = max(1, Int((region.width * scale).rounded()))
        config.height = max(1, Int((region.height * scale).rounded()))
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        // 佇列只留 3 張（全螢幕退路時一張可達數十 MB）
        config.queueDepth = 3
        config.showsCursor = false
        config.pixelFormat = kCVPixelFormatType_32BGRA
        return config
    }

    private func startStream(displayID: CGDirectDisplayID, screen: NSScreen) {
        isStarting = true
        Task { @MainActor in
            defer { self.isStarting = false }
            await self.stopStream()
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard self.isActive else { return }
                guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
                    // 2026-11-13：ScreenCaptureKit 還沒列出這台（剛插上等）→ 原本就此停在空白、不再重試；
                    // 改為清掉已嘗試紀錄，1 秒後由 tick() 再試
                    self.attemptedDisplayID = nil
                    self.retryNotBefore = ProcessInfo.processInfo.systemUptime + 1
                    return
                }
                let pid = ProcessInfo.processInfo.processIdentifier
                let ownApps = content.applications.filter { $0.processID == pid }
                let filter: SCContentFilter
                if ownApps.isEmpty {
                    // 找不到本程式的 SCRunningApplication 時，改為逐一排除本程式的視窗
                    let ownWindows = content.windows.filter { $0.owningApplication?.processID == pid }
                    filter = SCContentFilter(display: display, excludingWindows: ownWindows)
                } else {
                    filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])
                }
                // 每點像素數用 ScreenCaptureKit 對這個 filter 的倍率（同截圖，初審 #4）
                let scale = filter.pointPixelScale > 0 ? CGFloat(filter.pointPixelScale) : screen.backingScaleFactor
                let side = self.fullDisplay ? CGFloat.infinity : Self.regionSide
                // 以「現在」的游標算範圍（SCShareableContent 查詢期間游標可能已移動）
                let mainHeight = Self.mainScreenHeight(fallback: screen)
                let displayCG = WindowPicking.screenCGFrame(appKitFrame: screen.frame, mainScreenHeight: mainHeight)
                let mouseCG = WindowPicking.cgPoint(fromAppKit: self.currentMouse(), mainScreenHeight: mainHeight)
                let local = CGPoint(x: mouseCG.x - displayCG.minX, y: mouseCG.y - displayCG.minY)
                let region = MagnifierRegion.region(centeredAt: local, displaySize: displayCG.size, side: side)
                let config = Self.makeConfig(region: region, scale: scale)

                let newStream = SCStream(filter: filter, configuration: config, delegate: self.receiver)
                try newStream.addStreamOutput(self.receiver, type: .screen, sampleHandlerQueue: self.receiver.queue)
                try await newStream.startCapture()
                guard self.isActive else {
                    try? await newStream.stopCapture()
                    return
                }
                self.stream = newStream
                self.streamDisplayID = displayID
                self.streamFilter = filter
                self.streamScale = scale
                self.streamSide = side
                self.pendingRect = nil
                self.forceRender = true
            } catch {
                NSLog("AnnotateScreen：放大鏡啟動失敗 \(error.localizedDescription)")
                self.fail("放大鏡無法啟動：\(error.localizedDescription)")
            }
        }
    }

    private func stopStream() async {
        pendingRect = nil
        guard let s = stream else { return }
        stream = nil
        streamDisplayID = nil
        streamFilter = nil
        try? await s.stopCapture()
        receiver.reset()
    }
}
