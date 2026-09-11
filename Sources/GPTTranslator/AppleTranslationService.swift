import Foundation
import NaturalLanguage
import SwiftUI
@preconcurrency import Translation

@MainActor
final class AppleTranslationService {
    enum ServiceError: LocalizedError {
        case systemTooOld
        case languageUndetected
        case unsupportedPair
        case languagePackNotInstalled(source: String, target: String)

        var errorDescription: String? {
            switch self {
            case .systemTooOld:
                return "Apple 翻译需要 macOS 15 或更高版本。"
            case .languageUndetected:
                return "Apple 翻译无法识别原文语言。"
            case .unsupportedPair:
                return "Apple 翻译不支持这个语言组合。"
            case .languagePackNotInstalled(let source, let target):
                return "Apple 翻译缺少 \(source) 或 \(target) 语言包。请在系统设置“通用 → 语言与地区 → 翻译语言”中下载这两种语言后再使用。"
            }
        }
    }

    private let sessionModelStorage: AnyObject?

    init() {
        if #available(macOS 15.0, *) {
            sessionModelStorage = AppleTranslationSessionModel()
        } else {
            sessionModelStorage = nil
        }
    }

    func translate(text: String, source: LanguageOption, target: LanguageOption) async throws -> String {
        guard #available(macOS 15.0, *) else { throw ServiceError.systemTooOld }
        let sourceLanguage = try resolvedSourceLanguage(source, text: text)
        guard let targetLanguage = target.localeLanguage else { throw ServiceError.unsupportedPair }

        let status = await LanguageAvailability().status(from: sourceLanguage, to: targetLanguage)
        switch status {
        case .installed:
            break
        case .supported:
            throw ServiceError.languagePackNotInstalled(
                source: languageDisplayName(sourceLanguage),
                target: languageDisplayName(targetLanguage)
            )
        case .unsupported:
            throw ServiceError.unsupportedPair
        @unknown default:
            throw ServiceError.unsupportedPair
        }

        if #available(macOS 26.0, *) {
            let session = TranslationSession(installedSource: sourceLanguage, target: targetLanguage)
            let response = try await session.translate(text)
            return response.targetText.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return try await sessionModel.translate(text: text, source: sourceLanguage, target: targetLanguage)
    }

    func testInstalledPair(source: LanguageOption, target: LanguageOption, sampleText: String) async throws {
        guard #available(macOS 15.0, *) else { throw ServiceError.systemTooOld }
        let sourceLanguage = try resolvedSourceLanguage(source, text: sampleText)
        guard let targetLanguage = target.localeLanguage else { throw ServiceError.unsupportedPair }
        let status = await LanguageAvailability().status(from: sourceLanguage, to: targetLanguage)
        switch status {
        case .installed:
            return
        case .supported:
            throw ServiceError.languagePackNotInstalled(
                source: languageDisplayName(sourceLanguage),
                target: languageDisplayName(targetLanguage)
            )
        case .unsupported:
            throw ServiceError.unsupportedPair
        @unknown default:
            throw ServiceError.unsupportedPair
        }
    }

    @available(macOS 15.0, *)
    var sessionModel: AppleTranslationSessionModel {
        sessionModelStorage as! AppleTranslationSessionModel
    }

    private func resolvedSourceLanguage(_ source: LanguageOption, text: String) throws -> Locale.Language {
        if let language = source.localeLanguage { return language }

        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { throw ServiceError.languageUndetected }

        // NaturalLanguage frequently labels short Simplified Chinese words whose
        // glyphs are shared with Traditional Chinese (for example “所以” and
        // “可以”) as zh-Hant. This app exposes Simplified Chinese as its Chinese
        // language option, so prefer zh-Hans for Han-only text before asking the
        // statistical recognizer and avoid a false missing-language-pack error.
        if looksLikeHanText(trimmedText) {
            return Locale.Language(identifier: "zh-Hans")
        }

        guard let detected = NLLanguageRecognizer.dominantLanguage(for: trimmedText) else {
            if looksLikeLatinText(trimmedText) {
                return Locale.Language(identifier: "en")
            }
            throw ServiceError.languageUndetected
        }

        // NaturalLanguage can assign a short English brand name or acronym to an
        // unrelated language (for example, "Gemini" -> Turkish and "OK" -> Polish).
        // If that language is outside the app's supported language set, a short
        // Latin-script input is safer to treat as English than to report a false
        // missing-language-pack error.
        if shouldPreferEnglish(for: trimmedText, detected: detected) {
            return Locale.Language(identifier: "en")
        }

        if detected == .simplifiedChinese || detected == .traditionalChinese {
            return Locale.Language(identifier: "zh-Hans")
        }
        return Locale.Language(identifier: detected.rawValue)
    }

    private func shouldPreferEnglish(for text: String, detected: NLLanguage) -> Bool {
        guard looksLikeLatinText(text) else { return false }

        let supportedLanguageCodes: Set<String> = [
            NLLanguage.english.rawValue,
            NLLanguage.simplifiedChinese.rawValue,
            NLLanguage.traditionalChinese.rawValue,
            NLLanguage.japanese.rawValue,
            NLLanguage.korean.rawValue,
            NLLanguage.spanish.rawValue,
            NLLanguage.french.rawValue,
            NLLanguage.german.rawValue
        ]
        guard !supportedLanguageCodes.contains(detected.rawValue) else { return false }

        let wordCount = text.split(whereSeparator: { $0.isWhitespace || $0.isPunctuation }).count
        return text.count <= 40 || wordCount <= 4
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

    private func looksLikeHanText(_ text: String) -> Bool {
        let letters = text.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        guard !letters.isEmpty else { return false }
        return letters.allSatisfy { scalar in
            switch scalar.value {
            case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF:
                return true
            default:
                return false
            }
        }
    }

    private func languageDisplayName(_ language: Locale.Language) -> String {
        let identifier = (language.languageCode?.identifier ?? language.minimalIdentifier).lowercased()
        switch identifier {
        case "en", "en-us", "en-gb": return "English"
        case "zh", "zh-cn", "zh-hans", "zh-hans-cn": return "中文"
        case "ja", "ja-jp": return "日本語"
        case "ko", "ko-kr": return "한국어"
        case "es", "es-es": return "Español"
        case "fr", "fr-fr": return "Français"
        case "de", "de-de": return "Deutsch"
        default:
            let code = identifier.split(separator: "-").first.map(String.init) ?? identifier
            return Locale.current.localizedString(forLanguageCode: code) ?? identifier
        }
    }
}

