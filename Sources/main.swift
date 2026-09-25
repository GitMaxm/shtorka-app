import AppKit

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let args = CommandLine.arguments

    // Служебные режимы для сборки: отрисовать превью панели или иконку в PNG.
    if let i = args.firstIndex(of: "--render-preview"), i + 1 < args.count {
        let tab = PanelTab.allCases.first { args.contains($0.title) } ?? .shots
        Preview.renderPanel(to: args[i + 1], tab: tab, editing: args.contains("settings"))
        exit(0)
    }
    if let i = args.firstIndex(of: "--render-icon"), i + 1 < args.count {
        Preview.renderIcon(to: args[i + 1])
        exit(0)
    }

    #if SELFTEST
    if let i = args.firstIndex(of: "--fullscreen-helper"), i + 1 < args.count {
        SelfTest.runFullscreenHelper(mode: args[i + 1])
    }
    if let i = args.firstIndex(of: "--selftest"), i + 1 < args.count {
        SelfTest.run(outDir: args[i + 1])
    }
    #endif

    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
    withExtendedLifetime(delegate) {}
}
