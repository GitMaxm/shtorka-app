import AppKit
import SwiftUI

/// Офлайн-рендер панели и иконки в PNG (используется build.sh и для проверки дизайна).
@MainActor
enum Preview {
    static var isActive = false

    static func renderPanel(to path: String, tab: PanelTab, editing: Bool) {
        let previewDir = FileManager.default.temporaryDirectory.appendingPathComponent("shtorka-preview")
        isActive = true
        let state = AppState()
        state.isOpen = true
        state.tab = tab
        state.editing = editing
        let tools = ToolSettings(defaults: UserDefaults(suiteName: "local.shtorka.preview")!)
        tools.reset()
        if editing { tools.toggle(.pipette) }
        state.keepAwake = true
        state.darkMode = true
        let store = ShotStore()
        let now = Date()
        let offsets: [TimeInterval] = [-25, -60 * 7, -60 * 95, -60 * 60 * 26, -60 * 60 * 50, -60 * 60 * 80]
        let palette: [(NSColor, NSColor)] = [
            (.systemIndigo, .systemPink), (.systemTeal, .systemBlue), (.systemOrange, .systemRed),
            (.systemGreen, .systemTeal), (.systemPurple, .systemIndigo), (.systemYellow, .systemOrange),
        ]
        let shots = offsets.enumerated().map { i, offset in
            Shot(url: URL(fileURLWithPath: "/tmp/preview-\(i).\(i == 2 ? "mov" : "png")"), date: now.addingTimeInterval(offset))
        }
        for (i, shot) in shots.enumerated() {
            ThumbCache.shared.store(fakeScreenshot(palette[i % palette.count]), for: shot)
        }
        store.setPreviewShots(shots)

        let clipboard = ClipboardStore(directory: previewDir.appendingPathComponent("pinned"))
        let now2 = Date()
        let colors = palette[0]
        let image = fakeScreenshot(colors)
        clipboard.setPreviewItems([
            ClipItem(date: now2.addingTimeInterval(-20), kind: .text("#FF5A36"), signature: "1"),
            ClipItem(date: now2.addingTimeInterval(-60 * 3),
                     kind: .text("Скинь, пожалуйста, макет главной до вечера — хочу успеть сверстать хедер и карточки"),
                     signature: "2"),
            ClipItem(date: now2.addingTimeInterval(-60 * 12), kind: .image(preview: image, data: Data(), type: .png), signature: "3"),
            ClipItem(date: now2.addingTimeInterval(-60 * 40),
                     kind: .text("https://github.com/vercel/next.js/pull/42"), signature: "4"),
            ClipItem(date: now2.addingTimeInterval(-60 * 90),
                     kind: .files([URL(fileURLWithPath: "/tmp/Договор.pdf")]), signature: "5"),
        ])

        let shelf = ShelfStore(directory: previewDir.appendingPathComponent("shelf"))
        shelf.setPreviewItems([
            ShelfItem(urls: [URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app")]),
            ShelfItem(urls: [URL(fileURLWithPath: "/tmp/Договор.pdf"), URL(fileURLWithPath: "/tmp/Смета.xlsx"),
                             URL(fileURLWithPath: "/tmp/Бриф.docx")]),
        ])
        let ports = PortsStore()
        ports.setPreviewServers([
            DevServer(pid: 1, port: 3000, command: "node", kind: "Next.js",
                      folder: URL(fileURLWithPath: "/Users/me/projects/my-site"), canStop: true),
            DevServer(pid: 2, port: 5173, command: "node", kind: "Vite",
                      folder: URL(fileURLWithPath: "/Users/me/projects/shop-front"), canStop: true),
            DevServer(pid: 3, port: 8090, command: "com.docker.backend", kind: "Docker", folder: nil, canStop: false),
        ])
        if tab == .clipboard { clipboard.togglePin(clipboard.items[2]) }
        let actions = PanelActions(state: state, store: store, clipboard: clipboard, shelf: shelf, ports: ports)
        let view = PanelView(state: state, store: store, clipboard: clipboard, tools: tools, shelf: shelf, ports: ports,
                             actions: actions, topInset: 38, notchWidth: 200)
            .padding(24)
            .background(Color.white)
        write(view, to: path)
    }

    static func renderIcon(to path: String) {
        let view = ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: 230, style: .continuous)
                .fill(LinearGradient(colors: [Color(white: 0.26), Color(white: 0.1)], startPoint: .top, endPoint: .bottom))
            UnevenRoundedRectangle(bottomLeadingRadius: 90, bottomTrailingRadius: 90, style: .continuous)
                .fill(Color.black)
                .frame(width: 720, height: 430)
                .overlay(alignment: .bottom) {
                    HStack(spacing: 34) {
                        ForEach(0..<3) { i in
                            RoundedRectangle(cornerRadius: 34, style: .continuous)
                                .fill([Color.pink, Color.teal, Color.orange][i].gradient)
                                .frame(width: 170, height: 118)
                        }
                    }
                    .padding(.bottom, 64)
                }
                .padding(.top, 100)
            Image(systemName: "chevron.compact.down")
                .font(.system(size: 150, weight: .bold))
                .foregroundStyle(.white.opacity(0.85))
                .padding(.top, 590)
        }
        .frame(width: 1024, height: 1024)
        .clipShape(RoundedRectangle(cornerRadius: 230, style: .continuous))
        .scaleEffect(824.0 / 1024.0)  // стандартные поля macOS-иконки
        .frame(width: 1024, height: 1024)
        write(view, to: path, scale: 1)
    }

    private static func write<V: View>(_ view: V, to path: String, scale: CGFloat = 2) {
        let renderer = ImageRenderer(content: view)
        renderer.scale = scale
        guard let cg = renderer.cgImage else {
            FileHandle.standardError.write("render failed\n".data(using: .utf8)!)
            exit(1)
        }
        let rep = NSBitmapImageRep(cgImage: cg)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }

    private static func fakeScreenshot(_ colors: (NSColor, NSColor)) -> NSImage {
        NSImage(size: NSSize(width: 300, height: 188), flipped: true) { rect in
            NSGradient(starting: colors.0, ending: colors.1)?.draw(in: rect, angle: 35)
            NSColor.white.withAlphaComponent(0.92).setFill()
            NSBezierPath(roundedRect: NSRect(x: 34, y: 26, width: 232, height: 136), xRadius: 10, yRadius: 10).fill()
            NSColor.black.withAlphaComponent(0.08).setFill()
            NSBezierPath(rect: NSRect(x: 34, y: 26, width: 232, height: 20)).fill()
            for (i, w) in [150.0, 190, 120, 170].enumerated() {
                NSColor.black.withAlphaComponent(0.14).setFill()
                NSBezierPath(roundedRect: NSRect(x: 50, y: 62 + Double(i) * 22, width: w, height: 9), xRadius: 4, yRadius: 4).fill()
            }
            return true
        }
    }
}