@available(macOS 15.0, *)
@MainActor
final class AppleTranslationSessionModel: ObservableObject {
    @Published var configuration: TranslationSession.Configuration?

    private struct PendingRequest {
        let text: String
        let source: Locale.Language
        let target: Locale.Language
        let continuation: CheckedContinuation<String, Error>
    }

    private var requests: [PendingRequest] = []
    private var activeRequest: PendingRequest?
    private var isProcessing = false

    func translate(text: String, source: Locale.Language, target: Locale.Language) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            requests.append(PendingRequest(
                text: text,
                source: source,
                target: target,
                continuation: continuation
            ))
            startNextRequestIfNeeded()
        }
    }

    func beginSession(source: Locale.Language?, target: Locale.Language?) -> String? {
        guard !isProcessing,
              let request = activeRequest,
              source == request.source,
              target == request.target else { return nil }
        isProcessing = true
        return request.text
    }

    func completeSession(result: String?, errorMessage: String?) {
        guard let request = activeRequest, isProcessing else { return }
        if let result {
            request.continuation.resume(returning: result.trimmingCharacters(in: .whitespacesAndNewlines))
        } else {
            request.continuation.resume(throwing: NSError(
                domain: "AppleTranslation",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: errorMessage ?? "Apple 翻译失败。"]
            ))
        }
        activeRequest = nil
        isProcessing = false
        configuration = nil
        startNextRequestIfNeeded()
    }

    private func startNextRequestIfNeeded() {
        guard activeRequest == nil, !requests.isEmpty else { return }
        let request = requests.removeFirst()
        activeRequest = request
        configuration = nil
        Task { @MainActor [weak self] in
            await Task.yield()
            guard let self, let current = self.activeRequest else { return }
            self.configuration = TranslationSession.Configuration(source: current.source, target: current.target)
        }
    }
}

struct AppleTranslationBridgeHost: View {
    let service: AppleTranslationService

    @ViewBuilder
    var body: some View {
        if #available(macOS 15.0, *) {
            AppleTranslationSessionHost(model: service.sessionModel)
        } else {
            EmptyView()
        }
    }
}

@available(macOS 15.0, *)
private struct AppleTranslationSessionHost: View {
    @ObservedObject var model: AppleTranslationSessionModel

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .translationTask(model.configuration) { session in
                let source = session.sourceLanguage
                let target = session.targetLanguage
                guard let text = await MainActor.run(body: {
                    model.beginSession(source: source, target: target)
                }) else { return }
                do {
                    try await session.prepareTranslation()
                    let response = try await session.translate(text)
                    await MainActor.run {
                        model.completeSession(result: response.targetText, errorMessage: nil)
                    }
                } catch {
                    let message = error.localizedDescription
                    await MainActor.run {
                        model.completeSession(result: nil, errorMessage: message)
                    }
                }
            }
    }
}
