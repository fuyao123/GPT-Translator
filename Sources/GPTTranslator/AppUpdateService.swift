import Foundation

struct AppRelease: Equatable, Sendable {
    let version: String
    let pageURL: URL
}

enum AppUpdateState: Equatable, Sendable {
    case idle
    case checking
    case upToDate
    case available(AppRelease)
    case failed(String)
}

struct AppUpdateService: Sendable {
    private let latestReleaseURL = URL(
        string: "https://github.com/fuyao123/GPT-Translator-macOS/releases/latest"
    )!

    func latestRelease() async throws -> AppRelease {
        var request = URLRequest(url: latestReleaseURL)
        request.timeoutInterval = 12
        request.setValue("GPT-Translator-macOS", forHTTPHeaderField: "User-Agent")

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode),
              let finalURL = httpResponse.url,
              finalURL.path.contains("/releases/tag/") else {
            throw URLError(.badServerResponse)
        }

        return AppRelease(
            version: Self.normalizedVersion(finalURL.lastPathComponent),
            pageURL: finalURL
        )
    }

    func isNewer(_ candidate: String, than current: String) -> Bool {
        let candidateParts = Self.versionParts(candidate)
        let currentParts = Self.versionParts(current)
        let count = max(candidateParts.count, currentParts.count)

        for index in 0..<count {
            let candidatePart = index < candidateParts.count ? candidateParts[index] : 0
            let currentPart = index < currentParts.count ? currentParts[index] : 0
            if candidatePart != currentPart {
                return candidatePart > currentPart
            }
        }
        return false
    }

    private static func normalizedVersion(_ version: String) -> String {
        var result = version.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.lowercased().hasPrefix("v") {
            result.removeFirst()
        }
        return result
    }

    private static func versionParts(_ version: String) -> [Int] {
        normalizedVersion(version)
            .split(separator: "-", maxSplits: 1)[0]
            .split(separator: ".")
            .map { Int($0) ?? 0 }
    }
}
