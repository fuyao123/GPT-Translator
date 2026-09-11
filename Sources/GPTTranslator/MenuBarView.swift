import AppKit
import SwiftUI

private let menuActionColor = Color(nsColor: .labelColor)
private let menuPreferenceColor = Color(nsColor: .secondaryLabelColor)
private let menuShortcutColor = Color(nsColor: .tertiaryLabelColor)

private struct MenuCaptureIcon: View {
    enum Kind {
        case capture
        case translation
        case ocr
        case quickInput
    }

    let kind: Kind

    var body: some View {
        ZStack {
            switch kind {
            case .capture:
                Image(systemName: "camera.viewfinder")
            case .translation:
                Image(systemName: "doc.text.viewfinder")
            case .ocr:
                Image(systemName: "character.bubble")
            case .quickInput:
                Image(systemName: "text.magnifyingglass")
            }
        }
        .font(.system(size: 16, weight: .regular))
        .foregroundStyle(menuActionColor)
        .frame(width: 20, height: 20)
    }
}

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
                columns: Array(
                    repeating: GridItem(.flexible(minimum: 0), spacing: 8, alignment: .leading),
                    count: 3
                ),
                alignment: .leading,
                spacing: 6
            ) {
                ForEach(viewModel.enabledFloatingSources) { source in
                    let state = viewModel.connectionState(for: source)
                    HStack(spacing: 5) {
                        Circle()
                            .fill(statusColor(for: state))
                            .frame(width: 7, height: 7)
                        Text(source.displayName)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.82)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel("\(source.displayName)，\(statusText(for: state))")
                    .help(statusHelp(for: state))
                }
            }
            .font(.caption)

            Divider()

            Toggle(isOn: Binding(
                get: { globalController.selectionEnabled },
                set: {
                    globalController.setSelectionTranslationEnabled($0)
                }
            )) {
                HStack(spacing: 6) {
                    Text("启用划词翻译")
                    Text(globalController.translateShortcutDescription)
                        .foregroundStyle(menuShortcutColor)
                }
            }
            .foregroundStyle(menuPreferenceColor)

            Toggle("翻译中文内容", isOn: Binding(
                get: { viewModel.translateChineseContent },
                set: {
                    viewModel.setTranslateChineseContent($0)
                }
            ))
            .foregroundStyle(menuPreferenceColor)
            .help("关闭后，划词和截图识别到中文时不调用翻译接口")

            Button {
                globalController.captureScreenshot()
            } label: {
                HStack(spacing: 6) {
                    MenuCaptureIcon(kind: .capture)
                    Text("普通截图")
                        .foregroundStyle(menuActionColor)
                    Text(globalController.captureShortcutDescription)
                        .foregroundStyle(menuShortcutColor)
                }
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .disabled(globalController.isCapturing)
            .buttonStyle(.plain)

            Button {
                globalController.translateScreenshot()
            } label: {
                HStack(spacing: 6) {
                    MenuCaptureIcon(kind: .translation)
                    Text(globalController.isCapturing ? "截图处理中…" : "截图翻译")
                        .foregroundStyle(menuActionColor)
                    Text(globalController.screenshotShortcutDescription)
                        .foregroundStyle(menuShortcutColor)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .disabled(globalController.isCapturing)
            .buttonStyle(.plain)

            Button {
                globalController.recognizeScreenshot()
            } label: {
                HStack(spacing: 6) {
                    MenuCaptureIcon(kind: .ocr)
                    Text("截图 OCR")
                        .foregroundStyle(menuActionColor)
                    Text(globalController.ocrShortcutDescription)
                        .foregroundStyle(menuShortcutColor)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .disabled(globalController.isCapturing)
            .buttonStyle(.plain)

            Button {
                globalController.toggleQuickTranslationInput()
            } label: {
                HStack(spacing: 6) {
                    MenuCaptureIcon(kind: .quickInput)
                    Text("快捷翻译输入框")
                        .foregroundStyle(menuActionColor)
                    Text(globalController.quickInputShortcutDescription)
                        .foregroundStyle(menuShortcutColor)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)

            Divider()

            Button("打开主窗口", systemImage: "macwindow") { showMainWindow() }
                .buttonStyle(.borderless)
                .foregroundStyle(menuActionColor)
            Button("设置", systemImage: "gearshape") { showSettings() }
                .buttonStyle(.borderless)
                .foregroundStyle(menuActionColor)

            HStack {
                Button("退出", systemImage: "power") { NSApp.terminate(nil) }
                    .buttonStyle(.borderless)
                    .foregroundStyle(menuActionColor)
                Spacer()
                updateControl
            }
        }
        .padding(14)
        .frame(width: 310)
        .onAppear {
            globalController.connect(to: viewModel)
            viewModel.startConnectionMonitoring()
            Task { await viewModel.checkForUpdates() }
        }
    }

    @ViewBuilder
    private var updateControl: some View {
        switch viewModel.updateState {
        case .idle:
            Button("检查更新") {
                Task { await viewModel.checkForUpdates(force: true) }
            }
            .buttonStyle(.borderless)
        case .checking:
            HStack(spacing: 5) {
                ProgressView().controlSize(.small)
                Text("检查更新…")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        case .upToDate:
            Button("已是最新版 · v\(viewModel.currentAppVersion)") {
                Task { await viewModel.checkForUpdates(force: true) }
            }
            .buttonStyle(.borderless)
            .font(.caption)
            .foregroundStyle(.secondary)
            .help("点击重新检查更新")
        case .available(let release):
            Button {
                NSWorkspace.shared.open(release.pageURL)
            } label: {
                Label("发现 v\(release.version) 更新", systemImage: "arrow.down.circle.fill")
            }
            .buttonStyle(.borderless)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.blue)
            .help("打开 GitHub Releases 下载新版本")
        case .failed(let message):
            Button {
                Task { await viewModel.checkForUpdates(force: true) }
            } label: {
                Label("更新检查失败", systemImage: "exclamationmark.triangle")
            }
            .buttonStyle(.borderless)
            .font(.caption)
            .foregroundStyle(.orange)
            .help("\(message)；点击重试")
        }
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
        globalController.showSettingsWindow()
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
