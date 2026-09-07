import Foundation

/// Provider authentication must come only from the current request, never a previous user's session state.
enum ProviderNetworkSession {
    static func makeConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return configuration
    }
}

struct RemoteToolDefinition: Sendable {
    let name: String
    let description: String
    let parametersJSON: String
}

struct RemoteToolCall: Sendable {
    let id: String
    let name: String
    let argumentsJSON: String
}

struct RemoteGideonRequestContext {
    let endpoint: URL
    let apiKey: String
    let modelIdentifier: String
    let provider: String
    let maxNewTokens: Int
    let userMessage: String
    let history: [HarnessTurn]
    var systemInstruction: String = ""
    var tools: [RemoteToolDefinition] = []
    // Native lifecycle fence only; never serialized into provider/model context.
    var isRequestValid: @Sendable () async -> Bool = { true }
}

actor RemoteGideonRuntime {
    static let shared = RemoteGideonRuntime()

    private let session: URLSession
    private static let maxToolRounds = 6
    private static let maxToolCalls = 8
    private static let maxToolResultCharacters = 8_000

    init(session: URLSession = URLSession(configuration: ProviderNetworkSession.makeConfiguration())) {
        self.session = session
    }

    private enum ProviderProtocol {
        case openAICompatible, anthropicMessages, gemini
    }

    private struct NativeCall {
        let call: RemoteToolCall
        // Gemini permits calls without IDs; do not put our local ID on the wire.
        let responseID: String?
    }

    private struct Reply {
        let assistant: [String: Any]
        let text: String
        let calls: [NativeCall]
        let emptyMessage: String
    }

    private struct CachedResult {
        let name: String
        let arguments: String
        let text: String
        let isError: Bool
    }

    private enum RuntimeFailure: Error {
        case invalidTools, invalidRoute, malformedResponse
    }

    private struct DiscoveryFailure: Error { let message: String }

    /// Only the caller's allowlisted executor can perform actions. No scripts or code are evaluated here.
    func generateReply(
        context: RemoteGideonRequestContext,
        executeTool: (@Sendable (RemoteToolCall) async -> String)? = nil
    ) async -> String {
        let style = resolveProtocol(provider: context.provider, endpoint: context.endpoint)
        var model = context.modelIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        if model.isEmpty { model = defaultModelIdentifier(for: context.provider, style: style) }
        if style == .gemini { model = cleanGeminiModel(model) }
        let originalModel = model
        var conversation = historyMessages(context: context, style: style)
        var toolRounds = 0
        var callCount = 0
        var resultsByID: [String: CachedResult] = [:]
        var alternatives: [String] = []
        var discovered = false
        var fallbackAttempts = 0
        var textOnly = false

        func finish(_ text: String) -> String {
            let notice = model == originalModel ? "" : "\n\n[Used fallback model: \(model)]"
            let limitation = textOnly ? "\n\n[This model rejected tool calling. Text-only response; no tools were executed.]" : ""
            return redact(text + notice + limitation, key: context.apiKey)
        }

        do {
            try await checkRequestValidity(context)
            var definitions = try toolDefinitions(context.tools)
            let allowedNames = Set(context.tools.map(\.name))
            while true {
                try Task.checkCancellation()
                let request = try buildRequest(context: context, style: style, model: model,
                                               conversation: conversation, definitions: definitions)
                try await checkRequestValidity(context)
                let (data, response) = try await session.data(for: request)
                try await checkRequestValidity(context)
                guard let http = response as? HTTPURLResponse else { throw RuntimeFailure.malformedResponse }
                guard (200..<300).contains(http.statusCode) else {
                    // A single text-only recovery is safe only before any tool execution.
                    let error = errorFingerprint(data)
                    if toolRounds == 0, !definitions.isEmpty, !textOnly,
                       [400, 422].contains(http.statusCode),
                       (error.contains("tools") || error.contains("function calling")),
                       (error.contains("not support") || error.contains("unsupported")) {
                        textOnly = true
                        definitions = []
                        continue
                    }
                    // Never change models after a tool round: an action may already have committed.
                    if toolRounds == 0, isMissingModel(status: http.statusCode, data: data), fallbackAttempts < 5 {
                        if !discovered {
                            alternatives = try await discoverModels(context: context, style: style, preferred: model)
                            try await checkRequestValidity(context)
                            discovered = true
                        }
                        if !alternatives.isEmpty {
                            model = alternatives.removeFirst()
                            fallbackAttempts += 1
                            continue
                        }
                    }
                    return httpError(status: http.statusCode, data: data)
                }
                let reply = try parseReply(data, style: style, round: toolRounds)
                if textOnly, !reply.calls.isEmpty {
                    return finish("This model cannot use the available tools. Select a tool-capable model to inspect connected data.")
                }
                if reply.calls.isEmpty { return finish(reply.text.isEmpty ? reply.emptyMessage : reply.text) }
                guard toolRounds < Self.maxToolRounds else {
                    return finish("Tool round limit reached (6). No further actions were executed.")
                }
                guard callCount + reply.calls.count <= Self.maxToolCalls else {
                    return finish("Tool call limit reached (8). No actions in the last batch were executed.")
                }
                toolRounds += 1
                conversation.append(reply.assistant)
                var nativeResults: [[String: Any]] = []
                for native in reply.calls {
                    try Task.checkCancellation()
                    let call = native.call
                    callCount += 1
                    let canonicalArguments = canonicalObject(call.argumentsJSON)
                    let result: CachedResult
                    if let previous = resultsByID[call.id] {
                        if previous.name == call.name && previous.arguments == (canonicalArguments ?? call.argumentsJSON) {
                            result = previous
                        } else {
                            result = CachedResult(name: call.name, arguments: call.argumentsJSON,
                                                  text: "Tool error: reused call ID with different arguments; not executed.", isError: true)
                        }
                    } else {
                        let text: String
                        let isError: Bool
                        if !allowedNames.contains(call.name) {
                            text = "Tool error: unknown or unapproved tool; not executed."
                            isError = true
                        } else if canonicalArguments == nil {
                            text = "Tool error: arguments must be a valid JSON object; not executed."
                            isError = true
                        } else if let executeTool {
                            try await checkRequestValidity(context)
                            text = await executeTool(call)
                            try await checkRequestValidity(context)
                            isError = false // The nonthrowing executor owns its application-level error format.
                        } else {
                            text = "Tool error: no executor is available; not executed."
                            isError = true
                        }
                        result = CachedResult(name: call.name, arguments: canonicalArguments ?? call.argumentsJSON,
                                              text: boundedToolResult(redact(text, key: context.apiKey)), isError: isError)
                        resultsByID[call.id] = result
                    }
                    switch style {
                    case .openAICompatible:
                        nativeResults.append(["role": "tool", "tool_call_id": call.id, "content": result.text])
                    case .anthropicMessages:
                        nativeResults.append(["type": "tool_result", "tool_use_id": call.id,
                                              "content": result.text, "is_error": result.isError])
                    case .gemini:
                        var response: [String: Any] = ["name": call.name,
                                                     "response": [result.isError ? "error" : "result": result.text]]
                        if let id = native.responseID { response["id"] = id }
                        nativeResults.append(["functionResponse": response])
                    }
                }
                switch style {
                case .openAICompatible: conversation.append(contentsOf: nativeResults)
                case .anthropicMessages: conversation.append(["role": "user", "content": nativeResults])
                case .gemini: conversation.append(["role": "user", "parts": nativeResults])
                }
            }
        } catch is CancellationError {
            return "Request cancelled."
        } catch {
            // A throwing await also needs a fence before publishing diagnostics.
            do { try await checkRequestValidity(context) }
            catch { return "Request cancelled." }
            switch error {
            case let error as URLError:
                if error.code == .cancelled { return "Request cancelled." }
                if error.code == .timedOut { return "Provider request timed out. Try again later; completed actions were not retried." }
                return "Could not connect to the provider. Check your connection and endpoint settings. Completed actions were not retried."
            case let error as DiscoveryFailure:
                return error.message
            case RuntimeFailure.invalidTools:
                return "Could not build provider request: tool names must be unique and parameters must be JSON object schemas."
            case RuntimeFailure.invalidRoute:
                return "Could not build provider request: check the endpoint and model identifier."
            default:
                return "Provider returned an invalid response or request schema. No automatic action retry was performed."
            }
        }
    }

    private func checkRequestValidity(_ context: RemoteGideonRequestContext) async throws {
        try Task.checkCancellation()
        let valid = await context.isRequestValid()
        try Task.checkCancellation()
        guard valid else { throw CancellationError() }
        // This is the strongest async dispatch fence, not an atomic scope/URLSession
        // transaction: a scope change can still race the subsequent actor hop.
    }

    private func buildRequest(context: RemoteGideonRequestContext, style: ProviderProtocol, model: String,
                              conversation: [[String: Any]], definitions: [[String: Any]]) throws -> URLRequest {
        let url = try route(context.endpoint, style: style, model: model)
        var request = authenticatedRequest(url: url, context: context, style: style)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        let system = """
        \(context.systemInstruction)

        You are a connected \(context.provider) assistant in Gideon, using model \(model).
        Keep answers concise and practical. If asked your identity, identify this model and provider.
        Use conversation context and actual tool results. Never fabricate actions, tool output, or claim an action succeeded without evidence.
        \(definitions.isEmpty ? "No tools are available for this request. Do not claim to have retrieved connected data or executed actions." : "")
        """
        var payload: [String: Any]
        switch style {
        case .openAICompatible:
            payload = ["model": model, "messages": [["role": "system", "content": system]] + conversation,
                       "max_tokens": max(1, context.maxNewTokens), "temperature": 0.2]
            let reasoningModel = ["o1", "o3", "o4", "gpt-5"].contains { model == $0 || model.hasPrefix($0 + "-") }
            if reasoningModel {
                payload.removeValue(forKey: "max_tokens")
                payload.removeValue(forKey: "temperature")
                payload["max_completion_tokens"] = max(4096, context.maxNewTokens)
            }
            if !definitions.isEmpty { payload["tools"] = definitions.map { ["type": "function", "function": $0] } }
        case .anthropicMessages:
            payload = ["model": model, "system": system, "messages": conversation,
                       "max_tokens": max(1, context.maxNewTokens)]
            if !definitions.isEmpty {
                payload["tools"] = definitions.map {
                    ["name": $0["name"]!, "description": $0["description"]!, "input_schema": $0["parameters"]!]
                }
            }
        case .gemini:
            payload = ["systemInstruction": ["parts": [["text": system]]], "contents": conversation,
                       "generationConfig": ["maxOutputTokens": max(4096, context.maxNewTokens), "temperature": 0.2]]
            if !definitions.isEmpty {
                // Standard JSON Schema rather than Gemini's narrower Schema dialect.
                payload["tools"] = [["functionDeclarations": definitions.map {
                    ["name": $0["name"]!, "description": $0["description"]!, "parametersJsonSchema": $0["parameters"]!]
                }]]
            }
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: redactedJSON(payload, key: context.apiKey))
        return request
    }

    private func toolDefinitions(_ tools: [RemoteToolDefinition]) throws -> [[String: Any]] {
        var names = Set<String>()
        return try tools.map { tool in
            guard !tool.name.isEmpty, names.insert(tool.name).inserted,
                  let data = tool.parametersJSON.data(using: .utf8),
                  let schema = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  schema["type"] as? String == "object" else { throw RuntimeFailure.invalidTools }
            return ["name": tool.name, "description": tool.description, "parameters": schema]
        }
    }

    private func historyMessages(context: RemoteGideonRequestContext, style: ProviderProtocol) -> [[String: Any]] {
        var remaining = 32_000
        var turns: [(String, String)] = []
        for turn in context.history.suffix(16).reversed() {
            guard remaining > 0 else { break }
            let text = String(turn.text.prefix(remaining))
            remaining -= text.count
            turns.append((turn.role == .user ? "user" : "assistant", text))
        }
        turns.reverse()
        turns.append(("user", context.userMessage))
        return turns.map { role, text in
            switch style {
            case .openAICompatible: return ["role": role, "content": text]
            case .anthropicMessages: return ["role": role, "content": [["type": "text", "text": text]]]
            case .gemini: return ["role": role == "assistant" ? "model" : "user", "parts": [["text": text]]]
            }
        }
    }

    private func parseReply(_ data: Data, style: ProviderProtocol, round: Int) throws -> Reply {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw RuntimeFailure.malformedResponse
        }
        var assistant: [String: Any]
        var text: [String] = []
        var calls: [NativeCall] = []
        var emptyMessage = "Provider returned no usable text. Check the model's output budget and supported response format."
        switch style {
        case .openAICompatible:
            guard let choice = (root["choices"] as? [[String: Any]])?.first,
                  let message = choice["message"] as? [String: Any] else { throw RuntimeFailure.malformedResponse }
            assistant = message // Preserve content, reasoning fields and complete native tool_calls.
            assistant["role"] = "assistant"
            if let content = message["content"] as? String { text.append(content) }
            if let parts = message["content"] as? [[String: Any]] {
                text += parts.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
            }
            if let refusal = message["refusal"] as? String, text.isEmpty { text.append(refusal) }
            if let rawCalls = message["tool_calls"], !(rawCalls is NSNull) {
                guard let rows = rawCalls as? [[String: Any]] else { throw RuntimeFailure.malformedResponse }
                for row in rows {
                    guard row["type"] as? String == "function", let id = row["id"] as? String, !id.isEmpty,
                          let function = row["function"] as? [String: Any], let name = function["name"] as? String,
                          let args = function["arguments"] as? String else { throw RuntimeFailure.malformedResponse }
                    calls.append(NativeCall(call: RemoteToolCall(id: id, name: name, argumentsJSON: args), responseID: id))
                }
            }
            if choice["finish_reason"] as? String == "length", !calls.isEmpty { throw RuntimeFailure.malformedResponse }
        case .anthropicMessages:
            guard let content = root["content"] as? [[String: Any]] else { throw RuntimeFailure.malformedResponse }
            assistant = ["role": "assistant", "content": content] // Includes thinking/signature and redacted_thinking.
            for block in content {
                if block["type"] as? String == "text", let value = block["text"] as? String { text.append(value) }
                if block["type"] as? String == "tool_use" {
                    guard let id = block["id"] as? String, !id.isEmpty, let name = block["name"] as? String,
                          let input = block["input"] else { throw RuntimeFailure.malformedResponse }
                    calls.append(NativeCall(call: RemoteToolCall(id: id, name: name, argumentsJSON: try jsonString(input)), responseID: id))
                }
            }
            if root["stop_reason"] as? String == "max_tokens", !calls.isEmpty { throw RuntimeFailure.malformedResponse }
        case .gemini:
            let candidate = (root["candidates"] as? [[String: Any]])?.first
            emptyMessage = geminiEmptyResponseMessage(root, candidate: candidate)
            // Select one candidate only: mixing alternatives can execute mutually exclusive actions.
            assistant = candidate?["content"] as? [String: Any] ?? ["role": "model", "parts": []]
            assistant["role"] = "model"
            let finishReason = candidate?["finishReason"] as? String ?? ""
            if (root["promptFeedback"] as? [String: Any])?["blockReason"] != nil || isSafetyFinish(finishReason) {
                return Reply(assistant: assistant, text: "", calls: [], emptyMessage: emptyMessage)
            }
            for (index, part) in (assistant["parts"] as? [[String: Any]] ?? []).enumerated() {
                guard part["thought"] as? Bool != true else { continue }
                if let value = part["text"] as? String { text.append(value) }
                if let function = part["functionCall"] as? [String: Any] {
                    guard let name = function["name"] as? String else { throw RuntimeFailure.malformedResponse }
                    let id = function["id"] as? String
                    calls.append(NativeCall(call: RemoteToolCall(id: id ?? "gemini-\(round)-\(index)", name: name,
                                                                argumentsJSON: try jsonString(function["args"] ?? [:])), responseID: id))
                }
            }
            if finishReason == "MAX_TOKENS", !calls.isEmpty {
                return Reply(assistant: assistant, text: "", calls: [], emptyMessage: emptyMessage)
            }
        }
        return Reply(assistant: assistant, text: text.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines),
                     calls: calls, emptyMessage: emptyMessage)
    }

    private func geminiEmptyResponseMessage(_ root: [String: Any], candidate: [String: Any]?) -> String {
        let reason = candidate?["finishReason"] as? String ?? ""
        if (root["promptFeedback"] as? [String: Any])?["blockReason"] != nil || isSafetyFinish(reason) {
            return "Gemini blocked the response because of safety or content restrictions. Rephrase the request."
        }
        if reason == "MAX_TOKENS" {
            return "Gemini reached its output/thinking token budget (MAX_TOKENS) before returning usable text. Increase the output budget or simplify the request."
        }
        if reason == "MALFORMED_FUNCTION_CALL" || reason == "UNEXPECTED_TOOL_CALL" {
            return "Gemini returned an invalid tool call. Check the tool schema; no action was executed."
        }
        return "Gemini returned no usable non-thought text. Check the model, output budget, and response settings."
    }

    private func isSafetyFinish(_ reason: String) -> Bool {
        ["SAFETY", "RECITATION", "BLOCKLIST", "PROHIBITED_CONTENT", "SPII", "IMAGE_SAFETY"].contains(reason)
    }

    private func resolveProtocol(provider: String, endpoint: URL) -> ProviderProtocol {
        let name = provider.lowercased()
        let host = endpoint.host?.lowercased() ?? ""
        if name.contains("anthropic") || name.contains("claude") || host.contains("anthropic") { return .anthropicMessages }
        if name.contains("gemini") || name.contains("google") || host.contains("generativelanguage.googleapis.com") { return .gemini }
        return .openAICompatible
    }

    private func route(_ base: URL, style: ProviderProtocol, model: String? = nil) throws -> URL {
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false),
              ["https", "http"].contains(components.scheme?.lowercased() ?? ""), components.host != nil else {
            throw RuntimeFailure.invalidRoute
        }
        // Authentication always travels in headers, including discovery. Never reuse query-string keys.
        components.query = nil
        components.fragment = nil
        components.user = nil
        components.password = nil
        var segments = base.path.split(separator: "/").map(String.init)
        switch style {
        case .gemini:
            // Preserve an explicit API version and proxy prefix. Replace only the model/method suffix.
            if let version = segments.firstIndex(where: { $0 == "v1" || $0 == "v1beta" }) {
                segments = Array(segments.prefix(version + 1))
            } else {
                if let models = segments.firstIndex(of: "models") { segments = Array(segments.prefix(models)) }
                segments.append("v1beta")
            }
            segments.append("models")
            if let model {
                let identifier = cleanGeminiModel(model)
                let valid = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
                guard !identifier.isEmpty, identifier.count <= 200,
                      identifier.unicodeScalars.allSatisfy(valid.contains) else { throw RuntimeFailure.invalidRoute }
                segments.append("\(identifier):generateContent")
            }
        case .openAICompatible, .anthropicMessages:
            if segments.suffix(2) == ["chat", "completions"] { segments.removeLast(2) }
            else if let last = segments.last, ["messages", "models"].contains(last) { segments.removeLast() }
            if segments.last != "v1" { segments.append("v1") }
            segments += model == nil ? ["models"] : (style == .anthropicMessages ? ["messages"] : ["chat", "completions"])
        }
        components.path = "/" + segments.joined(separator: "/")
        guard let url = components.url else { throw RuntimeFailure.invalidRoute }
        return url
    }

    private func authenticatedRequest(url: URL, context: RemoteGideonRequestContext, style: ProviderProtocol) -> URLRequest {
        var request = URLRequest(url: url)
        request.timeoutInterval = 25
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        switch style {
        case .openAICompatible:
            if !context.apiKey.isEmpty { request.setValue("Bearer \(context.apiKey)", forHTTPHeaderField: "Authorization") }
        case .anthropicMessages:
            request.setValue(context.apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        case .gemini: request.setValue(context.apiKey, forHTTPHeaderField: "x-goog-api-key")
        }
        return request
    }

    private func isMissingModel(status: Int, data: Data) -> Bool {
        guard status == 404 else { return false }
        let text = errorFingerprint(data)
        guard !["quota", "rate_limit", "resource_exhausted", "schema", "permission", "api_key", "api key"].contains(where: text.contains) else { return false }
        return text.contains("model") && ["not found", "not_found", "does not exist", "no longer available", "not supported", "retired"].contains(where: text.contains)
    }

    private func errorFingerprint(_ data: Data) -> String {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = root["error"] as? [String: Any] else { return "" }
        // Classification only: provider text and URLs never escape into diagnostics.
        return ["message", "type", "code", "status"].compactMap { error[$0] as? String }.joined(separator: " ").lowercased()
    }

    private func httpError(status: Int, data: Data) -> String {
        let info = errorFingerprint(data)
        let detail: String
        if status == 401 || info.contains("api_key_invalid") || info.contains("api key not valid") || info.contains("invalid api key") {
            detail = "API key rejected. Check or replace the provider key."
        } else if status == 429 || info.contains("quota") || info.contains("resource_exhausted") {
            detail = "Quota or rate limit exceeded. Check billing and limits, then try again later."
        } else if status == 403 {
            detail = "Permission denied. Check key permissions and access to this model."
        } else if status == 408 || status == 504 {
            detail = "Provider request timed out. Try again later."
        } else if status >= 500 {
            detail = "Provider server error. Try again later."
        } else if status == 404 {
            detail = isMissingModel(status: status, data: data)
                ? "Model not found or unavailable. Refresh the provider model list and select an accessible text model."
                : "API route not found. Check the endpoint and API version."
        } else if status == 400 || status == 422 {
            detail = "Invalid request or unsupported schema. Check model capabilities, tool definitions, and generation settings."
        } else {
            detail = "Provider rejected the request. Check the provider configuration."
        }
        return "Provider error (HTTP \(status)): \(detail)"
    }

    private func discoverModels(context: RemoteGideonRequestContext, style: ProviderProtocol, preferred: String) async throws -> [String] {
        let base = try route(context.endpoint, style: style)
        var candidates: [String] = []
        var cursor: String?
        var seenCursors = Set<String>()
        for _ in 0..<3 {
            try Task.checkCancellation()
            var components = URLComponents(url: base, resolvingAgainstBaseURL: false)!
            if let cursor {
                components.queryItems = [URLQueryItem(name: style == .gemini ? "pageToken" : "after_id", value: cursor)]
            }
            guard let url = components.url else { break }
            var request = authenticatedRequest(url: url, context: context, style: style)
            request.httpMethod = "GET"
            try await checkRequestValidity(context)
            let (data, response) = try await session.data(for: request)
            try await checkRequestValidity(context)
            guard let http = response as? HTTPURLResponse else { throw RuntimeFailure.malformedResponse }
            guard (200..<300).contains(http.statusCode) else {
                throw DiscoveryFailure(message: httpError(status: http.statusCode, data: data))
            }
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw RuntimeFailure.malformedResponse }
            let rows = root[style == .gemini ? "models" : "data"] as? [[String: Any]] ?? []
            for row in rows {
                if style == .gemini {
                    guard let name = row["name"] as? String,
                          let methods = row["supportedGenerationMethods"] as? [String], methods.contains("generateContent") else { continue }
                    let identifier = cleanGeminiModel(name)
                    if isUsableTextModel(identifier), identifier.lowercased().contains("gemini") { candidates.append(identifier) }
                } else if let id = row["id"] as? String, isUsableTextModel(id) {
                    if style != .anthropicMessages || id.lowercased().contains("claude") { candidates.append(id) }
                }
            }
            if style == .gemini { cursor = root["nextPageToken"] as? String }
            else if style == .anthropicMessages, root["has_more"] as? Bool == true {
                cursor = root["last_id"] as? String ?? rows.last?["id"] as? String
            } else { cursor = nil }
            guard let next = cursor, !next.isEmpty, seenCursors.insert(next).inserted else { break }
        }
        let tier = ["flash-lite", "flash", "pro", "sonnet", "haiku", "opus"].first { preferred.lowercased().contains($0) }
        var seen = Set([preferred.lowercased()])
        let unique = candidates.filter { seen.insert($0.lowercased()).inserted }
        return Array(unique.sorted { left, right in
            if let tier {
                let a = left.lowercased().contains(tier), b = right.lowercased().contains(tier)
                if a != b { return a }
            }
            return left.localizedStandardCompare(right) == .orderedDescending
        }.prefix(style == .gemini ? 5 : 1))
    }

    private func isUsableTextModel(_ identifier: String) -> Bool {
        let lower = identifier.lowercased()
        // Preview/experimental text models are valid; exclude specialized modalities instead.
        return !["embedding", "imagen", "veo", "image", "tts", "audio", "live", "robotics", "computer-use", "aqa", "whisper", "dall-e", "realtime", "moderation"].contains(where: lower.contains)
    }

    private func defaultModelIdentifier(for provider: String, style: ProviderProtocol) -> String {
        if style == .anthropicMessages { return "claude-3-5-haiku-20241022" }
        if style == .gemini { return "gemini-2.0-flash-001" }
        let normalized = provider.lowercased()
        if normalized.contains("deepseek") { return "deepseek-chat" }
        if normalized.contains("perplexity") { return "llama-3.1-sonar-small-128k-online" }
        if normalized.contains("grok") || normalized.contains("xai") { return "grok-2" }
        return "gpt-4o-mini"
    }

    private func cleanGeminiModel(_ model: String) -> String {
        model.hasPrefix("models/") ? String(model.dropFirst(7)) : model
    }

    private func jsonString(_ object: Any) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .fragmentsAllowed]), as: UTF8.self)
    }

    private func canonicalObject(_ text: String) -> String? {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return try? jsonString(object)
    }

    private func boundedToolResult(_ text: String) -> String {
        let marker = "\n[Tool result truncated]"
        guard text.count > Self.maxToolResultCharacters else { return text }
        return String(text.prefix(Self.maxToolResultCharacters - marker.count)) + marker
    }

    private func redact(_ text: String, key: String) -> String {
        key.isEmpty ? text : text.replacingOccurrences(of: key, with: "[REDACTED]")
    }

    private func redactedJSON(_ value: Any, key: String) -> Any {
        if let text = value as? String { return redact(text, key: key) }
        if let array = value as? [Any] { return array.map { redactedJSON($0, key: key) } }
        if let object = value as? [String: Any] { return object.mapValues { redactedJSON($0, key: key) } }
        return value
    }
}
