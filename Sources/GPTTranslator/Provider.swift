import Foundation

enum ModelProvider: String, CaseIterable, Identifiable, Codable, Sendable {
    case openAIChatGPT
    case appleTranslation
    case deepSeek
    case zhipu
    case customAPI

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .openAIChatGPT: return "OpenAI / ChatGPT OAuth"
        case .appleTranslation: return "Apple 离线翻译"
        case .deepSeek: return "DeepSeek"
        case .zhipu: return "智谱 GLM"
        case .customAPI: return "自定义兼容 API"
        }
    }

    var shortName: String {
        switch self {
        case .openAIChatGPT: return "OpenAI"
        case .appleTranslation: return "Apple 离线"
        case .deepSeek: return "DeepSeek"
        case .zhipu: return "智谱"
        case .customAPI: return "自定义 API"
        }
    }

    var endpoint: URL? {
        switch self {
        case .openAIChatGPT, .appleTranslation, .customAPI: return nil
        case .deepSeek: return URL(string: "https://api.deepseek.com/chat/completions")
        case .zhipu: return URL(string: "https://open.bigmodel.cn/api/paas/v4/chat/completions")
        }
    }

    var needsAPIKey: Bool {
        switch self {
        case .openAIChatGPT, .appleTranslation: return false
        default: return true
        }
    }

    var isMachineTranslation: Bool {
        switch self {
        case .appleTranslation: return true
        default: return false
        }
    }

    var supportsModelSelection: Bool { !isMachineTranslation }

    var modelOptions: [String] {
        switch self {
        case .openAIChatGPT:
            return ["gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna", "gpt-5.5"]
        case .appleTranslation:
            return []
        case .deepSeek:
            return ["deepseek-chat", "deepseek-reasoner"]
        case .zhipu:
            return ["glm-5.3-flash", "glm-5-turbo", "glm-5.3", "glm-5.2", "glm-5.1", "glm-5", "glm-4.7", "glm-4.6", "glm-4.5-air", "glm-4.5"]
        case .customAPI:
            return []
        }
    }

    var defaultModel: String {
        switch self {
        case .openAIChatGPT: return ""
        case .appleTranslation: return ""
        case .deepSeek: return "deepseek-chat"
        case .zhipu: return "glm-5.3-flash"
        case .customAPI: return ""
        }
    }
}

enum ReasoningEffort: String, CaseIterable, Identifiable, Codable, Sendable {
    case none
    case low
    case medium
    case high
    case xhigh

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .none: return "关闭"
        case .low: return "低"
        case .medium: return "中"
        case .high: return "高"
        case .xhigh: return "极高"
        }
    }

    var apiValue: String? { self == .none ? nil : rawValue }
}
