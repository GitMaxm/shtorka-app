import AppKit

struct Toast: Equatable {
    let id = UUID()
    let text: String
    let symbol: String
    var color: NSColor? = nil
}

@MainActor
final class AppState: ObservableObject {
    @Published var isOpen = false
    @Published var tab: PanelTab = .shots
    @Published var editing = false
    /// «Очистить всё» нажато один раз — ждём подтверждения.
    @Published var confirmingClear = false
    /// Над шторкой держат файл — показываем «Отпусти — положу на полку».
    @Published var dropHover = false
    @Published var isDragging = false
    @Published var toast: Toast?

    @Published var keepAwake = false
    @Published var darkMode = false
    @Published var muted = false

    func showToast(_ text: String, symbol: String, color: NSColor? = nil, duration: TimeInterval = 1.6) {
        let toast = Toast(text: text, symbol: symbol, color: color)
        self.toast = toast
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
            if self.toast?.id == toast.id { self.toast = nil }
        }
    }
}

/// Всё, что умеют кнопки панели и миниатюры скриншотов.
@MainActor
final class PanelActions {
    private let state: AppState
    private let store: ShotStore
    private let clipboard: ClipboardStore
    private let shelf: ShelfStore
    private let ports: PortsStore

    var hidePanel: () -> Void = {}
    var flashPanel: (TimeInterval) -> Void = { _ in }
    var onDragChanged: (Bool) -> Void = { _ in }
    weak var menuDelegate: NSMenuDelegate?

    /// Куда последний раз ушёл скриншот в Корзине (пригодится для «вернуть»).
    private(set) var lastTrashed: URL?
    private(set) var lastTrashedAll: [URL] = []
    private var caffeinate: Process?
    private var sampler: NSColorSampler?
    private let scriptQueue = DispatchQueue(label: "shtorka.applescript")

    init(state: AppState, store: ShotStore, clipboard: ClipboardStore, shelf: ShelfStore, ports: PortsStore) {
        self.state = state
        self.store = store
        self.clipboard = clipboard
        self.shelf = shelf
        self.ports = ports
    }

    // MARK: - Скриншоты

