import Foundation

/// Закладки на файлы: macOS находит файл по закладке, даже если его переименовали или перенесли.
/// Этим пользуются полка и закреплённые файлы в буфере.
enum FileRefs {
    enum Resolution: Equatable {
        /// Файл на месте (возможно, по новому адресу); закладку стоит обновить, если она устарела.
        case found(URL, bookmark: Data)
        /// Файла больше нет: удалён или лежит в Корзине.
        case missing
        /// Файл на отключённом диске — ждём, пока диск вернут.
        case unavailable
    }

    static func bookmark(_ url: URL) -> Data {
        (try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)) ?? Data()
    }

    static func resolve(_ url: URL, bookmark: Data?) -> Resolution {
        if let bookmark, !bookmark.isEmpty {
            var stale = false
            if let found = try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting],
                                    relativeTo: nil, bookmarkDataIsStale: &stale) {
                let found = found.standardizedFileURL
                if isAlive(found) { return .found(found, bookmark: stale ? Self.bookmark(found) : bookmark) }
                if isInTrash(found) { return .missing }
            }
        }
        if isAlive(url) { return .found(url, bookmark: bookmark.flatMap { $0.isEmpty ? nil : $0 } ?? Self.bookmark(url)) }
        return isOnUnmountedVolume(url) ? .unavailable : .missing
    }

    static func isAlive(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path) && !isInTrash(url)
    }

    static func isInTrash(_ url: URL) -> Bool {
        url.path.contains("/.Trash/") || url.path.contains("/.Trashes/")
    }

    /// «/Volumes/Флешка/…», а флешку вынули.
    static func isOnUnmountedVolume(_ url: URL) -> Bool {
        let parts = url.path.split(separator: "/")
        guard parts.count >= 2, parts[0] == "Volumes" else { return false }
        return !FileManager.default.fileExists(atPath: "/Volumes/\(parts[1])")
    }
}
