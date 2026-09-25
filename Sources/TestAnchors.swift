import SwiftUI

extension View {
    /// В тестовой сборке запоминает, где на экране лежит элемент, чтобы самопроверка могла по нему кликнуть.
    /// В обычной сборке ничего не делает.
    @ViewBuilder
    func testAnchor(_ name: String) -> some View {
        #if SELFTEST
        background(GeometryReader { proxy in
            Color.clear
                .onAppear { TestAnchors.frames[name] = proxy.frame(in: .global) }
                .onChange(of: proxy.frame(in: .global)) { _, frame in TestAnchors.frames[name] = frame }
                .onDisappear { TestAnchors.frames[name] = nil }
        })
        #else
        self
        #endif
    }
}

#if SELFTEST
@MainActor
enum TestAnchors {
    static var frames: [String: CGRect] = [:]
}
#endif
