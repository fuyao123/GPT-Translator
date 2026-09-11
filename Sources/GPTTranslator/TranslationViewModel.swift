import AppKit
import Foundation
import NaturalLanguage
import SwiftUI

enum LanguageOption: String, CaseIterable, Identifiable, Codable, Sendable {
    case auto
    case chineseSimplified
    case english
    case japanese
    case korean
    case spanish
    case french
    case german

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .auto: return "自动识别"
        case .chineseSimplified: return "中文"
        case .english: return "English"
        case .japanese: return "日本語"
        case .korean: return "한국어"
        case .spanish: return "Español"
        case .french: return "Français"
        case .german: return "Deutsch"
        }
    }

    var promptName: String {
        switch self {
        case .auto: return "the detected source language"
        case .chineseSimplified: return "Simplified Chinese"
        case .english: return "English"
        case .japanese: return "Japanese"
        case .korean: return "Korean"
        case .spanish: return "Spanish"
        case .french: return "French"
        case .german: return "German"
        }
    }

    var googleCode: String {
        switch self {
        case .auto: return "auto"
        case .chineseSimplified: return "zh-CN"
        case .english: return "en"
        case .japanese: return "ja"
        case .korean: return "ko"
        case .spanish: return "es"
        case .french: return "fr"
        case .german: return "de"
        }
    }

    var localeLanguage: Locale.Language? {
        guard self != .auto else { return nil }
        return Locale.Language(identifier: googleCode)
    }
}

struct CustomAPISource: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var displayName: String
    var endpoint: String
    var model: String

    init(id: UUID = UUID(), displayName: String = "自定义 API", endpoint: String = "", model: String = "") {
        self.id = id
        self.displayName = displayName
        self.endpoint = endpoint
        self.model = model
    }

    var keychainAccount: String { "customAPI.\(id.uuidString)" }
}

struct TranslationSource: Identifiable, Hashable, Sendable {
    let id: String
    let provider: ModelProvider
    let customAPIID: UUID?
    let displayName: String

    var shortName: String { displayName }
}

struct ComparisonTranslationResult: Identifiable, Sendable {
    let source: TranslationSource
    var translatedText: String?
    var errorMessage: String?
    var isLoading: Bool

    var id: String { source.id }
}

struct DefaultFallbackTranslationResult {
    let text: String
    let sourceName: String
}

enum ProviderConnectionState: Equatable, Sendable {
    case checking
    case connected
    case disconnected(String)
}

@MainActor
final class TranslationViewModel: ObservableObject {
    @Published var sourceText = ""
    @Published var translatedText = ""
    @Published var sourceLanguage: LanguageOption = .auto
    @Published var targetLanguage: LanguageOption = .english
    @Published var isTranslating = false
    @Published var errorMessage: String?
    @Published var isLoggedIn = false
    @Published var isLoggingIn = false
    @Published var provider: ModelProvider
    @Published var modelName: String
    @Published var reasoningEffort: ReasoningEffort
    @Published var apiKey: String
    @Published var customAPIEndpoint: String
    @Published var customAPIDisplayName: String
    @Published private(set) var customAPISources: [CustomAPISource]
    @Published var selectedCustomAPIID: UUID?
    @Published var translateChineseContent: Bool
    @Published var translateEnglishSelectionToChinese: Bool
    @Published var resultFontSize: CGFloat
    @Published var floatingSourceIDs: Set<String>
    @Published private(set) var floatingSourceOrder: [String]
    @Published private(set) var comparisonResults: [ComparisonTranslationResult] = []
    @Published private(set) var providerConnectionStates: [String: ProviderConnectionState] = [:]
    @Published private(set) var isTestingConnections = false
    @Published private(set) var updateState: AppUpdateState = .idle

    private let codexService: CodexCLIService
    private let antigravityService: AntigravityCLIService
    private let directService: DirectProviderService
    let appleService: AppleTranslationService
    private let keychain: KeychainStore
    private var automaticTranslationTask: Task<Void, Never>?
    private var pendingAutomaticTranslation = false
    private var lastSubmittedText = ""
    private var translationCache: [String: String] = [:]
    private var cacheOrder: [String] = []
    private var comparisonTasks: [Task<Void, Never>] = []
    private var connectionMonitorTask: Task<Void, Never>?
    private let updateService = AppUpdateService()
    private var hasCheckedForUpdates = false

