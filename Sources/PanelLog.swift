import AppKit

/// Короткий журнал открытия шторки: ~/Library/Logs/Шторка/panel.log.
/// Только сведения об окне шторки (какое приложение впереди, видна ли она, какие окна над ней) —
/// без содержимого экрана. Нужен, чтобы разобраться, если шторка где-то не показывается.
enum PanelLog {
    private static let url: URL = {
        let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/Шторка", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("panel.log")
    }()

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    static func write(_ message: String) {
        let line = "\(formatter.string(from: Date()))  \(message)\n"
        // Не даём журналу разрастись: больше ~200 КБ — начинаем заново.
        if let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int, size > 200_000 {
            try? FileManager.default.removeItem(at: url)
        }
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }

    static var frontApp: String {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?"
    }

    /// Окна других программ, лежащие над шторкой и пересекающиеся с ней.
    static func windowsAbove(_ window: NSWindow) -> String {
        let id = CGWindowID(window.windowNumber)
        let list = CGWindowListCopyWindowInfo([.optionOnScreenAboveWindow], id) as? [[String: Any]] ?? []
        let mine = CGRect(x: window.frame.minX, y: 0, width: window.frame.width, height: window.frame.height)
        let above = list.compactMap { info -> String? in
            guard let b = info[kCGWindowBounds as String] as? [String: CGFloat] else { return nil }
            let rect = CGRect(x: b["X"] ?? 0, y: b["Y"] ?? 0, width: b["Width"] ?? 0, height: b["Height"] ?? 0)
            guard rect.intersects(mine) else { return nil }
            let owner = info[kCGWindowOwnerName as String] as? String ?? "?"
            let layer = info[kCGWindowLayer as String] as? Int ?? 0
            // Сам курсор мыши — тоже «окно» над всеми; он не мешает.
            if layer >= Int(CGWindowLevelForKey(.cursorWindow)) { return nil }
            return "\(owner) (уровень \(layer), \(Int(rect.width))×\(Int(rect.height)))"
        }
        return above.isEmpty ? "ничего" : above.joined(separator: ", ")
    }
}
