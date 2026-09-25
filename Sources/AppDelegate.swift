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
    private func enableLoginItemOnFirstLaunch() {
        let key = "didSetUpLoginItem"
        let path = Bundle.main.bundlePath
        let installed = path.hasPrefix("/Applications/") || path.hasPrefix(NSHomeDirectory() + "/Applications/")
        guard installed, !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        try? SMAppService.mainApp.register()
        NSLog("Shtorka login item status: \(SMAppService.mainApp.status.rawValue)")
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