    init(
        codexService: CodexCLIService = CodexCLIService(),
        antigravityService: AntigravityCLIService = AntigravityCLIService(),
        directService: DirectProviderService = DirectProviderService(),
        appleService: AppleTranslationService = AppleTranslationService(),
        keychain: KeychainStore = KeychainStore()
    ) {
        self.codexService = codexService
        self.antigravityService = antigravityService
        self.directService = directService
        self.appleService = appleService
        self.keychain = keychain

        let storedProvider = UserDefaults.standard.string(forKey: "provider")
            .flatMap(ModelProvider.init(rawValue:)) ?? .openAIChatGPT
        self.provider = storedProvider
        let decodedCustomSources = UserDefaults.standard.data(forKey: "customAPISources")
            .flatMap { try? JSONDecoder().decode([CustomAPISource].self, from: $0) } ?? []
        let legacyEndpoint = UserDefaults.standard.string(forKey: "customAPIEndpoint") ?? ""
        let legacyModel = UserDefaults.standard.string(forKey: Self.modelKey(for: .customAPI)) ?? ""
        let initialCustomSources = decodedCustomSources.isEmpty
            ? [CustomAPISource(displayName: "Gemini", endpoint: legacyEndpoint, model: legacyModel)]
            : decodedCustomSources
        self.customAPISources = initialCustomSources
        let savedCustomID = UserDefaults.standard.string(forKey: "selectedCustomAPIID").flatMap(UUID.init(uuidString:))
        let initialCustom = initialCustomSources.first(where: { $0.id == savedCustomID }) ?? initialCustomSources[0]
        self.selectedCustomAPIID = initialCustom.id
        self.customAPIDisplayName = initialCustom.displayName
        self.customAPIEndpoint = initialCustom.endpoint
        let storedModel = UserDefaults.standard.string(forKey: Self.modelKey(for: storedProvider))
            ?? (storedProvider == .openAIChatGPT ? UserDefaults.standard.string(forKey: "modelName") : nil)
        let obsoleteModels = ["gpt-4.1-mini", "deepseek-chat", "deepseek-reasoner"]
        self.modelName = storedProvider == .customAPI
            ? initialCustom.model
            : (storedModel.map(obsoleteModels.contains) == true ? storedProvider.defaultModel : (storedModel ?? storedProvider.defaultModel))
        self.reasoningEffort = UserDefaults.standard.string(forKey: "reasoningEffort")
            .flatMap(ReasoningEffort.init(rawValue:)) ?? .medium
        if storedProvider == .customAPI {
            self.apiKey = keychain.readAPIKey(account: initialCustom.keychainAccount)
                ?? keychain.readAPIKey(for: .customAPI)
                ?? ""
        } else {
            self.apiKey = storedProvider.needsAPIKey ? (keychain.readAPIKey(for: storedProvider) ?? "") : ""
        }
        self.translateChineseContent = UserDefaults.standard.object(forKey: "translateChineseContent") as? Bool ?? true
        self.translateEnglishSelectionToChinese = UserDefaults.standard.object(forKey: "translateEnglishSelectionToChinese") as? Bool ?? true
        self.resultFontSize = CGFloat(UserDefaults.standard.object(forKey: "resultFontSize") as? Double ?? 14)
        let customID = Self.customSourceID(initialCustom.id)
        let savedIDs = UserDefaults.standard.stringArray(forKey: "floatingSourceIDs")
            ?? (UserDefaults.standard.stringArray(forKey: "floatingProviders") ?? []).map { $0 == ModelProvider.customAPI.rawValue ? customID : $0 }
        self.floatingSourceIDs = savedIDs.isEmpty ? [ModelProvider.openAIChatGPT.rawValue, customID] : Set(savedIDs)
        let savedOrder = UserDefaults.standard.stringArray(forKey: "floatingSourceOrder")
            ?? (UserDefaults.standard.stringArray(forKey: "floatingProviderOrder") ?? []).map { $0 == ModelProvider.customAPI.rawValue ? customID : $0 }
        let allIDs = ModelProvider.allCases.filter { $0 != .customAPI }.map(\.rawValue)
            + initialCustomSources.map { Self.customSourceID($0.id) }
        self.floatingSourceOrder = Self.normalizedSourceOrder(savedOrder, allIDs: allIDs)
        if decodedCustomSources.isEmpty, let legacyKey = keychain.readAPIKey(for: .customAPI), !legacyKey.isEmpty {
            _ = keychain.saveAPIKey(legacyKey, account: initialCustom.keychainAccount)
        }
        refreshLoginStatus()
    }

    var canTranslate: Bool {
        !sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isTranslating
    }

