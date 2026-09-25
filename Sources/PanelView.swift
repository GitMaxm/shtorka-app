import SwiftUI
import UniformTypeIdentifiers

enum PanelTab: CaseIterable {
    case shots, clipboard, shelf, ports

    var title: String {
        switch self {
        case .shots: return "Скриншоты"
        case .clipboard: return "Буфер"
        case .shelf: return "Полка"
        case .ports: return "Порты"
        }
    }

    var symbol: String {
        switch self {
        case .shots: return "photo.on.rectangle.angled"
        case .clipboard: return "doc.on.clipboard"
        case .shelf: return "tray.full"
        case .ports: return "server.rack"
        }
    }
}

struct PanelView: View {
    @ObservedObject var state: AppState
    @ObservedObject var store: ShotStore
    @ObservedObject var clipboard: ClipboardStore
    @ObservedObject var tools: ToolSettings
    @ObservedObject var shelf: ShelfStore
    @ObservedObject var ports: PortsStore
    let actions: PanelActions
    let topInset: CGFloat
    var notchWidth: CGFloat = 0

    private var shape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(bottomLeadingRadius: 28, bottomTrailingRadius: 28, style: .continuous)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Layout.spacing) {
            header
            shelfArea
            controls
        }
        .padding(.horizontal, 16)
        .padding(.bottom, Layout.bottomPadding)
        .frame(width: Layout.contentWidth, height: Layout.contentHeight(topInset: topInset), alignment: .top)
        .overlay { if state.dropHover { DropHint() } }
        .onChange(of: state.dropHover) { _, targeted in
            if targeted, state.tab != .shelf {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { state.tab = .shelf }
            }
        }
        .background(shape.fill(Color.black))
        .overlay(shape.strokeBorder(Color.white.opacity(0.07), lineWidth: 1))
        .clipShape(shape)
        .scaleEffect(x: state.isOpen ? 1 : 0.4, y: state.isOpen ? 1 : 0.15, anchor: .top)
        .opacity(state.isOpen ? 1 : 0)
        .animation(.spring(response: 0.36, dampingFraction: 0.8), value: state.isOpen)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .environment(\.colorScheme, .dark)
    }

    // MARK: - Шапка

    private var header: some View {
        HStack(spacing: 0) {
            Group {
                if state.editing {
                    Label("Настройка панели", systemImage: "slider.horizontal.3")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.9))
                        .padding(.leading, 6)
                } else {
                    TabSwitcher(tab: $state.tab, counts: [
                        .shots: store.totalCount, .clipboard: clipboard.items.count,
                        .shelf: shelf.fileCount, .ports: ports.servers.count,
                    ])
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Под выемкой ничего не видно — оставляем там пустое место.
            Color.clear.frame(width: notchWidth > 0 ? notchWidth + 16 : 0)

            HStack(spacing: 6) {
                if state.editing {
                    PillButton(symbol: "checkmark", title: "Готово", style: .prominent) { setEditing(false) }
                } else if state.confirmingClear {
                    // Второй шаг «Очистить всё» — чтобы не удалить случайно.
                    PillButton(symbol: "xmark", title: "Отмена") { setConfirming(false) }
                    PillButton(symbol: "trash.fill", title: clearConfirmTitle, style: .destructive) {
                        setConfirming(false)
                        switch state.tab {
                        case .shots: actions.trashAllScreenshots()
                        case .clipboard: actions.clearClipboard()
                        case .shelf: actions.clearShelf()
                        case .ports: break
                        }
                    }
                } else {
                    if state.tab == .shots {
                        IconButton(symbol: "folder", help: "Открыть папку со скриншотами") { actions.openFolder() }
                    }
                    if clearableCount > 0 {
                        PillButton(symbol: "trash", title: "Очистить всё") { setConfirming(true) }
                    }
                    IconButton(symbol: "slider.horizontal.3", help: "Настроить панель") { setEditing(true) }
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 2)
        .frame(height: Layout.headerHeight(topInset: topInset))
        .onChange(of: state.tab) { _, _ in state.confirmingClear = false }
        .task(id: state.confirmingClear) {
            // Если не подтвердили за 5 секунд — отменяем.
            guard state.confirmingClear else { return }
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            if !Task.isCancelled { setConfirming(false) }
        }
    }

    private var clearableCount: Int {
        switch state.tab {
        case .shots: return store.totalCount
        case .clipboard: return clipboard.unpinnedCount   // закреплённые не стираются
        case .shelf: return shelf.items.count
        case .ports: return 0
        }
    }

    private var clearConfirmTitle: String {
        switch state.tab {
        case .shots: return "В Корзину: \(clearableCount)"
        case .clipboard: return "Удалить: \(clearableCount)"
        case .shelf, .ports: return "Убрать: \(clearableCount)"
        }
    }

    private func setConfirming(_ value: Bool) {
        withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) { state.confirmingClear = value }
    }

    // MARK: - Полка

    private func setEditing(_ value: Bool) {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { state.editing = value }
    }

    /// Средняя часть: карточки текущей вкладки или настройка панели.
    private var shelfArea: some View {
        Group {
            if state.editing {
                ToolsEditor(tools: tools, store: store, actions: actions)
            } else {
                shelfContent
            }
        }
        .frame(height: Layout.thumbSize.height + 8)
        .overlay {
            if let toast = state.toast {
                ToastView(toast: toast)
                    .transition(.scale(scale: 0.85).combined(with: .opacity))
                    .id(toast.id)
                    .allowsHitTesting(false)   // уведомление не мешает кликать по карточкам под ним
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.75), value: state.toast)
    }

    @ViewBuilder
    private var shelfContent: some View {
        switch state.tab {
        case .shots:
            if store.shots.isEmpty {
                EmptyShelf(
                    symbol: store.accessDenied ? "lock.fill" : "photo.on.rectangle.angled",
                    title: store.accessDenied ? "Нет доступа к папке со скриншотами" : "Скриншотов пока нет",
                    subtitle: store.accessDenied
                        ? "Настройки → Конфиденциальность → Файлы и папки → Шторка"
                        : "⌘⇧4 — снимок области, ⌘⇧5 — все режимы")
            } else {
                row(animating: store.shots) {
                    ForEach(Array(store.shots.enumerated()), id: \.element.id) { i, shot in
                        ShotCell(shot: shot, actions: actions, previewHover: Preview.isActive && i == 0)
                    }
                }
            }
        case .clipboard:
            if clipboard.items.isEmpty {
                EmptyShelf(symbol: "doc.on.clipboard",
                           title: "Здесь появится всё, что ты копируешь",
                           subtitle: "Клик по карточке — снова в буфер. Пароли не сохраняются")
            } else {
                row(animating: clipboard.items) {
                    ForEach(Array(clipboard.items.enumerated()), id: \.element.id) { i, item in
                        ClipCell(item: item, actions: actions, previewHover: Preview.isActive && i == 1)
                    }
                }
            }
        case .shelf:
            if shelf.items.isEmpty {
                EmptyShelf(symbol: "tray",
                           title: "Полка пустая",
                           subtitle: "Перетащи сюда файлы или картинки — они подождут здесь")
            } else {
                row(animating: shelf.items) {
                    ForEach(shelf.items) { item in ShelfCell(item: item, actions: actions) }
                }
            }
        case .ports:
            Group {
                if ports.servers.isEmpty {
                    EmptyShelf(symbol: "server.rack",
                               title: "Серверов не запущено",
                               subtitle: "Запусти npm run dev — он появится здесь")
                } else {
                    row(animating: ports.servers) {
                        ForEach(ports.servers) { server in PortCell(server: server, actions: actions) }
                    }
                }
            }
            .task {
                // Пока вкладка открыта — обновляем список каждые 2 секунды.
                guard !Preview.isActive else { return }
                while !Task.isCancelled {
                    await ports.refresh()
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                }
            }
        }
    }

    @ViewBuilder
    private func row<Value: Equatable, Content: View>(animating value: Value, @ViewBuilder _ content: () -> Content) -> some View {
        // Обычный, не «ленивый» ряд: LazyHStack переиспользует ячейки и не всегда двигает встроенные
        // AppKit-слои карточек — тогда клик по новой карточке срабатывал для соседней. Карточек не больше
        // нескольких десятков, так что ленивость здесь не нужна.
        let stack = HStack(spacing: 10) { content() }
            .padding(.vertical, 4)
            .padding(.horizontal, 2)
            .animation(.spring(response: 0.32, dampingFraction: 0.85), value: value)
        if Preview.isActive {
            // ImageRenderer не рисует ScrollView — для превью обычный ряд.
            stack.frame(width: Layout.contentWidth - 32, alignment: .leading).clipped()
        } else {
            ScrollView(.horizontal, showsIndicators: false) { stack }
        }
    }

    // MARK: - Быстрые кнопки

    private var controls: some View {
        HStack(spacing: 8) {
            if tools.visible.isEmpty {
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .foregroundStyle(.white.opacity(0.18))
                    .overlay {
                        Text("Все инструменты скрыты — верни нужные в настройках")
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(.white.opacity(0.45))
                    }
            } else {
                ForEach(tools.visible) { tool in tile(for: tool) }
            }
        }
        .frame(height: Layout.controlHeight)
        .animation(.spring(response: 0.32, dampingFraction: 0.85), value: tools.visible)
    }

    @ViewBuilder
    private func tile(for tool: Tool) -> some View {
        switch tool {
        case .screenshot:
            ControlTile(symbol: "camera.viewfinder", title: "Скриншот") { actions.takeScreenshot() }
        case .pipette:
            ControlTile(symbol: "eyedropper", title: "Пипетка") { actions.pickColor() }
        case .keepAwake:
            ControlTile(symbol: state.keepAwake ? "cup.and.saucer.fill" : "cup.and.saucer",
                        title: "Не спать", isOn: state.keepAwake) { actions.toggleKeepAwake() }
        case .theme:
            ControlTile(symbol: state.darkMode ? "moon.fill" : "sun.max.fill",
                        title: state.darkMode ? "Тёмная" : "Светлая", isOn: state.darkMode) { actions.toggleDarkMode() }
        case .sound:
            ControlTile(symbol: state.muted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                        title: "Без звука", isOn: state.muted) { actions.toggleMute() }
        }
    }
}

