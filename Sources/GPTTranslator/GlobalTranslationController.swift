import AppKit
import Carbon.HIToolbox
import Combine
import CoreGraphics
import Foundation
import OSLog
import ServiceManagement
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
}

enum ShortcutKey: String, CaseIterable, Identifiable {
    case a, b, c, d, e, f, g, h, i, j, k, l, m
    case n, o, p, q, r, s, t, u, v, w, x, y, z

    var id: String { rawValue }
    var displayName: String { rawValue.uppercased() }

    var carbonKeyCode: UInt32 {
        switch self {
        case .a: return UInt32(kVK_ANSI_A)
        case .b: return UInt32(kVK_ANSI_B)
        case .c: return UInt32(kVK_ANSI_C)
        case .d: return UInt32(kVK_ANSI_D)
        case .e: return UInt32(kVK_ANSI_E)
        case .f: return UInt32(kVK_ANSI_F)
        case .g: return UInt32(kVK_ANSI_G)
        case .h: return UInt32(kVK_ANSI_H)
        case .i: return UInt32(kVK_ANSI_I)
        case .j: return UInt32(kVK_ANSI_J)
        case .k: return UInt32(kVK_ANSI_K)
        case .l: return UInt32(kVK_ANSI_L)
        case .m: return UInt32(kVK_ANSI_M)
        case .n: return UInt32(kVK_ANSI_N)
        case .o: return UInt32(kVK_ANSI_O)
        case .p: return UInt32(kVK_ANSI_P)
        case .q: return UInt32(kVK_ANSI_Q)
        case .r: return UInt32(kVK_ANSI_R)
        case .s: return UInt32(kVK_ANSI_S)
        case .t: return UInt32(kVK_ANSI_T)
        case .u: return UInt32(kVK_ANSI_U)
        case .v: return UInt32(kVK_ANSI_V)
        case .w: return UInt32(kVK_ANSI_W)
        case .x: return UInt32(kVK_ANSI_X)
        case .y: return UInt32(kVK_ANSI_Y)
        case .z: return UInt32(kVK_ANSI_Z)
        }
    }
}

enum SelectionTriggerMode: String, CaseIterable, Identifiable {
    case button
    case automatic

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .button: return "显示翻译按钮"
        case .automatic: return "自动翻译"
        }
    }
}

struct QuickTranslationHistoryItem: Identifiable, Codable, Equatable {
    let id: UUID
    let sourceText: String
    let translatedText: String
    let createdAt: Date
}

private struct ScreenshotSelection {
    let image: CGImage
    let screenRect: CGRect
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
    @Published var translateShortcutKey: ShortcutKey
    @Published var screenshotShortcutModifiers: ShortcutModifiers
    @Published var screenshotShortcutKey: ShortcutKey
    @Published var captureShortcutModifiers: ShortcutModifiers
    @Published var captureShortcutKey: ShortcutKey
    @Published var ocrShortcutModifiers: ShortcutModifiers
    @Published var ocrShortcutKey: ShortcutKey
    @Published var quickInputShortcutModifiers: ShortcutModifiers
    @Published var quickInputShortcutKey: ShortcutKey
    @Published var showInDock: Bool
    @Published var launchAtLogin: Bool
    @Published private(set) var isResultWindowPinned = false
    @Published var quickInputText = ""
    @Published private(set) var quickInputTranslation = ""
    @Published private(set) var quickInputStatus = ""
    @Published private(set) var isQuickInputTranslating = false
    @Published private(set) var isQuickInputPinned = false
    @Published private(set) var quickInputHistory: [QuickTranslationHistoryItem]

    private weak var viewModel: TranslationViewModel?
    private var hotKeyHandler: EventHandlerRef?
    private var translateHotKey: EventHotKeyRef?
    private var screenshotHotKey: EventHotKeyRef?
    private var captureHotKey: EventHotKeyRef?
    private var ocrHotKey: EventHotKeyRef?
    private var quickInputHotKey: EventHotKeyRef?
    private var mouseMonitor: Any?
    private var localMouseMonitor: Any?
    private var overlayWindow: NSPanel?
    private var screenshotKeyMonitor: Any?
    private var screenshotGlobalKeyMonitor: Any?
    private var floatingButtonWindow: NSPanel?
    private var resultWindow: NSPanel?
    private var screenshotEditorWindow: ScreenshotEditorPanel?
    private var screenshotEditorWindows: [ScreenshotEditorPanel] = []
    private var screenshotTranslationWindow: NSPanel?
    private var settingsWindow: NSWindow?
    private var selectionStatusWindow: NSPanel?
    private var selectionStatusDismissWorkItem: DispatchWorkItem?
    private var pinnedScreenshotWindows: [PinnedScreenshotPanel] = []
    private var quickInputWindow: QuickTranslationPanel?
    private var resultWindowAnchor: NSPoint?
    private var resultSizingSubscription: AnyCancellable?
    private var workspaceActivationObserver: NSObjectProtocol?
    private var lastExternalApplicationPID: pid_t?
    private var lastExternalFocusedElement: AXUIElement?
    private var pendingSelectionText: String?
    private var pendingSelectionLocation: NSPoint?
    private var lastShortcutTime = Date.distantPast
    private var resultWindowShownAt = Date.distantPast
    private var hasRequestedScreenCapturePermission = false
    private var quickInputTargetElement: AXUIElement?
    private var quickInputTargetPID: pid_t?
    private var quickInputTranslationTask: Task<Void, Never>?

    private static let hotKeySignature: OSType = 0x4750_5452 // GPTR
    private static let translateHotKeyID: UInt32 = 1
    private static let screenshotHotKeyID: UInt32 = 2
    private static let quickInputHotKeyID: UInt32 = 3
    private static let captureHotKeyID: UInt32 = 4
    private static let ocrHotKeyID: UInt32 = 5

