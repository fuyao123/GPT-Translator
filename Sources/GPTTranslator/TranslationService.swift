import Foundation

struct CodexCLIService: Sendable {
    enum ServiceError: LocalizedError, Sendable {
        case codexNotInstalled
        case notLoggedIn
        case processFailed(String)
        case emptyResult

        var errorDescription: String? {
            switch self {
            case .codexNotInstalled:
                return "没有找到 Codex CLI。请先安装并运行 codex login。"
            case .notLoggedIn:
                return "尚未登录 ChatGPT，请在设置中点击“使用 ChatGPT 登录”。"
            case .processFailed(let message):
                return message
            case .emptyResult:
                return "模型没有返回翻译结果。"
            }
        }
    }

    private struct ProcessOutput: Sendable {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    private var codexURL: URL? {
        var candidates = [
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            "/usr/bin/codex"
        ]
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            candidates += path.split(separator: ":").map { "\($0)/codex" }
        }
        if let candidate = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return URL(fileURLWithPath: candidate)
        }
        return nil
    }

    func isInstalled() -> Bool {
        codexURL != nil
    }

    func loginStatus() async -> Bool {
        guard isInstalled() else { return false }
        do {
            let output = try await run(arguments: ["login", "status"])
            let combinedOutput = output.stdout + "\n" + output.stderr
            return output.status == 0 && combinedOutput.localizedCaseInsensitiveContains("logged in")
        } catch {
            return false
        }
    }

    func login() async throws {
        guard isInstalled() else { throw ServiceError.codexNotInstalled }
        let output = try await run(arguments: ["login"])
        guard output.status == 0 else {
            throw ServiceError.processFailed(output.stderr.isEmpty ? "ChatGPT 登录失败。" : output.stderr)
        }
    }

    func warmUp(model: String, reasoning: ReasoningEffort) async {
        guard let codexURL else { return }
        try? await CodexAppServerClient.shared.warmUp(
            model: model,
            reasoning: reasoning,
            executable: codexURL
        )
    }

    func translate(
        text: String,
        source: LanguageOption,
        target: LanguageOption,
        model: String,
        reasoning: ReasoningEffort
    ) async throws -> String {
        guard isInstalled() else { throw ServiceError.codexNotInstalled }
        do {
            return try await CodexAppServerClient.shared.translate(
                text: text,
                source: source,
                target: target,
                model: model,
                reasoning: reasoning,
                executable: codexURL!
            )
        } catch {
            // The app-server protocol is experimental. Keep the established CLI path as a fallback.
        }
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("gpt-translator-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: outputURL) }

        let sourceDescription = source == .auto ? "the detected source language" : source.promptName
        let prompt = """
        Translate the text below from \(sourceDescription) into \(target.promptName).
        Preserve meaning, tone, paragraphs, punctuation, Markdown, and line breaks.
        Return only the translation, without quotation marks, explanations, or a preface.

        <text>
        \(text)
        </text>
        """

        var arguments = [
            "exec", "--skip-git-repo-check", "--ephemeral", "--color", "never",
            "-s", "read-only", "-o", outputURL.path
        ]
        if !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            arguments += ["--model", model.trimmingCharacters(in: .whitespacesAndNewlines)]
        }
        if reasoning != .none {
            arguments += ["-c", "model_reasoning_effort=\"\(reasoning.rawValue)\""]
        }
        arguments.append("-")

        let processOutput = try await run(arguments: arguments, input: prompt)
        guard processOutput.status == 0 else {
            let message = processOutput.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            if message.localizedCaseInsensitiveContains("login")
                || message.localizedCaseInsensitiveContains("authentication") {
                throw ServiceError.notLoggedIn
            }
            throw ServiceError.processFailed(message.isEmpty ? "翻译进程执行失败。" : message)
        }
        guard let result = try? String(contentsOf: outputURL, encoding: .utf8),
              !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ServiceError.emptyResult
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func run(arguments: [String], input: String? = nil) async throws -> ProcessOutput {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: runSynchronously(arguments: arguments, input: input))
            }
        }
    }

    private func runSynchronously(arguments: [String], input: String? = nil) -> ProcessOutput {
        let process = Process()
        guard let executable = codexURL else {
            return ProcessOutput(status: -1, stdout: "", stderr: ServiceError.codexNotInstalled.localizedDescription)
        }
        process.executableURL = executable
        process.arguments = arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        if let input {
            let inputPipe = Pipe()
            process.standardInput = inputPipe
            do {
                try process.run()
                inputPipe.fileHandleForWriting.write(Data(input.utf8))
                inputPipe.fileHandleForWriting.closeFile()
            } catch {
                return ProcessOutput(status: -1, stdout: "", stderr: error.localizedDescription)
            }
        } else {
            do {
                try process.run()
            } catch {
                return ProcessOutput(status: -1, stdout: "", stderr: error.localizedDescription)
            }
        }

        process.waitUntilExit()
        let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return ProcessOutput(status: process.terminationStatus, stdout: stdout, stderr: stderr)
    }
}

