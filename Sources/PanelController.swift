import AppKit
import SwiftUI

enum Layout {
    static let contentWidth: CGFloat = 760
    static let thumbSize = CGSize(width: 150, height: 94)
    static let controlHeight: CGFloat = 60
    static let spacing: CGFloat = 12
    static let bottomPadding: CGFloat = 16

    static func headerHeight(topInset: CGFloat) -> CGFloat { max(topInset, 30) }

    static func contentHeight(topInset: CGFloat) -> CGFloat {
        headerHeight(topInset: topInset) + spacing + thumbSize.height + 8 + spacing + controlHeight + bottomPadding
    }
}

final class ShadePanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        // Уровень всплывающих меню: выше строки меню и выезжающих заголовков полноэкранных приложений
        // (они на уровне 26 — на нём шторку могло перекрыть).
        level = ShadePanel.shadeLevel
        collectionBehavior = ShadePanel.shadeBehavior
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = false
        isMovable = false
        acceptsMouseMovedEvents = true
        appearance = NSAppearance(named: .darkAqua)
    }

    static let shadeLevel = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.popUpMenuWindow)))
    /// На всех рабочих столах, включая полноэкранные приложения.
    static let shadeBehavior: NSWindow.CollectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    // Не даём системе «впихивать» окно под строку меню.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Принимает файлы, брошенные на шторку из других программ. Это делает AppKit, а не SwiftUI:
/// так одинаково читаются Finder, WebStorm (старый формат списка файлов) и «обещанные» файлы из Safari и Почты.
final class DropContainerView: NSView {
    var onHover: (Bool) -> Void = { _ in }
    var onDrop: (NSPasteboard) -> Bool = { _ in false }
    private var acceptsCurrentDrag = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes(ShelfStore.droppableTypes)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) не используется") }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        // Свои же карточки обратно на шторку не принимаем (у них draggingSource — наше окно).
        acceptsCurrentDrag = sender.draggingSource == nil && ShelfStore.canAccept(sender.draggingPasteboard)
        onHover(acceptsCurrentDrag)
        return acceptsCurrentDrag ? .copy : []
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { acceptsCurrentDrag ? .copy : [] }
    override func draggingExited(_ sender: NSDraggingInfo?) { onHover(false) }
    override func draggingEnded(_ sender: NSDraggingInfo) { onHover(false) }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        onHover(false)
        return acceptsCurrentDrag && onDrop(sender.draggingPasteboard)
    }
}

/// Показывает панель, когда курсор упирается в верх экрана по центру, и прячет, когда уходит.
@MainActor
final class PanelController: NSObject, NSMenuDelegate {
    private let state: AppState
    private let store: ShotStore
    private let clipboard: ClipboardStore
    private let tools: ToolSettings
    private let shelf: ShelfStore
    private let ports: PortsStore
    private let actions: PanelActions
    let panel = ShadePanel()
    private var hosting: FirstMouseHostingView<PanelView>!
    private var timer: Timer?

    private var isShown = false
    private var contentRect: NSRect = .zero
    private var hoverStart: Date?
    private var leaveStart: Date?
    private var holdUntil: Date?
    private var menuOpen = false
    private var orderOutWork: DispatchWorkItem?

    /// Реакция на курсор. Самопроверка выключает её, чтобы движения настоящей мыши не мешали кликам.
    var followsCursor = true

    private let showDelay: TimeInterval = 0.12
    private let hideDelay: TimeInterval = 0.35

    init(state: AppState, store: ShotStore, clipboard: ClipboardStore, tools: ToolSettings,
         shelf: ShelfStore, ports: PortsStore, actions: PanelActions) {
        self.state = state
        self.store = store
        self.clipboard = clipboard
        self.tools = tools
        self.shelf = shelf
        self.ports = ports
        self.actions = actions
        super.init()
        actions.menuDelegate = self
        actions.onDragChanged = { [weak self] dragging in self?.dragChanged(dragging) }
        hosting = FirstMouseHostingView(rootView: PanelView(state: state, store: store, clipboard: clipboard, tools: tools,
                                                           shelf: shelf, ports: ports, actions: actions, topInset: 0))
        let container = DropContainerView(frame: .zero)
        hosting.autoresizingMask = [.width, .height]
        container.addSubview(hosting)
        container.onHover = { [weak self] hovering in self?.state.dropHover = hovering }
        container.onDrop = { [weak self] pasteboard in self?.actions.acceptDrop(pasteboard) ?? false }
        panel.contentView = container

        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    // MARK: - Показ / скрытие

    func show(on screen: NSScreen? = nil, holdFor seconds: TimeInterval? = nil) {
        let screen = screen ?? screenUnderMouse() ?? NSScreen.main
        guard let screen else { return }
        if let seconds { holdUntil = Date().addingTimeInterval(seconds) }
        orderOutWork?.cancel()
        leaveStart = nil
        guard !isShown else { return }
        isShown = true

        let topInset = screen.safeAreaInsets.top
        let f = screen.frame
        let contentH = Layout.contentHeight(topInset: topInset)
        // Окно ровно по размеру шторки: без теней и прозрачных полей вокруг.
        contentRect = NSRect(x: f.midX - Layout.contentWidth / 2, y: f.maxY - contentH, width: Layout.contentWidth, height: contentH)

        var notchWidth: CGFloat = 0
        if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            notchWidth = max(0, right.minX - left.maxX)
        }
        hosting.rootView = PanelView(state: state, store: store, clipboard: clipboard, tools: tools,
                                     shelf: shelf, ports: ports, actions: actions,
                                     topInset: topInset, notchWidth: notchWidth)
        panel.setFrame(contentRect, display: false)
        hosting.frame = panel.contentView?.bounds ?? .zero
        panel.ignoresMouseEvents = false
        // На всякий случай заново: если что-то сбросило эти свойства, шторка не попадёт на полноэкранный стол.
        panel.level = ShadePanel.shadeLevel
        panel.collectionBehavior = ShadePanel.shadeBehavior
        panel.orderFrontRegardless()
        checkPlacement(attempt: 1)

        store.reload()
        actions.refreshToggles()
        // Файлы могли переименовать, перенести или удалить, пока шторка была закрыта.
        shelf.refreshLocations()
        clipboard.refreshFiles()
        Task { await ports.refresh() }
        DispatchQueue.main.async { self.state.isOpen = true }
    }