    override init() {
        let defaults = UserDefaults.standard
        showSelectionButton = defaults.object(forKey: "showSelectionButton") as? Bool ?? true
        autoTranslateSelection = defaults.bool(forKey: "autoTranslateSelection")
        selectionEnabled = defaults.object(forKey: "selectionEnabled") as? Bool ?? true
        translateShortcutModifiers = defaults.string(forKey: "translateShortcutModifiers")
            .flatMap(ShortcutModifiers.init(rawValue:)) ?? .commandShift
        translateShortcutKey = defaults.string(forKey: "translateShortcutKey")
            .flatMap(ShortcutKey.init(rawValue:)) ?? .t
        screenshotShortcutModifiers = defaults.string(forKey: "screenshotShortcutModifiers")
            .flatMap(ShortcutModifiers.init(rawValue:)) ?? .commandShift
        screenshotShortcutKey = defaults.string(forKey: "screenshotShortcutKey")
            .flatMap(ShortcutKey.init(rawValue:)) ?? .s
        captureShortcutModifiers = defaults.string(forKey: "captureShortcutModifiers")
            .flatMap(ShortcutModifiers.init(rawValue:)) ?? .commandShift
        captureShortcutKey = defaults.string(forKey: "captureShortcutKey")
            .flatMap(ShortcutKey.init(rawValue:)) ?? .a
        ocrShortcutModifiers = defaults.string(forKey: "ocrShortcutModifiers")
            .flatMap(ShortcutModifiers.init(rawValue:)) ?? .commandShift
        ocrShortcutKey = defaults.string(forKey: "ocrShortcutKey")
            .flatMap(ShortcutKey.init(rawValue:)) ?? .o
        quickInputShortcutModifiers = defaults.string(forKey: "quickInputShortcutModifiers")
            .flatMap(ShortcutModifiers.init(rawValue:)) ?? .commandShift
        quickInputShortcutKey = defaults.string(forKey: "quickInputShortcutKey")
            .flatMap(ShortcutKey.init(rawValue:)) ?? .d
        quickInputHistory = defaults.data(forKey: "quickTranslationHistory")
            .flatMap { try? JSONDecoder().decode([QuickTranslationHistoryItem].self, from: $0) } ?? []
        showInDock = defaults.object(forKey: "showInDock") as? Bool ?? true
        launchAtLogin = defaults.object(forKey: "launchAtLogin") as? Bool ?? false
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
                    self?.rememberExternalApplicationIfNeeded()
                    self?.hideUnpinnedResultWindowAfterFocusChange()
                }
            }
        }
        startGlobalHotkeys()
    }

    func stop() {
        if let translateHotKey { UnregisterEventHotKey(translateHotKey) }
        if let screenshotHotKey { UnregisterEventHotKey(screenshotHotKey) }
        if let captureHotKey { UnregisterEventHotKey(captureHotKey) }
        if let ocrHotKey { UnregisterEventHotKey(ocrHotKey) }
        if let quickInputHotKey { UnregisterEventHotKey(quickInputHotKey) }
        if let hotKeyHandler { RemoveEventHandler(hotKeyHandler) }
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        if let localMouseMonitor { NSEvent.removeMonitor(localMouseMonitor) }
        if let screenshotKeyMonitor { NSEvent.removeMonitor(screenshotKeyMonitor) }
        if let screenshotGlobalKeyMonitor { NSEvent.removeMonitor(screenshotGlobalKeyMonitor) }
        translateHotKey = nil
        screenshotHotKey = nil
        captureHotKey = nil
        ocrHotKey = nil
        quickInputHotKey = nil
        hotKeyHandler = nil
        mouseMonitor = nil
        localMouseMonitor = nil
        screenshotKeyMonitor = nil
        screenshotGlobalKeyMonitor = nil
        hideFloatingButton()
        resultWindow?.close()
        resultWindow = nil
        screenshotEditorWindows.forEach { $0.orderOut(nil) }
        screenshotEditorWindows.removeAll()
        screenshotEditorWindow = nil
        screenshotTranslationWindow?.orderOut(nil)
        screenshotTranslationWindow = nil
        settingsWindow?.close()
        settingsWindow = nil
        selectionStatusDismissWorkItem?.cancel()
        selectionStatusDismissWorkItem = nil
        selectionStatusWindow?.orderOut(nil)
        selectionStatusWindow = nil
        pinnedScreenshotWindows.forEach { $0.orderOut(nil) }
        pinnedScreenshotWindows.removeAll()
        quickInputTranslationTask?.cancel()
        quickInputWindow?.close()
        quickInputWindow = nil
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

    func showSettingsWindow() {
        guard let viewModel else {
            logger.error("Settings requested before translation controller was connected")
            return
        }
        if let settingsWindow {
            NSApp.activate(ignoringOtherApps: true)
            settingsWindow.makeKeyAndOrderFront(nil)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 560),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "设置"
        window.isReleasedWhenClosed = false
        window.center()
        window.contentViewController = NSHostingController(
            rootView: SettingsView()
                .environmentObject(viewModel)
                .environmentObject(self)
        )
        settingsWindow = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func translateSelection() {
        accessibilityTrusted = AXIsProcessTrusted()
        logger.info("translateSelection accessibilityTrusted=\(self.accessibilityTrusted, privacy: .public)")
        let location = NSEvent.mouseLocation
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard let text = await selectedTextWithClipboardFallback(),
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                logger.error("translateSelection selectedText=nil-or-empty")
                showResultWindow(at: location)
                viewModel?.errorMessage = accessibilityTrusted
                    ? "没有读取到已选中的文字。请先划词，再按 ⌘⇧T。"
                    : "需要辅助功能权限才能读取其他软件中的选中文字。"
                return
            }
            guard viewModel?.shouldTranslateFloatingText(text) != false else {
                resultWindow?.orderOut(nil)
                return
            }
            showResultWindow(at: location)
            logger.info("translateSelection selectedTextLength=\(text.count, privacy: .public)")
            viewModel?.translateForFloatingWindow(text)
        }
    }

    func toggleSelectionTranslation() {
        setSelectionTranslationEnabled(!selectionEnabled)
    }

    func setSelectionTranslationEnabled(_ enabled: Bool) {
        guard selectionEnabled != enabled else { return }
        selectionEnabled = enabled
        UserDefaults.standard.set(selectionEnabled, forKey: "selectionEnabled")
        if !selectionEnabled {
            hideFloatingButton()
            if !isResultWindowPinned { resultWindow?.orderOut(nil) }
        }
        showSelectionStatusHUD(enabled: selectionEnabled)
        logger.info("Selection translation enabled=\(self.selectionEnabled, privacy: .public)")
    }

    private func showSelectionStatusHUD(enabled: Bool) {
        selectionStatusDismissWorkItem?.cancel()

        let size = NSSize(width: 210, height: 54)
        let panel: NSPanel
        if let selectionStatusWindow {
            panel = selectionStatusWindow
        } else {
            panel = NSPanel(
                contentRect: NSRect(origin: .zero, size: size),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.isReleasedWhenClosed = false
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.level = .floating
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.ignoresMouseEvents = true
            selectionStatusWindow = panel
        }

        panel.contentView = NSHostingView(rootView: SelectionStatusHUD(enabled: enabled))
        let pointer = NSEvent.mouseLocation
        let visible = (NSScreen.screens.first { $0.frame.contains(pointer) } ?? NSScreen.main)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        panel.setFrameOrigin(NSPoint(
            x: visible.midX - size.width / 2,
            y: visible.midY + min(150, visible.height * 0.18)
        ))
        panel.alphaValue = 1
        panel.orderFrontRegardless()

        let workItem = DispatchWorkItem { [weak self, weak panel] in
            guard let self, let panel else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                panel.animator().alphaValue = 0
            } completionHandler: { [weak self, weak panel] in
                Task { @MainActor in
                    panel?.orderOut(nil)
                    self?.selectionStatusDismissWorkItem = nil
                }
            }
        }
        selectionStatusDismissWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.3, execute: workItem)
    }

    @discardableResult
    func saveSelectionPreferences() -> Bool {
        UserDefaults.standard.set(showSelectionButton, forKey: "showSelectionButton")
        UserDefaults.standard.set(autoTranslateSelection, forKey: "autoTranslateSelection")
        UserDefaults.standard.set(selectionEnabled, forKey: "selectionEnabled")
        UserDefaults.standard.set(translateShortcutModifiers.rawValue, forKey: "translateShortcutModifiers")
        UserDefaults.standard.set(translateShortcutKey.rawValue, forKey: "translateShortcutKey")
        UserDefaults.standard.set(screenshotShortcutModifiers.rawValue, forKey: "screenshotShortcutModifiers")
        UserDefaults.standard.set(screenshotShortcutKey.rawValue, forKey: "screenshotShortcutKey")
        UserDefaults.standard.set(captureShortcutModifiers.rawValue, forKey: "captureShortcutModifiers")
        UserDefaults.standard.set(captureShortcutKey.rawValue, forKey: "captureShortcutKey")
        UserDefaults.standard.set(ocrShortcutModifiers.rawValue, forKey: "ocrShortcutModifiers")
        UserDefaults.standard.set(ocrShortcutKey.rawValue, forKey: "ocrShortcutKey")
        UserDefaults.standard.set(quickInputShortcutModifiers.rawValue, forKey: "quickInputShortcutModifiers")
        UserDefaults.standard.set(quickInputShortcutKey.rawValue, forKey: "quickInputShortcutKey")
        UserDefaults.standard.set(showInDock, forKey: "showInDock")
        applyDockVisibility()
        guard applyLaunchAtLogin() else { return false }
        registerHotKeys()
        return true
    }

    var selectionTriggerMode: SelectionTriggerMode {
        get { autoTranslateSelection ? .automatic : .button }
        set {
            autoTranslateSelection = newValue == .automatic
            showSelectionButton = newValue == .button
        }
    }

    var appleTranslationService: AppleTranslationService {
        guard let viewModel else { preconditionFailure("Translation controller is not connected") }
        return viewModel.appleService
    }

    var translateShortcutDescription: String {
        translateShortcutModifiers.symbols + translateShortcutKey.displayName
    }

    var screenshotShortcutDescription: String {
        screenshotShortcutModifiers.symbols + screenshotShortcutKey.displayName
    }

    var captureShortcutDescription: String {
        captureShortcutModifiers.symbols + captureShortcutKey.displayName
    }

    var ocrShortcutDescription: String {
        ocrShortcutModifiers.symbols + ocrShortcutKey.displayName
    }

    var quickInputShortcutDescription: String {
        quickInputShortcutModifiers.symbols + quickInputShortcutKey.displayName
    }

    var hasShortcutConflict: Bool {
        Set([
            translateShortcutDescription,
            screenshotShortcutDescription,
            captureShortcutDescription,
            ocrShortcutDescription,
            quickInputShortcutDescription
        ]).count < 4
    }

    func applyDockVisibility() {
        NSApp.setActivationPolicy(showInDock ? .regular : .accessory)
    }

    var launchAtLoginStatusDescription: String {
        if #available(macOS 13.0, *) {
            switch SMAppService.mainApp.status {
            case .enabled:
                return "已启用"
            case .requiresApproval:
                return "需要在系统设置中允许"
            case .notRegistered:
                return "未启用"
            case .notFound:
                return "未启用"
            @unknown default:
                return "状态未知"
            }
        }
        return "需要 macOS 13 或更高版本"
    }

    func refreshLaunchAtLoginStatus() {
        guard #available(macOS 13.0, *) else {
            launchAtLogin = false
            return
        }
        switch SMAppService.mainApp.status {
        case .enabled, .requiresApproval:
            launchAtLogin = true
        case .notRegistered, .notFound:
            launchAtLogin = false
        @unknown default:
            break
        }
    }

    private func applyLaunchAtLogin() -> Bool {
        guard #available(macOS 13.0, *) else {
            UserDefaults.standard.set(false, forKey: "launchAtLogin")
            launchAtLogin = false
            return true
        }

        do {
            if launchAtLogin {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else if SMAppService.mainApp.status == .enabled || SMAppService.mainApp.status == .requiresApproval {
                try SMAppService.mainApp.unregister()
            }
            UserDefaults.standard.set(launchAtLogin, forKey: "launchAtLogin")
            return true
        } catch {
            viewModel?.errorMessage = "无法设置登录时自动启动：\(error.localizedDescription)"
            refreshLaunchAtLoginStatus()
            return false
        }
    }

    func toggleQuickTranslationInput() {
        if quickInputWindow?.isVisible == true {
            closeQuickTranslationInput()
        } else {
            showQuickTranslationInput()
        }
    }

    func updateQuickInputText(_ text: String) {
        quickInputText = text
        quickInputTranslationTask?.cancel()
        quickInputTranslation = ""
        quickInputStatus = ""
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            isQuickInputTranslating = false
            return
        }

        isQuickInputTranslating = true
        quickInputTranslationTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled, let self, let viewModel = self.viewModel else { return }
            do {
                let result = try await viewModel.translateQuickInput(trimmed)
                guard !Task.isCancelled, self.quickInputText.trimmingCharacters(in: .whitespacesAndNewlines) == trimmed else { return }
                self.quickInputTranslation = result
                self.quickInputStatus = viewModel.activeProviderDisplayName
                self.addQuickInputHistory(source: trimmed, translation: result)
            } catch {
                guard !Task.isCancelled else { return }
                self.quickInputStatus = error.localizedDescription
            }
            self.isQuickInputTranslating = false
        }
    }

    func copyQuickInputTranslation() {
        guard !quickInputTranslation.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(quickInputTranslation, forType: .string)
        quickInputStatus = "已复制"
    }

    func loadQuickInputHistory(_ item: QuickTranslationHistoryItem) {
        quickInputTranslationTask?.cancel()
        quickInputText = item.sourceText
        quickInputTranslation = item.translatedText
        quickInputStatus = "历史记录"
        isQuickInputTranslating = false
    }

    func copyQuickInputHistory(_ item: QuickTranslationHistoryItem) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(item.translatedText, forType: .string)
        quickInputStatus = "已复制历史译文"
    }

    func clearQuickInputHistory() {
        quickInputHistory.removeAll()
        UserDefaults.standard.removeObject(forKey: "quickTranslationHistory")
    }

    func clearQuickTranslationInput() {
        quickInputTranslationTask?.cancel()
        quickInputTranslationTask = nil
        quickInputText = ""
        quickInputTranslation = ""
        quickInputStatus = ""
        isQuickInputTranslating = false
    }

    func insertQuickInputTranslation() {
        guard !quickInputTranslation.isEmpty else { return }
        let text = quickInputTranslation
        let target = quickInputTargetElement
        let targetPID = quickInputTargetPID
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        guard let targetPID,
              let targetApplication = NSRunningApplication(processIdentifier: targetPID) else {
            quickInputStatus = "未找到原应用，译文已复制"
            return
        }
        closeQuickTranslationInput()
        targetApplication.activate(options: [.activateIgnoringOtherApps])
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard let self else { return }
            if let target {
                _ = AXUIElementSetAttributeValue(
                    target,
                    kAXFocusedAttribute as CFString,
                    kCFBooleanTrue
                )
            }
            try? await Task.sleep(nanoseconds: 80_000_000)
            self.postPasteShortcut()
        }
    }

    func toggleQuickInputPinned() {
        isQuickInputPinned.toggle()
        quickInputWindow?.hidesOnDeactivate = !isQuickInputPinned
    }

    func closeQuickTranslationInput() {
        quickInputTranslationTask?.cancel()
        quickInputTranslationTask = nil
        quickInputWindow?.orderOut(nil)
        quickInputTargetElement = nil
        quickInputTargetPID = nil
        isQuickInputTranslating = false
    }

    private func showQuickTranslationInput() {
        accessibilityTrusted = AXIsProcessTrusted()
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let currentlyFocused = accessibilityTrusted ? focusedUIElement() : nil
        var focusedPID: pid_t = 0
        if let currentlyFocused { _ = AXUIElementGetPid(currentlyFocused, &focusedPID) }

        if let frontmostPID, frontmostPID != ownPID {
            quickInputTargetPID = frontmostPID
            lastExternalApplicationPID = frontmostPID
            if focusedPID == frontmostPID {
                quickInputTargetElement = currentlyFocused
                lastExternalFocusedElement = currentlyFocused
            } else {
                quickInputTargetElement = nil
            }
        } else {
            quickInputTargetPID = lastExternalApplicationPID
            quickInputTargetElement = lastExternalFocusedElement
        }
        if let target = quickInputTargetElement {
            var pid: pid_t = 0
            if AXUIElementGetPid(target, &pid) == .success { quickInputTargetPID = pid }
        }
        quickInputText = ""
        quickInputTranslation = ""
        quickInputStatus = ""
        isQuickInputTranslating = false

        let panel = quickInputWindow ?? QuickTranslationPanel(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 430),
            styleMask: [.titled, .closable, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.contentView = NSHostingView(rootView: QuickTranslationInputView(controller: self))
        panel.title = "快捷翻译"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.closeHandler = { [weak self] in
            self?.closeQuickTranslationInput()
        }
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = !isQuickInputPinned
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        quickInputWindow = panel

        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        panel.setFrameOrigin(NSPoint(
            x: screen.midX - panel.frame.width / 2,
            y: screen.maxY - panel.frame.height - 120
        ))
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows
            .filter { $0 !== panel && !($0 is NSPanel) && $0.canBecomeMain }
            .forEach { $0.orderOut(nil) }
        panel.makeKeyAndOrderFront(nil)
    }

    private func postPasteShortcut() {
        guard let source = CGEventSource(stateID: .hidSystemState),
              let keyDown = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false) else { return }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }

    private func addQuickInputHistory(source: String, translation: String) {
        quickInputHistory.removeAll {
            $0.sourceText == source && $0.translatedText == translation
        }
        quickInputHistory.insert(
            QuickTranslationHistoryItem(
                id: UUID(),
                sourceText: source,
                translatedText: translation,
                createdAt: Date()
            ),
            at: 0
        )
        if quickInputHistory.count > 20 {
            quickInputHistory.removeLast(quickInputHistory.count - 20)
        }
        if let data = try? JSONEncoder().encode(quickInputHistory) {
            UserDefaults.standard.set(data, forKey: "quickTranslationHistory")
        }
    }

    private func rememberExternalApplicationIfNeeded() {
        guard let application = NSWorkspace.shared.frontmostApplication,
              application.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        lastExternalApplicationPID = application.processIdentifier
        guard accessibilityTrusted, let focused = focusedUIElement() else { return }
        var pid: pid_t = 0
        guard AXUIElementGetPid(focused, &pid) == .success,
              pid == application.processIdentifier else { return }
        lastExternalFocusedElement = focused
    }

    private func focusedUIElement() -> AXUIElement? {
        let systemWide = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused,
              CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        return unsafeDowncast(focused, to: AXUIElement.self)
    }

    func translateScreenshot() {
        guard !isCapturing else { return }
        isCapturing = true
        removeScreenshotEscapeMonitors()
        Task { @MainActor in
            defer {
                isCapturing = false
                if screenshotEditorWindow != nil { installScreenshotEditorEscapeMonitors() }
            }
            // Keep existing screenshot windows visible so they can be included
            // in the new screen capture, while the new overlay owns key events.
            await Task.yield()
            guard let displayImage = currentDisplayImage() else { return }
            do {
                guard let selection = try await selectRegion(from: displayImage) else { return }
                guard let recognizedText = try recognizeText(in: selection.image),
                      !recognizedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    viewModel?.errorMessage = "选区中没有识别到文字。"
                    return
                }
                guard let viewModel else {
                    logger.error("Screenshot translation requested before translation controller was connected")
                    return
                }
                showResultWindow(at: NSEvent.mouseLocation)
                viewModel.translateForFloatingWindow(recognizedText)
            } catch {
                viewModel?.errorMessage = error.localizedDescription
            }
        }
    }

    func captureScreenshot() {
        guard !isCapturing else { return }
        isCapturing = true
        removeScreenshotEscapeMonitors()
        Task { @MainActor in
            defer {
                isCapturing = false
                if screenshotEditorWindow != nil { installScreenshotEditorEscapeMonitors() }
            }
            await Task.yield()
            guard let displayImage = currentDisplayImage() else { return }
            do {
                guard let selection = try await selectRegion(from: displayImage) else { return }
                showScreenshotEditor(with: selection)
            } catch {
                viewModel?.errorMessage = error.localizedDescription
            }
        }
    }

    func recognizeScreenshot() {
        guard !isCapturing else { return }
        isCapturing = true
        removeScreenshotEscapeMonitors()
        Task { @MainActor in
            defer {
                isCapturing = false
                if screenshotEditorWindow != nil { installScreenshotEditorEscapeMonitors() }
            }
            await Task.yield()
            guard let displayImage = currentDisplayImage() else { return }
            do {
                guard let selection = try await selectRegion(from: displayImage) else { return }
                guard let recognizedText = try recognizeText(in: selection.image),
                      !recognizedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    viewModel?.errorMessage = "选区中没有识别到文字。"
                    return
                }
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(recognizedText, forType: .string)
                showScreenshotOCRStatus("OCR 文字已复制")
            } catch {
                viewModel?.errorMessage = "OCR 识别失败：\(error.localizedDescription)"
            }
        }
    }

    private func currentDisplayImage() -> CGImage? {
        guard CGPreflightScreenCaptureAccess() else {
            if !hasRequestedScreenCapturePermission {
                hasRequestedScreenCapturePermission = true
                _ = CGRequestScreenCaptureAccess()
            }
            viewModel?.errorMessage = "需要屏幕录制权限。请在系统设置中允许 GPT 翻译助手；首次授权后可能需要重新启动应用。"
            return nil
        }
        guard let image = CGDisplayCreateImage(CGMainDisplayID()) else {
            viewModel?.errorMessage = "无法截取屏幕。请在系统设置中允许本应用使用屏幕录制。"
            return nil
        }
        hasRequestedScreenCapturePermission = false
        return image
    }

    private func showScreenshotEditor(with selection: ScreenshotSelection) {
        guard let screen = NSScreen.screens.first(where: { $0.frame.intersects(selection.screenRect) }) ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        let toolAreaHeight: CGFloat = 98
        let maximumPanelWidth = visible.width - 16
        let maximumImageHeight = visible.height - toolAreaHeight - 16
        let imageScale = min(
            1,
            maximumPanelWidth / selection.screenRect.width,
            maximumImageHeight / selection.screenRect.height
        )
        let imageDisplayWidth = selection.screenRect.width * imageScale
        let imageDisplayHeight = selection.screenRect.height * imageScale
        let panelWidth = min(max(imageDisplayWidth, 620), maximumPanelWidth)
        let panelHeight = imageDisplayHeight + toolAreaHeight
        let toolbarBelow = selection.screenRect.minY - toolAreaHeight >= visible.minY + 8
        let imageOffsetX = (panelWidth - imageDisplayWidth) / 2
        let originX = min(
            max(selection.screenRect.minX - imageOffsetX, visible.minX + 8),
            visible.maxX - panelWidth - 8
        )
        let originY = toolbarBelow
            ? selection.screenRect.minY - toolAreaHeight
            : min(selection.screenRect.minY, visible.maxY - panelHeight - 8)

        let panel = ScreenshotEditorPanel(
            contentRect: NSRect(x: originX, y: originY, width: panelWidth, height: panelHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.closeHandler = { [weak self, weak panel] in
            guard let panel else { return }
            self?.closeScreenshotEditor(panel)
        }
        panel.contentView = NSHostingView(
            rootView: CompactScreenshotEditorView(
                image: selection.image,
                displaySize: NSSize(width: imageDisplayWidth, height: imageDisplayHeight),
                panelWidth: panelWidth,
                toolbarBelow: toolbarBelow,
                onCancel: { [weak self, weak panel] in
                    guard let panel else { return }
                    self?.closeScreenshotEditor(panel)
                },
                onConfirm: { [weak self] in
                    self?.closeAllScreenshotEditors()
                },
                onOCRTranslate: { [weak self] image in
                    self?.translateScreenshotEditorImage(image, near: selection.screenRect)
                },
                onPin: { [weak self, weak panel] renderedImage in
                    guard let panel else { return }
                    self?.showPinnedScreenshot(renderedImage, near: selection.screenRect, replacing: panel)
                }
            )
        )
        screenshotEditorWindows.append(panel)
        screenshotEditorWindow = panel
        panel.orderFrontRegardless()
        installScreenshotEditorEscapeMonitors()
    }

    private func translateScreenshotEditorImage(_ image: CGImage, near selectionRect: CGRect) {
        do {
            guard let recognizedText = try recognizeText(in: image),
                  !recognizedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                viewModel?.errorMessage = "选区中没有识别到文字。"
                return
            }
            guard let viewModel else {
                logger.error("OCR translate requested before translation controller was connected")
                return
            }
            showScreenshotTranslation(recognizedText, using: viewModel, near: selectionRect)
        } catch {
            viewModel?.errorMessage = "OCR 翻译失败：\(error.localizedDescription)"
        }
    }

    private func showScreenshotTranslation(
        _ text: String,
        using viewModel: TranslationViewModel,
        near selectionRect: CGRect
    ) {
        screenshotTranslationWindow?.orderOut(nil)
        let model = ScreenshotTranslationResultModel()
        let width = min(max(selectionRect.width, 420), 620)
        let height: CGFloat = 190
        let screen = NSScreen.screens.first(where: { $0.frame.intersects(selectionRect) }) ?? NSScreen.main
        let visible = screen?.visibleFrame ?? selectionRect
        let x = min(max(selectionRect.midX - width / 2, visible.minX + 8), visible.maxX - width - 8)
        let editorBottom = screenshotEditorWindow?.frame.minY ?? selectionRect.minY
        let y = editorBottom - height - 6 >= visible.minY + 8
            ? editorBottom - height - 6
            : min((screenshotEditorWindow?.frame.maxY ?? selectionRect.maxY) + 6, visible.maxY - height - 8)
        let panel = NSPanel(
            contentRect: NSRect(x: x, y: y, width: width, height: height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(
            rootView: ScreenshotTranslationResultView(model: model) { [weak self] in
                self?.screenshotTranslationWindow?.orderOut(nil)
                self?.screenshotTranslationWindow = nil
            }
        )
        screenshotTranslationWindow = panel
        panel.orderFrontRegardless()
        model.translate(text, using: viewModel)
    }

    private func showPinnedScreenshot(
        _ image: CGImage,
        near originalRect: CGRect,
        replacing editorPanel: ScreenshotEditorPanel
    ) {
        closeScreenshotEditor(editorPanel)
        let panel = PinnedScreenshotPanel(
            contentRect: originalRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.escapeHandler = { [weak self, weak panel] in
            guard let self, let panel else { return }
            self.closePinnedScreenshot(panel)
        }
        panel.contentView = NSHostingView(
            rootView: PinnedScreenshotView(
                image: image,
                onFocus: { [weak panel] in
                    panel?.makeKeyAndOrderFront(nil)
                },
                onClose: { [weak self, weak panel] in
                    guard let self, let panel else { return }
                    self.closePinnedScreenshot(panel)
                }
            )
        )
        pinnedScreenshotWindows.append(panel)
        panel.orderFrontRegardless()
    }

    private func closePinnedScreenshot(_ panel: PinnedScreenshotPanel) {
        panel.orderOut(nil)
        pinnedScreenshotWindows.removeAll { $0 === panel }
    }

    func closeScreenshotEditor(_ panel: ScreenshotEditorPanel? = nil) {
        guard let target = panel ?? screenshotEditorWindow else { return }
        target.orderOut(nil)
        screenshotEditorWindows.removeAll { $0 === target }
        screenshotEditorWindow = screenshotEditorWindows.last
        screenshotTranslationWindow?.orderOut(nil)
        screenshotTranslationWindow = nil
        removeScreenshotEscapeMonitors()
        if screenshotEditorWindow != nil, !isCapturing {
            installScreenshotEditorEscapeMonitors()
        }
    }

    private func closeAllScreenshotEditors() {
        screenshotEditorWindows.forEach { $0.orderOut(nil) }
        screenshotEditorWindows.removeAll()
        screenshotEditorWindow = nil
        screenshotTranslationWindow?.orderOut(nil)
        screenshotTranslationWindow = nil
        removeScreenshotEscapeMonitors()
    }

    private func installScreenshotEditorEscapeMonitors() {
        removeScreenshotEscapeMonitors()
        screenshotKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == UInt16(kVK_Escape) else { return event }
            if self?.screenshotEditorWindow?.firstResponder is NSTextView {
                return event
            }
            self?.closeScreenshotEditor()
            return nil
        }
        screenshotGlobalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == UInt16(kVK_Escape) else { return }
            Task { @MainActor [weak self] in
                self?.closeScreenshotEditor()
            }
        }
    }

    private func removeScreenshotEscapeMonitors() {
        if let screenshotKeyMonitor {
            NSEvent.removeMonitor(screenshotKeyMonitor)
            self.screenshotKeyMonitor = nil
        }
        if let screenshotGlobalKeyMonitor {
            NSEvent.removeMonitor(screenshotGlobalKeyMonitor)
            self.screenshotGlobalKeyMonitor = nil
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
        if let captureHotKey { UnregisterEventHotKey(captureHotKey) }
        if let ocrHotKey { UnregisterEventHotKey(ocrHotKey) }
        if let quickInputHotKey { UnregisterEventHotKey(quickInputHotKey) }
        translateHotKey = nil
        screenshotHotKey = nil
        captureHotKey = nil
        ocrHotKey = nil
        quickInputHotKey = nil
        let translateID = EventHotKeyID(signature: Self.hotKeySignature, id: Self.translateHotKeyID)
        let screenshotID = EventHotKeyID(signature: Self.hotKeySignature, id: Self.screenshotHotKeyID)
        let captureID = EventHotKeyID(signature: Self.hotKeySignature, id: Self.captureHotKeyID)
        let ocrID = EventHotKeyID(signature: Self.hotKeySignature, id: Self.ocrHotKeyID)
        let quickInputID = EventHotKeyID(signature: Self.hotKeySignature, id: Self.quickInputHotKeyID)
        RegisterEventHotKey(
            translateShortcutKey.carbonKeyCode, translateShortcutModifiers.carbonFlags, translateID,
            GetApplicationEventTarget(), 0, &translateHotKey
        )
        RegisterEventHotKey(
            screenshotShortcutKey.carbonKeyCode, screenshotShortcutModifiers.carbonFlags, screenshotID,
            GetApplicationEventTarget(), 0, &screenshotHotKey
        )
        RegisterEventHotKey(
            captureShortcutKey.carbonKeyCode, captureShortcutModifiers.carbonFlags, captureID,
            GetApplicationEventTarget(), 0, &captureHotKey
        )
        RegisterEventHotKey(
            ocrShortcutKey.carbonKeyCode, ocrShortcutModifiers.carbonFlags, ocrID,
            GetApplicationEventTarget(), 0, &ocrHotKey
        )
        RegisterEventHotKey(
            quickInputShortcutKey.carbonKeyCode, quickInputShortcutModifiers.carbonFlags, quickInputID,
            GetApplicationEventTarget(), 0, &quickInputHotKey
        )
    }

    private func handleRegisteredHotKey(_ id: UInt32) {
        guard Date().timeIntervalSince(lastShortcutTime) > 0.3 else { return }
        lastShortcutTime = Date()
        if id == Self.translateHotKeyID {
            toggleSelectionTranslation()
        } else if id == Self.screenshotHotKeyID {
            translateScreenshot()
        } else if id == Self.captureHotKeyID {
            captureScreenshot()
        } else if id == Self.ocrHotKeyID {
            recognizeScreenshot()
        } else if id == Self.quickInputHotKeyID {
            toggleQuickTranslationInput()
        }
    }

    private func handleSelectionMouseUp() {
        guard selectionEnabled, !NSApp.isActive, (showSelectionButton || autoTranslateSelection) else { return }
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier != "com.apple.finder" else {
            hideFloatingButton()
            return
        }
        accessibilityTrusted = AXIsProcessTrusted()
        guard accessibilityTrusted else { return }
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 180_000_000)
            guard let self,
                  self.selectionEnabled,
                  NSWorkspace.shared.frontmostApplication?.bundleIdentifier != "com.apple.finder",
                  let text = await self.selectedTextWithClipboardFallback(),
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            guard self.viewModel?.shouldTranslateFloatingText(text) != false else {
                self.hideFloatingButton()
                return
            }
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
        guard viewModel?.shouldTranslateFloatingText(text) != false else {
            hideFloatingButton()
            return
        }
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

    private func selectedTextWithClipboardFallback() async -> String? {
        if let text = selectedText(), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return text
        }
        guard accessibilityTrusted,
              let application = NSWorkspace.shared.frontmostApplication,
              application.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }

        let pasteboard = NSPasteboard.general
        let savedItems = pasteboard.pasteboardItems?.map { item in
            item.types.reduce(into: [NSPasteboard.PasteboardType: Data]()) { values, type in
                if let data = item.data(forType: type) { values[type] = data }
            }
        } ?? []
        let previousChangeCount = pasteboard.changeCount

        guard let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_ANSI_C), keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_ANSI_C), keyDown: false) else {
            return nil
        }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.postToPid(application.processIdentifier)
        keyUp.postToPid(application.processIdentifier)

        for _ in 0..<8 where pasteboard.changeCount == previousChangeCount {
            try? await Task.sleep(nanoseconds: 40_000_000)
        }
        let copiedText = pasteboard.changeCount != previousChangeCount
            ? pasteboard.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines)
            : nil
        restorePasteboard(savedItems, to: pasteboard)
        if let copiedText, !copiedText.isEmpty {
            logger.debug("selectedText used clipboard fallback for pid=\(application.processIdentifier, privacy: .public)")
            return copiedText
        }
        return nil
    }

    private func restorePasteboard(
        _ savedItems: [[NSPasteboard.PasteboardType: Data]],
        to pasteboard: NSPasteboard
    ) {
        pasteboard.clearContents()
        let items = savedItems.map { values -> NSPasteboardItem in
            let item = NSPasteboardItem()
            values.forEach { type, data in item.setData(data, forType: type) }
            return item
        }
        if !items.isEmpty { pasteboard.writeObjects(items) }
    }

    private func selectRegion(from image: CGImage) async throws -> ScreenshotSelection? {
        guard let screen = NSScreen.main else { return nil }
        let previousEditor = screenshotEditorWindow
        let previousApplication = lastExternalApplicationPID.flatMap(NSRunningApplication.init(processIdentifier:))

        // Opening a MenuBarExtra can temporarily activate this regular app.
        // Keep its main window hidden while the capture overlay is active so
        // dismissing the overlay with Escape cannot reveal it underneath.
        NSApp.windows
            .filter { $0.canBecomeMain && $0.title == "GPT 翻译助手" }
            .forEach { $0.orderOut(nil) }

        return await withCheckedContinuation { continuation in
            var panel: NSPanel?
            var hasFinished = false
            let overlay = ScreenshotOverlayView(image: image, frame: NSRect(origin: .zero, size: screen.frame.size)) { [weak self] rect in
                guard !hasFinished else { return }
                hasFinished = true
                let selection: ScreenshotSelection?
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
                    selection = image.cropping(to: imageRect).map {
                        ScreenshotSelection(
                            image: $0,
                            screenRect: CGRect(
                                x: screen.frame.minX + rect.minX,
                                y: screen.frame.minY + rect.minY,
                                width: rect.width,
                                height: rect.height
                            )
                        )
                    }
                } else {
                    selection = nil
                }
                panel?.orderOut(nil)
                self?.removeScreenshotEscapeMonitors()
                self?.overlayWindow = nil
                if rect == nil {
                    if let previousEditor {
                        previousEditor.orderFrontRegardless()
                    } else {
                        previousApplication?.activate(options: [.activateIgnoringOtherApps])
                    }
                }
                continuation.resume(returning: selection)
            }
            let newPanel = NSPanel(
                contentRect: screen.frame,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel = newPanel
            newPanel.contentView = overlay
            newPanel.level = .screenSaver
            newPanel.isOpaque = false
            newPanel.backgroundColor = .clear
            newPanel.hasShadow = false
            newPanel.acceptsMouseMovedEvents = true
            newPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            newPanel.orderFrontRegardless()
            self.overlayWindow = newPanel
            self.screenshotKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                if event.keyCode == UInt16(kVK_Escape) {
                    overlay.cancelSelection()
                    return nil
                }
                if event.keyCode == UInt16(kVK_ANSI_C), event.modifierFlags.contains(.command) {
                    overlay.copyCurrentColor()
                    return nil
                }
                return event
            }
            self.screenshotGlobalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
                Task { @MainActor in
                    if event.keyCode == UInt16(kVK_Escape) {
                        overlay.cancelSelection()
                    } else if event.keyCode == UInt16(kVK_ANSI_C), event.modifierFlags.contains(.command) {
                        overlay.copyCurrentColor()
                    }
                }
            }
        }
    }

    private func recognizeText(in image: CGImage) throws -> String? {
        try ScreenshotOCRService.recognizeText(in: image)
    }

    private func showScreenshotOCRStatus(_ message: String) {
        selectionStatusDismissWorkItem?.cancel()

        let size = NSSize(width: 220, height: 54)
        let panel: NSPanel
        if let selectionStatusWindow {
            panel = selectionStatusWindow
        } else {
            panel = NSPanel(
                contentRect: NSRect(origin: .zero, size: size),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.isReleasedWhenClosed = false
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.level = .floating
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.ignoresMouseEvents = true
            selectionStatusWindow = panel
        }

        panel.contentView = NSHostingView(rootView: ScreenshotOCRStatusHUD(message: message))
        let pointer = NSEvent.mouseLocation
        let visible = (NSScreen.screens.first { $0.frame.contains(pointer) } ?? NSScreen.main)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        panel.setFrameOrigin(NSPoint(
            x: visible.midX - size.width / 2,
            y: visible.midY + min(150, visible.height * 0.18)
        ))
        panel.alphaValue = 1
        panel.orderFrontRegardless()

        let workItem = DispatchWorkItem { [weak self, weak panel] in
            guard let self, let panel else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                panel.animator().alphaValue = 0
            } completionHandler: { [weak self, weak panel] in
                Task { @MainActor in
                    panel?.orderOut(nil)
                    self?.selectionStatusDismissWorkItem = nil
                }
            }
        }
        selectionStatusDismissWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.3, execute: workItem)
    }
}

