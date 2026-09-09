import AppKit
import Carbon.HIToolbox
import Combine
import CoreGraphics
import Foundation
import OSLog
import SwiftUI
import UniformTypeIdentifiers
import Vision

enum ShortcutModifiers: String, CaseIterable, Identifiable {
    case commandShift
    case commandOption
    case controlOption
    case controlShift

    var id: String { rawValue }
    var symbols: String {
        switch self {
        case .commandShift: return "⌘⇧"
        case .commandOption: return "⌘⌥"
        case .controlOption: return "⌃⌥"
        case .controlShift: return "⌃⇧"
        }
    }
    var carbonFlags: UInt32 {
        switch self {
        case .commandShift: return UInt32(cmdKey | shiftKey)
        case .commandOption: return UInt32(cmdKey | optionKey)
        case .controlOption: return UInt32(controlKey | optionKey)
        case .controlShift: return UInt32(controlKey | shiftKey)
        }
    }
    var eventFlags: NSEvent.ModifierFlags {
        switch self {
        case .commandShift: return [.command, .shift]
        case .commandOption: return [.command, .option]
        case .controlOption: return [.control, .option]
        case .controlShift: return [.control, .shift]
        }
    }
}

@MainActor
final class GlobalTranslationController: NSObject, ObservableObject {
    private let logger = Logger(subsystem: "com.gpttranslator.app", category: "GlobalTranslation")
    @Published private(set) var accessibilityTrusted = false
    @Published private(set) var isCapturing = false
    @Published var showSelectionButton: Bool
    @Published var autoTranslateSelection: Bool
    @Published var selectionEnabled: Bool
    @Published var translateShortcutModifiers: ShortcutModifiers
    @Published var screenshotShortcutModifiers: ShortcutModifiers
    @Published var showInDock: Bool
    @Published var showingSettings = false
    @Published private(set) var isResultWindowPinned = false

    private weak var viewModel: TranslationViewModel?
    private var hotKeyHandler: EventHandlerRef?
    private var translateHotKey: EventHotKeyRef?
    private var screenshotHotKey: EventHotKeyRef?
    private var globalKeyMonitor: Any?
    private var localKeyMonitor: Any?
    private var mouseMonitor: Any?
    private var localMouseMonitor: Any?
    private var overlayWindow: NSPanel?
    private var floatingButtonWindow: NSPanel?
    private var resultWindow: NSPanel?
    private var resultWindowAnchor: NSPoint?
    private var resultSizingSubscription: AnyCancellable?
    private var workspaceActivationObserver: NSObjectProtocol?
    private var pendingSelectionText: String?
    private var pendingSelectionLocation: NSPoint?
    private var lastShortcutTime = Date.distantPast
    private var resultWindowShownAt = Date.distantPast
    private var hasRequestedScreenCapturePermission = false

    private static let hotKeySignature: OSType = 0x4750_5452 // GPTR
    private static let translateHotKeyID: UInt32 = 1
    private static let screenshotHotKeyID: UInt32 = 2

    override init() {
        let defaults = UserDefaults.standard
        showSelectionButton = defaults.object(forKey: "showSelectionButton") as? Bool ?? true
        autoTranslateSelection = defaults.bool(forKey: "autoTranslateSelection")
        selectionEnabled = defaults.object(forKey: "selectionEnabled") as? Bool ?? true
        translateShortcutModifiers = defaults.string(forKey: "translateShortcutModifiers")
            .flatMap(ShortcutModifiers.init(rawValue:)) ?? .commandShift
        screenshotShortcutModifiers = defaults.string(forKey: "screenshotShortcutModifiers")
            .flatMap(ShortcutModifiers.init(rawValue:)) ?? .commandShift
        showInDock = defaults.object(forKey: "showInDock") as? Bool ?? true
        super.init()
    }

