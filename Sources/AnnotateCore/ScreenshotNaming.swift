import Foundation

/// 截圖檔名：AnnotateScreen_yyyyMMdd_HHmmss.png，同秒重複加 _2、_3…
public enum ScreenshotNaming {
    public static let prefix = "AnnotateScreen"

    /// 不含副檔名的基本檔名
    public static func baseName(for date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        return "\(prefix)_\(formatter.string(from: date))"
    }

    /// 產生不重複的檔名；exists 回答「這個檔名是否已存在」
    public static func fileName(
        for date: Date,
        timeZone: TimeZone = .current,
        exists: (String) -> Bool
    ) -> String {
        let base = baseName(for: date, timeZone: timeZone)
        var candidate = base + ".png"
        var n = 2
        while exists(candidate) {
            candidate = "\(base)_\(n).png"
            n += 1
        }
        return candidate
    }
}
