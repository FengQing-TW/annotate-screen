import AppKit
import ScreenCaptureKit
import AnnotateCore

enum ScreenshotError: LocalizedError {
    case displayNotFound
    case encodeFailed

    var errorDescription: String? {
        switch self {
        case .displayNotFound: return "找不到要截圖的螢幕"
        case .encodeFailed: return "無法轉成 PNG"
        }
    }
}

/// 截圖：游標所在螢幕的完整畫面，或螢幕內的指定範圍（簡報＋標註），排除工具列與 toast
@MainActor
final class ScreenshotService {
    /// ~/Downloads（2026-11-13 使用者裁示：由 ~/Pictures/AnnotateScreen 改為下載資料夾，直接放、不建子資料夾；
    /// 檔名以 AnnotateScreen_ 開頭可辨識）
    static var folderURL: URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads", isDirectory: true)
    }

    /// 截圖、存檔並複製到剪貼簿，回傳檔案位置
    /// - region：螢幕內座標、左上原點、單位為點；nil 表示整個螢幕
    func capture(
        screen: NSScreen,
        displayID: CGDirectDisplayID,
        region: CGRect? = nil,
        excludingWindowNumbers: Set<Int>
    ) async throws -> URL {
        let pointSize = region?.size ?? screen.frame.size

        // onScreenWindowsOnly: false——要排除的視窗有些剛收起（範圍選取的遮罩），只查畫面上的視窗會找不到它們，
        // 排除就沒生效（2026-11-13 初審 #2）
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw ScreenshotError.displayNotFound
        }
        // sharingType = .none 在 macOS 15 起可能不被 ScreenCaptureKit 理會，這裡再明確排除一次
        let excluded = content.windows.filter { excludingWindowNumbers.contains(Int($0.windowID)) }
        let filter = SCContentFilter(display: display, excludingWindows: excluded)
        // 輸出像素用 ScreenCaptureKit 對這個 filter 的倍率；AppKit 的 backingScaleFactor 在特殊顯示器上可能不同（初審 #4）
        let scale = filter.pointPixelScale > 0 ? CGFloat(filter.pointPixelScale) : screen.backingScaleFactor

        let config = SCStreamConfiguration()
        let pixels = RegionSelection.pixelSize(of: CGRect(origin: .zero, size: pointSize), scale: scale)
        config.width = pixels.width
        config.height = pixels.height
        if let region {
            // 範圍截圖：sourceRect 以顯示器左上為原點、單位為點
            config.sourceRect = region
        }
        config.showsCursor = false

        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)

        // PNG 壓縮與寫檔放到背景，避免高解析度螢幕卡住主執行緒（聚光燈、雷射會停頓）
        // 2026-11-13：剪貼簿用的 TIFF 也在這裡產生（原本在主執行緒產生未壓縮 TIFF，6016×3384 約 80 MB 會卡住畫面）
        let folder = Self.folderURL
        let now = Date()
        let (url, png, tiff) = try await Task.detached(priority: .userInitiated) { () throws -> (URL, Data, Data?) in
            let rep = NSBitmapImageRep(cgImage: image)
            guard let png = rep.representation(using: .png, properties: [:]) else {
                throw ScreenshotError.encodeFailed
            }
            let fm = FileManager.default
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            let name = ScreenshotNaming.fileName(for: now) { candidate in
                fm.fileExists(atPath: folder.appendingPathComponent(candidate).path)
            }
            let url = folder.appendingPathComponent(name)
            try png.write(to: url, options: .atomic)
            // PNG 產生完才改 size，PNG 內容維持原樣；TIFF 帶點數大小，貼到其他 App 時尺寸與原本相同
            rep.size = pointSize
            let tiff = rep.representation(
                using: .tiff,
                properties: [.compressionMethod: NSNumber(value: NSBitmapImageRep.TIFFCompression.lzw.rawValue)]
            )
            return (url, png, tiff)
        }.value

        copyToPasteboard(png: png, tiff: tiff)
        return url
    }

    /// 只做 pasteboard 寫入（TIFF 已在背景產生；產生失敗就只放 PNG）
    private func copyToPasteboard(png: Data, tiff: Data?) {
        let pb = NSPasteboard.general
        if let tiff {
            pb.declareTypes([.png, .tiff], owner: nil)
            pb.setData(png, forType: .png)
            pb.setData(tiff, forType: .tiff)
        } else {
            pb.declareTypes([.png], owner: nil)
            pb.setData(png, forType: .png)
        }
    }
}

/// 螢幕錄製權限與對話框
@MainActor
enum Alerts {
    /// 有權限回傳 true；沒有就請求並說明
    static func ensureScreenCaptureAccess() -> Bool {
        if CGPreflightScreenCaptureAccess() { return true }
        _ = CGRequestScreenCaptureAccess()
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "需要「螢幕與系統錄音」權限"
        alert.informativeText = """
        截圖與放大鏡需要螢幕錄製權限。
        請到「系統設定 → 隱私權與安全性 → 螢幕與系統錄音」打開 AnnotateScreen，然後重新開啟本程式。
        （畫圖、聚光燈、白板不需要這個權限。）
        """
        alert.addButton(withTitle: "開啟系統設定")
        alert.addButton(withTitle: "稍後")
        if run(alert) == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
        return false
    }

    static func showShortcutHelp(failed: [String]) {
        let alert = NSAlert()
        alert.messageText = "AnnotateScreen 快捷鍵"
        var text = """
        全域（任何時候）
        ⌃⌥A 切換畫圖／穿透
        ⌃⌥S 截圖　⌃⌥R 範圍截圖（拖曳選取，Esc 或右鍵取消）
        ⌃⌥E 視窗截圖（點選視窗，Esc 或右鍵取消）
        ⌃⌥X 清除游標所在螢幕　⌃⌥Z 復原
        ⌃⌥F 聚光燈　⌃⌥M 放大鏡
        ⌃⌥W 白板　⌃⌥B 黑板
        ⌃⌥H 隱藏／顯示標註　⌃⌥T 顯示／隱藏工具列
        聚光燈或放大鏡開啟時：[ ] 調整半徑／倍率
        ⌘4 畫筆／滑鼠切換：畫圖中按＝清除所有螢幕並回到滑鼠控制；再按＝回到畫筆
        ⌘3 畫筆／滑鼠切換：畫圖中按＝隱藏所有標註（不清除）並回到滑鼠控制；再按＝回到畫筆並顯示標註

        畫圖模式內
        P 畫筆　H 螢光筆　L 直線　A 箭頭　R 方框
        O 橢圓　T 文字　G 雷射筆　E 橡皮擦
        1～8 顏色（紅橙黃綠藍紫黑白）　[ ] 粗細
        ⌘Z 復原　⇧⌘Z 重做　⌫ 清除目前畫面
        Shift 拖曳：直線鎖 45°、方框正方形、橢圓正圓
        Esc 結束畫圖（文字輸入中先取消輸入）
        文字：Enter 確定、Shift+Enter 換行、Esc 取消
        """
        if !failed.isEmpty {
            text += "\n\n以下快捷鍵被其他程式佔用，無法使用：\n" + failed.joined(separator: "\n")
        }
        alert.informativeText = text
        alert.addButton(withTitle: "好")
        _ = run(alert)
    }

    /// 對話框要蓋在覆蓋層（screenSaver 層級）之上，才不會被白板擋住
    @discardableResult
    static func run(_ alert: NSAlert) -> NSApplication.ModalResponse {
        NSApp.activate()
        alert.window.level = WindowLevels.alert
        return alert.runModal()
    }
}