    /// Проверяем, что шторка действительно на текущем рабочем столе и её видно. Если нет — переоткрываем
    /// окно и пишем в журнал, что было вокруг: это поможет, если какое-то приложение всё равно её спрячет.
    private func checkPlacement(attempt: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self, self.isShown else { return }
            let onSpace = self.panel.isOnActiveSpace
            let visible = self.panel.occlusionState.contains(.visible)
            PanelLog.write("открыта (попытка \(attempt)): впереди \(PanelLog.frontApp), на текущем столе \(onSpace), "
                           + "видна \(visible), поверх неё: \(PanelLog.windowsAbove(self.panel))")
            guard !(onSpace && visible), attempt < 3 else { return }
            self.panel.collectionBehavior = ShadePanel.shadeBehavior
            self.panel.orderOut(nil)
            self.panel.orderFrontRegardless()
            self.checkPlacement(attempt: attempt + 1)
        }
    }

    func hide() {
        guard isShown else { return }
        isShown = false
        holdUntil = nil
        state.isOpen = false
        state.editing = false
        state.confirmingClear = false
        PointerCursor.shared.reset()
        panel.ignoresMouseEvents = true
        scheduleOrderOut()
    }

    private func scheduleOrderOut() {
        orderOutWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.state.isOpen else { return }
            self.panel.orderOut(nil)
        }
        orderOutWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    // MARK: - Слежение за курсором

    private func tick() {
        guard followsCursor else { return }
        let p = NSEvent.mouseLocation

        if !isShown {
            guard let screen = screenUnderMouse(), inTriggerZone(p, screen: screen) else {
                hoverStart = nil
                return
            }
            if let start = hoverStart {
                if Date().timeIntervalSince(start) >= showDelay {
                    hoverStart = nil
                    show(on: screen)
                }
            } else {
                hoverStart = Date()
            }
            return
        }

        // Пока тащим файл — панель не прячем, но убираем с дороги, если курсор ушёл вниз.
        if state.isDragging {
            if state.isOpen && !contentRect.insetBy(dx: -24, dy: -24).contains(p) {
                state.isOpen = false
                panel.ignoresMouseEvents = true
            }
            return
        }
        if menuOpen { leaveStart = nil; return }

        if contentRect.insetBy(dx: -10, dy: -10).contains(p) {
            leaveStart = nil
            holdUntil = nil
            return
        }
        if let hold = holdUntil, hold > Date() { return }
        if let start = leaveStart {
            if Date().timeIntervalSince(start) >= hideDelay { hide() }
        } else {
            leaveStart = Date()
        }
    }

    private func dragChanged(_ dragging: Bool) {
        state.isDragging = dragging
        // Если во время перетаскивания панель убрали с дороги — после броска закрываем её совсем.
        if !dragging && !state.isOpen { hide() }
    }

    private func inTriggerZone(_ p: NSPoint, screen: NSScreen) -> Bool {
        let f = screen.frame
        guard p.y >= f.maxY - 4 else { return false }
        var halfWidth: CGFloat = 160
        if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            halfWidth = (right.minX - left.maxX) / 2 + 20
        }
        return abs(p.x - f.midX) <= halfWidth
    }

    private func screenUnderMouse() -> NSScreen? {
        let p = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(p, $0.frame, false) }
    }

    // MARK: - NSMenuDelegate (контекстное меню миниатюры)

    func menuWillOpen(_ menu: NSMenu) { menuOpen = true }
    func menuDidClose(_ menu: NSMenu) { menuOpen = false }
}
