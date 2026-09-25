import AppKit
import SwiftUI

/// Прозрачный слой поверх карточки: клик, двойной клик, крестик в углу, контекстное меню
/// и настоящее перетаскивание — как из Finder, поэтому бросать можно куда угодно.
struct CardInteraction: NSViewRepresentable {
    var preview: NSImage?
    var writers: () -> [NSPasteboardWriting]
    var onHover: (Bool) -> Void
    var onCloseHover: (Bool) -> Void
    var onClick: () -> Void
    var onDoubleClick: () -> Void = {}
    var onClose: (() -> Void)?
    /// Кнопка в левом верхнем углу (закрепить запись). nil — угла нет.
    var onPin: (() -> Void)? = nil
    var onPinHover: (Bool) -> Void = { _ in }
    /// Кнопка в правом нижнем углу («Положить на полку»). nil — угла нет.
    var onAccessory: (() -> Void)? = nil
    var onAccessoryHover: (Bool) -> Void = { _ in }
    var onDragChanged: (Bool) -> Void
    var makeMenu: () -> NSMenu

    func makeNSView(context: Context) -> CardDragView { CardDragView() }

    func updateNSView(_ view: CardDragView, context: Context) {
        view.preview = preview
        view.writers = writers
        view.onHover = onHover
        view.onCloseHover = onCloseHover
        view.onClick = onClick
        view.onDoubleClick = onDoubleClick
        view.onClose = onClose
        view.onPin = onPin
        view.onPinHover = onPinHover
        view.onAccessory = onAccessory
        view.onAccessoryHover = onAccessoryHover
        view.onDragChanged = onDragChanged
        view.makeMenu = makeMenu
    }
}

final class CardDragView: NSView, NSDraggingSource {
    var preview: NSImage?
    var writers: () -> [NSPasteboardWriting] = { [] }
    var onHover: (Bool) -> Void = { _ in }
    var onCloseHover: (Bool) -> Void = { _ in }
    var onClick: () -> Void = {}
    var onDoubleClick: () -> Void = {}
    var onClose: (() -> Void)?
    var onPin: (() -> Void)?
    var onPinHover: (Bool) -> Void = { _ in }
    var onAccessory: (() -> Void)?
    var onAccessoryHover: (Bool) -> Void = { _ in }
    var onDragChanged: (Bool) -> Void = { _ in }
    var makeMenu: () -> NSMenu = { NSMenu() }

    enum Corner: String, CaseIterable { case close, pin, accessory }

    private var mouseDownEvent: NSEvent?
    private var pressedCorner: Corner?
    private(set) var overClose = false
    private(set) var overPin = false
    private(set) var overAccessory = false
    private(set) var isHovered = false

    /// Зоны угловых кнопок — чуть больше самих значков, чтобы легко попасть.
    private var closeRect: NSRect { NSRect(x: bounds.maxX - 28, y: 0, width: 28, height: 28) }
    private var pinRect: NSRect { NSRect(x: 0, y: 0, width: 28, height: 28) }
    private var accessoryRect: NSRect { NSRect(x: bounds.maxX - 28, y: bounds.maxY - 28, width: 28, height: 28) }

    private var enabledCorners: Set<Corner> {
        var corners: Set<Corner> = []
        if onClose != nil { corners.insert(.close) }
        if onPin != nil { corners.insert(.pin) }
        if onAccessory != nil { corners.insert(.accessory) }
        return corners
    }

    private func rect(of corner: Corner) -> NSRect {
        switch corner {
        case .close: return closeRect
        case .pin: return pinRect
        case .accessory: return accessoryRect
        }
    }

    private func corner(at point: NSPoint) -> Corner? {
        Corner.allCases.first { enabledCorners.contains($0) && rect(of: $0).contains(point) }
    }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: - Наведение