private final class CodexAppServerClient: @unchecked Sendable {
    static let shared = CodexAppServerClient()

    private let queue = DispatchQueue(label: "com.gpttranslator.codex-app-server", qos: .userInitiated)
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var readBuffer = Data()
    private var nextRequestID = 1
    private var threadID: String?

    private init() {}

    func warmUp(model: String, reasoning: ReasoningEffort, executable: URL) async throws {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                do {
                    try ensureStarted(executable: executable, model: model, reasoning: reasoning)
                    continuation.resume()
                } catch {
                    stop()
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func translate(
        text: String,
        source: LanguageOption,
        target: LanguageOption,
        model: String,
        reasoning: ReasoningEffort,
        executable: URL
    ) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                do {
                    let result = try translateSynchronously(
                        text: text,
                        source: source,
                        target: target,
                        model: model,
                        reasoning: reasoning,
                        executable: executable
                    )
                    continuation.resume(returning: result)
                } catch {
                    stop()
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func translateSynchronously(
        text: String,
        source: LanguageOption,
        target: LanguageOption,
        model: String,
        reasoning: ReasoningEffort,
        executable: URL
    ) throws -> String {
        try ensureStarted(executable: executable, model: model, reasoning: reasoning)
        guard let threadID else { throw CodexCLIService.ServiceError.emptyResult }

        let sourceDescription = source == .auto ? "the detected source language" : source.promptName
        let prompt = "Translate from \(sourceDescription) to \(target.promptName). Preserve formatting. Return only the translation.\n\n\(text)"
        let requestID = allocateRequestID()
        let selectedModel: Any = model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? NSNull() : model
        try send([
            "jsonrpc": "2.0", "id": requestID, "method": "turn/start",
            "params": [
                "threadId": threadID,
                "input": [["type": "text", "text": prompt]],
                "model": selectedModel,
                "effort": reasoning.rawValue
            ]
        ])

        var translation: String?
        while true {
            let message = try readMessage()
            if let id = message["id"] as? Int, id == requestID, message["error"] != nil {
                throw CodexCLIService.ServiceError.processFailed("Codex 常驻翻译请求失败。")
            }
            if message["method"] as? String == "item/completed",
               let params = message["params"] as? [String: Any],
               let item = params["item"] as? [String: Any],
               item["type"] as? String == "agentMessage",
               let value = item["text"] as? String,
               !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                translation = value.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if message["method"] as? String == "turn/completed" {
                guard let translation else { throw CodexCLIService.ServiceError.emptyResult }
                // Translation requests are independent. Do not carry earlier source text into
                // the next request: that wastes input tokens and makes later translations slower.
                // The app-server process remains warm; only its lightweight thread is renewed.
                self.threadID = nil
                return translation
            }
        }
    }

    private func ensureStarted(executable: URL, model: String, reasoning: ReasoningEffort) throws {
        if process?.isRunning == true {
            if threadID != nil { return }
            try startThread(model: model, reasoning: reasoning)
            return
        }

        stop()

        let process = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.executableURL = executable
        process.arguments = [
            "--disable", "plugins", "--disable", "apps", "--disable", "memories",
            "--disable", "recommended_plugins", "--disable", "browser_use", "--disable", "computer_use",
            "app-server", "--stdio", "-c", "mcp_servers={}"
        ]
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        errorPipe.fileHandleForReading.readabilityHandler = { handle in _ = handle.availableData }
        try process.run()
        self.process = process
        input = inputPipe.fileHandleForWriting
        output = outputPipe.fileHandleForReading
        readBuffer.removeAll(keepingCapacity: true)

        let initializeID = allocateRequestID()
        try send([
            "jsonrpc": "2.0", "id": initializeID, "method": "initialize",
            "params": [
                "clientInfo": ["name": "gpt-translator", "version": "1.0"],
                "capabilities": ["experimentalApi": true]
            ]
        ])
        _ = try waitForResponse(id: initializeID)
        try send(["jsonrpc": "2.0", "method": "initialized", "params": [:]])

        try startThread(model: model, reasoning: reasoning)
    }

    private func startThread(model: String, reasoning: ReasoningEffort) throws {
        let threadRequestID = allocateRequestID()
        let selectedModel: Any = model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? NSNull() : model
        try send([
            "jsonrpc": "2.0", "id": threadRequestID, "method": "thread/start",
            "params": [
                "model": selectedModel,
                "ephemeral": true,
                "cwd": FileManager.default.temporaryDirectory.path,
                "approvalPolicy": "never",
                "sandbox": "read-only",
                "environments": [],
                "runtimeWorkspaceRoots": [],
                "selectedCapabilityRoots": [],
                "baseInstructions": "You are a translation engine. Never use tools. Return only the translation.",
                "config": ["model_reasoning_effort": reasoning.rawValue]
            ]
        ])
        let response = try waitForResponse(id: threadRequestID)
        guard let result = response["result"] as? [String: Any],
              let thread = result["thread"] as? [String: Any],
              let id = thread["id"] as? String else {
            throw CodexCLIService.ServiceError.processFailed("无法启动 Codex 常驻翻译服务。")
        }
        threadID = id
    }

    private func allocateRequestID() -> Int {
        defer { nextRequestID += 1 }
        return nextRequestID
    }

    private func waitForResponse(id: Int) throws -> [String: Any] {
        while true {
            let message = try readMessage()
            if message["id"] as? Int == id {
                if message["error"] != nil {
                    throw CodexCLIService.ServiceError.processFailed("Codex 常驻服务返回错误。")
                }
                return message
            }
        }
    }

    private func send(_ object: [String: Any]) throws {
        guard let input else { throw CodexCLIService.ServiceError.processFailed("Codex 常驻服务未启动。") }
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(0x0A)
        try input.write(contentsOf: data)
    }

    private func readMessage() throws -> [String: Any] {
        guard let output else { throw CodexCLIService.ServiceError.processFailed("Codex 常驻服务未启动。") }
        while true {
            if let newline = readBuffer.firstIndex(of: 0x0A) {
                let line = readBuffer[..<newline]
                readBuffer.removeSubrange(...newline)
                if line.isEmpty { continue }
                if let object = try JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] {
                    return object
                }
            }
            let data = output.availableData
            guard !data.isEmpty else { throw CodexCLIService.ServiceError.processFailed("Codex 常驻服务意外退出。") }
            readBuffer.append(data)
        }
    }

    private func stop() {
        input?.closeFile()
        output?.closeFile()
        process?.terminate()
        process = nil
        input = nil
        output = nil
        threadID = nil
        readBuffer.removeAll(keepingCapacity: false)
    }
}

struct DirectProviderService: Sendable {
    enum ServiceError: LocalizedError, Sendable {
        case missingAPIKey
        case unsupportedProvider
        case invalidResponse
        case emptyResult
        case api(String)

        var errorDescription: String? {
            switch self {
            case .missingAPIKey: return "请先在设置中填写该服务的 API Key。"
            case .unsupportedProvider: return "该服务需要使用 ChatGPT OAuth 登录。"
            case .invalidResponse: return "服务返回了无法识别的响应。"
            case .emptyResult: return "模型没有返回翻译结果。"
            case .api(let message): return message
            }
        }
    }

    private struct RequestBody: Encodable, Sendable {
        let model: String
        let messages: [Message]
        let reasoning_effort: String?

        struct Message: Encodable, Sendable {
            let role: String
            let content: String
        }
    }

    private struct ResponseBody: Decodable, Sendable {
        let choices: [Choice]

        struct Choice: Decodable, Sendable {
            let message: Message
        }

        struct Message: Decodable, Sendable {
            let content: String
        }
    }

    private struct ErrorBody: Decodable, Sendable {
        let error: APIError?

        struct APIError: Decodable, Sendable {
            let message: String?
        }
    }

    func translate(
        text: String,
        source: LanguageOption,
        target: LanguageOption,
        provider: ModelProvider,
        model: String,
        reasoning: ReasoningEffort,
        apiKey: String,
        customEndpoint: String = ""
    ) async throws -> String {
        guard provider.needsAPIKey else { throw ServiceError.unsupportedProvider }
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ServiceError.missingAPIKey
        }
        let url: URL?
        if provider == .customAPI {
            url = URL(string: customEndpoint.trimmingCharacters(in: .whitespacesAndNewlines))
        } else {
            url = provider.endpoint
        }
        guard let url else { throw ServiceError.api("请填写有效的 API 接口地址。") }

        let sourceDescription = source == .auto ? "the detected source language" : source.promptName
        let systemPrompt = """
        You are a professional translator. Translate from \(sourceDescription) into \(target.promptName).
        Preserve meaning, tone, paragraphs, punctuation, Markdown, and line breaks.
        Return only the translated text, without explanations or a preface.
        """
        let body = RequestBody(
            model: model.isEmpty ? provider.defaultModel : model,
            messages: [
                .init(role: "system", content: systemPrompt),
                .init(role: "user", content: text)
            ],
            reasoning_effort: reasoning.apiValue
        )

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 90
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey.trimmingCharacters(in: .whitespacesAndNewlines))", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else { throw ServiceError.invalidResponse }
        guard (200...299).contains(httpResponse.statusCode) else {
            if let errorBody = try? JSONDecoder().decode(ErrorBody.self, from: data),
               let message = errorBody.error?.message {
                throw ServiceError.api(message)
            }
            throw ServiceError.api("请求失败（HTTP \(httpResponse.statusCode)）。")
        }
        guard let result = try? JSONDecoder().decode(ResponseBody.self, from: data),
              let content = result.choices.first?.message.content.trimmingCharacters(in: .whitespacesAndNewlines),
              !content.isEmpty else {
            throw ServiceError.emptyResult
        }
        return content
    }

}