// MARK: - Настройка панели

private struct ToolsEditor: View {
    @ObservedObject var tools: ToolSettings
    @ObservedObject var store: ShotStore
    let actions: PanelActions
    @State private var dragging: Tool?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Нажми, чтобы скрыть или вернуть инструмент. Перетащи, чтобы поменять порядок")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.4))
            HStack(spacing: 6) {
                ForEach(tools.order) { tool in
                    let chip = ToolChip(tool: tool, visible: tools.isVisible(tool)) { tools.toggle(tool) }
                        .opacity(dragging == tool ? 0.4 : 1)
                    if Preview.isActive {
                        chip  // ImageRenderer не умеет рисовать drag & drop
                    } else {
                        chip
                            .onDrag {
                                dragging = tool
                                return NSItemProvider(item: tool.rawValue as NSString, typeIdentifier: UTType.shtorkaTool.identifier)
                            }
                            .onDrop(of: [.shtorkaTool], delegate: ToolDropDelegate(target: tool, tools: tools, dragging: $dragging))
                    }
                }
            }
            .animation(.spring(response: 0.3, dampingFraction: 0.8), value: tools.order)
            HStack(spacing: 6) {
                Image(systemName: "folder.fill").font(.system(size: 10.5))
                    .foregroundStyle(.white.opacity(0.45))
                Text("Скриншоты сохраняются в")
                    .foregroundStyle(.white.opacity(0.45))
                Text(ShotStore.displayName(for: store.folder))
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                PillButton(symbol: "folder.badge.gearshape", title: "Изменить…") { actions.chooseScreenshotFolder() }
            }
            .font(.system(size: 11, weight: .medium))
        }
        .padding(.horizontal, 2)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct ToolChip: View {
    let tool: Tool
    let visible: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: visible ? tool.symbol : "eye.slash")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(height: 14)
                Text(tool.title)
                    .font(.system(size: 10, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .foregroundStyle(visible ? Color.black : Color.white.opacity(0.4))
            .frame(maxWidth: .infinity)
            .frame(height: 40)
            .background(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(visible ? Color.white.opacity(hovering ? 0.85 : 1) : Color.white.opacity(hovering ? 0.1 : 0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(Color.white.opacity(visible ? 0 : 0.12), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            )
            .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        }
        .buttonStyle(PressStyle())
        .onHover { hovering = $0 }
        .pointingHandCursor()
        .help(visible ? "Скрыть «\(tool.title)»" : "Показать «\(tool.title)»")
        .accessibilityLabel("Инструмент \(tool.title)")
        .testAnchor("Инструмент \(tool.title)")
    }
}

extension UTType {
    /// Инструмент, который перетаскивают в настройке панели (объявлен в Info.plist).
    static let shtorkaTool = UTType(exportedAs: "local.shtorka.tool")
}

private struct ToolDropDelegate: DropDelegate {
    let target: Tool
    let tools: ToolSettings
    @Binding var dragging: Tool?

    func dropEntered(info: DropInfo) {
        guard let dragging, dragging != target else { return }
        tools.move(dragging, to: target)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        return true
    }
}

// MARK: - Карточки

private let cardCorner = RoundedRectangle(cornerRadius: 11, style: .continuous)

/// Общая рамка карточки: скругление, подсветка при наведении, крестик в углу.
private struct CardChrome: ViewModifier {
    let hovering: Bool
    let closeHover: Bool
    var showsClose = true
    /// nil — у карточки нет закрепления (скриншоты, полка, порты).
    var pinned: Bool? = nil
    var pinHover = false
    var showsShelfButton = false
    var shelfHover = false

    func body(content: Content) -> some View {
        content
            .frame(width: Layout.thumbSize.width, height: Layout.thumbSize.height)
            .clipShape(cardCorner)
            .overlay(cardCorner.strokeBorder(borderColor, lineWidth: hovering || pinned == true ? 1.5 : 1))
            .overlay(alignment: .topTrailing) {
                if showsClose {
                    CloseBadge(highlighted: closeHover)
                        .padding(6)
                        .opacity(hovering ? 1 : 0)
                        .scaleEffect(hovering ? 1 : 0.6)
                }
            }
            .overlay(alignment: .topLeading) {
                if let pinned {
                    PinBadge(pinned: pinned, highlighted: pinHover)
                        .padding(6)
                        .opacity(pinned || hovering ? 1 : 0)
                        .scaleEffect(pinned || hovering ? 1 : 0.6)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if showsShelfButton {
                    ShelfBadge(highlighted: shelfHover)
                        .padding(6)
                        .opacity(hovering ? 1 : 0)
                        .scaleEffect(hovering ? 1 : 0.6)
                }
            }
            .scaleEffect(hovering ? 1.035 : 1)
            .animation(.easeOut(duration: 0.14), value: hovering)
            .animation(.easeOut(duration: 0.1), value: closeHover)
            .animation(.easeOut(duration: 0.1), value: pinHover)
            .animation(.easeOut(duration: 0.1), value: shelfHover)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: pinned)
    }

    private var borderColor: Color {
        if pinned == true { return Color.yellow.opacity(hovering ? 0.9 : 0.6) }
        return Color.white.opacity(hovering ? 0.55 : 0.1)
    }
}

struct ShotCell: View {
    let shot: Shot
    let actions: PanelActions
    var previewHover = false
    @State private var image: NSImage?
    @State private var hovering = false
    @State private var closeHover = false

    init(shot: Shot, actions: PanelActions, previewHover: Bool = false) {
        self.shot = shot
        self.actions = actions
        self.previewHover = previewHover
        _image = State(initialValue: ThumbCache.shared.cached(shot))
    }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Color.white.opacity(0.06)
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: Layout.thumbSize.width, height: Layout.thumbSize.height)
                    .clipped()
            } else {
                Image(systemName: shot.isVideo ? "film" : "photo")
                    .font(.system(size: 20))
                    .foregroundStyle(.white.opacity(0.25))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            LinearGradient(colors: [.clear, .black.opacity(0.6)], startPoint: .center, endPoint: .bottom)
            CardFooter(symbol: shot.isVideo ? "play.fill" : nil, date: shot.date, onLight: false)
        }
        .modifier(CardChrome(hovering: hovering || previewHover, closeHover: closeHover))
        .overlay {
            if !Preview.isActive {
                CardInteraction(
                    preview: image,
                    writers: { [shot.url as NSURL] },
                    onHover: { hovering = $0 },
                    onCloseHover: { closeHover = $0 },
                    onClick: { actions.copy(shot) },
                    onDoubleClick: { actions.open(shot) },
                    onClose: { actions.trash(shot) },
                    onDragChanged: { actions.onDragChanged($0) },
                    makeMenu: { actions.menu(for: shot) }
                )
            }
        }
        .task(id: shot) {
            if image == nil { image = await ThumbCache.shared.load(shot, size: Layout.thumbSize) }
        }
    }
}

