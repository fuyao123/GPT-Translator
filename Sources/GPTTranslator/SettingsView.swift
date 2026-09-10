import AppKit
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var viewModel: TranslationViewModel
    @EnvironmentObject private var globalController: GlobalTranslationController
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ScrollView {
                Form {
                Section("翻译服务") {
                    Picker("服务", selection: Binding(
                        get: { viewModel.provider },
                        set: { viewModel.selectProvider($0) }
                    )) {
                        ForEach(ModelProvider.allCases) { provider in
                            Text(provider.displayName).tag(provider)
                        }
                    }

                    if viewModel.provider == .openAIChatGPT {
                        HStack {
                            Label(
                                viewModel.isLoggedIn ? "已通过 ChatGPT OAuth 登录" : "尚未登录 ChatGPT",
                                systemImage: viewModel.isLoggedIn ? "checkmark.circle.fill" : "person.crop.circle"
                            )
                            .foregroundStyle(viewModel.isLoggedIn ? .green : .secondary)
                            Spacer()
                            Button(viewModel.isLoggingIn ? "登录中…" : "使用 ChatGPT 登录") {
                                viewModel.loginWithChatGPT()
                            }
                            .disabled(viewModel.isLoggingIn)
                            .buttonStyle(.borderedProminent)
                        }
                        Text("登录会打开浏览器完成 OAuth，并复用本机 Codex CLI 会话。应用不会要求或保存 OpenAI API Key。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if viewModel.provider == .antigravityOAuth {
                        Label(
                            viewModel.providerReady ? "已找到官方 Antigravity CLI" : "未找到 Antigravity CLI（agy）",
                            systemImage: viewModel.providerReady ? "checkmark.circle.fill" : "terminal"
                        )
                        .foregroundStyle(viewModel.providerReady ? .green : .secondary)
                        Text("使用 agy 自己管理的 Google OAuth 登录会话。应用不会读取、复制或打包 OAuth Token；当前固定使用 \(ModelProvider.antigravityFastModel)（低推理）以优先降低翻译延迟。首次使用请先在终端运行 agy 完成 Google 登录。连接测试会发出一次极短请求，并可能受 Google 地区与额度限制。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if viewModel.provider == .appleTranslation {
                        Label("无需账号或 API Key", systemImage: "apple.logo")
                            .foregroundStyle(.secondary)
                        Text("使用系统翻译语言包，本地处理且不消耗云端 token。缺少语言包时，请先在系统“翻译”App 或系统设置中下载；下载完成后即可离线使用。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if viewModel.provider == .googleWeb {
                        Label("无需账号或 API Key", systemImage: "globe")
                            .foregroundStyle(.secondary)
                        Text("使用 Google 网页翻译的非官方公共接口，可能受网络环境或请求频率限制；HTTP 429 时请切换其他翻译源。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        if viewModel.provider == .customAPI {
                            HStack {
                                Picker("配置", selection: Binding(
                                    get: { viewModel.selectedCustomAPIID },
                                    set: { if let id = $0 { viewModel.selectCustomAPI(id) } }
                                )) {
                                    ForEach(viewModel.customAPISources) { source in
                                        Text(source.displayName).tag(Optional(source.id))
                                    }
                                }
                                Button("添加", systemImage: "plus") { viewModel.addCustomAPI() }
                                Button("删除", systemImage: "trash") { viewModel.deleteSelectedCustomAPI() }
                                    .disabled(viewModel.customAPISources.count <= 1)
                            }
                            TextField("显示名称，例如 Gemini", text: $viewModel.customAPIDisplayName)
                                .textFieldStyle(.roundedBorder)
                            TextField("接口地址，例如 https://example.com/v1/chat/completions", text: $viewModel.customAPIEndpoint)
                                .textFieldStyle(.roundedBorder)
                        }
                        SecureField("\(viewModel.provider.shortName) API Key", text: $viewModel.apiKey)
                            .textFieldStyle(.roundedBorder)
                        Button("重新授权钥匙串读取", systemImage: "key") {
                            viewModel.authorizeSelectedAPIKeyFromKeychain()
                        }
                        .help("仅在你主动点击时显示钥匙串授权；启动和后台检测不会弹窗")
                        Text(credentialHelp)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if viewModel.provider.supportsModelSelection {
                    Section("模型与推理") {
                    Picker("预设模型", selection: Binding(
                        get: {
                            viewModel.provider.modelOptions.contains(viewModel.modelName) ? viewModel.modelName : ""
                        },
                        set: { if !$0.isEmpty { viewModel.modelName = $0 } }
                    )) {
                        Text("自定义模型…").tag("")
                        ForEach(viewModel.provider.modelOptions, id: \.self) { model in
                            Text(model).tag(model)
                        }
                    }
                    TextField("模型名称", text: $viewModel.modelName)
                        .textFieldStyle(.roundedBorder)
                    Picker("推理强度", selection: $viewModel.reasoningEffort) {
                        ForEach(ReasoningEffort.allCases) { effort in
                            Text(effort.displayName).tag(effort)
                        }
                    }
                    Text("Codex OAuth、DeepSeek、智谱和自定义兼容 API 会使用所选模型及 reasoning_effort 参数。Antigravity OAuth 使用 agy 当前账号可用的 Gemini 模型。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Section("系统权限") {
                    HStack {
                        Label(
                            globalController.accessibilityTrusted ? "辅助功能权限已允许" : "需要辅助功能权限",
                            systemImage: globalController.accessibilityTrusted ? "checkmark.shield.fill" : "lock.shield"
                        )
                        .foregroundStyle(globalController.accessibilityTrusted ? .green : .secondary)
                        Spacer()
                        Button("检查并打开设置") {
                            globalController.requestAccessibilityPermission()
                        }
                    }
                    Text("划词翻译需要辅助功能权限；截图翻译首次使用时，macOS 还会请求屏幕录制权限。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Section("应用显示") {
                    Toggle("在 Dock 中显示应用", isOn: $globalController.showInDock)
                    Toggle("登录时自动启动", isOn: $globalController.launchAtLogin)
                    Text("隐藏 Dock 图标后仍可通过菜单栏图标打开主窗口和设置；自动启动由 macOS 登录项管理。当前状态：\(globalController.launchAtLoginStatusDescription)。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Section("划词翻译") {
                    Toggle("启用划词监听", isOn: $globalController.selectionEnabled)
                    Picker("选中后操作", selection: Binding(
                        get: { globalController.selectionTriggerMode },
                        set: { globalController.selectionTriggerMode = $0 }
                    )) {
                        ForEach(SelectionTriggerMode.allCases) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    Toggle("自动判断中英文翻译方向", isOn: $viewModel.translateEnglishSelectionToChinese)
                    Text("检测到英文时译成中文，检测到中文时译成英文。是否处理中文可在菜单栏中快速切换。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Section("快捷键") {
                    shortcutPicker(
                        title: "划词翻译",
                        modifiers: $globalController.translateShortcutModifiers,
                        key: $globalController.translateShortcutKey
                    )
                    shortcutPicker(
                        title: "截图翻译（OCR）",
                        modifiers: $globalController.screenshotShortcutModifiers,
                        key: $globalController.screenshotShortcutKey
                    )
                    shortcutPicker(
                        title: "普通截图",
                        modifiers: $globalController.captureShortcutModifiers,
                        key: $globalController.captureShortcutKey
                    )
                    shortcutPicker(
                        title: "快捷翻译输入框",
                        modifiers: $globalController.quickInputShortcutModifiers,
                        key: $globalController.quickInputShortcutKey
                    )
                    Text("菜单栏会显示普通截图、截图翻译和快捷翻译输入框的当前快捷键；划词翻译快捷键仍可在此自定义。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if globalController.hasShortcutConflict {
                        Label("四个功能不能使用相同的快捷键。", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }

                Section("悬浮窗结果来源") {
                    ForEach(viewModel.allTranslationSources) { source in
                        Toggle(source.displayName, isOn: Binding(
                            get: { viewModel.isFloatingSourceEnabled(source) },
                            set: { viewModel.setFloatingSource(source, enabled: $0) }
                        ))
                    }
                    Text("至少保留一个来源。划词和截图翻译会并行请求已勾选的来源；云服务需要先切换到对应服务并保存凭据。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                }
                .fixedSize(horizontal: false, vertical: true)
            }

            if let errorMessage = viewModel.errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .font(.callout)
            }

            HStack {
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.escape)
                Button("保存") {
                    viewModel.saveSettings()
                    if globalController.saveSelectionPreferences() {
                        dismiss()
                    }
                }
                .disabled(globalController.hasShortcutConflict)
                .keyboardShortcut(.return)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 680, height: 560)
        .onAppear {
            viewModel.refreshLoginStatus()
            globalController.refreshAccessibilityStatus()
            globalController.refreshLaunchAtLoginStatus()
        }
    }

    private var credentialHelp: String {
        viewModel.provider == .customAPI
            ? "支持 OpenAI Chat Completions 兼容接口；API Key 只保存在本机钥匙串中。"
            : "API Key 只保存在本机钥匙串中。"
    }

    private func shortcutPicker(
        title: String,
        modifiers: Binding<ShortcutModifiers>,
        key: Binding<ShortcutKey>
    ) -> some View {
        HStack {
            Text(title)
            Spacer()
            Picker("组合键", selection: modifiers) {
                ForEach(ShortcutModifiers.allCases) { option in
                    Text(option.symbols).tag(option)
                }
            }
            .labelsHidden()
            .frame(width: 90)
            Picker("按键", selection: key) {
                ForEach(ShortcutKey.allCases) { option in
                    Text(option.displayName).tag(option)
                }
            }
            .labelsHidden()
            .frame(width: 70)
        }
    }

}