    /// Наведение считаем сами, по положению курсора (см. HoverTracker): у неактивной шторки macOS
    /// присылает события «вошёл/вышел» неполно, а в прокручиваемом ряду ещё и с неверной геометрией —
    /// на записи экрана нижняя треть карточки не подсвечивалась.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            HoverTracker.shared.register(self)
        } else {
            HoverTracker.shared.unregister(self)
            updateHover(at: nil)
        }
    }

    /// point — курсор в координатах экрана; nil — курсора над карточкой нет.
    func updateHover(at point: NSPoint?) {
        var local: NSPoint?
        if let point, let window, window.isVisible, !window.ignoresMouseEvents, !isHiddenOrHasHiddenAncestor {
            let p = convert(window.convertPoint(fromScreen: point), from: nil)
            if bounds.contains(p), isInsideVisibleArea(p) { local = p }
        }
        let inside = local != nil
        if inside != isHovered {
            isHovered = inside
            onHover(inside)
            PointerCursor.shared.set(ObjectIdentifier(self), hovering: inside)
        }
        let corner = local.flatMap(corner(at:))
        setOverClose(corner == .close)
        setOverPin(corner == .pin)
        setOverAccessory(corner == .accessory)
    }

    /// Часть карточки, уехавшая за край прокручиваемого ряда, не считается.
    private func isInsideVisibleArea(_ p: NSPoint) -> Bool {
        guard let clip = enclosingScrollView?.contentView else { return true }
        return clip.bounds.contains(clip.convert(p, from: self))
    }

    override func mouseDown(with event: NSEvent) {
        if let corner = corner(at: location(of: event)) {
            pressedCorner = corner
        } else {
            mouseDownEvent = event
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let down = mouseDownEvent else { return }
        let dx = event.locationInWindow.x - down.locationInWindow.x
        let dy = event.locationInWindow.y - down.locationInWindow.y
        guard hypot(dx, dy) > 4 else { return }
        mouseDownEvent = nil

        let image = preview ?? NSImage(systemSymbolName: "doc", accessibilityDescription: nil) ?? NSImage()
        let frame = aspectFitFrame(for: image.size)
        let items = writers().map { writer -> NSDraggingItem in
            let item = NSDraggingItem(pasteboardWriter: writer)
            item.setDraggingFrame(frame, contents: image)
            return item
        }
        guard !items.isEmpty else { return }
        onDragChanged(true)
        beginDraggingSession(with: items, event: down, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        if let pressed = pressedCorner {
            pressedCorner = nil
            guard corner(at: location(of: event)) == pressed else { return }
            switch pressed {
            case .close: onClose?()
            case .pin: onPin?()
            case .accessory: onAccessory?()
            }
            return
        }
        defer { mouseDownEvent = nil }
        guard mouseDownEvent != nil else { return }
        if event.clickCount >= 2 {
            onDoubleClick()
        } else {
            onClick()
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? { makeMenu() }

    // MARK: - NSDraggingSource

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? .copy : []
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        onDragChanged(false)
    }

    // MARK: - Помощники

    private func location(of event: NSEvent) -> NSPoint { convert(event.locationInWindow, from: nil) }

    private func setOverAccessory(_ value: Bool) {
        guard value != overAccessory else { return }
        overAccessory = value
        onAccessoryHover(value)
    }

    private func setOverPin(_ value: Bool) {
        guard value != overPin else { return }
        overPin = value
        onPinHover(value)
    }

    private func setOverClose(_ value: Bool) {
        guard value != overClose else { return }
        overClose = value
        onCloseHover(value)
    }

    private func aspectFitFrame(for size: NSSize) -> NSRect {
        guard size.width > 0, size.height > 0 else { return bounds }
        let scale = min(bounds.width / size.width, bounds.height / size.height)
        let w = size.width * scale, h = size.height * scale
        return NSRect(x: bounds.midX - w / 2, y: bounds.midY - h / 2, width: w, height: h)
    }
}

/// Раз в 1/30 секунды сообщает карточкам, где курсор. Работает, только пока карточки на экране.
@MainActor
final class HoverTracker {
    static let shared = HoverTracker()

    private let views = NSHashTable<CardDragView>.weakObjects()
    private var timer: Timer?

    func register(_ view: CardDragView) {
        views.add(view)
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func unregister(_ view: CardDragView) {
        views.remove(view)
        if views.allObjects.isEmpty {
            timer?.invalidate()
            timer = nil
        }
    }

    private func tick() {
        let point = NSEvent.mouseLocation
        for view in views.allObjects where view.window?.isVisible == true || view.isHovered {
            view.updateHover(at: point)
        }
        PointerCursor.shared.reassert()
    }
}