struct ClipCell: View {
    let item: ClipItem
    let actions: PanelActions
    var previewHover = false
    @State private var hovering = false
    @State private var closeHover = false
    @State private var pinHover = false
    @State private var shelfHover = false
    @State private var fileImage: NSImage?

    init(item: ClipItem, actions: PanelActions, previewHover: Bool = false) {
        self.item = item
        self.actions = actions
        self.previewHover = previewHover
        _fileImage = State(initialValue: item.fileURLs.flatMap { ThumbCache.shared.cached(url: $0[0]) })
    }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            content
            if let urls = item.fileURLs {
                FileFooter(urls: urls, date: item.date)
            } else {
                CardFooter(symbol: item.symbol, date: item.date, onLight: item.color?.isLight ?? false,
                           dimmed: !isVisual)
            }
        }
        .modifier(CardChrome(hovering: hovering || previewHover, closeHover: closeHover,
                             pinned: item.pinned, pinHover: pinHover,
                             showsShelfButton: item.canGoOnShelf, shelfHover: shelfHover))
        .overlay {
            if !Preview.isActive {
                CardInteraction(
                    preview: fileImage ?? item.dragPreview,
                    writers: { item.pasteboardWriters },
                    onHover: { hovering = $0 },
                    onCloseHover: { closeHover = $0 },
                    onClick: { actions.recopy(item) },
                    onClose: { actions.removeClip(item) },
                    onPin: { actions.togglePin(item) },
                    onPinHover: { pinHover = $0 },
                    onAccessory: item.canGoOnShelf ? { actions.putOnShelf(item) } : nil,
                    onAccessoryHover: { shelfHover = $0 },
                    onDragChanged: { actions.onDragChanged($0) },
                    makeMenu: { actions.menu(for: item) }
                )
            }
        }
    }

    private var isVisual: Bool {
        if case .image = item.kind { return true }
        return item.color != nil
    }

    @ViewBuilder
    private var content: some View {
        switch item.kind {
        case .image(let preview, _, _):
            Color.white.opacity(0.06)
            Image(nsImage: preview)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: Layout.thumbSize.width, height: Layout.thumbSize.height)
                .clipped()
            LinearGradient(colors: [.clear, .black.opacity(0.6)], startPoint: .center, endPoint: .bottom)

        case .files(let urls):
            FileThumbnail(url: urls[0], image: $fileImage)
            LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .center, endPoint: .bottom)

        case .text:
            if let color = item.color {
                Color(nsColor: color)
                Text(item.text?.uppercased() ?? "")
                    .font(.system(size: 15, weight: .bold, design: .monospaced))
                    .foregroundStyle(color.isLight ? Color.black.opacity(0.75) : Color.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let url = item.webURL {
                VStack(alignment: .leading, spacing: 3) {
                    Text(url.host ?? "")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.92))
                        .lineLimit(1)
                    Text(url.path.isEmpty ? url.absoluteString : url.path)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.white.opacity(0.5))
                        .lineLimit(3)
                }
                .padding(.horizontal, 10)
                .padding(.top, 10)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(Color.accentColor.opacity(0.18))
            } else {
                Text(item.text ?? "")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.88))
                    .lineLimit(4)
                    .multilineTextAlignment(.leading)
                    .padding(.horizontal, 10)
                    .padding(.top, 9)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .background(Color.white.opacity(0.07))
            }
        }
    }
}

