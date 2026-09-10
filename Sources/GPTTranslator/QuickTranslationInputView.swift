import AppKit
import SwiftUI

final class QuickTranslationPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

struct QuickTranslationInputView: View {
    @ObservedObject var controller: GlobalTranslationController
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "character.cursor.ibeam")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                TextField("输入中文或英文…", text: $controller.quickInputText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 22))
                    .focused($inputFocused)
                    .onChange(of: controller.quickInputText) { newValue in
                        controller.updateQuickInputText(newValue)
                    }
                if controller.isQuickInputTranslating {
                    ProgressView()
                        .controlSize(.small)
                }
                Button {
                    controller.toggleQuickInputPinned()
                } label: {
                    Image(systemName: controller.isQuickInputPinned ? "pin.fill" : "pin")
                }
                .buttonStyle(.plain)
                .foregroundStyle(controller.isQuickInputPinned ? Color.accentColor : Color.secondary)
                .help(controller.isQuickInputPinned ? "取消置顶" : "置顶窗口")
                Button {
                    controller.closeQuickTranslationInput()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .keyboardShortcut(.cancelAction)
            }

            Divider()

            Group {
                if controller.quickInputTranslation.isEmpty {
                    Text(controller.quickInputStatus.isEmpty ? "输入后自动判断中英文并翻译" : controller.quickInputStatus)
                        .foregroundStyle(.secondary)
                } else {
                    Text(controller.quickInputTranslation)
                        .font(.system(size: 17))
                        .textSelection(.enabled)
                        .lineLimit(4)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 64, alignment: .topLeading)

            HStack {
                Text(controller.quickInputStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Button("复制", systemImage: "doc.on.doc") {
                    controller.copyQuickInputTranslation()
                }
                .disabled(controller.quickInputTranslation.isEmpty)
                Button("输入到原文本框", systemImage: "arrow.turn.down.left") {
                    controller.insertQuickInputTranslation()
                }
                .disabled(controller.quickInputTranslation.isEmpty)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: .command)
            }

            Divider()

            HStack {
                Text("历史记录")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button("清空") {
                    controller.clearQuickInputHistory()
                }
                .buttonStyle(.borderless)
                .disabled(controller.quickInputHistory.isEmpty)
            }

            if controller.quickInputHistory.isEmpty {
                Text("暂无历史记录")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(controller.quickInputHistory) { item in
                            HStack(alignment: .top, spacing: 10) {
                                Button {
                                    controller.loadQuickInputHistory(item)
                                } label: {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(item.sourceText)
                                            .lineLimit(1)
                                            .foregroundStyle(.secondary)
                                        Text(item.translatedText)
                                            .lineLimit(2)
                                            .foregroundStyle(.primary)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .buttonStyle(.plain)
                                Button {
                                    controller.copyQuickInputHistory(item)
                                } label: {
                                    Image(systemName: "doc.on.doc")
                                }
                                .buttonStyle(.borderless)
                                .help("复制译文")
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }
            }
        }
        .padding(18)
        .frame(width: 620, height: 430)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(alignment: .topLeading) {
            AppleTranslationBridgeHost(service: controller.appleTranslationService)
        }
        .onAppear { inputFocused = true }
    }
}
