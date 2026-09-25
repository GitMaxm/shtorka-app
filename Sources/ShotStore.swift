import AppKit
import QuickLookThumbnailing

struct Shot: Identifiable, Hashable {
    let url: URL
    let date: Date
    var id: URL { url }
    var isVideo: Bool { ["mov", "mp4"].contains(url.pathExtension.lowercased()) }
}

/// Следит за папкой, куда macOS сохраняет скриншоты, и держит список последних.
@MainActor
final class ShotStore: ObservableObject {
    @Published private(set) var shots: [Shot] = []
    @Published private(set) var folder: URL = ShotStore.screenshotFolder()
    @Published private(set) var accessDenied = false
    /// Сколько скриншотов в папке всего (на полке показываем не больше `limit`).
    @Published private(set) var totalCount = 0

    nonisolated static let limit = 24
    /// Для самопроверки: смотреть в другую папку вместо системной.
    var folderOverride: URL?

    private var source: DispatchSourceFileSystemObject?
    private var watchedPath: String?
    private var pendingReload: DispatchWorkItem?

    /// Папка из `defaults read com.apple.screencapture location`, иначе рабочий стол.
    nonisolated static func screenshotFolder() -> URL {
        let domain = "com.apple.screencapture" as CFString
        CFPreferencesAppSynchronize(domain)
        if let location = CFPreferencesCopyAppValue("location" as CFString, domain) as? String, !location.isEmpty {
            let path = (location as NSString).expandingTildeInPath
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
                return URL(fileURLWithPath: path, isDirectory: true)
            }
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop", isDirectory: true)
    }