/// Файл или стопка файлов на полке.
struct ShelfCell: View {
    let item: ShelfItem
    let actions: PanelActions
    @State private var image: NSImage?
    @State private var hovering = false
    @State private var closeHover = false

    init(item: ShelfItem, actions: PanelActions) {
        self.item = item
        self.actions = actions
        _image = State(initialValue: ThumbCache.shared.cached(url: item.urls[0]))
    }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            FileThumbnail(url: item.urls[0], image: $image)
            LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .center, endPoint: .bottom)
            FileFooter(urls: item.urls)
        }
        .modifier(CardChrome(hovering: hovering, closeHover: closeHover))
        .overlay {
            if !Preview.isActive {
                CardInteraction(
                    preview: image ?? NSWorkspace.shared.icon(forFile: item.urls[0].path),
                    writers: { item.urls.map { $0 as NSURL } },
                    onHover: { hovering = $0 },
                    onCloseHover: { closeHover = $0 },
                    onClick: { actions.copy(item) },
                    onDoubleClick: { actions.open(item) },
                    onClose: { actions.removeFromShelf(item) },
                    onDragChanged: { actions.onDragChanged($0) },
                    makeMenu: { actions.menu(for: item) }
                )
            }
        }
    }
}

/// Превью файла: картинки и видео — на всю карточку, документы — страницей, остальное — иконкой.
private struct FileThumbnail: View {
    let url: URL
    @Binding var image: NSImage?

