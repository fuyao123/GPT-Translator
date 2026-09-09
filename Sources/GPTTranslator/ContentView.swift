import AppKit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var viewModel: TranslationViewModel
    @EnvironmentObject private var globalController: GlobalTranslationController

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            languageBar
            editorArea
            footer
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(isPresented: $globalController.showingSettings) {
            SettingsView()
                .environmentObject(viewModel)
                .environmentObject(globalController)
        }
        .onChange(of: viewModel.sourceText) { _ in
            viewModel.scheduleAutomaticTranslation()
        }
        .onChange(of: viewModel.sourceLanguage) { _ in
            viewModel.scheduleAutomaticTranslation(delayNanoseconds: 100_000_000)
        }
        .onChange(of: viewModel.targetLanguage) { _ in
            viewModel.scheduleAutomaticTranslation(delayNanoseconds: 100_000_000)
        }
    }

    private var header: some View {
        HStack {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .scaledToFit()
                .frame(width: 30, height: 30)
            Text("GPT 翻译助手")
                .font(.title2.weight(.semibold))
            Spacer()
            Button {
                globalController.showingSettings = true
            } label: {
                Label("设置", systemImage: "gearshape")
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    private var languageBar: some View {
        HStack(spacing: 12) {
            LanguagePicker(title: "原文", selection: $viewModel.sourceLanguage)
            Button(action: viewModel.swapLanguages) {
                Image(systemName: "arrow.left.arrow.right")
            }
            .buttonStyle(.borderless)
            .help("交换语言")
            LanguagePicker(title: "译文", selection: $viewModel.targetLanguage, excludesAuto: true)
            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
    }

    private var editorArea: some View {
        HStack(spacing: 16) {
            EditorCard(
                title: "原文",
                text: $viewModel.sourceText,
                placeholder: "输入或粘贴要翻译的内容…",
                fontSize: viewModel.resultFontSize,
                footer: {
                    Button("清空", systemImage: "xmark.circle") { viewModel.clear() }
                        .buttonStyle(.borderless)
                        .disabled(viewModel.sourceText.isEmpty && viewModel.translatedText.isEmpty)
                }
            )
            EditorCard(
                title: "译文",
                text: .constant(viewModel.translatedText),
                placeholder: "翻译结果会显示在这里…",
                fontSize: viewModel.resultFontSize,
                footer: {
                    Button("复制", systemImage: "doc.on.doc") { viewModel.copyTranslation() }
                        .buttonStyle(.borderless)
                        .disabled(viewModel.translatedText.isEmpty)
                }
            )
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 8)
    }

    private var footer: some View {
        VStack(spacing: 10) {
            if let errorMessage = viewModel.errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Picker("默认翻译源", selection: Binding(
                    get: { viewModel.activeSourceID },
                    set: { selectedID in
                        if let source = viewModel.allTranslationSources.first(where: { $0.id == selectedID }) {
                            viewModel.selectTranslationSource(source)
                            viewModel.saveSettings()
                        }
                    }
                )) {
                    ForEach(viewModel.allTranslationSources) { source in
                        Text(source.displayName).tag(source.id)
                    }
                }
                .pickerStyle(.menu)
                .fixedSize()
                .help("选择并保存主窗口的默认翻译源")

                Divider()
                    .frame(height: 18)

                if viewModel.isTranslating {
                    ProgressView()
                        .controlSize(.small)
                    Text("正在翻译…")
                        .foregroundStyle(.secondary)
                } else {
                    Text("\(viewModel.modelLabel) · 推理\(viewModel.reasoningEffort.displayName) · 停止输入后自动翻译")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }
                Spacer()
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }
}

private struct LanguagePicker: View {
    let title: String
    @Binding var selection: LanguageOption
    var excludesAuto = false

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .foregroundStyle(.secondary)
            Picker(title, selection: $selection) {
                ForEach(LanguageOption.allCases.filter { !excludesAuto || $0 != .auto }) { language in
                    Text(language.displayName).tag(language)
                }
            }
            .labelsHidden()
            .frame(width: 150)
        }
    }
}

private struct EditorCard<Footer: View>: View {
    let title: String
    @Binding var text: String
    let placeholder: String
    let fontSize: CGFloat
    @ViewBuilder let footer: Footer

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title)
                    .font(.headline)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            Divider()

            ZStack(alignment: .topLeading) {
                TextEditor(text: $text)
                    .font(.system(size: fontSize))
                    .scrollContentBackground(.hidden)
                    .padding(8)
                if text.isEmpty {
                    Text(placeholder)
                        .font(.system(size: fontSize))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 16)
                        .allowsHitTesting(false)
                }
            }

            Divider()
            HStack {
                footer
                Spacer()
                Text("\(text.count) 字")
                    .foregroundStyle(.tertiary)
                    .font(.caption)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
        }
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(.quaternary, lineWidth: 1)
        }
    }
}
