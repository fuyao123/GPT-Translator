import AppKit
import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject private var viewModel: TranslationViewModel
    @EnvironmentObject private var globalController: GlobalTranslationController
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "character.bubble.fill")
                    .foregroundStyle(.tint)
                Text("GPT 翻译助手")
                    .font(.headline)
                Spacer()
                Button {
                    Task { await viewModel.testEnabledProviderConnections() }
                } label: {
                    if viewModel.isTestingConnections {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .buttonStyle(.borderless)
                .disabled(viewModel.isTestingConnections)
                .help("立即测试所有已开启的翻译源")
            }

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 105), spacing: 12, alignment: .leading)],
                alignment: .leading,
                spacing: 8
            ) {
                ForEach(viewModel.enabledFloatingSources) { source in
                    let state = viewModel.connectionState(for: source)
                    HStack(spacing: 7) {
                        Circle()
                            .fill(statusColor(for: state))
                            .frame(width: 8, height: 8)
                        Text("\(source.displayName) \(statusText(for: state))")
                            .foregroundStyle(statusColor(for: state))
                            .lineLimit(1)
                    }
                    .help(statusHelp(for: state))
                }
            }
            .font(.caption)

            Divider()

            Toggle("启用划词翻译", isOn: Binding(
                get: { globalController.selectionEnabled },
                set: {
                    globalController.selectionEnabled = $0
                    globalController.saveSelectionPreferences()
                }
            ))

            Button {
                globalController.translateSelection()
            } label: {
                Label("翻译所选文字", systemImage: "text.cursor")
            }

            Button {
                globalController.translateScreenshot()
            } label: {
                Label(globalController.isCapturing ? "截图处理中…" : "截图翻译（OCR）", systemImage: "viewfinder")
            }
            .disabled(globalController.isCapturing)

            Divider()

            Button("打开主窗口", systemImage: "macwindow") { showMainWindow() }
            Button("设置", systemImage: "gearshape") { showSettings() }
            Button("退出", systemImage: "power") { NSApp.terminate(nil) }
        }
        .padding(14)
        .frame(width: 310)
        .onAppear { viewModel.startConnectionMonitoring() }
    }

    private func showMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: "main")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows
                .first(where: { $0.canBecomeMain && $0.title == "GPT 翻译助手" })?
                .makeKeyAndOrderFront(nil)
        }
    }

    private func showSettings() {
        globalController.showingSettings = true
        showMainWindow()
    }

    private func statusColor(for state: ProviderConnectionState) -> Color {
        switch state {
        case .checking: return .orange
        case .connected: return .green
        case .disconnected: return .red
        }
    }

    private func statusText(for state: ProviderConnectionState) -> String {
        switch state {
        case .checking: return "测试中"
        case .connected: return "正常"
        case .disconnected: return "异常"
        }
    }

    private func statusHelp(for state: ProviderConnectionState) -> String {
        switch state {
        case .checking: return "正在进行真实连接测试"
        case .connected: return "最近一次真实连接测试成功；应用启动时测试，之后每小时复测"
        case .disconnected(let message): return message
        }
    }
}
