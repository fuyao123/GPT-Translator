import SwiftUI

@main
struct TranslationApp: App {
    @StateObject private var viewModel = TranslationViewModel()
    @StateObject private var globalController = GlobalTranslationController()

    var body: some Scene {
        WindowGroup("GPT 翻译助手", id: "main") {
            ContentView()
                .environmentObject(viewModel)
                .environmentObject(globalController)
                .frame(minWidth: 920, minHeight: 620)
                .onAppear {
                    globalController.connect(to: viewModel)
                    viewModel.startConnectionMonitoring()
                    Task { await viewModel.checkForUpdates() }
                }
        }
        .windowResizability(.contentSize)
        .commands {
            CommandMenu("显示") {
                Button("放大字体") { viewModel.increaseFontSize() }
                    .keyboardShortcut("+", modifiers: .command)
                Button("缩小字体") { viewModel.decreaseFontSize() }
                    .keyboardShortcut("-", modifiers: .command)
                Button("恢复默认字体") { viewModel.resetFontSize() }
                    .keyboardShortcut("0", modifiers: .command)
            }
        }

        MenuBarExtra {
            MenuBarView()
                .environmentObject(viewModel)
                .environmentObject(globalController)
        } label: {
            MenuBarTranslationIcon(selectionEnabled: globalController.selectionEnabled)
        }
        .menuBarExtraStyle(.window)
    }
}

private struct MenuBarTranslationIcon: View {
    let selectionEnabled: Bool

    var body: some View {
        Group {
            if let icon = renderedIcon(enabled: selectionEnabled) {
                Image(nsImage: icon)
                    .interpolation(.high)
            } else {
                Image(systemName: selectionEnabled ? "character.bubble.fill" : "character.bubble")
                    .resizable()
                    .scaledToFit()
            }
        }
        .frame(width: 20, height: 17)
        .id(selectionEnabled)
        .accessibilityLabel(selectionEnabled ? "AI 翻译助手，划词翻译已开启" : "AI 翻译助手，划词翻译已关闭")
    }

    private func renderedIcon(enabled: Bool) -> NSImage? {
        guard let iconURL = Bundle.main.url(forResource: "MenuBarIcon", withExtension: "png"),
              let source = NSImage(contentsOf: iconURL) else { return nil }

        let size = NSSize(width: 20, height: 17)
        let image = NSImage(size: size)
        image.lockFocus()
        source.draw(
            in: NSRect(origin: .zero, size: size),
            from: NSRect(origin: .zero, size: source.size),
            operation: .sourceOver,
            fraction: enabled ? 1 : 0.44,
            respectFlipped: true,
            hints: [.interpolation: NSImageInterpolation.high]
        )
        if !enabled {
            let slash = NSBezierPath()
            slash.move(to: NSPoint(x: 3.2, y: 2.2))
            slash.line(to: NSPoint(x: 16.8, y: 14.8))
            slash.lineWidth = 1.35
            NSColor.black.withAlphaComponent(0.88).setStroke()
            slash.stroke()
        }
        image.unlockFocus()
        image.isTemplate = true
        return image
    }
}
