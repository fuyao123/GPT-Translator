import Foundation

struct AntigravityCLIService: Sendable {
    enum ServiceError: LocalizedError, Sendable {
        case notInstalled
        case processFailed(String)
        case emptyResult

        var errorDescription: String? {
            switch self {
            case .notInstalled:
                return "没有找到 Antigravity CLI（agy）。请先安装官方 CLI。"
            case .processFailed(let message):
                return message
            case .emptyResult:
                return "Gemini OAuth 没有返回翻译结果。"
            }
        }
    }

    private var executableURL: URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var candidates = ["\(home)/.local/bin/agy", "/opt/homebrew/bin/agy", "/usr/local/bin/agy"]
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            candidates += path.split(separator: ":").map { "\($0)/agy" }
        }
        return candidates.first(where: FileManager.default.isExecutableFile(atPath:)).map(URL.init(fileURLWithPath:))
    }

    func isInstalled() -> Bool { executableURL != nil }

    func warmUp() async {
        guard let executableURL else { return }

        // Starting the stream process alone does not always wake a dormant
        // Antigravity/Gemini session. Send a tiny real turn so the first user
        // translation does not have to perform that initialization.
        let prompt = "Connection warm-up. Reply only with OK."
        do {
            _ = try await AntigravityStreamClient.shared.translate(
                prompt: prompt,
                executable: executableURL
            )
        } catch {
            // Some installations need the desktop app to refresh its Google
            // session before agy can complete a turn. Reopen it in the
            // background, allow a short initialization window, then retry.
            wakeAntigravityDesktopApp()
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            _ = try? await AntigravityStreamClient.shared.translate(
                prompt: prompt,
                executable: executableURL
            )
        }
    }

    private func wakeAntigravityDesktopApp() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-g", "-j", "-b", "com.google.antigravity"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }

    func translate(text: String, source: LanguageOption, target: LanguageOption) async throws -> String {
        guard let executableURL else { throw ServiceError.notInstalled }
        let prompt = translationPrompt(text: text, source: source, target: target)

        do {
            return try await AntigravityStreamClient.shared.translate(
                prompt: prompt,
                executable: executableURL
            )
        } catch let serviceError as ServiceError {
            throw normalizedServiceError(serviceError)
        } catch {
            // Keep a one-shot fallback for older or damaged agy installations. A normal
            // provider error is returned directly so we do not send the same request twice.
            return try await translateOneShot(
                executable: executableURL,
                prompt: prompt
            )
        }
    }

    private func translationPrompt(text: String, source: LanguageOption, target: LanguageOption) -> String {
        let sourceDescription = source == .auto ? "the detected source language" : source.promptName
        return """
        Each request is independent. Ignore any previous requests or translations.
        Translate the text below from \(sourceDescription) into \(target.promptName).
        Preserve meaning, tone, paragraphs, punctuation, Markdown, and line breaks.
        Return only the translation, without quotation marks, explanations, or a preface.

        <text>
        \(text)
        </text>
        """
    }

    private func translateOneShot(executable: URL, prompt: String) async throws -> String {
        let output = await run(executable: executable, arguments: [
            "--disable-slash-commands",
            "--model", ModelProvider.antigravityFastModel,
            "--output-format", "text", "--effort", "low", "--print-timeout", "45s", "--print=\(prompt)"
        ])
        guard output.status == 0 else {
            let raw = (output.stderr + "\n" + output.stdout).trimmingCharacters(in: .whitespacesAndNewlines)
            throw normalizedServiceError(.processFailed(raw.isEmpty ? "Antigravity CLI 执行失败。" : raw))
        }
        let result = output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty else { throw ServiceError.emptyResult }
        return result
    }

    private func normalizedServiceError(_ error: ServiceError) -> ServiceError {
        guard case .processFailed(let raw) = error else { return error }
        if raw.localizedCaseInsensitiveContains("location is not supported") {
            return .processFailed("Google OAuth 已登录，但当前网络地区不支持 Antigravity API。请切换到受支持的网络地区后重试。")
        }
        if raw.localizedCaseInsensitiveContains("auth") || raw.localizedCaseInsensitiveContains("login") {
            return .processFailed("尚未完成 Google OAuth 登录，请先在终端运行 agy 完成登录。")
        }
        return error
    }

    private func run(executable: URL, arguments: [String]) async -> (status: Int32, stdout: String, stderr: String) {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = executable
                process.arguments = arguments
                process.currentDirectoryURL = FileManager.default.temporaryDirectory
                var environment = ProcessInfo.processInfo.environment
                environment["HOME"] = FileManager.default.homeDirectoryForCurrentUser.path
                process.environment = environment
                let stdoutPipe = Pipe(), stderrPipe = Pipe()
                process.standardOutput = stdoutPipe
                process.standardError = stderrPipe
                do { try process.run(); process.waitUntilExit() } catch {
                    continuation.resume(returning: (-1, "", error.localizedDescription)); return
                }
                let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                continuation.resume(returning: (process.terminationStatus, stdout, stderr))
            }
        }
    }
}

