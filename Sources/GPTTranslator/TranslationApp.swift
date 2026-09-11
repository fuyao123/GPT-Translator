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
        HStack(spacing: 2) {
            Group {
                if let iconURL = Bundle.main.url(forResource: "MenuBarIcon", withExtension: "png"),
                   let icon = NSImage(contentsOf: iconURL) {
                    Image(nsImage: templateImage(icon))
                        .interpolation(.high)
                } else {
                    Image(systemName: "character.bubble.fill")
                        .resizable()
                        .scaledToFit()
                }
            }
            .frame(width: 20, height: 17)

            if !selectionEnabled {
                Text("关")
                    .font(.system(size: 9, weight: .bold))
                    .fixedSize()
            }
        }
        .id(selectionEnabled)
        .accessibilityLabel(selectionEnabled ? "AI 翻译助手，划词翻译已开启" : "AI 翻译助手，划词翻译已关闭")
    }

    private func templateImage(_ image: NSImage) -> NSImage {
        image.size = NSSize(width: 20, height: 17)
        image.isTemplate = true
        return image
    }
}
