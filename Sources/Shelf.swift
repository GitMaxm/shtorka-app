import AppKit
import UniformTypeIdentifiers

/// Что лежит на полке: один файл или стопка, брошенная за раз.
struct ShelfItem: Identifiable, Equatable, Codable {
    var id = UUID()
    var urls: [URL]
    var addedAt = Date()
    /// Файлы, которые Шторка сохранила сама (картинка из браузера и т. п.). Их удаляем вместе с записью,
    /// а обычные файлы с диска никогда не трогаем — полка хранит только ссылки на них.
    var owned = false
    /// Закладки на файлы (по одной на каждый URL) — чтобы найти файл после переименования или переноса.
    var bookmarks: [Data]?

    var title: String { Self.title(for: urls) }

    /// «Договор.pdf» или «3 файла».
    static func title(for urls: [URL]) -> String {
        urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) \(files(urls.count))"
    }

    private static func files(_ n: Int) -> String {
        let mod10 = n % 10, mod100 = n % 100
        if mod10 == 1 && mod100 != 11 { return "файл" }
        if (2...4).contains(mod10) && !(12...14).contains(mod100) { return "файла" }
        return "файлов"
    }
}

/// Полка для файлов: перетащи файл на шторку, потом забери его куда нужно.
@MainActor
final class ShelfStore: ObservableObject {
    @Published private(set) var items: [ShelfItem] = []

    let directory: URL
    private var indexURL: URL { directory.appendingPathComponent("shelf.json") }

    init(directory: URL = AppFolders.support.appendingPathComponent("Shelf", isDirectory: true)) {
        self.directory = directory
        load()
    }

    var fileCount: Int { items.reduce(0) { $0 + $1.urls.count } }

    func add(_ urls: [URL], owned: Bool = false) {
        guard !urls.isEmpty else { return }
        let urls = urls.map(\.standardizedFileURL)
        // Тот же файл уже на полке — просто поднимаем его наверх.
        if let index = items.firstIndex(where: { Set($0.urls) == Set(urls) }) {
            var existing = items.remove(at: index)
            existing.addedAt = Date()
            items.insert(existing, at: 0)
        } else {
            items.insert(ShelfItem(urls: urls, owned: owned, bookmarks: urls.map(FileRefs.bookmark)), at: 0)
        }
        save()
    }

    /// Картинка без файла (например, скопированная из браузера) — сохраняем её к себе и кладём на полку.
    @discardableResult
    func addImage(_ data: Data, type: NSPasteboard.PasteboardType) -> URL? {
        let ext = UTType(type.rawValue)?.preferredFilenameExtension ?? "png"
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'в' HH.mm.ss"
        let base = "Картинка \(formatter.string(from: Date()))"
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var target = directory.appendingPathComponent(base).appendingPathExtension(ext)
        var n = 2
        while FileManager.default.fileExists(atPath: target.path) {
            target = directory.appendingPathComponent("\(base) \(n)").appendingPathExtension(ext)
            n += 1
        }
        guard (try? data.write(to: target)) != nil else { return nil }
        add([target], owned: true)
        return target
    }

    /// Сверяет полку с диском: переименованные и перенесённые файлы находит по закладкам,
    /// удалённые (и отправленные в Корзину) убирает. Файлы на отключённых дисках не трогает.
    @discardableResult
    func refreshLocations() -> Bool {
        var changed = false
        var result: [ShelfItem] = []
        for var item in items {
            var urls: [URL] = []
            var marks: [Data] = []
            for (i, url) in item.urls.enumerated() {
                let mark = item.bookmarks.flatMap { i < $0.count ? $0[i] : nil }
                switch FileRefs.resolve(url, bookmark: mark) {
                case .found(let now, let bookmark):
                    urls.append(now)
                    marks.append(bookmark)
                case .unavailable:
                    urls.append(url)
                    marks.append(mark ?? Data())
                case .missing:
                    if item.owned { deleteOwned(url) }
                }
            }
            if urls != item.urls || marks != (item.bookmarks ?? []) { changed = true }
            guard !urls.isEmpty else { continue }
            item.urls = urls
            item.bookmarks = marks
            result.append(item)
        }
        if changed {
            items = result
            save()
        }
        return changed
    }

    /// Убирает с полки. Оригиналы остаются где были; удаляются только копии, сделанные самой Шторкой.
    func remove(_ item: ShelfItem) {
        items.removeAll { $0.id == item.id }
        if item.owned { item.urls.forEach(deleteOwned) }
        save()
    }

    func clear() {
        items.forEach { item in
            if item.owned { item.urls.forEach(deleteOwned) }
        }
        items.removeAll()
        save()
    }