    private var isPicture: Bool {
        UTType(filenameExtension: url.pathExtension).map { $0.conforms(to: .image) || $0.conforms(to: .movie) } ?? false
    }

    var body: some View {
        ZStack {
            Color.white.opacity(0.07)
            if let image {
                if isPicture {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: Layout.thumbSize.width, height: Layout.thumbSize.height)
                        .clipped()
                } else {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .padding(.top, 10)
                        .padding(.bottom, 24)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                    .resizable()
                    .frame(width: 44, height: 44)
                    .padding(.bottom, 14)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: Layout.thumbSize.width, height: Layout.thumbSize.height)
        .task(id: url) {
            if image == nil { image = await ThumbCache.shared.load(url: url, size: Layout.thumbSize) }
        }
    }
}

/// Подпись файловой карточки: «Договор.pdf» или «3 файла», для буфера — ещё и время.
private struct FileFooter: View {
    let urls: [URL]
    var date: Date? = nil

    var body: some View {
        HStack(spacing: 4) {
            if urls.count > 1 { Image(systemName: "square.stack.fill").font(.system(size: 8, weight: .bold)) }
            Text(ShelfItem.title(for: urls)).lineLimit(1).truncationMode(.middle)
            if let date {
                Text(verbatim: "· \(date.shelfLabel)").opacity(0.6).fixedSize()
            }
        }
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(.white.opacity(0.92))
        .padding(.leading, 7)
        .padding(.trailing, 26)   // справа место для кнопки «На полку»
        .padding(.vertical, 5)
    }
}

/// Запущенный локальный сервер: клик — открыть в браузере, крестик — остановить.
struct PortCell: View {
    let server: DevServer
    let actions: PanelActions
    @State private var hovering = false
    @State private var closeHover = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                Circle().fill(Color.green).frame(width: 6, height: 6)
                Text("localhost").font(.system(size: 10, weight: .medium)).foregroundStyle(.white.opacity(0.45))
            }
            Text(verbatim: ":\(server.port)")
                .font(.system(size: 21, weight: .bold, design: .monospaced))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Spacer(minLength: 0)
            Text(server.kind)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(1)
            Text(server.subtitle)
                .font(.system(size: 10.5))
                .foregroundStyle(.white.opacity(0.5))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.white.opacity(0.07))
        .modifier(CardChrome(hovering: hovering, closeHover: closeHover, showsClose: server.canStop))
        .overlay {
            if !Preview.isActive {
                CardInteraction(
                    preview: nil,
                    writers: { [server.url as NSURL] },
                    onHover: { hovering = $0 },
                    onCloseHover: { closeHover = $0 },
                    onClick: { actions.open(server) },
                    onClose: server.canStop ? { actions.stop(server) } : nil,
                    onDragChanged: { actions.onDragChanged($0) },
                    makeMenu: { actions.menu(for: server) }
                )
            }
        }
        .help(server.canStop ? "Клик — открыть в браузере, крестик — остановить" : "Клик — открыть в браузере")
    }
}

