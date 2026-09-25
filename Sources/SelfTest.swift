#if SELFTEST
import AppKit
import SwiftUI

/// Самопроверка: поднимает настоящую панель, кликает по ней синтетическими событиями
/// (тот же путь, что у реальных кликов внутри окна) и проверяет результат.
/// Собирается только в тестовой сборке: ./build.sh --selftest
@MainActor
enum SelfTest {
    private static var passed = 0
    private static var failed = 0
    private static var outDir: URL!

    static func run(outDir path: String) -> Never {
        outDir = URL(fileURLWithPath: path)
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        Task { @MainActor in
            await scenario()
            print("\nИТОГО: \(passed) ✅   \(failed) ❌")
            exit(failed == 0 ? 0 : 1)
        }
        app.run()
        exit(1)
    }

    /// Отдельный процесс-«IDE»: окно на весь экран (maximized) или в полноэкранном режиме macOS (fullscreen).
    static func runFullscreenHelper(mode: String) -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let screen = NSScreen.main!
        let window = NSWindow(contentRect: screen.visibleFrame, styleMask: [.titled, .closable, .resizable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.title = "Шторка — тестовое окно"
        window.collectionBehavior = [.fullScreenPrimary]
        window.contentView = NSHostingView(rootView: Text("Тестовое окно Шторки — закроется само")
            .font(.largeTitle).frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.gray))
        window.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)
        if mode == "fullscreen" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { window.toggleFullScreen(nil) }
        }
        // По сигналу USR1 выходим на передний план — так тест возвращается на рабочий стол этого окна.
        signal(SIGUSR1, SIG_IGN)
        let wake = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
        wake.setEventHandler {
            app.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
        }
        wake.resume()
        withExtendedLifetime(wake) { app.run() }
        exit(0)
    }

    /// Первый клик по только что открытой (неактивной) шторке должен сразу нажимать кнопку.
    private static func firstClickScenario(controller: PanelController, state: AppState) async {
        section("Первый клик по неактивной шторке")
        let window = controller.panel
        for (tab, label) in [(PanelTab.clipboard, "Вкладка Буфер"), (.ports, "Вкладка Порты"), (.shots, "Вкладка Скриншоты")] {
            controller.hide()
            await sleep(0.5)
            controller.show(on: NSScreen.main, holdFor: 600)
            await sleep(0.9)
            check(!window.isKeyWindow, "шторка открылась неактивной (как в жизни)")
            guard let (_, point) = anchor(in: window, { $0 == label }) else { check(false, label, "не найдена"); continue }
            click(point, in: window)
            await sleep(0.4)
            check(state.tab == tab, "один клик по «\(label)» сразу переключает вкладку")
        }
    }

    /// Курсор-«рука» над карточкой — проверяем то, что реально показывает система.
    private static func cursorScenario(controller: PanelController, state: AppState) async {
        section("Курсор-рука")
        setPasteboard("Шторка: проверка курсора")
        await sleep(0.8)
        state.tab = .clipboard
        let window = controller.panel
        controller.show(on: NSScreen.main, holdFor: 600)
        await sleep(1.0)
        guard let card = cardViews(in: window).first else { check(false, "карточка на месте"); return }
        let original = CGEvent(source: nil)?.location ?? .zero
        let mainHeight = CGDisplayBounds(CGMainDisplayID()).height
        func warp(_ p: NSPoint) async {
            let screen = window.convertPoint(toScreen: p)
            CGWarpMouseCursorPosition(CGPoint(x: screen.x, y: mainHeight - screen.y))
            await sleep(0.3)
        }
        func isHand() -> Bool { NSCursor.currentSystem?.hotSpot == NSCursor.pointingHand.hotSpot }
        let f = windowFrame(card)
        await warp(NSPoint(x: f.midX, y: f.midY))
        check(isHand(), "над карточкой — рука (так показывает система)", "hotSpot=\(NSCursor.currentSystem?.hotSpot ?? .zero)")
        await warp(NSPoint(x: f.midX, y: f.minY - 9))   // промежуток между карточками и плитками
        check(!isHand(), "между карточками и плитками — обычная стрелка", "hotSpot=\(NSCursor.currentSystem?.hotSpot ?? .zero)")
        await warp(NSPoint(x: f.midX, y: f.midY))
        controller.hide()
        await sleep(0.5)
        check(!isHand(), "шторка закрылась — курсор снова обычный")
        CGWarpMouseCursorPosition(original)
    }

    /// Открывается ли шторка поверх окна «на весь экран» — обычного развёрнутого и полноэкранного.
    private static func fullscreenScenario(controller: PanelController, state: AppState) async {
        section("Поверх окна на весь экран")
        let window = controller.panel
        let original = CGEvent(source: nil)?.location ?? .zero
        let bounds = CGDisplayBounds(CGMainDisplayID())
        controller.followsCursor = true
        for mode in ["maximized", "fullscreen"] {
            controller.hide()
            let helper = Process()
            helper.executableURL = Bundle.main.executableURL
            helper.arguments = ["--fullscreen-helper", mode]
            try? helper.run()
            await sleep(mode == "fullscreen" ? 4.0 : 1.5)
            let covering = helperCoversScreen(pid: helper.processIdentifier)
            print("   \(mode): окно-заглушка \(covering ? "закрывает весь экран" : "НЕ закрывает весь экран")")
            CGWarpMouseCursorPosition(CGPoint(x: bounds.midX, y: bounds.midY))
            await sleep(0.4)
            // Как настоящая мышь: упираемся ровно в верхний край (y = 0), а не на пункт ниже.
            CGWarpMouseCursorPosition(CGPoint(x: bounds.midX, y: bounds.minY))
            await sleep(0.2)
            let p = NSEvent.mouseLocation
            let onScreen = NSScreen.screens.contains { NSMouseInRect(p, $0.frame, false) }
            print("   курсор у края: \(p), экран \(NSScreen.main!.frame), «на экране» по NSMouseInRect: \(onScreen)")
            await sleep(0.8)
            check(window.isVisible && state.isOpen && window.isOnActiveSpace,
                  mode == "fullscreen" ? "курсор у выемки над полноэкранным окном — шторка открылась"
                                       : "курсор у выемки над развёрнутым окном — шторка открылась",
                  "visible=\(window.isVisible) open=\(state.isOpen) onSpace=\(window.isOnActiveSpace) cursor=\(NSEvent.mouseLocation) screen=\(NSScreen.main!.frame)")
            // Порядок окон у верхнего края: что лежит поверх чего (первое — самое верхнее).
            let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
            let top = list.filter { info in
                guard let b = info[kCGWindowBounds as String] as? [String: CGFloat] else { return false }
                return (b["Y"] ?? 999) < 40 && (b["Width"] ?? 0) > 300
            }
            for (i, info) in top.prefix(8).enumerated() {
                let owner = info[kCGWindowOwnerName as String] as? String ?? "?"
                let layer = info[kCGWindowLayer as String] as? Int ?? -1
                let b = info[kCGWindowBounds as String] as? [String: CGFloat] ?? [:]
                let mine = (info[kCGWindowNumber as String] as? Int) == window.windowNumber
                print("     \(i). \(owner) layer=\(layer) y=\(Int(b["Y"] ?? 0)) h=\(Int(b["Height"] ?? 0)) w=\(Int(b["Width"] ?? 0))\(mine ? "   ← шторка" : "")")
            }
            CGWarpMouseCursorPosition(CGPoint(x: bounds.midX, y: bounds.midY))
            await sleep(0.8)
            helper.terminate()
            await sleep(mode == "fullscreen" ? 2.5 : 0.6)
        }
        CGWarpMouseCursorPosition(original)
    }

    private static func helperCoversScreen(pid: Int32) -> Bool {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        let screen = CGDisplayBounds(CGMainDisplayID())
        return list.contains { info in
            guard (info[kCGWindowOwnerPID as String] as? Int32) == pid,
                  let b = info[kCGWindowBounds as String] as? [String: CGFloat] else { return false }
            return (b["Width"] ?? 0) >= screen.width - 1 && (b["Height"] ?? 0) >= screen.height - 40
        }
    }

    // MARK: - Сценарий

    private static func scenario() async {
        let fm = FileManager.default
        let sandbox = outDir.appendingPathComponent("sandbox")
        try? fm.removeItem(at: sandbox)
        let shotsDir = sandbox.appendingPathComponent("shots")
        let newDir = sandbox.appendingPathComponent("Новая папка")
        try? fm.createDirectory(at: shotsDir, withIntermediateDirectories: true)
        try? fm.createDirectory(at: newDir, withIntermediateDirectories: true)

        let names = (1...3).map { "Снимок экрана 2026-09-23 в 10.00.0\($0) shtorka-test.png" }
        for (i, name) in names.enumerated() {
            let url = shotsDir.appendingPathComponent(name)
            try? png([NSColor.systemPink, .systemTeal, .systemOrange][i]).write(to: url)
            try? fm.setAttributes([.creationDate: Date().addingTimeInterval(Double(i - 10) * 60)], ofItemAtPath: url.path)
        }
        try? "не скриншот".write(to: shotsDir.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        try? png(.gray).write(to: shotsDir.appendingPathComponent("photo.png"))

        // Что вернуть на место после теста
        let savedPasteboard = savePasteboard()
        CFPreferencesAppSynchronize("com.apple.screencapture" as CFString)
        let originalLocation = CFPreferencesCopyAppValue("location" as CFString, "com.apple.screencapture" as CFString) as? String
        let originalSoundMuted = soundMuted()
        let originalCursor = CGEvent(source: nil)?.location ?? .zero

        let suite = "local.shtorka.selftest"
        UserDefaults().removePersistentDomain(forName: suite)
        let state = AppState()
        let store = ShotStore()
        let pinnedDir = sandbox.appendingPathComponent("pinned")
        let shelfDir = sandbox.appendingPathComponent("shelf-store")
        let clipboard = ClipboardStore(directory: pinnedDir)
        let tools = ToolSettings(defaults: UserDefaults(suiteName: suite)!)
        let shelf = ShelfStore(directory: shelfDir)
        let ports = PortsStore()
        let actions = PanelActions(state: state, store: store, clipboard: clipboard, shelf: shelf, ports: ports)
        let controller = PanelController(state: state, store: store, clipboard: clipboard, tools: tools,
                                         shelf: shelf, ports: ports, actions: actions)
        actions.hidePanel = { controller.hide() }
        actions.flashPanel = { controller.show(holdFor: $0) }
        controller.followsCursor = false
        store.folderOverride = shotsDir
        store.reload()
        clipboard.start()
        await sleep(0.6)
        if ProcessInfo.processInfo.environment["FIRSTCLICK_ONLY"] != nil {
            await firstClickScenario(controller: controller, state: state)
            restorePasteboard(savedPasteboard)
            try? fm.removeItem(at: sandbox)
            return
        }
        if ProcessInfo.processInfo.environment["CURSOR_ONLY"] != nil {
            await cursorScenario(controller: controller, state: state)
            restorePasteboard(savedPasteboard)
            try? fm.removeItem(at: sandbox)
            return
        }
        if ProcessInfo.processInfo.environment["FULLSCREEN_ONLY"] != nil {
            await fullscreenScenario(controller: controller, state: state)
            restorePasteboard(savedPasteboard)
            try? fm.removeItem(at: sandbox)
            return
        }

        // ---------------------------------------------------------------
        section("Скриншоты")
        check(store.shots.count == 3, "находит 3 скриншота и пропускает обычные файлы", "нашлось \(store.shots.count)")
        check(store.shots.first?.url.lastPathComponent == names[2], "новые идут первыми")

        section("Панель")
        let window = controller.panel
        controller.show(on: NSScreen.main, holdFor: 600)
        await sleep(0.8)
        let screen = NSScreen.main!
        check(window.isVisible && state.isOpen, "панель открывается",
              "visible=\(window.isVisible) open=\(state.isOpen) cursor=\(NSEvent.mouseLocation) frame=\(window.frame)")
        check(abs(window.frame.maxY - screen.frame.maxY) < 1 && abs(window.frame.midX - screen.frame.midX) < 1,
              "прижата к верхнему краю по центру")
        snapshot(window, "1-скриншоты")

        var cards = cardViews(in: window)
        check(cards.count == 3, "на полке 3 карточки", "\(cards.count)")
        let newest = store.shots[0]
        if !cards.isEmpty {
            click(center(of: cards[0]), in: window)
            await sleep(0.3)
            check(NSPasteboard.general.data(forType: .png) == (try? Data(contentsOf: newest.url)),
                  "клик по карточке копирует картинку в буфер")
            check(state.toast?.text == "Скопировано в буфер", "появляется «Скопировано в буфер»", state.toast?.text ?? "нет")

            await sleep(0.5)
            cards = cardViews(in: window)
            click(closePoint(of: cards[0]), in: window)
            await sleep(0.8)
            check(!fm.fileExists(atPath: newest.url.path), "крестик отправляет скриншот в Корзину")
            check(store.shots.count == 2, "карточка пропадает с полки", "осталось \(store.shots.count)")
            check(state.toast?.text == "Скриншот в Корзине", "появляется «Скриншот в Корзине»", state.toast?.text ?? "нет")
            removeFromTrash(actions.lastTrashed)

            cards = cardViews(in: window)
            let clickedMiddle = store.shots.first
            click(NSPoint(x: windowFrame(cards[0]).maxX - 40, y: windowFrame(cards[0]).midY), in: window)
            await sleep(0.3)
            check(store.shots.first == clickedMiddle && fm.fileExists(atPath: clickedMiddle!.url.path),
                  "клик рядом с крестиком не удаляет")
        }

        // ---------------------------------------------------------------
        section("Буфер")
        await sleep(0.6)
        if case .image = clipboard.items.first?.kind {
            check(true, "скопированный скриншот попал в историю")
        } else {
            check(false, "скопированный скриншот попал в историю")
        }
        setPasteboard("Шторка: тестовый текст")
        await sleep(0.7)
        check(clipboard.items.first?.text == "Шторка: тестовый текст", "скопированный текст попадает в историю")
        setPasteboard("#FF5A36")
        await sleep(0.7)
        check(clipboard.items.first?.color != nil, "HEX-код распознаётся как цвет")
        let countBefore = clipboard.items.count
        setPasteboard("Шторка: тестовый текст")
        await sleep(0.7)
        check(clipboard.items.count == countBefore && clipboard.items.first?.text == "Шторка: тестовый текст",
              "повторное копирование поднимает запись наверх без дубля")
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString("secret-password-123", forType: .string)
        pb.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        await sleep(0.7)
        check(!clipboard.items.contains { $0.text == "secret-password-123" }, "пароли из менеджеров паролей не сохраняются")

        await tap(window, { $0 == "Вкладка Буфер" }, "клик по вкладке «Буфер» переключает её") { state.tab == .clipboard }
        await sleep(1.0)  // ждём, пока уедут карточки скриншотов
        snapshot(window, "2-буфер")

        cards = cardViews(in: window)
        // Не трогаем карточки, если вкладка не переключилась — иначе крестик попадёт по скриншотам.
        if state.tab == .clipboard, cards.count >= 2, clipboard.items.count >= 2 {
            let second = clipboard.items[1]
            click(center(of: cards[1]), in: window)
            await sleep(0.8)
            check(clipboard.items.first?.signature == second.signature, "клик по записи снова копирует её и поднимает наверх")
            check(state.toast?.text == "Снова в буфере", "появляется «Снова в буфере»", state.toast?.text ?? "нет")

            let n = clipboard.items.count
            await sleep(0.5)
            cards = cardViews(in: window)
            click(closePoint(of: cards[0]), in: window)
            await sleep(0.5)
            check(clipboard.items.count == n - 1, "крестик убирает одну запись", "\(n) → \(clipboard.items.count)")
        } else {
            check(false, "карточки буфера на месте", "карточек \(cards.count), записей \(clipboard.items.count)")
        }
        section("Закрепление")
        await sleep(0.4)
        cards = cardViews(in: window)
        if state.tab == .clipboard, cards.count >= 2, clipboard.items.count >= 2 {
            let target = clipboard.items[1]
            click(pinPoint(of: cards[1]), in: window)
            await sleep(0.5)
            check(clipboard.items.first?.id == target.id && clipboard.items.first?.pinned == true,
                  "значок в углу закрепляет запись и ставит её первой")
            check(fm.fileExists(atPath: pinnedDir.appendingPathComponent("pinned.json").path), "закреплённое сохраняется на диск")
            setPasteboard("Шторка: свежий текст")
            await sleep(0.7)
            check(clipboard.items.first?.id == target.id, "новые копии встают после закреплённых")
            let reloaded = ClipboardStore(directory: pinnedDir)
            check(reloaded.items.count == 1 && reloaded.items.first?.pinned == true && reloaded.items.first?.signature == target.signature,
                  "после перезапуска закреплённое на месте")
        } else {
            check(false, "карточки для закрепления на месте")
        }

        await tap(window, { $0 == "Очистить всё" }, "«Очистить всё» в буфере сначала спрашивает") { state.confirmingClear }
        check(!clipboard.items.isEmpty, "до подтверждения история на месте")
        await tap(window, { $0.hasPrefix("Удалить:") }, "подтверждение очищает историю, закреплённое остаётся") {
            clipboard.items.count == 1 && clipboard.items.first?.pinned == true
        }
        cards = cardViews(in: window)
        if let card = cards.first {
            click(pinPoint(of: card), in: window)
            await sleep(0.4)
            check(clipboard.pinned.isEmpty, "повторный клик по значку открепляет")
            check(ClipboardStore(directory: pinnedDir).items.isEmpty, "и на диске его больше нет")
        }

        // ---------------------------------------------------------------
        section("Полка для файлов")
        let docs = sandbox.appendingPathComponent("docs")
        try? fm.createDirectory(at: docs, withIntermediateDirectories: true)
        let contract = docs.appendingPathComponent("Договор.txt")
        try? "текст договора".write(to: contract, atomically: true, encoding: .utf8)
        await tap(window, { $0 == "Вкладка Полка" }, "вкладка «Полка» открывается") { state.tab == .shelf }
        // То, что приходит при перетаскивании, — отдельный «буфер» перетаскивания. Кладём туда данные так,
        // как это делают разные программы, и отдаём шторке — ровно то, что она получает при броске.
        let dragBoard = NSPasteboard(name: NSPasteboard.Name("local.shtorka.selftest.drag"))
        func drop(_ fill: (NSPasteboard) -> Void) -> Bool {
            dragBoard.clearContents()
            fill(dragBoard)
            return actions.acceptDrop(dragBoard)
        }
        check(drop { $0.writeObjects([contract as NSURL]) }
              && shelf.items.first?.urls.first?.path == contract.standardizedFileURL.path && shelf.items.first?.owned == false,
              "файл из Finder ложится на полку ссылкой")

        let styles = docs.appendingPathComponent("styles.css")
        let script = docs.appendingPathComponent("app.js")
        try? "body { margin: 0 }".write(to: styles, atomically: true, encoding: .utf8)
        try? "console.log('hi')".write(to: script, atomically: true, encoding: .utf8)
        check(drop { $0.writeObjects([styles as NSURL, script as NSURL]) }
              && shelf.items.first?.urls.map(\.lastPathComponent) == ["styles.css", "app.js"],
              "CSS и JS из Finder ложатся на полку стопкой")
        shelf.clear()
        check(drop { $0.setPropertyList([styles.path, script.path], forType: ShelfStore.legacyFilenames) }
              && shelf.items.first?.urls.map(\.lastPathComponent) == ["styles.css", "app.js"],
              "CSS и JS из WebStorm (старый формат списка файлов) тоже ложатся")
        shelf.clear()
        check(drop { $0.setString(script.path, forType: .string) } && shelf.items.first?.urls.first?.lastPathComponent == "app.js",
              "путь к файлу текстом (Copy Path в IDE) — кладётся сам файл")
        check(!drop { $0.setString("просто текст", forType: .string) } && shelf.items.count == 1,
              "обычный текст на полку не кладётся")
        check(!ShelfStore.canAccept({ dragBoard.clearContents(); dragBoard.setString("abc", forType: .string); return dragBoard }()),
              "…и шторка даже не подсвечивается под ним")
        shelf.clear()
        _ = drop { $0.writeObjects([contract as NSURL]) }
        check(drop { $0.setData(png(.systemPurple), forType: .png) } && shelf.items.first?.owned == true,
              "картинка из браузера сохраняется копией")
        let ownedCopy = shelf.items.first?.urls.first
        check(ownedCopy.map { fm.fileExists(atPath: $0.path) } == true, "копия лежит в папке Шторки")
        await sleep(0.6)
        snapshot(window, "4-полка")
        cards = cardViews(in: window)
        check(cards.count == 2, "на полке 2 карточки", "\(cards.count)")
        if cards.count == 2 {
            // Длинное уведомление поверх карточек не должно мешать кликам.
            state.showToast(String(repeating: "Очень длинное уведомление ", count: 3), symbol: "info.circle", duration: 3)
            await sleep(0.4)
            click(center(of: cards[1]), in: window)
            await sleep(0.3)
            let copied = NSPasteboard.general.readObjects(forClasses: [NSURL.self]) as? [URL]
            check(copied?.first?.standardizedFileURL.path == contract.standardizedFileURL.path, "клик копирует файл (можно вставить ⌘V)")
            check(ShelfStore(directory: shelfDir).items.count == 2, "полка переживает перезапуск")
            await sleep(0.4)
            cards = cardViews(in: window)
            click(closePoint(of: cards[0]), in: window)
            await sleep(0.4)
            check(shelf.items.count == 1 && ownedCopy.map { !fm.fileExists(atPath: $0.path) } == true,
                  "крестик убирает с полки и стирает сохранённую копию")
            cards = cardViews(in: window)
            click(closePoint(of: cards[0]), in: window)
            await sleep(0.4)
            check(shelf.items.isEmpty && fm.fileExists(atPath: contract.path), "а обычный файл остаётся на своём месте")
        }
        shelf.add([contract])
        await sleep(0.3)
        await tap(window, { $0 == "Очистить всё" }, "«Очистить всё» на полке спрашивает") { state.confirmingClear }
        await tap(window, { $0.hasPrefix("Убрать:") }, "и убирает всё с полки") { shelf.items.isEmpty }
        check(fm.fileExists(atPath: contract.path), "файлы при этом не удаляются")

        // ---------------------------------------------------------------
        section("Порты")
        let project = sandbox.appendingPathComponent("my-landing")
        try? fm.createDirectory(at: project, withIntermediateDirectories: true)
        let port = Int.random(in: 47000...47999)
        let server = Process()
        server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        server.arguments = ["-m", "http.server", "\(port)", "--bind", "127.0.0.1"]
        server.currentDirectoryURL = project
        server.standardOutput = FileHandle.nullDevice
        server.standardError = FileHandle.nullDevice
        try? server.run()
        await tap(window, { $0 == "Вкладка Порты" }, "вкладка «Порты» открывается") { state.tab == .ports }
        var found: DevServer?
        for _ in 0..<40 where found == nil {
            await sleep(0.2)
            found = ports.servers.first { $0.port == port }
        }
        check(found != nil, "запущенный сервер появляется в списке", "порт \(port)")
        check(found?.kind == "Python http.server" && found?.subtitle == "my-landing",
              "видно, что это за сервер и из какой он папки", "\(found?.kind ?? "-") / \(found?.subtitle ?? "-")")
        check(!ports.servers.contains { $0.command == "ControlCenter" || $0.command == "rapportd" },
              "системные службы в список не попадают")
        check(ports.servers.filter { $0.kind == "Docker" }.allSatisfy { !$0.canStop },
              "контейнеры Docker остановить отсюда нельзя (чтобы не уронить весь Docker)")
        await sleep(0.5)
        snapshot(window, "5-порты")
        if let found, let card = cardViews(in: window).first(where: { _ in true }),
           let index = ports.servers.firstIndex(of: found) {
            let target = cardViews(in: window)[index]
            _ = card
            click(closePoint(of: target), in: window)
            for _ in 0..<30 where server.isRunning { await sleep(0.1) }
            check(!server.isRunning, "крестик останавливает сервер")
            for _ in 0..<20 where ports.servers.contains(where: { $0.port == port }) { await sleep(0.1) }
            check(!ports.servers.contains { $0.port == port }, "и он пропадает из списка",
                  ports.servers.filter { $0.port == port }.map { "pid \($0.pid) alive=\(kill($0.pid, 0) == 0) found=\(found.pid)" }.joined(separator: ", ")
                  + " | lsof: " + PortsStore.scan().filter { $0.port == port }.map { "\($0.pid)" }.joined(separator: ","))
        }
        if server.isRunning { server.terminate() }

        // ---------------------------------------------------------------
        section("Полка: переименование, перенос, удаление")
        let moves = sandbox.appendingPathComponent("moves")
        let other = sandbox.appendingPathComponent("другая папка")
        try? fm.createDirectory(at: moves, withIntermediateDirectories: true)
        try? fm.createDirectory(at: other, withIntermediateDirectories: true)
        let report = moves.appendingPathComponent("Отчёт.txt")
        try? "отчёт".write(to: report, atomically: true, encoding: .utf8)
        shelf.clear()
        shelf.add([report])
        let renamed = moves.appendingPathComponent("Отчёт (финал).txt")
        try? fm.moveItem(at: report, to: renamed)
        shelf.refreshLocations()
        check(shelf.items.first?.urls.first?.path == renamed.path, "переименованный файл полка находит",
              shelf.items.first?.urls.first?.lastPathComponent ?? "нет")
        let relocated = other.appendingPathComponent("Отчёт (финал).txt")
        try? fm.moveItem(at: renamed, to: relocated)
        shelf.refreshLocations()
        check(shelf.items.first?.urls.first?.path == relocated.path, "перенесённый в другую папку — тоже")
        let relocatedAgain = moves.appendingPathComponent("Отчёт v2.txt")
        try? fm.moveItem(at: relocated, to: relocatedAgain)
        check(ShelfStore(directory: shelfDir).items.first?.urls.first?.path == relocatedAgain.path,
              "и после перезапуска Шторки находит его на новом месте")
        var trashedURL: NSURL?
        try? fm.trashItem(at: relocatedAgain, resultingItemURL: &trashedURL)
        shelf.refreshLocations()
        check(shelf.items.isEmpty, "файл отправили в Корзину — с полки он пропал")
        removeFromTrash(trashedURL as URL?)
        let scratch = moves.appendingPathComponent("Черновик.txt")
        try? "черновик".write(to: scratch, atomically: true, encoding: .utf8)
        shelf.add([scratch])
        try? fm.removeItem(at: scratch)
        shelf.refreshLocations()
        check(shelf.items.isEmpty, "удалённый файл с полки пропадает")

        // ---------------------------------------------------------------
        section("Файлы в буфере")
        await tap(window, { $0 == "Вкладка Буфер" }, "вкладка «Буфер»") { state.tab == .clipboard }
        let brief = moves.appendingPathComponent("Бриф.pdf")
        try? png(.systemBlue).write(to: brief)   // содержимое неважно — важен сам файл
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([brief as NSURL])
        await sleep(0.8)
        check(clipboard.items.first?.fileURLs?.first?.path == brief.path, "скопированный файл появляется в буфере")
        await sleep(0.6)
        snapshot(window, "6-буфер-файлы")
        if let item = clipboard.items.first { clipboard.togglePin(item) }
        let briefMoved = other.appendingPathComponent("Бриф финал.pdf")
        try? fm.moveItem(at: brief, to: briefMoved)
        clipboard.refreshFiles()
        check(clipboard.items.first?.fileURLs?.first?.path == briefMoved.path,
              "закреплённый файл находится после переименования и переноса")
        let briefAgain = moves.appendingPathComponent("Бриф-3.pdf")
        try? fm.moveItem(at: briefMoved, to: briefAgain)
        check(ClipboardStore(directory: pinnedDir).items.first?.fileURLs?.first?.path == briefAgain.path,
              "и после перезапуска Шторки")
        clipboard.refreshFiles()
        var trashedBrief: NSURL?
        try? fm.trashItem(at: briefAgain, resultingItemURL: &trashedBrief)
        clipboard.refreshFiles()
        check(!clipboard.items.contains { $0.fileURLs?.contains { $0.lastPathComponent.hasPrefix("Бриф") } == true },
              "файл удалили — запись пропала из буфера")
        check(ClipboardStore(directory: pinnedDir).items.isEmpty, "и из сохранённых закреплённых тоже")
        removeFromTrash(trashedBrief as URL?)

        section("Копирование из WebStorm")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setPropertyList([styles.path], forType: ShelfStore.legacyFilenames)
        NSPasteboard.general.setString("styles.css", forType: .string)
        await sleep(0.8)
        check(clipboard.items.first?.fileURLs?.first?.lastPathComponent == "styles.css",
              "⌘C по файлу в WebStorm попадает в буфер файлом, а не текстом")
        setPasteboard(script.path)
        await sleep(0.8)
        check(clipboard.items.first?.canGoOnShelf == true, "у скопированного пути к файлу есть кнопка «На полку»")
        check(ClipItem(kind: .text("/нет/такого/файла.js"), signature: "x").canGoOnShelf == false,
              "а у пути к несуществующему файлу — нет")

        section("Положить на полку")
        shelf.clear()
        let deck = moves.appendingPathComponent("Презентация.key")
        try? "презентация".write(to: deck, atomically: true, encoding: .utf8)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([deck as NSURL])
        await sleep(0.9)
        // Переоткрываем шторку: после кликов она стала активным окном, а проверить нужно как до первого клика.
        controller.hide()
        await sleep(0.5)
        controller.show(on: NSScreen.main, holdFor: 600)
        await sleep(0.8)
        cards = cardViews(in: window)
        if let first = cards.first, clipboard.items.first?.fileURLs?.first?.path == deck.path {
            // Наведение — настоящим курсором, как рукой: шторка при этом не активное окно (как в жизни до первого клика).
            let f = windowFrame(first)
            let mainHeight = CGDisplayBounds(CGMainDisplayID()).height
            func hover(_ p: NSPoint) async {
                let screen = window.convertPoint(toScreen: p)
                CGWarpMouseCursorPosition(CGPoint(x: screen.x, y: mainHeight - screen.y))
                await sleep(0.15)
            }
            check(!window.isKeyWindow, "шторка не активное окно — проверяем в худшем случае")
            await hover(NSPoint(x: f.midX, y: f.maxY + 20))
            check(!first.isHovered, "над карточкой — не подсвечена")
            await hover(NSPoint(x: f.midX, y: f.maxY - 10))
            check(first.isHovered, "верх карточки — подсвечена")
            await hover(NSPoint(x: f.midX, y: f.midY))
            check(first.isHovered, "середина — подсвечена")
            await hover(NSPoint(x: f.midX, y: f.minY + 8))
            check(first.isHovered && !first.overAccessory, "низ карточки (подпись) — подсвечена")
            await hover(NSPoint(x: f.maxX - 10, y: f.minY + 10))
            check(first.isHovered && first.overAccessory, "правый нижний угол — подсвечена кнопка «На полку»")
            await hover(NSPoint(x: f.maxX - 10, y: f.maxY - 10))
            check(first.overClose && !first.overAccessory, "правый верхний — крестик")
            await hover(NSPoint(x: f.minX + 10, y: f.maxY - 10))
            check(first.overPin && !first.overClose, "левый верхний — булавка")
            await hover(NSPoint(x: f.midX, y: f.minY - 20))
            check(!first.isHovered && !first.overPin, "ушли вниз — подсветка снята")
            click(shelfPoint(of: first), in: window)
            await sleep(0.4)
            check(shelf.items.first?.urls.first?.path == deck.path && shelf.items.first?.owned == false,
                  "кнопка в углу карточки кладёт файл на полку (ссылкой)")
            check(state.toast?.text == "На полке: Презентация.key", "появляется «На полке: …»", state.toast?.text ?? "нет")
        } else {
            check(false, "карточка файла в буфере на месте")
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setData(png(.systemGreen), forType: .png)
        await sleep(0.9)
        await sleep(0.4)
        cards = cardViews(in: window)
        if let first = cards.first, case .image = clipboard.items.first?.kind {
            click(shelfPoint(of: first), in: window)
            await sleep(0.4)
            let saved = shelf.items.first
            check(saved?.owned == true && saved.map { fm.fileExists(atPath: $0.urls[0].path) } == true,
                  "картинку из буфера сохраняет файлом и кладёт на полку", shelf.items.map(\.title).joined(separator: ", "))
        } else {
            check(false, "карточка картинки в буфере на месте")
        }
        check(ClipItem(kind: .text("текст"), signature: "t").canGoOnShelf == false, "у текста кнопки «На полку» нет")

        section("Карточки после новой записи")
        // Как в жизни: шторка закрыта, копируешь новое, открываешь и жмёшь на первую карточку.
        controller.hide()
        await sleep(0.5)
        setPasteboard("Шторка: самая свежая запись")
        await sleep(0.8)
        controller.show(on: NSScreen.main, holdFor: 600)
        await sleep(0.9)
        cards = cardViews(in: window)
        if let first = cards.first, let newest = clipboard.items.first, newest.text == "Шторка: самая свежая запись" {
            setPasteboard("что-то другое")
            await sleep(0.7)
            await sleep(0.5)
            cards = cardViews(in: window)
            let target = clipboard.items[0]
            click(center(of: cards[0]), in: window)
            await sleep(0.8)
            check(NSPasteboard.general.string(forType: .string) == target.text,
                  "клик по первой карточке копирует именно её, а не соседнюю", NSPasteboard.general.string(forType: .string) ?? "-")
            _ = first
            let before = clipboard.items.map(\.id)
            await sleep(0.5)
            cards = cardViews(in: window)
            let expectedRemoved = clipboard.items[0].id
            click(closePoint(of: cards[0]), in: window)
            await sleep(0.5)
            check(!clipboard.items.contains { $0.id == expectedRemoved } && clipboard.items.count == before.count - 1,
                  "крестик на первой карточке удаляет именно её")
        } else {
            check(false, "новая запись появилась первой")
        }
        shelf.clear()
        await tap(window, { $0 == "Вкладка Скриншоты" }, "назад на скриншоты") { state.tab == .shots }

        // ---------------------------------------------------------------
        section("Настройка панели")
        await tap(window, { $0 == "Настроить панель" }, "кнопка настроек открывает настройку") { state.editing }
        await sleep(0.4)
        snapshot(window, "3-настройка")
        await tap(window, { $0 == "Инструмент Пипетка" }, "клик по «Пипетка» скрывает её") { !tools.isVisible(.pipette) }
        await sleep(0.4)
        check(TestAnchors.frames["Пипетка"] == nil, "плитка «Пипетка» пропала из ряда")
        check(UserDefaults(suiteName: suite)?.stringArray(forKey: "tools.hidden") == ["pipette"], "настройка сохраняется")
        let reloaded = ToolSettings(defaults: UserDefaults(suiteName: suite)!)
        check(!reloaded.isVisible(.pipette), "после перезапуска Пипетка остаётся скрытой")
        await tap(window, { $0 == "Инструмент Пипетка" }, "повторный клик возвращает «Пипетку»") { tools.isVisible(.pipette) }
        tools.move(.sound, to: .screenshot)
        check(tools.visible.first == .sound, "перестановка: «Без звука» встаёт первым")
        await sleep(0.4)
        let tileTitles = Set(Tool.allCases.map(\.title) + ["Тёмная", "Светлая"])
        let firstTile = TestAnchors.frames.filter { tileTitles.contains($0.key) }.min { $0.value.minX < $1.value.minX }
        check(firstTile?.key == "Без звука", "и в ряду плиток он тоже первый", firstTile?.key ?? "нет")
        tools.reset()
        await tap(window, { $0 == "Готово" }, "«Готово» закрывает настройку") { !state.editing }

        // ---------------------------------------------------------------
        section("Не спать")
        let pid = ProcessInfo.processInfo.processIdentifier
        await tap(window, { $0 == "Не спать" }, "«Не спать» запускает caffeinate") { caffeinateRunning(for: pid) }
        await tap(window, { $0 == "Не спать" }, "повторный клик его останавливает") { !caffeinateRunning(for: pid) }

        section("Звук")
        let soundBefore = soundMuted()
        await tap(window, { $0 == "Без звука" }, "«Без звука» переключает звук") { soundMuted() == !soundBefore }
        await tap(window, { $0 == "Без звука" }, "повторный клик возвращает звук") { soundMuted() == soundBefore }

        // ---------------------------------------------------------------
        section("Папка для скриншотов")
        actions.setScreenshotFolder(newDir, moveOld: true, restartSystemUI: false)
        CFPreferencesAppSynchronize("com.apple.screencapture" as CFString)
        let written = CFPreferencesCopyAppValue("location" as CFString, "com.apple.screencapture" as CFString) as? String
        check(written == newDir.path, "macOS получает новую папку для скриншотов", written ?? "нет")
        let movedCount = ShotStore.allScreenshots(in: newDir).count
        check(movedCount == 2, "старые скриншоты переносятся", "перенесено \(movedCount)")
        check(ShotStore.allScreenshots(in: shotsDir).isEmpty, "в старой папке их больше нет")
        check(fm.fileExists(atPath: shotsDir.appendingPathComponent("notes.txt").path), "обычные файлы остались на месте")
        store.folderOverride = nil
        store.reload()
        await sleep(0.6)
        check(store.folder.standardizedFileURL.path == newDir.standardizedFileURL.path && store.shots.count == 2,
              "полка смотрит в новую папку", "\(store.folder.path), \(store.shots.count)")
        check(ShotStore.displayName(for: newDir).hasSuffix("Новая папка"), "название папки показывается по-человечески",
              ShotStore.displayName(for: newDir))

        // ---------------------------------------------------------------
        section("Очистить все скриншоты")
        // Только в тестовой папке — настоящие скриншоты не трогаем ни при каких условиях.
        if store.folder.standardizedFileURL.path.hasPrefix(sandbox.standardizedFileURL.path) {
            try? "заметка".write(to: newDir.appendingPathComponent("заметка.txt"), atomically: true, encoding: .utf8)
            try? png(.gray).write(to: newDir.appendingPathComponent("фото из отпуска.png"))
            await tap(window, { $0 == "Вкладка Скриншоты" }, "возвращаемся на вкладку скриншотов") { state.tab == .shots }
            await sleep(0.8)
            await tap(window, { $0 == "Очистить всё" }, "«Очистить всё» сначала спрашивает") { state.confirmingClear }
            check(ShotStore.allScreenshots(in: newDir).count == 2, "до подтверждения ничего не удалено")
            await tap(window, { $0 == "Отмена" }, "«Отмена» закрывает вопрос") { !state.confirmingClear }
            check(ShotStore.allScreenshots(in: newDir).count == 2, "после отмены всё на месте")
            await tap(window, { $0 == "Очистить всё" }, "снова «Очистить всё»") { state.confirmingClear }
            await tap(window, { $0.hasPrefix("В Корзину") }, "подтверждение отправляет все скриншоты в Корзину") {
                ShotStore.allScreenshots(in: newDir).isEmpty
            }
            await sleep(0.5)
            check(store.shots.isEmpty && store.totalCount == 0, "полка пустая")
            check(fm.fileExists(atPath: newDir.appendingPathComponent("заметка.txt").path)
                  && fm.fileExists(atPath: newDir.appendingPathComponent("фото из отпуска.png").path),
                  "обычные файлы и картинки в папке не трогаются")
            actions.lastTrashedAll.forEach { removeFromTrash($0) }
        } else {
            check(false, "очистка проверяется только в тестовой папке", store.folder.path)
        }

        // ---------------------------------------------------------------
        section("Показ по наведению (настоящий курсор)")
        controller.followsCursor = true
        controller.hide()
        await sleep(0.6)
        check(!window.isVisible, "панель прячется")
        let bounds = CGDisplayBounds(CGMainDisplayID())
        CGWarpMouseCursorPosition(CGPoint(x: bounds.midX, y: bounds.minY + 1))
        await sleep(0.8)
        check(window.isVisible && state.isOpen, "курсор у выемки открывает панель")
        CGWarpMouseCursorPosition(CGPoint(x: bounds.midX, y: bounds.midY + 150))
        await sleep(1.0)
        check(!window.isVisible, "курсор ушёл — панель спряталась")
        CGWarpMouseCursorPosition(CGPoint(x: bounds.minX + 40, y: bounds.minY + 1))
        await sleep(0.8)
        check(!window.isVisible, "в левом углу у строки меню панель не открывается")

        // ---------------------------------------------------------------
        section("Уборка")
        CGWarpMouseCursorPosition(originalCursor)
        actions.stopKeepAwake()
        if soundMuted() != originalSoundMuted { _ = appleScript("set volume output muted \(originalSoundMuted)") }
        if let originalLocation {
            ShotStore.setScreenshotFolder(URL(fileURLWithPath: originalLocation), restartSystemUI: false)
        } else {
            run("/usr/bin/defaults", ["delete", "com.apple.screencapture", "location"])
        }
        CFPreferencesAppSynchronize("com.apple.screencapture" as CFString)
        let restored = CFPreferencesCopyAppValue("location" as CFString, "com.apple.screencapture" as CFString) as? String
        check(restored == originalLocation, "папка скриншотов вернулась как была", restored ?? "по умолчанию")
        restorePasteboard(savedPasteboard)
        UserDefaults().removePersistentDomain(forName: suite)
        try? fm.removeItem(at: sandbox)
        print("   буфер обмена, курсор и звук возвращены")
    }

    // MARK: - Проверки

    private static func section(_ title: String) { print("\n— \(title)") }

    private static func check(_ ok: Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
        if ok {
            passed += 1
            print("✅ \(name)")
        } else {
            failed += 1
            print("❌ \(name)  [\(detail())]")
        }
        fflush(stdout)
    }

    private static func sleep(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    /// Кликает по элементу, найденному по подписи, и ждёт, пока выполнится условие.
    private static func tap(_ window: NSWindow, _ match: (String) -> Bool, _ name: String,
                            until condition: () -> Bool) async {
        guard let (label, point) = anchor(in: window, match) else {
            check(false, name, "элемент не найден")
            return
        }
        click(point, in: window)
        for _ in 0..<15 where !condition() { await sleep(0.1) }
        check(condition(), name, "клик по «\(label)» ничего не изменил")
        await sleep(0.35)  // даём интерфейсу перерисоваться перед следующим шагом
    }

    /// Точка элемента в координатах окна (по якорям из testAnchor).
    private static func anchor(in window: NSWindow, _ match: (String) -> Bool) -> (String, NSPoint)? {
        guard let host = window.contentView,
              let (label, frame) = TestAnchors.frames.first(where: { match($0.key) }) else { return nil }
        let y = host.isFlipped ? frame.midY : host.bounds.height - frame.midY
        return (label, host.convert(NSPoint(x: frame.midX, y: y), to: nil))
    }

    // MARK: - События и поиск элементов

    private static func click(_ point: NSPoint, in window: NSWindow) {
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                                                 timestamp: ProcessInfo.processInfo.systemUptime,
                                                 windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                                 clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0) else { continue }
            window.sendEvent(event)
        }
    }

    private static func cardViews(in window: NSWindow) -> [CardDragView] {
        var result: [CardDragView] = []
        func walk(_ view: NSView) {
            if let card = view as? CardDragView { result.append(card) }
            view.subviews.forEach(walk)
        }
        if let root = window.contentView { walk(root) }
        let visible = window.contentView?.bounds ?? .zero
        return result
            .filter { $0.window != nil && !$0.isHiddenOrHasHiddenAncestor && visible.contains(windowFrame($0)) }
            .sorted { windowFrame($0).minX < windowFrame($1).minX }
    }

    private static func windowFrame(_ view: NSView) -> NSRect { view.convert(view.bounds, to: nil) }
    private static func center(of view: NSView) -> NSPoint { NSPoint(x: windowFrame(view).midX, y: windowFrame(view).midY) }
    private static func shelfPoint(of view: NSView) -> NSPoint {
        let f = windowFrame(view)
        return NSPoint(x: f.maxX - 12, y: f.minY + 12)
    }

    private static func pinPoint(of view: NSView) -> NSPoint {
        let f = windowFrame(view)
        return NSPoint(x: f.minX + 12, y: f.maxY - 12)
    }

    private static func closePoint(of view: NSView) -> NSPoint {
        let f = windowFrame(view)
        return NSPoint(x: f.maxX - 12, y: f.maxY - 12)
    }

    // MARK: - Окружение

    private static func snapshot(_ window: NSWindow, _ name: String) {
        guard let image = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(window.windowNumber),
                                                  [.boundsIgnoreFraming, .bestResolution]),
              image.width > 1 else {
            print("   (снимок окна «\(name)» недоступен)")
            return
        }
        let url = outDir.appendingPathComponent("\(name).png")
        try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: url)
        print("   снимок окна: \(url.lastPathComponent)")
    }

    private static func png(_ color: NSColor) -> Data {
        let image = NSImage(size: NSSize(width: 320, height: 200), flipped: false) { rect in
            color.setFill()
            rect.fill()
            return true
        }
        let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
        return rep.representation(using: .png, properties: [:])!
    }

    private static func setPasteboard(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }

    private static func savePasteboard() -> [[NSPasteboard.PasteboardType: Data]] {
        (NSPasteboard.general.pasteboardItems ?? []).map { item in
            Dictionary(uniqueKeysWithValues: item.types.compactMap { type in item.data(forType: type).map { (type, $0) } })
        }
    }

    private static func restorePasteboard(_ saved: [[NSPasteboard.PasteboardType: Data]]) {
        NSPasteboard.general.clearContents()
        let items = saved.map { dict -> NSPasteboardItem in
            let item = NSPasteboardItem()
            dict.forEach { item.setData($0.value, forType: $0.key) }
            return item
        }
        if !items.isEmpty { NSPasteboard.general.writeObjects(items) }
    }

    /// Убираем из Корзины ровно тот тестовый файл, который туда отправили.
    private static func removeFromTrash(_ url: URL?) {
        guard let url else { return }
        if (try? FileManager.default.removeItem(at: url)) != nil {
            print("   тестовый файл убран из Корзины")
        } else {
            print("   (тестовый файл «\(url.lastPathComponent)» остался в Корзине)")
        }
    }

    private static func soundMuted() -> Bool { appleScript("output muted of (get volume settings)")?.booleanValue ?? false }

    private static func appleScript(_ source: String) -> NSAppleEventDescriptor? {
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        return error == nil ? result : nil
    }

    private static func caffeinateRunning(for pid: Int32) -> Bool {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-f", "caffeinate -di -w \(pid)"]
        process.standardOutput = pipe
        try? process.run()
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    private static func run(_ path: String, _ arguments: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        try? process.run()
        process.waitUntilExit()
    }
}
#endif