    func setPreviewItems(_ items: [ShelfItem]) { self.items = items }

    // MARK: - Приём файлов

    enum DropResult { case added(Int), receiving, nothing }

    nonisolated static let legacyFilenames = NSPasteboard.PasteboardType("NSFilenamesPboardType")

    /// Что принимаем при перетаскивании на шторку.
    nonisolated static var droppableTypes: [NSPasteboard.PasteboardType] {
        [.fileURL, legacyFilenames, .png, .tiff, .string]
            + NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }
    }

    /// Файлы из буфера или перетаскивания — и в новом формате (Finder, VS Code),
    /// и в старом списке путей (так отдают WebStorm и другие IDE от JetBrains).
    nonisolated static func fileURLs(in pasteboard: NSPasteboard) -> [URL] {
        var urls = (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        if urls.isEmpty, let paths = pasteboard.propertyList(forType: legacyFilenames) as? [String] {
            urls = paths.map { URL(fileURLWithPath: $0) }
        }
        return urls.map(\.standardizedFileURL).filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Путь к файлу, записанный текстом («/Users/…/app.js», «~/…», «file://…»), если такой файл есть.
    nonisolated static func filePath(in text: String) -> URL? {
        let s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, !s.contains("\n") else { return nil }
        let url: URL?
        if s.hasPrefix("file://") {
            url = URL(string: s)
        } else if s.hasPrefix("/") {
            url = URL(fileURLWithPath: s)
        } else if s.hasPrefix("~/") {
            url = URL(fileURLWithPath: (s as NSString).expandingTildeInPath)
        } else {
            url = nil
        }
        guard let url, url.isFileURL, FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url.standardizedFileURL
    }

    nonisolated static func canAccept(_ pasteboard: NSPasteboard) -> Bool {
        !fileURLs(in: pasteboard).isEmpty
            || pasteboard.canReadObject(forClasses: [NSFilePromiseReceiver.self], options: nil)
            || pasteboard.availableType(from: [.png, .tiff]) != nil
            || pasteboard.string(forType: .string).flatMap(filePath(in:)) != nil
    }

    /// Принимает то, что бросили на шторку: файлы — ссылками, картинки и «обещанные» файлы
    /// (картинка из Safari, вложение из Почты) — сохраняет к себе. Обещанные приходят не сразу —
    /// о каждом сообщит `onReceived`.
    func accept(from pasteboard: NSPasteboard, onReceived: @escaping (URL) -> Void) -> DropResult {
        let urls = Self.fileURLs(in: pasteboard)
        if !urls.isEmpty {
            add(urls)
            return .added(urls.count)
        }
        if let receivers = pasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self]) as? [NSFilePromiseReceiver],
           !receivers.isEmpty {
            receivePromises(receivers, onReceived: onReceived)
            return .receiving
        }
        if let type = pasteboard.availableType(from: [.png, .tiff]), let data = pasteboard.data(forType: type) {
            return addImage(data, type: type) == nil ? .nothing : .added(1)
        }
        if let text = pasteboard.string(forType: .string), let url = Self.filePath(in: text) {
            add([url])
            return .added(1)
        }
        return .nothing
    }

    private let promiseQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.qualityOfService = .userInitiated
        return queue
    }()

    private func receivePromises(_ receivers: [NSFilePromiseReceiver], onReceived: @escaping (URL) -> Void) {
        // Своя папка на каждый бросок — чтобы одинаковые имена не перезаписали друг друга.
        let folder = directory.appendingPathComponent("Получено \(UUID().uuidString.prefix(8))", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for receiver in receivers {
            receiver.receivePromisedFiles(atDestination: folder, options: [:], operationQueue: promiseQueue) { url, error in
                guard error == nil else { return }
                DispatchQueue.main.async {
                    self.add([url], owned: true)
                    onReceived(url)
                }
            }
        }
    }

    /// Удаляет файл, который Шторка сохранила сама, и опустевшую папку «Получено…».
    private func deleteOwned(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
        let parent = url.deletingLastPathComponent()
        if parent.standardizedFileURL != directory.standardizedFileURL,
           (try? FileManager.default.contentsOfDirectory(atPath: parent.path))?.isEmpty == true {
            try? FileManager.default.removeItem(at: parent)
        }
    }

    // MARK: - Хранение

    private func save() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? JSONEncoder().encode(items).write(to: indexURL, options: .atomic)
    }

    private func load() {
        guard let data = try? Data(contentsOf: indexURL),
              let stored = try? JSONDecoder().decode([ShelfItem].self, from: data) else { return }
        items = stored
        refreshLocations()
    }
}