/// Кнопка «Положить на полку» в углу карточки буфера.
private struct ShelfBadge: View {
    let highlighted: Bool

    var body: some View {
        Image(systemName: "tray.and.arrow.down.fill")
            .font(.system(size: 8.5, weight: .bold))
            .foregroundStyle(highlighted ? Color.black : Color.white)
            .frame(width: 18, height: 18)
            .background(Circle().fill(highlighted ? Color.white : Color.black.opacity(0.72)))
            .overlay(Circle().strokeBorder(Color.white.opacity(highlighted ? 0 : 0.25), lineWidth: 0.5))
    }
}

private struct PinBadge: View {
    let pinned: Bool
    let highlighted: Bool

    var body: some View {
        Image(systemName: pinned ? "pin.fill" : "pin")
            .font(.system(size: 8.5, weight: .bold))
            .rotationEffect(.degrees(45))
            .foregroundStyle(pinned ? Color.black : (highlighted ? Color.black : Color.white))
            .frame(width: 18, height: 18)
            .background(Circle().fill(pinned ? Color.yellow : (highlighted ? Color.white : Color.black.opacity(0.72))))
            .overlay(Circle().strokeBorder(Color.white.opacity(pinned || highlighted ? 0 : 0.25), lineWidth: 0.5))
    }
}