    func connect(to viewModel: TranslationViewModel) {
        self.viewModel = viewModel
        resultSizingSubscription = viewModel.$comparisonResults
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.resizeResultWindowToFit() }
            }
        accessibilityTrusted = AXIsProcessTrusted()
        logger.info("connect accessibilityTrusted=\(self.accessibilityTrusted, privacy: .public)")
        applyDockVisibility()
        if workspaceActivationObserver == nil {
            workspaceActivationObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.hideUnpinnedResultWindowAfterFocusChange()
                }
            }
        }
        startGlobalHotkeys()
    }

    func stop() {
        if let translateHotKey { UnregisterEventHotKey(translateHotKey) }
        if let screenshotHotKey { UnregisterEventHotKey(screenshotHotKey) }
        if let hotKeyHandler { RemoveEventHandler(hotKeyHandler) }
        if let globalKeyMonitor { NSEvent.removeMonitor(globalKeyMonitor) }
        if let localKeyMonitor { NSEvent.removeMonitor(localKeyMonitor) }
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        if let localMouseMonitor { NSEvent.removeMonitor(localMouseMonitor) }
        translateHotKey = nil
        screenshotHotKey = nil
        hotKeyHandler = nil
        globalKeyMonitor = nil
        localKeyMonitor = nil
        mouseMonitor = nil
        localMouseMonitor = nil
        hideFloatingButton()
        resultWindow?.close()
        resultWindow = nil
        resultSizingSubscription = nil
        if let workspaceActivationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(workspaceActivationObserver)
            self.workspaceActivationObserver = nil
        }
    }

    func requestAccessibilityPermission() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        accessibilityTrusted = AXIsProcessTrustedWithOptions(options)
    }

    func refreshAccessibilityStatus() {
        accessibilityTrusted = AXIsProcessTrusted()
    }

    func translateSelection() {
        accessibilityTrusted = AXIsProcessTrusted()
        logger.info("translateSelection accessibilityTrusted=\(self.accessibilityTrusted, privacy: .public)")
        showResultWindow(at: NSEvent.mouseLocation)
        guard let text = selectedText(), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            logger.error("translateSelection selectedText=nil-or-empty")
            viewModel?.errorMessage = accessibilityTrusted
                ? "没有读取到已选中的文字。请先划词，再按 ⌘⇧T。"
                : "需要辅助功能权限才能读取其他软件中的选中文字。"
            return
        }
        logger.info("translateSelection selectedTextLength=\(text.count, privacy: .public)")
        viewModel?.translateForFloatingWindow(text)
    }

    func saveSelectionPreferences() {
        UserDefaults.standard.set(showSelectionButton, forKey: "showSelectionButton")
        UserDefaults.standard.set(autoTranslateSelection, forKey: "autoTranslateSelection")
        UserDefaults.standard.set(selectionEnabled, forKey: "selectionEnabled")
        UserDefaults.standard.set(translateShortcutModifiers.rawValue, forKey: "translateShortcutModifiers")
        UserDefaults.standard.set(screenshotShortcutModifiers.rawValue, forKey: "screenshotShortcutModifiers")
        UserDefaults.standard.set(showInDock, forKey: "showInDock")
        applyDockVisibility()
        registerHotKeys()
    }

    func applyDockVisibility() {
        NSApp.setActivationPolicy(showInDock ? .regular : .accessory)
    }

    func translateScreenshot() {
        guard !isCapturing else { return }
        guard CGPreflightScreenCaptureAccess() else {
            if !hasRequestedScreenCapturePermission {
                hasRequestedScreenCapturePermission = true
                _ = CGRequestScreenCaptureAccess()
            }
            viewModel?.errorMessage = "需要屏幕录制权限。请在系统设置中允许 GPT 翻译助手；首次授权后可能需要重新启动应用。"
            return
        }
        guard let displayImage = CGDisplayCreateImage(CGMainDisplayID()) else {
            viewModel?.errorMessage = "无法截取屏幕。请在系统设置中允许本应用使用屏幕录制。"
            return
        }

        hasRequestedScreenCapturePermission = false

        isCapturing = true
        Task { @MainActor in
            defer { isCapturing = false }
            do {
                guard let selectedImage = try await selectRegion(from: displayImage),
                      let recognizedText = try recognizeText(in: selectedImage),
                      !recognizedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    viewModel?.errorMessage = "选区中没有识别到文字。"
                    return
                }
                showResultWindow(at: NSEvent.mouseLocation)
                viewModel?.translateForFloatingWindow(recognizedText)
            } catch {
                viewModel?.errorMessage = error.localizedDescription
            }
        }
    }

    func toggleResultWindowPinned() {
        isResultWindowPinned.toggle()
    }

    private func startGlobalHotkeys() {
        guard hotKeyHandler == nil else { return }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let callback: EventHandlerUPP = { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotKeyID
            )
            guard status == noErr else { return status }
            let controller = Unmanaged<GlobalTranslationController>
                .fromOpaque(userData)
                .takeUnretainedValue()
            Task { @MainActor in
                controller.handleRegisteredHotKey(hotKeyID.id)
            }
            return noErr
        }

        let userData = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(
            GetApplicationEventTarget(),
            callback,
            1,
            &eventType,
            userData,
            &hotKeyHandler
        )

        registerHotKeys()

        let keyHandler: (NSEvent) -> Void = { [weak self] event in
            Task { @MainActor [weak self] in
                self?.handleKeyEvent(event)
            }
        }
        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: keyHandler)
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            keyHandler(event)
            return event
        }

        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.dismissUnpinnedResultIfNeeded(at: NSEvent.mouseLocation)
                self?.handleSelectionMouseUp()
            }
        }
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            self?.dismissUnpinnedResultIfNeeded(at: NSEvent.mouseLocation)
            return event
        }
        logger.info("hotkeys installed translate=\(self.translateHotKey != nil, privacy: .public) screenshot=\(self.screenshotHotKey != nil, privacy: .public) mouse=\(self.mouseMonitor != nil, privacy: .public)")
    }

    private func registerHotKeys() {
        if let translateHotKey { UnregisterEventHotKey(translateHotKey) }
        if let screenshotHotKey { UnregisterEventHotKey(screenshotHotKey) }
        translateHotKey = nil
        screenshotHotKey = nil
        let translateID = EventHotKeyID(signature: Self.hotKeySignature, id: Self.translateHotKeyID)
        let screenshotID = EventHotKeyID(signature: Self.hotKeySignature, id: Self.screenshotHotKeyID)
        RegisterEventHotKey(
            UInt32(kVK_ANSI_T), translateShortcutModifiers.carbonFlags, translateID,
            GetApplicationEventTarget(), 0, &translateHotKey
        )
        RegisterEventHotKey(
            UInt32(kVK_ANSI_S), screenshotShortcutModifiers.carbonFlags, screenshotID,
            GetApplicationEventTarget(), 0, &screenshotHotKey
        )
    }

    private func handleRegisteredHotKey(_ id: UInt32) {
        guard Date().timeIntervalSince(lastShortcutTime) > 0.3 else { return }
        lastShortcutTime = Date()
        if id == Self.translateHotKeyID {
            translateSelection()
        } else if id == Self.screenshotHotKeyID {
            translateScreenshot()
        }
    }

    private func handleKeyEvent(_ event: NSEvent) {
        let relevant: NSEvent.ModifierFlags = [.command, .shift, .option, .control]
        let flags = event.modifierFlags.intersection(relevant)
        guard Date().timeIntervalSince(lastShortcutTime) > 0.3 else { return }
        if event.keyCode == UInt16(kVK_ANSI_T), flags == translateShortcutModifiers.eventFlags {
            lastShortcutTime = Date()
            translateSelection()
        } else if event.keyCode == UInt16(kVK_ANSI_S), flags == screenshotShortcutModifiers.eventFlags {
            lastShortcutTime = Date()
            translateScreenshot()
        }
    }

    private func handleSelectionMouseUp() {
        guard selectionEnabled, !NSApp.isActive, (showSelectionButton || autoTranslateSelection) else { return }
        accessibilityTrusted = AXIsProcessTrusted()
        guard accessibilityTrusted else { return }
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 180_000_000)
            guard let self, let text = self.selectedText(),
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            if self.autoTranslateSelection {
                self.showResultWindow(at: NSEvent.mouseLocation)
                self.viewModel?.translateForFloatingWindow(text)
            } else if self.showSelectionButton {
                self.showFloatingButton(for: text, at: NSEvent.mouseLocation)
            }
        }
    }

    private func showFloatingButton(for text: String, at location: NSPoint) {
        hideFloatingButton()
        pendingSelectionText = text
        pendingSelectionLocation = location

        let button = NSButton(frame: NSRect(x: 0, y: 0, width: 38, height: 38))
        button.image = NSImage(systemSymbolName: "character.bubble.fill", accessibilityDescription: "翻译")
        button.imageScaling = .scaleProportionallyUpOrDown
        button.bezelStyle = .texturedRounded
        button.isBordered = true
        button.toolTip = "翻译所选文字"
        button.target = self
        button.action = #selector(floatingButtonClicked)

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 38, height: 38),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = button
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let screen = NSScreen.screens.first(where: { $0.frame.contains(location) }) ?? NSScreen.main
        let maxX = (screen?.frame.maxX ?? location.x + 38) - 44
        let maxY = (screen?.frame.maxY ?? location.y + 38) - 44
        panel.setFrameOrigin(NSPoint(x: min(location.x + 10, maxX), y: min(location.y + 10, maxY)))
        panel.orderFrontRegardless()
        floatingButtonWindow = panel

        let dismiss = DispatchWorkItem { [weak self] in
            Task { @MainActor in self?.hideFloatingButton() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: dismiss)
    }

    @objc private func floatingButtonClicked() {
        guard let text = pendingSelectionText else { return }
        let location = pendingSelectionLocation ?? NSEvent.mouseLocation
        hideFloatingButton()
        showResultWindow(at: location)
        viewModel?.translateForFloatingWindow(text)
    }

    private func hideFloatingButton() {
        floatingButtonWindow?.orderOut(nil)
        floatingButtonWindow = nil
        pendingSelectionText = nil
        pendingSelectionLocation = nil
    }

    private func showResultWindow(at location: NSPoint) {
        guard let viewModel else { return }
        resultWindowAnchor = location
        let size = desiredResultWindowSize()
        let panel: NSPanel
        if let resultWindow {
            panel = resultWindow
            panel.contentView = NSHostingView(rootView: SelectionTranslationView(viewModel: viewModel, controller: self))
        } else {
            panel = NSPanel(
                contentRect: NSRect(origin: .zero, size: size),
                styleMask: [.titled, .closable, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.title = "划词翻译"
            panel.level = .floating
            panel.isFloatingPanel = true
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.contentView = NSHostingView(rootView: SelectionTranslationView(viewModel: viewModel, controller: self))
            resultWindow = panel
        }

        let screen = NSScreen.screens.first(where: { $0.frame.contains(location) }) ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let x = min(max(location.x + 12, visible.minX + 8), visible.maxX - size.width - 8)
        let preferredY = location.y - size.height - 14
        let y = min(max(preferredY, visible.minY + 8), visible.maxY - size.height - 8)
        panel.setFrame(NSRect(origin: NSPoint(x: x, y: y), size: size), display: true)
        panel.orderFrontRegardless()
        resultWindowShownAt = Date()
    }

    private func dismissUnpinnedResultIfNeeded(at location: NSPoint) {
        guard !isResultWindowPinned,
              Date().timeIntervalSince(resultWindowShownAt) > 0.35,
              let panel = resultWindow,
              panel.isVisible,
              !panel.frame.contains(location) else { return }
        panel.orderOut(nil)
    }

    private func hideUnpinnedResultWindowAfterFocusChange() {
        guard !isResultWindowPinned,
              Date().timeIntervalSince(resultWindowShownAt) > 0.35,
              let panel = resultWindow,
              panel.isVisible else { return }
        panel.orderOut(nil)
    }

    private func resizeResultWindowToFit() {
        guard let panel = resultWindow, panel.isVisible else { return }
        let size = desiredResultWindowSize()
        let anchor = resultWindowAnchor ?? NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(anchor) }) ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let top = min(panel.frame.maxY, visible.maxY - 8)
        let x = min(max(panel.frame.minX, visible.minX + 8), visible.maxX - size.width - 8)
        let y = max(visible.minY + 8, top - size.height)
        panel.setFrame(NSRect(origin: NSPoint(x: x, y: y), size: size), display: true, animate: true)
    }

    private func desiredResultWindowSize() -> NSSize {
        guard let viewModel else { return NSSize(width: 420, height: 180) }
        let texts = [viewModel.sourceText] + viewModel.comparisonResults.compactMap { $0.translatedText ?? $0.errorMessage }
        let font = NSFont.systemFont(ofSize: viewModel.resultFontSize)
        let longestLineWidth = texts
            .flatMap { $0.components(separatedBy: .newlines) }
            .map { ($0 as NSString).size(withAttributes: [.font: font]).width }
            .max() ?? 280
        let width = min(max(longestLineWidth + 88, 390), 560)
        let textWidth = width - 56
        let sourceHeight = min(measuredTextHeight(viewModel.sourceText, width: textWidth, font: .systemFont(ofSize: 11)), 160)
        let resultsHeight = viewModel.comparisonResults.reduce(CGFloat.zero) { total, result in
            let contentHeight: CGFloat
            if result.isLoading {
                contentHeight = 20
            } else {
                let content = result.translatedText ?? result.errorMessage ?? ""
                contentHeight = measuredTextHeight(content, width: textWidth - 24, font: font)
            }
            return total + 54 + max(contentHeight, 18)
        }
        let gaps = CGFloat(max(viewModel.comparisonResults.count - 1, 0)) * 10
        let naturalHeight = 91 + sourceHeight + resultsHeight + gaps
        let screenLimit = (NSScreen.main?.visibleFrame.height ?? 900) * 0.72
        return NSSize(width: width, height: min(max(naturalHeight, 155), screenLimit))
    }

    private func measuredTextHeight(_ text: String, width: CGFloat, font: NSFont) -> CGFloat {
        guard !text.isEmpty else { return 16 }
        return ceil((text as NSString).boundingRect(
            with: NSSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font]
        ).height)
    }

    private func selectedText() -> String? {
        if NSApp.isActive,
           let textView = NSApp.keyWindow?.firstResponder as? NSTextView,
           textView.selectedRange().length > 0 {
            let value = textView.string as NSString
            return value.substring(with: textView.selectedRange())
        }

        let systemWide = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused,
              CFGetTypeID(focused) == AXUIElementGetTypeID() else {
            logger.debug("selectedText focused element unavailable")
            return nil
        }

        var selected: CFTypeRef?
        let element = unsafeDowncast(focused, to: AXUIElement.self)
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &selected) == .success else {
            logger.debug("selectedText AXSelectedText unavailable")
            return nil
        }
        guard let selected = selected as? String,
              !selected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return selected
    }

    private func selectRegion(from image: CGImage) async throws -> CGImage? {
        guard let screen = NSScreen.main else { return nil }
        return await withCheckedContinuation { continuation in
            var panel: NSPanel?
            let overlay = ScreenshotOverlayView(image: image, frame: NSRect(origin: .zero, size: screen.frame.size)) { [weak self] rect in
                let crop: CGImage?
                if let rect {
                    let bounds = NSRect(origin: .zero, size: screen.frame.size)
                    let scaleX = CGFloat(image.width) / bounds.width
                    let scaleY = CGFloat(image.height) / bounds.height
                    let imageRect = CGRect(
                        x: rect.minX * scaleX,
                        y: (bounds.height - rect.maxY) * scaleY,
                        width: rect.width * scaleX,
                        height: rect.height * scaleY
                    ).integral
                    crop = image.cropping(to: imageRect)
                } else {
                    crop = nil
                }
                panel?.orderOut(nil)
                self?.overlayWindow = nil
                continuation.resume(returning: crop)
            }
            let newPanel = NSPanel(
                contentRect: screen.frame,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            panel = newPanel
            newPanel.contentView = overlay
            newPanel.level = .screenSaver
            newPanel.isOpaque = false
            newPanel.backgroundColor = .clear
            newPanel.hasShadow = false
            newPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            newPanel.makeKeyAndOrderFront(nil)
            newPanel.makeFirstResponder(overlay)
            NSApp.activate(ignoringOtherApps: true)
            self.overlayWindow = newPanel
        }
    }

    private func recognizeText(in image: CGImage) throws -> String? {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = ["zh-Hans", "en-US", "ja-JP", "ko-KR", "es-ES", "fr-FR", "de-DE"]
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])
        let lines = request.results?.compactMap { $0.topCandidates(1).first?.string } ?? []
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }
}

