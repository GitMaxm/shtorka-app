import AppKit
import SwiftUI

/// Курсор-«рука» над всем, на что можно нажать: карточки, плитки, вкладки, кнопки.
@MainActor
final class PointerCursor {
    static let shared = PointerCursor()
    private var hovered = Set<AnyHashable>()

    private init() { Self.allowCursorInBackground() }

    /// Шторка — фоновое приложение, а таким macOS не даёт менять курсор. Включаем это для своего
    /// соединения с оконным сервером (недокументированно, но так делают утилиты строки меню).
    /// Если когда-нибудь не получится — останется обычная стрелка, остальное работает как прежде.
    private static func allowCursorInBackground() {
        typealias DefaultConnection = @convention(c) () -> Int32
        typealias SetProperty = @convention(c) (Int32, Int32, CFString, CFTypeRef) -> Int32
        guard let handle = dlopen(nil, RTLD_NOW),
              let connection = dlsym(handle, "_CGSDefaultConnection"),
              let setProperty = dlsym(handle, "CGSSetConnectionProperty") else { return }
        let id = unsafeBitCast(connection, to: DefaultConnection.self)()
        _ = unsafeBitCast(setProperty, to: SetProperty.self)(id, id, "SetsCursorInBackground" as CFString, kCFBooleanTrue)
    }

    var isPointing: Bool { !hovered.isEmpty }

    func set(_ key: AnyHashable, hovering: Bool) {
        let was = isPointing
        if hovering { hovered.insert(key) } else { hovered.remove(key) }
        if isPointing != was { (isPointing ? NSCursor.pointingHand : NSCursor.arrow).set() }
    }

    /// Приложение под шторкой может вернуть свою стрелку — пока курсор над кнопкой, держим «руку».
    func reassert() {
        if isPointing { NSCursor.pointingHand.set() }
    }

    /// Шторка закрылась — возвращаем обычный курсор.
    func reset() {
        guard isPointing else { return }
        hovered.removeAll()
        NSCursor.arrow.set()
    }
}

extension View {
    func pointingHandCursor() -> some View { modifier(PointingHandModifier()) }
}

private struct PointingHandModifier: ViewModifier {
    @State private var id = UUID()

    func body(content: Content) -> some View {
        content
            .onHover { PointerCursor.shared.set(id, hovering: $0) }
            .onDisappear { PointerCursor.shared.set(id, hovering: false) }
    }
}