/// Подсказка, когда над шторкой держат файл.
private struct DropHint: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 22, style: .continuous)
            .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [7, 5]))
            .foregroundStyle(Color.white.opacity(0.7))
            .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Color.black.opacity(0.82)))
            .overlay {
                VStack(spacing: 8) {
                    Image(systemName: "tray.and.arrow.down.fill").font(.system(size: 28, weight: .semibold))
                    Text("Отпусти — положу на полку").font(.system(size: 14, weight: .semibold))
                }
                .foregroundStyle(.white)
            }
            .padding(10)
            .allowsHitTesting(false)
    }
}

private struct CardFooter: View {
    let symbol: String?
    let date: Date
    var onLight = false
    var dimmed = false

    var body: some View {
        HStack(spacing: 4) {
            if let symbol { Image(systemName: symbol).font(.system(size: 8, weight: .bold)) }
            Text(date.shelfLabel)
        }
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(onLight ? Color.black.opacity(0.6) : Color.white.opacity(dimmed ? 0.45 : 0.92))
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
    }
}

private struct CloseBadge: View {
    let highlighted: Bool

    var body: some View {
        Image(systemName: "xmark")
            .font(.system(size: 8, weight: .heavy))
            .foregroundStyle(highlighted ? Color.black : Color.white)
            .frame(width: 18, height: 18)
            .background(Circle().fill(highlighted ? Color.white : Color.black.opacity(0.72)))
            .overlay(Circle().strokeBorder(Color.white.opacity(highlighted ? 0 : 0.25), lineWidth: 0.5))
    }
}

private struct EmptyShelf: View {
    let symbol: String
    let title: String
    let subtitle: String

    var body: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
            .foregroundStyle(.white.opacity(0.18))
            .overlay {
                VStack(spacing: 5) {
                    Image(systemName: symbol)
                        .font(.system(size: 18))
                        .foregroundStyle(.white.opacity(0.4))
                    Text(title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.75))
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.4))
                }
            }
    }
}

// MARK: - Шапка: вкладки и кнопки

private struct TabSwitcher: View {
    @Binding var tab: PanelTab
    let counts: [PanelTab: Int]
    @Namespace private var namespace

    var body: some View {
        HStack(spacing: 2) {
            ForEach(PanelTab.allCases, id: \.self) { value in
                TabButton(tab: value, count: counts[value] ?? 0, selected: tab == value, namespace: namespace) {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { tab = value }
                }
            }
        }
        .padding(2)
        .background(Capsule().fill(Color.white.opacity(0.08)))
    }
}