private struct SelectionTranslationView: View {
    @ObservedObject var viewModel: TranslationViewModel
    @ObservedObject var controller: GlobalTranslationController
    @State private var draggedSourceID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "character.bubble.fill")
                    .foregroundStyle(.tint)
                Text("翻译结果")
                    .font(.headline)
                Spacer()
                Button {
                    controller.toggleResultWindowPinned()
                } label: {
                    Image(systemName: controller.isResultWindowPinned ? "pin.fill" : "pin")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(controller.isResultWindowPinned ? Color.accentColor : Color.secondary)
                .help(controller.isResultWindowPinned ? "取消钉住；失焦后自动隐藏" : "钉住结果窗口")
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    Text(viewModel.sourceText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)

                    Divider()

                    ForEach(viewModel.comparisonResults) { result in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Image(systemName: "line.3.horizontal")
                                    .foregroundStyle(.tertiary)
                                    .help("拖拽调整翻译源顺序")
                                Text(result.source.displayName)
                                    .font(.subheadline.weight(.semibold))
                                Spacer()
                                if let text = result.translatedText {
                                    Button("复制", systemImage: "doc.on.doc") {
                                        NSPasteboard.general.clearContents()
                                        NSPasteboard.general.setString(text, forType: .string)
                                    }
                                    .buttonStyle(.borderless)
                                }
                            }
                            if result.isLoading {
                                HStack(spacing: 8) {
                                    ProgressView().controlSize(.small)
                                    Text("正在翻译…").foregroundStyle(.secondary)
                                }
                            } else if let error = result.errorMessage {
                                Label(error, systemImage: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.red)
                                    .font(.caption)
                            } else if let text = result.translatedText {
                                Text(text)
                                    .font(.system(size: viewModel.resultFontSize))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .textSelection(.enabled)
                            }
                        }
                        .padding(12)
                        .background(.quaternary.opacity(0.35))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .onDrag {
                            draggedSourceID = result.source.id
                            return NSItemProvider(object: result.source.id as NSString)
                        }
                        .onDrop(
                            of: [UTType.text],
                            delegate: ProviderDropDelegate(
                                destinationID: result.source.id,
                                draggedSourceID: $draggedSourceID,
                                viewModel: viewModel
                            )
                        )
                    }
                }
                .onDrop(of: [UTType.text], isTargeted: nil) { _ in
                    guard let draggedSourceID else { return false }
                    viewModel.moveComparisonProviderToEnd(draggedSourceID)
                    self.draggedSourceID = nil
                    return true
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct ProviderDropDelegate: DropDelegate {
    let destinationID: String
    @Binding var draggedSourceID: String?
    let viewModel: TranslationViewModel

    func dropEntered(info: DropInfo) {
        guard let draggedSourceID, draggedSourceID != destinationID else { return }
        viewModel.moveComparisonProvider(draggedSourceID, before: destinationID)
    }

    func performDrop(info: DropInfo) -> Bool {
        draggedSourceID = nil
        return true
    }
}

@MainActor
private final class ScreenshotOverlayView: NSView {
    private let image: CGImage
    private var startPoint: NSPoint?
    private var currentPoint: NSPoint?
    private let onFinish: (CGRect?) -> Void

    init(image: CGImage, frame: NSRect, onFinish: @escaping (CGRect?) -> Void) {
        self.image = image
        self.onFinish = onFinish
        super.init(frame: frame)
        wantsLayer = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var acceptsFirstResponder: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(origin: .zero, size: bounds.size))
        context.restoreGState()
        NSColor.black.withAlphaComponent(0.42).setFill()
        bounds.fill(using: .sourceOver)

        if let selection = selectionRect, selection.width > 1, selection.height > 1 {
            NSColor.clear.setFill()
            selection.fill(using: .copy)
            NSColor.white.setStroke()
            let border = NSBezierPath(rect: selection)
            border.lineWidth = 2
            border.stroke()
        }
        let hint = "拖动选择区域 · Esc 取消"
        let attributes: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.white,
            .font: NSFont.systemFont(ofSize: 16, weight: .medium)
        ]
        (hint as NSString).draw(at: NSPoint(x: 24, y: bounds.height - 42), withAttributes: attributes)
    }

    override func mouseDown(with event: NSEvent) {
        startPoint = convert(event.locationInWindow, from: nil)
        currentPoint = startPoint
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        currentPoint = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        currentPoint = convert(event.locationInWindow, from: nil)
        guard let selection = selectionRect, selection.width > 4, selection.height > 4 else {
            onFinish(nil)
            return
        }
        onFinish(selection)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onFinish(nil) } else { super.keyDown(with: event) }
    }

    private var selectionRect: CGRect? {
        guard let startPoint, let currentPoint else { return nil }
        return CGRect(
            x: min(startPoint.x, currentPoint.x),
            y: min(startPoint.y, currentPoint.y),
            width: abs(currentPoint.x - startPoint.x),
            height: abs(currentPoint.y - startPoint.y)
        )
    }
}
