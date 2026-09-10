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
        case languagePackNotInstalled

        var errorDescription: String? {
            switch self {
            case .systemTooOld:
                return "Apple 翻译需要 macOS 15 或更高版本。"
            case .languageUndetected:
                return "Apple 翻译无法识别原文语言。"
            case .unsupportedPair:
                return "Apple 翻译不支持这个语言组合。"
            case .languagePackNotInstalled:
                return "Apple 翻译语言包尚未下载；首次实际翻译时，macOS 会提示下载。"
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
        guard status != .unsupported else { throw ServiceError.unsupportedPair }

        if #available(macOS 26.0, *), status == .installed {
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
            throw ServiceError.languagePackNotInstalled
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
        guard let detected = NLLanguageRecognizer.dominantLanguage(for: text) else {
            throw ServiceError.languageUndetected
        }
        return Locale.Language(identifier: detected.rawValue)
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
