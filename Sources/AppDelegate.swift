import AppKit
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let state = AppState()
    private let store = ShotStore()
    private let clipboard = ClipboardStore()
    private let tools = ToolSettings()
    private let shelf = ShelfStore()
    private let ports = PortsStore()
    private var actions: PanelActions!
    private var panel: PanelController!
    private var statusItem: NSStatusItem!
    private var loginItem: NSMenuItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        actions = PanelActions(state: state, store: store, clipboard: clipboard, shelf: shelf, ports: ports)
        panel = PanelController(state: state, store: store, clipboard: clipboard, tools: tools,
                                shelf: shelf, ports: ports, actions: actions)
        actions.hidePanel = { [weak self] in self?.panel.hide() }
        actions.flashPanel = { [weak self] seconds in self?.panel.show(holdFor: seconds) }
        setupStatusItem()
        removeOldCopy()
        enableLoginItemOnFirstLaunch()
        store.reload()
        clipboard.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        actions.stopKeepAwake()
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let image = NSImage(systemSymbolName: "rectangle.topthird.inset.filled", accessibilityDescription: "Шторка")
        image?.isTemplate = true
        statusItem.button?.image = image

        let menu = NSMenu()
        menu.addItem(ClosureMenuItem("Показать шторку", symbol: "chevron.down.circle") { [weak self] in
            self?.panel.show(holdFor: 4)
        })
        menu.addItem(ClosureMenuItem("Открыть папку скриншотов", symbol: "folder") { [weak self] in
            self?.actions.openFolder()
        })
        menu.addItem(ClosureMenuItem("Настроить панель…", symbol: "slider.horizontal.3") { [weak self] in
            self?.panel.show(holdFor: 6)
            self?.state.editing = true
        })
        menu.addItem(.separator())
        loginItem = ClosureMenuItem("Открывать при входе в систему") { [weak self] in self?.toggleLoginItem() }
        menu.addItem(loginItem)
        menu.addItem(.separator())
        let hint = NSMenuItem(title: "Наведи мышь на выемку вверху экрана", action: nil, keyEquivalent: "")
        hint.isEnabled = false
        menu.addItem(hint)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Выйти из Шторки", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
        menu.delegate = self
        statusItem.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    // MARK: - Автозапуск

    /// При первом запуске из «Программ» сразу добавляем Шторку в объекты входа.
    /// Если Шторку перенесли или переименовали — перепривязываем автозапуск к новому месту.
    private func enableLoginItemOnFirstLaunch() {
        let key = "didSetUpLoginItem", pathKey = "loginItemPath"
        let defaults = UserDefaults.standard
        let path = Bundle.main.bundlePath
        let installed = path.hasPrefix("/Applications/") || path.hasPrefix(NSHomeDirectory() + "/Applications/")
        guard installed else { return }
        if !defaults.bool(forKey: key) {
            defaults.set(true, forKey: key)
            try? SMAppService.mainApp.register()
        } else if defaults.string(forKey: pathKey) != path, SMAppService.mainApp.status == .enabled {
            try? SMAppService.mainApp.unregister()
            try? SMAppService.mainApp.register()
        }
        defaults.set(path, forKey: pathKey)
        NSLog("Shtorka login item status: \(SMAppService.mainApp.status.rawValue)")
    }

    /// Версия 1.0 лежала в «Шторка.app». Если она осталась рядом — закрываем её и убираем в Корзину,
    /// чтобы в «Программах» не было двух Шторок.
    private func removeOldCopy() {
        let current = Bundle.main.bundleURL.standardizedFileURL
        let old = current.deletingLastPathComponent().appendingPathComponent("Шторка.app")
        guard current.lastPathComponent != old.lastPathComponent,
              let id = Bundle.main.bundleIdentifier,
              Bundle(url: old)?.bundleIdentifier == id else { return }
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: id)
        where app.bundleURL?.standardizedFileURL.path == old.path {
            app.forceTerminate()
        }
        NSWorkspace.shared.recycle([old]) { _, error in
            if let error { NSLog("Shtorka: не удалось убрать старую копию: \(error)") }
        }
    }

    private func toggleLoginItem() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
            }
        } catch {
            SMAppService.openSystemSettingsLoginItems()
        }
        if service.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
    }
}

/// Пункт меню с замыканием вместо target/action.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, symbol: String? = nil, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
        if let symbol { image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
    }

    required init(coder: NSCoder) { fatalError("init(coder:) не используется") }

    @objc private func fire() { handler() }
}
