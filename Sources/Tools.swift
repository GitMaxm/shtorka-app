import Foundation

/// Инструменты нижнего ряда. Порядок и видимость настраиваются в самой панели.
enum Tool: String, CaseIterable, Identifiable {
    case screenshot, pipette, keepAwake, theme, sound

    var id: String { rawValue }

    /// Название в настройках (на самой плитке оно может меняться, например «Тёмная/Светлая»).
    var title: String {
        switch self {
        case .screenshot: return "Скриншот"
        case .pipette: return "Пипетка"
        case .keepAwake: return "Не спать"
        case .theme: return "Тема"
        case .sound: return "Без звука"
        }
    }

    var symbol: String {
        switch self {
        case .screenshot: return "camera.viewfinder"
        case .pipette: return "eyedropper"
        case .keepAwake: return "cup.and.saucer.fill"
        case .theme: return "circle.lefthalf.filled"
        case .sound: return "speaker.slash.fill"
        }
    }
}

@MainActor
final class ToolSettings: ObservableObject {
    @Published private(set) var order: [Tool]
    @Published private(set) var hidden: Set<Tool>

    private let defaults: UserDefaults
    private static let orderKey = "tools.order"
    private static let hiddenKey = "tools.hidden"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = (defaults.stringArray(forKey: Self.orderKey) ?? []).compactMap(Tool.init(rawValue:))
        let added = Tool.allCases.filter { !stored.contains($0) }
        // Новые инструменты из будущих версий добавляются в конец.
        order = stored + added
        hidden = Set((defaults.stringArray(forKey: Self.hiddenKey) ?? []).compactMap(Tool.init(rawValue:)))
        if !added.isEmpty { save() }
    }

    var visible: [Tool] { order.filter { !hidden.contains($0) } }

    func isVisible(_ tool: Tool) -> Bool { !hidden.contains(tool) }

    func toggle(_ tool: Tool) {
        if hidden.contains(tool) { hidden.remove(tool) } else { hidden.insert(tool) }
        save()
    }

    /// Ставит `tool` на место `target` (используется при перетаскивании).
    func move(_ tool: Tool, to target: Tool) {
        guard tool != target, let from = order.firstIndex(of: tool), let to = order.firstIndex(of: target) else { return }
        order.remove(at: from)
        order.insert(tool, at: to)
        save()
    }

    func reset() {
        order = Tool.allCases
        hidden = []
        save()
    }

    private func save() {
        defaults.set(order.map(\.rawValue), forKey: Self.orderKey)
        defaults.set(hidden.map(\.rawValue).sorted(), forKey: Self.hiddenKey)
    }
}