    func copy(_ shot: Shot) {
        let item = NSPasteboardItem()
        if shot.isVideo {
            item.setString(shot.url.absoluteString, forType: .fileURL)
        } else if let png = pngData(for: shot.url) {
            item.setData(png, forType: .png)
        } else {
            item.setString(shot.url.absoluteString, forType: .fileURL)
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([item])
        state.showToast(shot.isVideo ? "Файл скопирован" : "Скопировано в буфер", symbol: "doc.on.doc.fill")
    }

    func open(_ shot: Shot) {
        hidePanel()
        NSWorkspace.shared.open(shot.url)
    }

    func reveal(_ shot: Shot) {
        hidePanel()
        NSWorkspace.shared.activateFileViewerSelecting([shot.url])
    }

    /// Крестик на скриншоте: файл уходит в Корзину, оттуда его можно вернуть.
    func trash(_ shot: Shot) {
        do {
            var resulting: NSURL?
            try FileManager.default.trashItem(at: shot.url, resultingItemURL: &resulting)
            lastTrashed = resulting as URL?
            store.remove(shot)
            state.showToast("Скриншот в Корзине", symbol: "trash.fill")
        } catch {
            state.showToast("Не получилось удалить", symbol: "exclamationmark.triangle.fill")
        }
        store.reload()
    }

    /// «Очистить всё» на вкладке скриншотов (после подтверждения): всё уходит в Корзину.
    func trashAllScreenshots() {
        let all = ShotStore.allScreenshots(in: store.folder)
        var trashed: [URL] = []
        for shot in all {
            var resulting: NSURL?
            if (try? FileManager.default.trashItem(at: shot.url, resultingItemURL: &resulting)) != nil, let resulting {
                trashed.append(resulting as URL)
            }
        }
        lastTrashedAll = trashed
        store.removeAllLocally()
        store.reload()
        state.showToast("Скриншотов в Корзине: \(trashed.count)", symbol: "trash.fill")
    }

    func menu(for shot: Shot) -> NSMenu {
        let menu = NSMenu()
        menu.delegate = menuDelegate
        menu.addItem(ClosureMenuItem("Открыть", symbol: "arrow.up.forward.app") { [weak self] in self?.open(shot) })
        menu.addItem(ClosureMenuItem("Скопировать", symbol: "doc.on.doc") { [weak self] in self?.copy(shot) })
        menu.addItem(ClosureMenuItem("Показать в Finder", symbol: "folder") { [weak self] in self?.reveal(shot) })
        menu.addItem(ClosureMenuItem("Положить на полку", symbol: "tray.and.arrow.down") { [weak self] in
            self?.putOnShelf([shot.url])
        })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Переместить в Корзину", symbol: "trash") { [weak self] in self?.trash(shot) })
        return menu
    }

    // MARK: - История буфера

    func recopy(_ item: ClipItem) {
        clipboard.copy(item)
        state.showToast("Снова в буфере", symbol: "doc.on.doc.fill")
    }

    func removeClip(_ item: ClipItem) { clipboard.remove(item) }

    func togglePin(_ item: ClipItem) {
        clipboard.togglePin(item)
        state.showToast(item.pinned ? "Откреплено" : "Закреплено", symbol: item.pinned ? "pin.slash.fill" : "pin.fill")
    }

    func clearClipboard() {
        let kept = clipboard.pinned.count
        clipboard.clear()
        state.showToast(kept > 0 ? "Очищено, закреплённые остались" : "История очищена", symbol: "trash.fill")
    }

    func menu(for item: ClipItem) -> NSMenu {
        let menu = NSMenu()
        menu.delegate = menuDelegate
        menu.addItem(ClosureMenuItem("Скопировать", symbol: "doc.on.doc") { [weak self] in self?.recopy(item) })
        menu.addItem(ClosureMenuItem(item.pinned ? "Открепить" : "Закрепить", symbol: item.pinned ? "pin.slash" : "pin") { [weak self] in
            self?.togglePin(item)
        })
        if item.canGoOnShelf {
            menu.addItem(ClosureMenuItem("Положить на полку", symbol: "tray.and.arrow.down") { [weak self] in
                self?.putOnShelf(item)
            })
        }
        menu.addItem(ClosureMenuItem("Удалить из истории", symbol: "xmark") { [weak self] in self?.removeClip(item) })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Очистить всю историю", symbol: "trash") { [weak self] in self?.clearClipboard() })
        return menu
    }

    func openFolder() {
        hidePanel()
        NSWorkspace.shared.open(store.folder)
    }

    private func pngData(for url: URL) -> Data? {
        if url.pathExtension.lowercased() == "png" { return try? Data(contentsOf: url) }
        guard let image = NSImage(contentsOf: url), let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    // MARK: - Полка для файлов

    /// Бросили что-то на шторку.
    func acceptDrop(_ pasteboard: NSPasteboard) -> Bool {
        state.tab = .shelf
        let result = shelf.accept(from: pasteboard) { [weak self] url in
            self?.state.showToast("На полке: \(url.lastPathComponent)", symbol: "tray.and.arrow.down.fill")
        }
        switch result {
        case .added:
            let first = shelf.items.first
            state.showToast(first?.owned == true ? "Картинка на полке" : "На полке: \(first?.title ?? "")",
                            symbol: "tray.and.arrow.down.fill")
            return true
        case .receiving:
            state.showToast("Получаю файл…", symbol: "arrow.down.circle")
            return true
        case .nothing:
            state.showToast("Сюда можно класть файлы и картинки", symbol: "exclamationmark.triangle.fill", duration: 2.5)
            return false
        }
    }

    func copy(_ item: ShelfItem) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects(item.urls.map { $0 as NSURL })
        state.showToast("Скопировано: \(item.title)", symbol: "doc.on.doc.fill")
    }

    func open(_ item: ShelfItem) {
        hidePanel()
        if item.urls.count == 1 {
            NSWorkspace.shared.open(item.urls[0])
        } else {
            NSWorkspace.shared.activateFileViewerSelecting(item.urls)
        }
    }

    func removeFromShelf(_ item: ShelfItem) { shelf.remove(item) }

    /// «Положить на полку» из буфера: файлы — ссылками, картинку — сохранив в файл.
    func putOnShelf(_ item: ClipItem) {
        switch item.kind {
        case .files(let urls):
            putOnShelf(urls)
        case .image(_, let data, let type):
            guard shelf.addImage(data, type: type) != nil else {
                state.showToast("Не получилось сохранить картинку", symbol: "exclamationmark.triangle.fill")
                return
            }
            state.showToast("Картинка на полке", symbol: "tray.and.arrow.down.fill")
        case .text(let text):
            if let url = ShelfStore.filePath(in: text) { putOnShelf([url]) }
        }
    }

    func putOnShelf(_ urls: [URL]) {
        shelf.add(urls)
        state.showToast("На полке: \(ShelfItem.title(for: urls))", symbol: "tray.and.arrow.down.fill")
    }

    func clearShelf() {
        shelf.clear()
        state.showToast("Полка пустая", symbol: "tray")
    }

    func menu(for item: ShelfItem) -> NSMenu {
        let menu = NSMenu()
        menu.delegate = menuDelegate
        menu.addItem(ClosureMenuItem("Открыть", symbol: "arrow.up.forward.app") { [weak self] in self?.open(item) })
        menu.addItem(ClosureMenuItem("Показать в Finder", symbol: "folder") { [weak self] in
            self?.hidePanel()
            NSWorkspace.shared.activateFileViewerSelecting(item.urls)
        })
        menu.addItem(ClosureMenuItem("Скопировать", symbol: "doc.on.doc") { [weak self] in self?.copy(item) })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Убрать с полки", symbol: "xmark") { [weak self] in self?.removeFromShelf(item) })
        return menu
    }

    // MARK: - Порты

    func open(_ server: DevServer) {
        hidePanel()
        NSWorkspace.shared.open(server.url)
    }

    func stop(_ server: DevServer) {
        Task {
            let stopped = await ports.stop(server)
            state.showToast(stopped ? "Остановлен :\(server.port)" : "Не получилось остановить :\(server.port)",
                            symbol: stopped ? "stop.circle.fill" : "exclamationmark.triangle.fill")
        }
    }

    func menu(for server: DevServer) -> NSMenu {
        let menu = NSMenu()
        menu.delegate = menuDelegate
        menu.addItem(ClosureMenuItem("Открыть в браузере", symbol: "safari") { [weak self] in self?.open(server) })
        menu.addItem(ClosureMenuItem("Скопировать адрес", symbol: "link") { [weak self] in
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(server.url.absoluteString, forType: .string)
            self?.state.showToast("Скопировано: \(server.url.absoluteString)", symbol: "link")
        })
        if let folder = server.folder {
            menu.addItem(ClosureMenuItem("Показать папку проекта", symbol: "folder") { [weak self] in
                self?.hidePanel()
                NSWorkspace.shared.open(folder)
            })
        }
        if server.canStop {
            menu.addItem(.separator())
            menu.addItem(ClosureMenuItem("Остановить", symbol: "stop.circle") { [weak self] in self?.stop(server) })
        }
        return menu
    }

    // MARK: - Быстрые кнопки

    func refreshToggles() {
        state.keepAwake = caffeinate?.isRunning == true
        state.darkMode = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua

        scriptQueue.async {
            let muted = Self.runAppleScript("output muted of (get volume settings)").result?.booleanValue ?? false
            DispatchQueue.main.async { self.state.muted = muted }
        }
    }

    func takeScreenshot() {
        hidePanel()
        // Даём шторке уехать, чтобы она не попала в кадр.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Screenshot.app"))
        }
    }