private final class AntigravityStreamClient: @unchecked Sendable {
    static let shared = AntigravityStreamClient()

    private enum ClientError: Error {
        case processUnavailable
        case invalidMessage
    }

    private let queue = DispatchQueue(label: "com.gpttranslator.antigravity-stream", qos: .userInitiated)
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var errorOutput: FileHandle?
    private var readBuffer = Data()
    private var ready = false
    private var executablePath: String?

    private init() {}

    func warmUp(executable: URL) async throws {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                do {
                    try ensureStarted(executable: executable)
                    continuation.resume()
                } catch {
                    stop()
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func translate(prompt: String, executable: URL) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                do {
                    let result = try translateSynchronously(prompt: prompt, executable: executable)
                    continuation.resume(returning: result)
                } catch {
                    if error is ClientError { stop() }
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func translateSynchronously(prompt: String, executable: URL) throws -> String {
        try ensureStarted(executable: executable)
        try send([
            "event": "user",
            "message": [
                "role": "user",
                "content": [["type": "text", "text": prompt]]
            ]
        ])

        while true {
            let message = try readMessage()
            guard let event = message["event"] as? String else { continue }
            guard event == "result" else { continue }

            let result = message["result"] as? [String: Any] ?? [:]
            let status = (result["status"] as? String ?? "").uppercased()
            guard status == "SUCCESS" else {
                let raw = (result["error"] as? String)
                    ?? (result["response"] as? String)
                    ?? "Antigravity CLI 返回失败。"
                throw AntigravityCLIService.ServiceError.processFailed(raw)
            }

            let response = (result["response"] as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !response.isEmpty else { throw AntigravityCLIService.ServiceError.emptyResult }
            return response
        }
    }

    private func ensureStarted(executable: URL) throws {
        if process?.isRunning == true, executablePath == executable.path {
            if !ready { try waitForReady() }
            return
        }

        stop()

        let process = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.executableURL = executable
        process.arguments = [
            "--disable-slash-commands",
            "--model", ModelProvider.antigravityFastModel,
            "--input-format", "stream-json",
            "--output-format", "stream-json",
            "--effort", "low",
            "--print-timeout", "45s"
        ]
        process.currentDirectoryURL = FileManager.default.temporaryDirectory
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = FileManager.default.homeDirectoryForCurrentUser.path
        process.environment = environment
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        errorPipe.fileHandleForReading.readabilityHandler = { handle in
            // NSFileHandle keeps invoking the readability handler after the child exits.
            // Stop monitoring at EOF; otherwise a failed OAuth/region request can leave the
            // menu-bar app spinning at a full CPU core indefinitely.
            if handle.availableData.isEmpty {
                handle.readabilityHandler = nil
            }
        }
        try process.run()

        self.process = process
        input = inputPipe.fileHandleForWriting
        output = outputPipe.fileHandleForReading
        errorOutput = errorPipe.fileHandleForReading
        executablePath = executable.path
        readBuffer.removeAll(keepingCapacity: true)
        ready = false
        try waitForReady()
    }

    private func waitForReady() throws {
        let message = try readMessage()
        guard message["event"] as? String == "init" else { throw ClientError.invalidMessage }
        ready = true
    }

    private func send(_ object: [String: Any]) throws {
        guard let input else { throw ClientError.processUnavailable }
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(0x0A)
        try input.write(contentsOf: data)
    }

    private func readMessage() throws -> [String: Any] {
        guard let output else { throw ClientError.processUnavailable }
        while true {
            if let newline = readBuffer.firstIndex(of: 0x0A) {
                let line = readBuffer[..<newline]
                readBuffer.removeSubrange(...newline)
                if line.isEmpty { continue }
                guard let object = try JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else {
                    throw ClientError.invalidMessage
                }
                return object
            }

            let data = output.availableData
            guard !data.isEmpty else { throw ClientError.processUnavailable }
            readBuffer.append(data)
        }
    }

    private func stop() {
        errorOutput?.readabilityHandler = nil
        input?.closeFile()
        output?.closeFile()
        errorOutput?.closeFile()
        process?.terminate()
        process = nil
        input = nil
        output = nil
        errorOutput = nil
        executablePath = nil
        ready = false
        readBuffer.removeAll(keepingCapacity: false)
    }
}

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
        Each translation request is independent. Ignore any previous requests or translations.
        Translate the text below from \(sourceDescription) into \(target.promptName).
        Preserve meaning, tone, paragraphs, punctuation, Markdown, and line breaks.
        Return only the translation, without quotation marks, explanations, or a preface.

        <text>
        \(text)
        </text>
        """

        var arguments = [
            "exec", "--disable", "plugins", "--disable", "apps", "--disable", "memories",
            "--disable", "recommended_plugins", "--disable", "browser_use", "--disable", "computer_use",
            "--skip-git-repo-check", "--ephemeral", "--color", "never",
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
    private var threadTurnCount = 0
    private var threadInputCharacters = 0

    private let maxThreadTurns = 8
    private let maxThreadInputCharacters = 20_000

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
        guard let activeThreadID = threadID else { throw CodexCLIService.ServiceError.emptyResult }

        let sourceDescription = source == .auto ? "the detected source language" : source.promptName
        let prompt = "Translate from \(sourceDescription) to \(target.promptName). Preserve formatting. Return only the translation.\n\n\(text)"
        let requestID = allocateRequestID()
        let selectedModel: Any = model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? NSNull() : model
        try send([
            "jsonrpc": "2.0", "id": requestID, "method": "turn/start",
            "params": [
                "threadId": activeThreadID,
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
                threadTurnCount += 1
                threadInputCharacters += text.count
                if threadTurnCount >= maxThreadTurns || threadInputCharacters >= maxThreadInputCharacters {
                    // Keep the process warm, but periodically renew the lightweight thread so
                    // old translation text cannot make the context grow without bound.
                    threadID = nil
                    threadTurnCount = 0
                    threadInputCharacters = 0
                }
                return translation
            }
        }
    }

    private func ensureStarted(executable: URL, model: String, reasoning: ReasoningEffort) throws {
        if process?.isRunning == true {
            if threadID == nil || threadTurnCount >= maxThreadTurns || threadInputCharacters >= maxThreadInputCharacters {
                try startThread(model: model, reasoning: reasoning)
            }
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
        errorPipe.fileHandleForReading.readabilityHandler = { handle in
            // A terminated app-server closes stderr. Detach the handler at EOF so an
            // unexpected CLI exit cannot turn into a zero-byte read busy loop.
            if handle.availableData.isEmpty {
                handle.readabilityHandler = nil
            }
        }
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
                "baseInstructions": "You are a translation engine. Never use tools. Each request is independent; ignore previous source text and translations. Return only the translation.",
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
        threadTurnCount = 0
        threadInputCharacters = 0
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
        if provider == .googleWeb {
            return try await translateWithGoogleWeb(text: text, source: source, target: target)
        }
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

    private func translateWithGoogleWeb(
        text: String,
        source: LanguageOption,
        target: LanguageOption
    ) async throws -> String {
        var components = URLComponents(string: "https://translate.googleapis.com/translate_a/single")
        components?.queryItems = [
            URLQueryItem(name: "client", value: "gtx"),
            URLQueryItem(name: "sl", value: source.googleCode),
            URLQueryItem(name: "tl", value: target.googleCode),
            URLQueryItem(name: "dt", value: "t"),
            URLQueryItem(name: "q", value: text)
        ]
        guard let url = components?.url else { throw ServiceError.invalidResponse }

        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else { throw ServiceError.invalidResponse }
        guard (200...299).contains(httpResponse.statusCode) else {
            if httpResponse.statusCode == 429 {
                throw ServiceError.api("Google 网页翻译请求过于频繁（HTTP 429），请稍后再试或切换其他翻译源。")
            }
            throw ServiceError.api("Google 网页翻译请求失败（HTTP \(httpResponse.statusCode)）。")
        }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [Any],
              let segments = root.first as? [Any] else { throw ServiceError.invalidResponse }
        let translated = segments.compactMap { segment -> String? in
            guard let values = segment as? [Any], let value = values.first as? String else { return nil }
            return value
        }.joined()
        guard !translated.isEmpty else { throw ServiceError.emptyResult }
        return translated
    }

}