    var currentAppVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.1.2"
    }

    func checkForUpdates(force: Bool = false) async {
        if case .checking = updateState { return }
        guard force || !hasCheckedForUpdates else { return }

        hasCheckedForUpdates = true
        updateState = .checking
        do {
            let release = try await updateService.latestRelease()
            updateState = updateService.isNewer(release.version, than: currentAppVersion)
                ? .available(release)
                : .upToDate
        } catch {
            updateState = .failed(error.localizedDescription)
        }
    }

    var modelLabel: String {
        modelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "默认模型" : modelName
    }

    var providerReady: Bool {
        isProviderReady(provider)
    }

    var selectedCustomAPI: CustomAPISource? {
        customAPISources.first { $0.id == selectedCustomAPIID }
    }

    var activeProviderDisplayName: String {
        provider == .customAPI ? (selectedCustomAPI?.displayName ?? "自定义 API") : provider.shortName
    }

    var activeSourceID: String {
        provider == .customAPI ? selectedCustomAPIID.map(Self.customSourceID) ?? provider.rawValue : provider.rawValue
    }

    var allTranslationSources: [TranslationSource] {
        let builtIns = ModelProvider.allCases.filter { $0 != .customAPI }.map {
            TranslationSource(id: $0.rawValue, provider: $0, customAPIID: nil, displayName: $0.shortName)
        }
        let custom = customAPISources.map {
            TranslationSource(id: Self.customSourceID($0.id), provider: .customAPI, customAPIID: $0.id, displayName: $0.displayName)
        }
        return builtIns + custom
    }

    var enabledFloatingSources: [TranslationSource] {
        let byID = Dictionary(uniqueKeysWithValues: allTranslationSources.map { ($0.id, $0) })
        return floatingSourceOrder.compactMap { floatingSourceIDs.contains($0) ? byID[$0] : nil }
    }

    func isProviderReady(_ provider: ModelProvider) -> Bool {
        switch provider {
        case .openAIChatGPT:
            return isLoggedIn
        case .antigravityOAuth:
            return antigravityService.isInstalled()
        case .appleTranslation:
            if #available(macOS 15.0, *) { return true }
            return false
        case .googleWeb:
            return true
        case .customAPI:
            guard let config = selectedCustomAPI else { return false }
            return !(keychain.readAPIKey(account: config.keychainAccount) ?? apiKey)
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        default:
            if provider == self.provider {
                return !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            return !(keychain.readAPIKey(for: provider) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    func connectionState(for source: TranslationSource) -> ProviderConnectionState {
        providerConnectionStates[source.id] ?? .checking
    }

    func startConnectionMonitoring() {
        guard connectionMonitorTask == nil else { return }
        connectionMonitorTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.testEnabledProviderConnections()
                try? await Task.sleep(nanoseconds: 3_600_000_000_000)
            }
        }
    }

    func testEnabledProviderConnections() async {
        guard !isTestingConnections else { return }
        isTestingConnections = true
        defer { isTestingConnections = false }
        let sources = enabledFloatingSources
        for source in sources {
            providerConnectionStates[source.id] = .checking
        }

        await withTaskGroup(of: (String, ProviderConnectionState).self) { group in
            for source in sources {
                group.addTask { [weak self] in
                    guard let self else { return (source.id, .disconnected("应用已停止")) }
                    do {
                        try await self.performConnectionTest(for: source)
                        return (source.id, .connected)
                    } catch {
                        return (source.id, .disconnected(error.localizedDescription))
                    }
                }
            }
            for await (sourceID, state) in group {
                providerConnectionStates[sourceID] = state
            }
        }
    }

    func selectProvider(_ newProvider: ModelProvider) {
        guard newProvider != provider else { return }
        persistCurrentProviderSettings()
        provider = newProvider
        if newProvider == .customAPI, let config = selectedCustomAPI {
            customAPIDisplayName = config.displayName
            customAPIEndpoint = config.endpoint
            modelName = config.model
            apiKey = keychain.readAPIKey(account: config.keychainAccount) ?? ""
        } else {
            modelName = UserDefaults.standard.string(forKey: modelKey(for: newProvider)) ?? newProvider.defaultModel
            apiKey = newProvider.needsAPIKey
                ? (keychain.readAPIKey(for: newProvider) ?? "")
                : ""
        }
        errorMessage = nil
        refreshLoginStatus()
        translatedText = ""
        lastSubmittedText = ""
        if !sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            scheduleAutomaticTranslation(delayNanoseconds: 100_000_000)
        }
    }

    func selectTranslationSource(_ source: TranslationSource) {
        guard source.id != activeSourceID else { return }
        persistCurrentProviderSettings()

        if source.provider == .customAPI,
           let id = source.customAPIID,
           let config = customAPISources.first(where: { $0.id == id }) {
            provider = .customAPI
            selectedCustomAPIID = id
            customAPIDisplayName = config.displayName
            customAPIEndpoint = config.endpoint
            modelName = config.model
            apiKey = keychain.readAPIKey(account: config.keychainAccount) ?? ""
            UserDefaults.standard.set(id.uuidString, forKey: "selectedCustomAPIID")
        } else {
            provider = source.provider
            modelName = UserDefaults.standard.string(forKey: modelKey(for: source.provider)) ?? source.provider.defaultModel
            apiKey = source.provider.needsAPIKey
                ? (keychain.readAPIKey(for: source.provider) ?? "")
                : ""
        }

        errorMessage = nil
        translatedText = ""
        lastSubmittedText = ""
        refreshLoginStatus()
        if !sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            scheduleAutomaticTranslation(delayNanoseconds: 100_000_000)
        }
    }

    func selectCustomAPI(_ id: UUID) {
        persistCurrentProviderSettings()
        guard let config = customAPISources.first(where: { $0.id == id }) else { return }
        selectedCustomAPIID = id
        customAPIDisplayName = config.displayName
        customAPIEndpoint = config.endpoint
        modelName = config.model
        apiKey = keychain.readAPIKey(account: config.keychainAccount) ?? ""
        UserDefaults.standard.set(id.uuidString, forKey: "selectedCustomAPIID")
    }

    func authorizeSelectedAPIKeyFromKeychain() {
        if provider == .customAPI, let config = selectedCustomAPI {
            apiKey = keychain.readAPIKey(account: config.keychainAccount, allowInteraction: true) ?? ""
        } else if provider.needsAPIKey {
            apiKey = keychain.readAPIKey(for: provider, allowInteraction: true) ?? ""
        }
    }

    func addCustomAPI() {
        persistCurrentProviderSettings()
        let config = CustomAPISource(displayName: "新自定义 API")
        customAPISources.append(config)
        floatingSourceOrder.append(Self.customSourceID(config.id))
        selectedCustomAPIID = config.id
        customAPIDisplayName = config.displayName
        customAPIEndpoint = ""
        modelName = ""
        apiKey = ""
        persistCustomSources()
    }

    func deleteSelectedCustomAPI() {
        guard customAPISources.count > 1, let id = selectedCustomAPIID else { return }
        let sourceID = Self.customSourceID(id)
        _ = keychain.deleteAPIKey(account: "customAPI.\(id.uuidString)")
        customAPISources.removeAll { $0.id == id }
        floatingSourceIDs.remove(sourceID)
        floatingSourceOrder.removeAll { $0 == sourceID }
        selectCustomAPI(customAPISources[0].id)
        persistCustomSources()
    }

    func refreshLoginStatus() {
        Task {
            isLoggedIn = await codexService.loginStatus()
            if isLoggedIn, provider == .openAIChatGPT {
                await codexService.warmUp(model: modelName, reasoning: reasoningEffort)
            } else if provider == .antigravityOAuth {
                await antigravityService.warmUp()
            }
        }
    }

    func loginWithChatGPT() {
        guard provider == .openAIChatGPT, !isLoggingIn else { return }
        isLoggingIn = true
        errorMessage = nil
        Task {
            do {
                try await codexService.login()
                isLoggedIn = await codexService.loginStatus()
                if !isLoggedIn { errorMessage = "登录流程未完成，请重试。" }
            } catch {
                errorMessage = error.localizedDescription
            }
            isLoggingIn = false
        }
    }

    func translate() {
        guard !sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            errorMessage = "请输入需要翻译的内容。"
            return
        }
        guard !isTranslating else {
            pendingAutomaticTranslation = true
            return
        }
        errorMessage = nil
        isTranslating = true
        let text = sourceText
        lastSubmittedText = text
        pendingAutomaticTranslation = false
        let source = sourceLanguage
        let target = targetLanguage
        let selectedProvider = provider
        let model = modelName
        let reasoning = reasoningEffort
        let key = apiKey
        let cacheKey = makeCacheKey(text: text, source: source, target: target, provider: selectedProvider, model: model, reasoning: reasoning, sourceID: selectedProvider == .customAPI ? selectedCustomAPIID.map(Self.customSourceID) : nil)

        if let cached = translationCache[cacheKey] {
            translatedText = cached
            isTranslating = false
            return
        }

        Task {
            do {
                let result: String
                if selectedProvider == .openAIChatGPT {
                    result = try await codexService.translate(
                        text: text,
                        source: source,
                        target: target,
                        model: model,
                        reasoning: reasoning
                    )
                } else if selectedProvider == .antigravityOAuth {
                    result = try await antigravityService.translate(text: text, source: source, target: target)
                } else if selectedProvider == .appleTranslation {
                    result = try await appleService.translate(
                        text: text,
                        source: source,
                        target: target
                    )
                    providerConnectionStates[ModelProvider.appleTranslation.rawValue] = .connected
                } else {
                    result = try await directService.translate(
                        text: text,
                        source: source,
                        target: target,
                        provider: selectedProvider,
                        model: model,
                        reasoning: reasoning,
                        apiKey: key,
                        customEndpoint: customAPIEndpoint
                    )
                }
                if sourceText == text {
                    translatedText = result
                    storeInCache(result, for: cacheKey)
                }
            } catch {
                if sourceText == text {
                    errorMessage = error.localizedDescription
                }
                if case CodexCLIService.ServiceError.notLoggedIn = error {
                    isLoggedIn = false
                }
            }
            isTranslating = false
            if pendingAutomaticTranslation || sourceText != text {
                pendingAutomaticTranslation = false
                scheduleAutomaticTranslation(delayNanoseconds: 150_000_000)
            }
        }
    }

    func scheduleAutomaticTranslation(delayNanoseconds: UInt64? = nil) {
        automaticTranslationTask?.cancel()
        let text = sourceText
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            translatedText = ""
            errorMessage = nil
            lastSubmittedText = ""
            return
        }
        guard text != lastSubmittedText else { return }

        let cacheKey = makeCacheKey(
            text: text,
            source: sourceLanguage,
            target: targetLanguage,
            provider: provider,
            model: modelName,
            reasoning: reasoningEffort
        )
        if let cached = translationCache[cacheKey] {
            translatedText = cached
            errorMessage = nil
            lastSubmittedText = text
            return
        }

        translatedText = ""
        errorMessage = nil
        automaticTranslationTask = Task { [weak self] in
            let delay = delayNanoseconds ?? (self?.provider.isMachineTranslation == true ? 280_000_000 : 480_000_000)
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled,
                  let self,
                  self.sourceText == text else { return }
            self.translate()
        }
    }

    func setTextAndTranslate(_ text: String) {
        automaticTranslationTask?.cancel()
        sourceText = text
        translatedText = ""
        lastSubmittedText = ""
        translate()
    }

    func translateForFloatingWindow(_ text: String) {
        automaticTranslationTask?.cancel()
        comparisonTasks.forEach { $0.cancel() }
        comparisonTasks.removeAll()

        lastSubmittedText = text
        sourceText = text
        translatedText = ""
        errorMessage = nil

        let selected = enabledFloatingSources
        comparisonResults = selected.map {
            ComparisonTranslationResult(source: $0, translatedText: nil, errorMessage: nil, isLoading: true)
        }
        let source = sourceLanguage
        let target = floatingTargetLanguage(for: text)

        for translationSource in selected {
            let selectedProvider = translationSource.provider
            let customConfig = translationSource.customAPIID.flatMap { id in customAPISources.first { $0.id == id } }
            let model = customConfig?.model ?? (selectedProvider == provider
                ? modelName
                : (UserDefaults.standard.string(forKey: Self.modelKey(for: selectedProvider)) ?? selectedProvider.defaultModel))
            let reasoning = reasoningEffort
            let key = customConfig.map { keychain.readAPIKey(account: $0.keychainAccount) ?? "" }
                ?? (selectedProvider == provider ? apiKey : (keychain.readAPIKey(for: selectedProvider) ?? ""))
            let cacheKey = makeCacheKey(
                text: text,
                source: source,
                target: target,
                provider: selectedProvider,
                model: model,
                reasoning: reasoning,
                sourceID: translationSource.id
            )

            if let cached = translationCache[cacheKey] {
                updateComparisonResult(for: translationSource.id, translatedText: cached, errorMessage: nil)
                continue
            }

            let task = Task { [weak self] in
                guard let self else { return }
                do {
                    let result: String
                    if selectedProvider == .openAIChatGPT {
                        result = try await codexService.translate(
                            text: text,
                            source: source,
                            target: target,
                            model: model,
                            reasoning: reasoning
                        )
                    } else if selectedProvider == .antigravityOAuth {
                        result = try await antigravityService.translate(text: text, source: source, target: target)
                    } else if selectedProvider == .appleTranslation {
                        result = try await appleService.translate(
                            text: text,
                            source: source,
                            target: target
                        )
                        self.providerConnectionStates[ModelProvider.appleTranslation.rawValue] = .connected
                    } else {
                        result = try await directService.translate(
                            text: text,
                            source: source,
                            target: target,
                            provider: selectedProvider,
                            model: model,
                            reasoning: reasoning,
                            apiKey: key,
                            customEndpoint: customConfig?.endpoint ?? self.customAPIEndpoint
                        )
                    }
                    guard !Task.isCancelled, self.sourceText == text else { return }
                    self.storeInCache(result, for: cacheKey)
                    self.updateComparisonResult(for: translationSource.id, translatedText: result, errorMessage: nil)
                    if translationSource.id == self.activeSourceID {
                        self.translatedText = result
                    }
                } catch {
                    guard !Task.isCancelled, self.sourceText == text else { return }
                    self.updateComparisonResult(for: translationSource.id, translatedText: nil, errorMessage: error.localizedDescription)
                }
            }
            comparisonTasks.append(task)
        }
    }

    func translateQuickInput(_ text: String) async throws -> String {
        let defaultSource = TranslationSource(
            id: activeSourceID,
            provider: provider,
            customAPIID: provider == .customAPI ? selectedCustomAPIID : nil,
            displayName: activeProviderDisplayName
        )
        return try await translateQuickInput(text, with: defaultSource)
    }

    func translateWithDefaultFallback(_ text: String) async throws -> DefaultFallbackTranslationResult {
        let defaultSource = TranslationSource(
            id: activeSourceID,
            provider: provider,
            customAPIID: provider == .customAPI ? selectedCustomAPIID : nil,
            displayName: activeProviderDisplayName
        )
        let candidates = [defaultSource] + enabledFloatingSources.filter { $0.id != defaultSource.id }
        var failures: [String] = []
        for source in candidates {
            do {
                let translated = try await translateQuickInput(text, with: source)
                return DefaultFallbackTranslationResult(text: translated, sourceName: source.displayName)
            } catch {
                failures.append("\(source.displayName)：\(error.localizedDescription)")
            }
        }
        throw NSError(
            domain: "GPTTranslator.ScreenshotTranslation",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: failures.joined(separator: "；")]
        )
    }

    private func translateQuickInput(_ text: String, with sourceConfig: TranslationSource) async throws -> String {
        let selectedProvider = sourceConfig.provider
        let customConfig = sourceConfig.customAPIID.flatMap { id in customAPISources.first { $0.id == id } }
        let selectedModel = customConfig?.model ?? (selectedProvider == provider
            ? modelName
            : (UserDefaults.standard.string(forKey: Self.modelKey(for: selectedProvider)) ?? selectedProvider.defaultModel))
        let target = floatingTargetLanguage(for: text)
        let source: LanguageOption = target == .english ? .chineseSimplified : .english
        if selectedProvider == .openAIChatGPT {
            return try await codexService.translate(
                text: text,
                source: source,
                target: target,
                model: selectedModel,
                reasoning: .none
            )
        }

        if selectedProvider == .antigravityOAuth {
            return try await antigravityService.translate(text: text, source: source, target: target)
        }

        if selectedProvider == .appleTranslation {
            let result = try await appleService.translate(
                text: text,
                source: source,
                target: target
            )
            providerConnectionStates[ModelProvider.appleTranslation.rawValue] = .connected
            return result
        }

        let selectedKey: String
        let endpoint: String
        if selectedProvider == .customAPI, let config = customConfig {
            selectedKey = keychain.readAPIKey(account: config.keychainAccount) ?? apiKey
            endpoint = config.endpoint
        } else {
            selectedKey = selectedProvider == provider ? apiKey : (keychain.readAPIKey(for: selectedProvider) ?? "")
            endpoint = ""
        }
        return try await directService.translate(
            text: text,
            source: source,
            target: target,
            provider: selectedProvider,
            model: selectedModel,
            reasoning: .none,
            apiKey: selectedKey,
            customEndpoint: endpoint
        )
    }

    func shouldTranslateFloatingText(_ text: String) -> Bool {
        translateChineseContent || !isPredominantlyChinese(text)
    }

    func setTranslateChineseContent(_ enabled: Bool) {
        translateChineseContent = enabled
        UserDefaults.standard.set(enabled, forKey: "translateChineseContent")
    }

    func isFloatingSourceEnabled(_ source: TranslationSource) -> Bool {
        floatingSourceIDs.contains(source.id)
    }

    func setFloatingSource(_ source: TranslationSource, enabled: Bool) {
        if enabled {
            floatingSourceIDs.insert(source.id)
        } else if floatingSourceIDs.count > 1 {
            floatingSourceIDs.remove(source.id)
        }
        Task { await testEnabledProviderConnections() }
    }

    func moveComparisonProvider(_ sourceID: String, before destinationID: String) {
        guard sourceID != destinationID,
              let sourceIndex = comparisonResults.firstIndex(where: { $0.source.id == sourceID }),
              let destinationIndex = comparisonResults.firstIndex(where: { $0.source.id == destinationID }) else { return }

        let result = comparisonResults.remove(at: sourceIndex)
        let insertionIndex = sourceIndex < destinationIndex ? destinationIndex - 1 : destinationIndex
        comparisonResults.insert(result, at: insertionIndex)
        persistFloatingSourceOrder(comparisonResults.map(\.source.id))
    }

    func moveComparisonProviderToEnd(_ sourceID: String) {
        guard let sourceIndex = comparisonResults.firstIndex(where: { $0.source.id == sourceID }),
              sourceIndex != comparisonResults.index(before: comparisonResults.endIndex) else { return }
        let result = comparisonResults.remove(at: sourceIndex)
        comparisonResults.append(result)
        persistFloatingSourceOrder(comparisonResults.map(\.source.id))
    }

    func swapLanguages() {
        guard sourceLanguage != .auto else { return }
        let oldSource = sourceLanguage
        sourceLanguage = targetLanguage
        targetLanguage = oldSource
        if !translatedText.isEmpty {
            sourceText = translatedText
            translatedText = ""
        }
    }

    func clear() {
        automaticTranslationTask?.cancel()
        sourceText = ""
        translatedText = ""
        errorMessage = nil
        lastSubmittedText = ""
    }

    func copyTranslation() {
        guard !translatedText.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(translatedText, forType: .string)
    }

    func increaseFontSize() {
        setFontSize(resultFontSize + 1)
    }

    func decreaseFontSize() {
        setFontSize(resultFontSize - 1)
    }

    func resetFontSize() {
        setFontSize(14)
    }

    private func setFontSize(_ size: CGFloat) {
        resultFontSize = min(max(size, 11), 24)
        UserDefaults.standard.set(Double(resultFontSize), forKey: "resultFontSize")
    }

    func saveSettings() {
        persistSettings()
        Task { await testEnabledProviderConnections() }
    }

    func persistSettings() {
        persistCurrentProviderSettings()
        UserDefaults.standard.set(provider.rawValue, forKey: "provider")
        UserDefaults.standard.set(reasoningEffort.rawValue, forKey: "reasoningEffort")
        UserDefaults.standard.set(Array(floatingSourceIDs).sorted(), forKey: "floatingSourceIDs")
        UserDefaults.standard.set(floatingSourceOrder, forKey: "floatingSourceOrder")
        UserDefaults.standard.set(translateChineseContent, forKey: "translateChineseContent")
        UserDefaults.standard.set(translateEnglishSelectionToChinese, forKey: "translateEnglishSelectionToChinese")
        UserDefaults.standard.set(Double(resultFontSize), forKey: "resultFontSize")
    }

    private func persistCurrentProviderSettings() {
        let trimmedModel = modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        modelName = trimmedModel
        if provider == .customAPI, let id = selectedCustomAPIID,
           let index = customAPISources.firstIndex(where: { $0.id == id }) {
            let trimmedName = customAPIDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
            customAPIDisplayName = trimmedName.isEmpty ? "自定义 API" : trimmedName
            customAPIEndpoint = customAPIEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
            customAPISources[index].displayName = customAPIDisplayName
            customAPISources[index].endpoint = customAPIEndpoint
            customAPISources[index].model = trimmedModel
            apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            _ = keychain.saveAPIKey(apiKey, account: customAPISources[index].keychainAccount)
            persistCustomSources()
        } else {
            UserDefaults.standard.set(trimmedModel, forKey: modelKey(for: provider))
        }
        if provider.needsAPIKey, provider != .customAPI {
            apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            _ = keychain.saveAPIKey(apiKey, for: provider)
        }
    }

    private func floatingTargetLanguage(for text: String) -> LanguageOption {
        guard translateEnglishSelectionToChinese else { return targetLanguage }
        if isPredominantlyChinese(text) {
            return .english
        }
        if looksLikeLatinText(text) {
            return .chineseSimplified
        }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        let hypotheses = recognizer.languageHypotheses(withMaximum: 3)
        if (hypotheses[.english] ?? 0) >= 0.5 { return .chineseSimplified }
        if (hypotheses[.simplifiedChinese] ?? 0) >= 0.5 || (hypotheses[.traditionalChinese] ?? 0) >= 0.5 {
            return .english
        }
        return targetLanguage
    }

    private func looksLikeLatinText(_ text: String) -> Bool {
        let letters = text.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        guard !letters.isEmpty else { return false }
        return letters.allSatisfy { scalar in
            switch scalar.value {
            case 0x0041...0x024F, 0x1E00...0x1EFF, 0x2C60...0x2C7F, 0xA720...0xA7FF:
                return true
            default:
                return false
            }
        }
    }

    private func isPredominantlyChinese(_ text: String) -> Bool {
        let scalars = text.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        guard !scalars.isEmpty else { return false }
        let hanCount = scalars.reduce(into: 0) { count, scalar in
            switch scalar.value {
            case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF:
                count += 1
            default:
                break
            }
        }
        return hanCount > 0 && hanCount * 2 >= scalars.count
    }

    private func performConnectionTest(for translationSource: TranslationSource) async throws {
        let testText = "connection test"
        let sourceLanguage: LanguageOption = .english
        let target: LanguageOption = .chineseSimplified

        let provider = translationSource.provider
        let customConfig = translationSource.customAPIID.flatMap { id in customAPISources.first { $0.id == id } }

        let model = customConfig?.model ?? (provider == self.provider
            ? modelName
            : (UserDefaults.standard.string(forKey: Self.modelKey(for: provider)) ?? provider.defaultModel))
        let key = customConfig.map { keychain.readAPIKey(account: $0.keychainAccount) ?? "" } ?? (provider == self.provider
            ? apiKey
            : (keychain.readAPIKey(for: provider) ?? ""))

        if provider == .openAIChatGPT {
            guard await codexService.loginStatus() else { throw CodexCLIService.ServiceError.notLoggedIn }
            _ = try await codexService.translate(
                text: testText,
                source: sourceLanguage,
                target: target,
                model: model,
                reasoning: reasoningEffort
            )
            isLoggedIn = true
        } else if provider == .antigravityOAuth {
            _ = try await antigravityService.translate(
                text: testText,
                source: sourceLanguage,
                target: target
            )
        } else if provider == .appleTranslation {
            try await appleService.testInstalledPair(
                source: sourceLanguage,
                target: target,
                sampleText: testText
            )
        } else {
            _ = try await directService.translate(
                text: testText,
                source: sourceLanguage,
                target: target,
                provider: provider,
                model: model,
                reasoning: reasoningEffort,
                apiKey: key,
                customEndpoint: customConfig?.endpoint ?? customAPIEndpoint
            )
        }
    }

    private static func modelKey(for provider: ModelProvider) -> String {
        "modelName.\(provider.rawValue)"
    }

    private static func customSourceID(_ id: UUID) -> String { "custom.\(id.uuidString)" }

    private static func normalizedSourceOrder(_ savedOrder: [String], allIDs: [String]) -> [String] {
        var seen = Set<String>()
        let validSavedOrder = savedOrder.filter { allIDs.contains($0) && seen.insert($0).inserted }
        return validSavedOrder + allIDs.filter { !seen.contains($0) }
    }

    private func persistFloatingSourceOrder(_ visibleOrder: [String]) {
        let visible = Set(visibleOrder)
        floatingSourceOrder = visibleOrder + floatingSourceOrder.filter { !visible.contains($0) }
        UserDefaults.standard.set(floatingSourceOrder, forKey: "floatingSourceOrder")
    }

    private func persistCustomSources() {
        if let data = try? JSONEncoder().encode(customAPISources) {
            UserDefaults.standard.set(data, forKey: "customAPISources")
        }
        UserDefaults.standard.set(selectedCustomAPIID?.uuidString, forKey: "selectedCustomAPIID")
        UserDefaults.standard.set(Array(floatingSourceIDs).sorted(), forKey: "floatingSourceIDs")
        UserDefaults.standard.set(floatingSourceOrder, forKey: "floatingSourceOrder")
    }

    private func modelKey(for provider: ModelProvider) -> String {
        Self.modelKey(for: provider)
    }

    private func makeCacheKey(text: String, source: LanguageOption, target: LanguageOption, provider: ModelProvider, model: String, reasoning: ReasoningEffort, sourceID: String? = nil) -> String {
        [sourceID ?? provider.rawValue, model, reasoning.rawValue, source.rawValue, target.rawValue, text].joined(separator: "\u{1F}")
    }

    private func storeInCache(_ result: String, for key: String) {
        if translationCache[key] == nil {
            cacheOrder.append(key)
        }
        translationCache[key] = result
        while cacheOrder.count > 100 {
            let oldest = cacheOrder.removeFirst()
            translationCache.removeValue(forKey: oldest)
        }
    }

    private func updateComparisonResult(for sourceID: String, translatedText: String?, errorMessage: String?) {
        guard let index = comparisonResults.firstIndex(where: { $0.source.id == sourceID }) else { return }
        comparisonResults[index].translatedText = translatedText
        comparisonResults[index].errorMessage = errorMessage
        comparisonResults[index].isLoading = false
    }
}