    func pickColor() {
        hidePanel()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            let sampler = NSColorSampler()
            self.sampler = sampler
            sampler.show { color in
                DispatchQueue.main.async {
                    self.sampler = nil
                    guard let c = color?.usingColorSpace(.sRGB) else { return }
                    let hex = String(format: "#%02X%02X%02X",
                                     Int((c.redComponent * 255).rounded()),
                                     Int((c.greenComponent * 255).rounded()),
                                     Int((c.blueComponent * 255).rounded()))
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(hex, forType: .string)
                    self.state.showToast("\(hex) скопирован", symbol: "eyedropper.full", color: c, duration: 2)
                    self.flashPanel(2)
                }
            }
        }
    }

    func toggleKeepAwake() {
        if let process = caffeinate, process.isRunning {
            stopKeepAwake()
            state.showToast("Мак снова может засыпать", symbol: "moon.zzz.fill")
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
        // -w: caffeinate сам завершится, если Шторка закроется или упадёт.
        process.arguments = ["-di", "-w", "\(ProcessInfo.processInfo.processIdentifier)"]
        do {
            try process.run()
            caffeinate = process
            state.keepAwake = true
            state.showToast("Мак не уснёт", symbol: "cup.and.saucer.fill")
        } catch {
            state.showToast("Не удалось запустить caffeinate", symbol: "exclamationmark.triangle.fill")
        }
    }

    func stopKeepAwake() {
        caffeinate?.terminate()
        caffeinate = nil
        state.keepAwake = false
    }

    func toggleDarkMode() {
        let target = !state.darkMode
        state.darkMode = target
        scriptQueue.async {
            let error = Self.runAppleScript(
                "tell application \"System Events\" to tell appearance preferences to set dark mode to \(target)"
            ).error
            DispatchQueue.main.async {
                if error != nil {
                    self.state.darkMode = !target
                    self.state.showToast("Разреши доступ: Настройки → Конфиденциальность → Автоматизация",
                                         symbol: "lock.fill", duration: 3.5)
                }
            }
        }
    }

    func toggleMute() {
        let target = !state.muted
        state.muted = target
        scriptQueue.async {
            _ = Self.runAppleScript("set volume output muted \(target)")
        }
        state.showToast(target ? "Звук выключен" : "Звук включён", symbol: target ? "speaker.slash.fill" : "speaker.wave.2.fill")
    }

    // MARK: - Папка для скриншотов

    func chooseScreenshotFolder() {
        hidePanel()
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Сохранять сюда"
        panel.message = "Выбери папку для новых скриншотов"
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Pictures")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        setScreenshotFolder(url)
    }

    /// moveOld: nil — спросить, true/false — не спрашивая (для самопроверки).
    func setScreenshotFolder(_ url: URL, moveOld: Bool? = nil, restartSystemUI: Bool = true) {
        let old = store.folder
        ShotStore.setScreenshotFolder(url, restartSystemUI: restartSystemUI)
        let newName = ShotStore.displayName(for: url)
        var message = "Скриншоты теперь в «\(newName)»"

        let oldShots = old.standardizedFileURL == url.standardizedFileURL ? [] : ShotStore.allScreenshots(in: old)
        if !oldShots.isEmpty {
            var shouldMove = moveOld
            if shouldMove == nil {
                let alert = NSAlert()
                alert.messageText = "Перенести старые скриншоты?"
                alert.informativeText = "В папке «\(ShotStore.displayName(for: old))» лежит скриншотов: \(oldShots.count). "
                    + "Перенести их в «\(newName)»?"
                alert.addButton(withTitle: "Перенести")
                alert.addButton(withTitle: "Оставить")
                shouldMove = alert.runModal() == .alertFirstButtonReturn
            }
            if shouldMove == true {
                let moved = ShotStore.move(oldShots, to: url)
                message = "Перенесено \(moved), новые — в «\(newName)»"
            }
        }
        store.reload()
        state.showToast(message, symbol: "folder.fill", duration: 3)
        flashPanel(3)
    }

    // MARK: - Помощники

    nonisolated private static func runAppleScript(_ source: String) -> (result: NSAppleEventDescriptor?, error: String?) {
        guard let script = NSAppleScript(source: source) else { return (nil, "bad script") }
        var errorInfo: NSDictionary?
        let result = script.executeAndReturnError(&errorInfo)
        if let errorInfo { return (nil, errorInfo[NSAppleScript.errorMessage] as? String ?? "error") }
        return (result, nil)
    }
}