/// Выбранная вкладка — со значком и названием, остальные — значок и число (название во всплывающей подсказке).
private struct TabButton: View {
    let tab: PanelTab
    let count: Int
    let selected: Bool
    let namespace: Namespace.ID
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: tab.symbol).font(.system(size: 11, weight: .semibold))
                if selected {
                    Text(tab.title).font(.system(size: 11.5, weight: .semibold)).fixedSize()
                } else if count > 0 {
                    Text(verbatim: count > 99 ? "99+" : "\(count)")
                        .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                        .opacity(0.55)
                }
            }
            .foregroundStyle(selected ? Color.black : Color.white.opacity(hovering ? 1 : 0.7))
            .padding(.horizontal, selected ? 9 : 7)
            .padding(.vertical, 4)
            .background {
                if selected {
                    Capsule().fill(Color.white).matchedGeometryEffect(id: "tab", in: namespace)
                } else if hovering {
                    Capsule().fill(Color.white.opacity(0.14))
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .help(tab.title)
        .accessibilityLabel("Вкладка \(tab.title)")
        .testAnchor("Вкладка \(tab.title)")
    }
}

struct PillButton: View {
    enum Style { case normal, prominent, destructive }

    let symbol: String
    let title: String
    var style: Style = .normal
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 10, weight: .semibold))
                Text(title).font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(style == .prominent ? Color.black : Color.white.opacity(style == .destructive ? 1 : 0.85))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(background))
            .contentShape(Capsule())
        }
        .buttonStyle(PressStyle())
        .onHover { hovering = $0 }
        .pointingHandCursor()
        .accessibilityLabel(title)
        .testAnchor(title)
    }

    private var background: Color {
        switch style {
        case .normal: return Color.white.opacity(hovering ? 0.16 : 0.08)
        case .prominent: return Color.white.opacity(hovering ? 0.85 : 1)
        case .destructive: return Color.red.opacity(hovering ? 1 : 0.85)
        }
    }
}

// MARK: - Мелкие компоненты

struct ControlTile: View {
    let symbol: String
    let title: String
    var isOn = false
    /// Цвет включённой плитки; на белом — чёрный текст, на цветном — белый.
    var onColor: Color = .white
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 17, weight: .medium))
                    .frame(height: 20)
                    .contentTransition(.symbolEffect(.replace))
                Text(title)
                    .font(.system(size: 10.5, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(isOn ? (onColor == .white ? Color.black : Color.white) : Color.white.opacity(0.9))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .fill(isOn ? onColor : Color.white.opacity(hovering ? 0.15 : 0.08))
            )
            .contentShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
        }
        .buttonStyle(PressStyle())
        .onHover { hovering = $0 }
        .pointingHandCursor()
        .accessibilityLabel(title)
        .testAnchor(title)
        .animation(.easeOut(duration: 0.15), value: isOn)
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

struct IconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: 26, height: 24)
                .background(Circle().fill(Color.white.opacity(hovering ? 0.16 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .onHover { hovering = $0 }
        .pointingHandCursor()
        .help(help)
        .accessibilityLabel(help)
        .testAnchor(help)
    }
}

struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

struct ToastView: View {
    let toast: Toast

    var body: some View {
        HStack(spacing: 8) {
            if let color = toast.color {
                Circle()
                    .fill(Color(nsColor: color))
                    .frame(width: 16, height: 16)
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.4), lineWidth: 1))
            } else {
                Image(systemName: toast.symbol).font(.system(size: 12, weight: .semibold))
            }
            Text(toast.text).font(.system(size: 12.5, weight: .semibold))
        }
        .foregroundStyle(.black)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(Capsule().fill(Color.white))
        .shadow(color: .black.opacity(0.4), radius: 12, y: 4)
    }
}

extension NSColor {
    var isLight: Bool {
        guard let c = usingColorSpace(.sRGB) else { return false }
        return 0.299 * c.redComponent + 0.587 * c.greenComponent + 0.114 * c.blueComponent > 0.6
    }
}

extension Date {
    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.dateFormat = "HH:mm"
        return f
    }()

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.dateFormat = "d MMM"
        return f
    }()

    /// «сейчас», «5 мин», «14:05», «вчера», «12 сент.»
    var shelfLabel: String {
        let seconds = Date().timeIntervalSince(self)
        if seconds < 60 { return "сейчас" }
        if seconds < 3600 { return "\(Int(seconds / 60)) мин" }
        let calendar = Calendar.current
        if calendar.isDateInToday(self) { return Date.timeFormatter.string(from: self) }
        if calendar.isDateInYesterday(self) { return "вчера" }
        return Date.dayFormatter.string(from: self)
    }
}