    func reload() {
        let dir = folderOverride ?? Self.screenshotFolder()
        folder = dir
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Self.scan(dir, limit: .max)
            DispatchQueue.main.async {
                switch result {
                case .success(let all):
                    self.accessDenied = false
                    let shots = Array(all.prefix(Self.limit))
                    if shots != self.shots { self.shots = shots }
                    self.totalCount = all.count
                    if self.watchedPath != dir.path { self.watch(dir) }
                case .failure:
                    self.accessDenied = true
                    self.shots = []
                    self.totalCount = 0
                }
            }
        }
    }

    func setPreviewShots(_ shots: [Shot]) {
        self.shots = shots
        totalCount = shots.count
    }

    /// Убираем карточку сразу, не дожидаясь пересканирования папки.
    func remove(_ shot: Shot) {
        shots.removeAll { $0.id == shot.id }
        totalCount = max(0, totalCount - 1)
    }

    func removeAllLocally() {
        shots = []
        totalCount = 0
    }

    private func scheduleReload() {
        pendingReload?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.reload() }
        pendingReload = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    private func watch(_ dir: URL) {
        source?.cancel()
        source = nil
        watchedPath = nil
        let fd = open(dir.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
        src.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.scheduleReload() }
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        source = src
        watchedPath = dir.path
    }

    // MARK: - Сканирование

    nonisolated private static let extensions: Set<String> = ["png", "jpg", "jpeg", "heic", "tiff", "gif", "mov", "mp4"]
    nonisolated private static let prefixes = ["снимок экрана", "запись экрана", "screenshot", "screen shot", "screen recording", "cleanshot"]

    nonisolated private static func scan(_ dir: URL, limit: Int) -> Result<[Shot], Error> {
        let keys: [URLResourceKey] = [.creationDateKey, .contentModificationDateKey, .isRegularFileKey]
        let items: [URL]
        do {
            items = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
        } catch {
            return .failure(error)
        }
        let shots = items.compactMap { url -> Shot? in
            guard extensions.contains(url.pathExtension.lowercased()), isScreenCapture(url) else { return nil }
            let values = try? url.resourceValues(forKeys: Set(keys))
            guard values?.isRegularFile == true else { return nil }
            return Shot(url: url, date: values?.creationDate ?? values?.contentModificationDate ?? .distantPast)
        }
        return .success(Array(shots.sorted { $0.date > $1.date }.prefix(limit)))
    }

    // MARK: - Смена папки

    /// Меняет папку, куда macOS сохраняет скриншоты (то же, что ⌘⇧5 → Параметры → Сохранить в).
    nonisolated static func setScreenshotFolder(_ url: URL, restartSystemUI: Bool = true) {
        run("/usr/bin/defaults", ["write", "com.apple.screencapture", "location", "-string", url.path])
        if restartSystemUI { run("/usr/bin/killall", ["SystemUIServer"]) }
        CFPreferencesAppSynchronize("com.apple.screencapture" as CFString)
    }

    /// Все скриншоты в папке, без ограничения по количеству.
    nonisolated static func allScreenshots(in dir: URL) -> [Shot] {
        (try? scan(dir, limit: .max).get()) ?? []
    }

    /// Переносит файлы в папку; при совпадении имён добавляет « 2», « 3»…
    nonisolated static func move(_ shots: [Shot], to folder: URL) -> Int {
        var moved = 0
        for shot in shots {
            let name = shot.url.deletingPathExtension().lastPathComponent
            let ext = shot.url.pathExtension
            var target = folder.appendingPathComponent(shot.url.lastPathComponent)
            var n = 2
            while FileManager.default.fileExists(atPath: target.path) {
                target = folder.appendingPathComponent("\(name) \(n)").appendingPathExtension(ext)
                n += 1
            }
            if (try? FileManager.default.moveItem(at: shot.url, to: target)) != nil { moved += 1 }
        }
        return moved
    }

    /// «Рабочий стол», «Изображения › Скриншоты» — как в Finder.
    nonisolated static func displayName(for folder: URL) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        var url = folder.standardizedFileURL
        var parts: [String] = []
        while url.path != home, url.path != "/", !url.path.isEmpty {
            parts.insert(FileManager.default.displayName(atPath: url.path), at: 0)
            url.deleteLastPathComponent()
        }
        return parts.isEmpty ? "Домашняя папка" : parts.joined(separator: " › ")
    }

    nonisolated private static func run(_ path: String, _ arguments: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        try? process.run()
        process.waitUntilExit()
    }

    nonisolated private static func isScreenCapture(_ url: URL) -> Bool {
        let name = url.lastPathComponent.precomposedStringWithCanonicalMapping.lowercased()
        if prefixes.contains(where: { name.hasPrefix($0) }) { return true }
        // macOS помечает свои скриншоты этим атрибутом независимо от имени файла.
        return getxattr(url.path, "com.apple.metadata:kMDItemIsScreenCapture", nil, 0, 0, 0) > 0
    }
}

/// Кэш миниатюр через Quick Look — одинаково работает для картинок и видео.
@MainActor
final class ThumbCache {
    static let shared = ThumbCache()
    private let cache = NSCache<NSString, NSImage>()

    private func key(_ shot: Shot) -> NSString { "\(shot.url.path)|\(shot.date.timeIntervalSince1970)" as NSString }

    func cached(_ shot: Shot) -> NSImage? { cache.object(forKey: key(shot)) }

    func store(_ image: NSImage, for shot: Shot) { cache.setObject(image, forKey: key(shot)) }

    /// Миниатюра любого файла (для полки). Ключ — путь и дата изменения.
    func load(url: URL, size: CGSize) async -> NSImage? {
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
        return await load(Shot(url: url, date: modified), size: size)
    }

    func cached(url: URL) -> NSImage? {
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
        return cached(Shot(url: url, date: modified))
    }

    func load(_ shot: Shot, size: CGSize) async -> NSImage? {
        if let hit = cached(shot) { return hit }
        let request = QLThumbnailGenerator.Request(fileAt: shot.url, size: size, scale: 2, representationTypes: .thumbnail)
        guard let rep = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) else { return nil }
        let image = rep.nsImage
        store(image, for: shot)
        return image
    }
}