private struct SelectionStatusHUD: View {
    let enabled: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: enabled ? "text.bubble.fill" : "text.bubble")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(enabled ? Color.green : Color.secondary)
            Text(enabled ? "划词翻译已开启" : "划词翻译已关闭")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 18)
        .frame(width: 210, height: 54)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .stroke(Color.primary.opacity(0.12), lineWidth: 1)
        }
    }
}

private struct ScreenshotOCRStatusHUD: View {
    let message: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "doc.text.viewfinder")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.green)
            Text(message)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 18)
        .frame(width: 220, height: 54)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .stroke(Color.primary.opacity(0.12), lineWidth: 1)
        }
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
        .overlay(alignment: .topLeading) {
            AppleTranslationBridgeHost(service: viewModel.appleService)
        }
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
    private var cursorPoint: NSPoint?
    private var copiedColorValue: String?
    private var trackingAreaReference: NSTrackingArea?
    private let onFinish: (CGRect?) -> Void

    init(image: CGImage, frame: NSRect, onFinish: @escaping (CGRect?) -> Void) {
        self.image = image
        self.onFinish = onFinish
        super.init(frame: frame)
        wantsLayer = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var acceptsFirstResponder: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaReference {
            removeTrackingArea(trackingAreaReference)
        }
        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseMoved, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        trackingAreaReference = trackingArea
    }

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

        if let cursorPoint {
            drawMagnifier(at: cursorPoint, in: context)
        }
    }

    override func mouseMoved(with event: NSEvent) {
        cursorPoint = boundedPoint(convert(event.locationInWindow, from: nil))
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        startPoint = boundedPoint(convert(event.locationInWindow, from: nil))
        currentPoint = startPoint
        cursorPoint = startPoint
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        currentPoint = boundedPoint(convert(event.locationInWindow, from: nil))
        cursorPoint = currentPoint
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
        if event.keyCode == UInt16(kVK_Escape) { cancelSelection() } else { super.keyDown(with: event) }
    }

    override func cancelOperation(_ sender: Any?) {
        cancelSelection()
    }

    func cancelSelection() {
        onFinish(nil)
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

    private func boundedPoint(_ point: NSPoint) -> NSPoint {
        NSPoint(x: min(max(point.x, 0), bounds.width), y: min(max(point.y, 0), bounds.height))
    }

    private func drawMagnifier(at point: NSPoint, in context: CGContext) {
        let scaleX = CGFloat(image.width) / bounds.width
        let scaleY = CGFloat(image.height) / bounds.height
        let imagePoint = CGPoint(
            x: min(max(point.x * scaleX, 0), CGFloat(image.width - 1)),
            y: min(max((bounds.height - point.y) * scaleY, 0), CGFloat(image.height - 1))
        )
        let sampleSide: CGFloat = 15
        let sourceRect = CGRect(
            x: min(max(imagePoint.x - sampleSide / 2, 0), CGFloat(image.width) - sampleSide),
            y: min(max(imagePoint.y - sampleSide / 2, 0), CGFloat(image.height) - sampleSide),
            width: min(sampleSide, CGFloat(image.width)),
            height: min(sampleSide, CGFloat(image.height))
        ).integral
        guard let sample = image.cropping(to: sourceRect) else { return }

        let boxSize = CGSize(width: 166, height: 190)
        var origin = CGPoint(x: point.x + 20, y: point.y - boxSize.height - 20)
        if origin.x + boxSize.width > bounds.maxX { origin.x = point.x - boxSize.width - 20 }
        if origin.y < bounds.minY { origin.y = point.y + 20 }
        origin.x = min(max(origin.x, 8), bounds.maxX - boxSize.width - 8)
        origin.y = min(max(origin.y, 8), bounds.maxY - boxSize.height - 8)
        let box = CGRect(origin: origin, size: boxSize)

        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -2), blur: 8, color: NSColor.black.withAlphaComponent(0.45).cgColor)
        context.setFillColor(NSColor.windowBackgroundColor.withAlphaComponent(0.96).cgColor)
        context.fill(box)
        context.restoreGState()

        let preview = CGRect(x: box.minX + 6, y: box.minY + 64, width: 154, height: 120)
        context.saveGState()
        context.interpolationQuality = .none
        context.draw(sample, in: preview)
        context.restoreGState()
        context.setStrokeColor(NSColor.white.withAlphaComponent(0.85).cgColor)
        context.setLineWidth(1)
        context.stroke(CGRect(x: preview.midX - 4, y: preview.midY - 4, width: 8, height: 8))

        let color = pixelColor(at: imagePoint) ?? .clear
        color.setFill()
        NSBezierPath(roundedRect: CGRect(x: box.minX + 8, y: box.minY + 39, width: 18, height: 18), xRadius: 3, yRadius: 3).fill()
        let hexValue = hexString(for: color)
        let rgbValue = rgbString(for: color)
        (hexValue as NSString).draw(
            at: NSPoint(x: box.minX + 33, y: box.minY + 41),
            withAttributes: [
                .foregroundColor: NSColor.labelColor,
                // `monospacedSystemFont` can produce an invalid CoreText font
                // attribute on some macOS 26 builds and crash while the
                // screenshot magnifier is drawn. The regular system font is
                // stable here and the short color value remains aligned.
                .font: NSFont.systemFont(ofSize: 12, weight: .medium)
            ]
        )
        (rgbValue as NSString).draw(
            at: NSPoint(x: box.minX + 8, y: box.minY + 23),
            withAttributes: [
                .foregroundColor: NSColor.labelColor,
                .font: NSFont.systemFont(ofSize: 11, weight: .regular)
            ]
        )
        let copyHint = copiedColorValue == hexValue ? "已复制 HEX + RGB" : "⌘C 复制色号"
        (copyHint as NSString).draw(
            at: NSPoint(x: box.minX + 8, y: box.minY + 7),
            withAttributes: [
                .foregroundColor: copiedColorValue == hexValue ? NSColor.systemGreen : NSColor.secondaryLabelColor,
                .font: NSFont.systemFont(ofSize: 10, weight: .medium)
            ]
        )
    }

    private func pixelColor(at point: CGPoint) -> NSColor? {
        guard let pixel = image.cropping(to: CGRect(x: floor(point.x), y: floor(point.y), width: 1, height: 1)) else { return nil }
        var bytes = [UInt8](repeating: 0, count: 4)
        guard let context = CGContext(
            data: &bytes,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return NSColor(
            calibratedRed: CGFloat(bytes[0]) / 255,
            green: CGFloat(bytes[1]) / 255,
            blue: CGFloat(bytes[2]) / 255,
            alpha: CGFloat(bytes[3]) / 255
        )
    }

    private func hexString(for color: NSColor) -> String {
        guard let rgb = color.usingColorSpace(.deviceRGB) else { return "#000000" }
        return String(
            format: "#%02X%02X%02X",
            Int((rgb.redComponent * 255).rounded()),
            Int((rgb.greenComponent * 255).rounded()),
            Int((rgb.blueComponent * 255).rounded())
        )
    }

    private func rgbString(for color: NSColor) -> String {
        guard let rgb = color.usingColorSpace(.deviceRGB) else { return "RGB(0, 0, 0)" }
        return String(
            format: "RGB(%d, %d, %d)",
            Int((rgb.redComponent * 255).rounded()),
            Int((rgb.greenComponent * 255).rounded()),
            Int((rgb.blueComponent * 255).rounded())
        )
    }

    func copyCurrentColor() {
        guard let cursorPoint else { return }
        let scaleX = CGFloat(image.width) / bounds.width
        let scaleY = CGFloat(image.height) / bounds.height
        let imagePoint = CGPoint(
            x: min(max(cursorPoint.x * scaleX, 0), CGFloat(image.width - 1)),
            y: min(max((bounds.height - cursorPoint.y) * scaleY, 0), CGFloat(image.height - 1))
        )
        guard let color = pixelColor(at: imagePoint) else { return }
        let value = hexString(for: color)
        let rgbValue = rgbString(for: color)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("\(value)\n\(rgbValue)", forType: .string)
        copiedColorValue = value
        needsDisplay = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard self?.copiedColorValue == value else { return }
            self?.copiedColorValue = nil
            self?.needsDisplay = true
        }
    }
}
