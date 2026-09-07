import Foundation

// Standalone fixtures: compile this file with RemoteGideonRuntime.swift, not the app harness.
struct HarnessTurn: Sendable {
    enum Role: Sendable { case user, assistant }
    let role: Role
    let text: String
}

private struct TestFailure: Error, CustomStringConvertible {
    let description: String
}

private func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw TestFailure(description: message) }
}

private func json(_ value: Any) throws -> Data {
    try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
}

private func body(_ request: URLRequest) throws -> [String: Any] {
    guard let data = request.httpBody,
          let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw TestFailure(description: "Missing JSON request body")
    }
    return value
}

private func equalJSON(_ left: Any, _ right: Any) throws -> Bool { try json(left) == json(right) }

private struct MockReply: Sendable {
    let status: Int
    let data: Data
    init(_ object: Any, status: Int = 200) throws {
        self.status = status
        self.data = try json(object)
    }
}

/// Every request is intercepted, including unexpected requests. There is no real-network fallback.
private final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    final class State: @unchecked Sendable {
        let lock = NSLock()
        var handler: (@Sendable (URLRequest, Int) throws -> MockReply?)?
        var requests: [URLRequest] = []
        var failures: [String] = []

        func install(_ handler: @escaping @Sendable (URLRequest, Int) throws -> MockReply?) {
            lock.lock(); defer { lock.unlock() }
            self.handler = handler
            requests = []
            failures = []
        }

        func handle(_ request: URLRequest) throws -> MockReply? {
            lock.lock()
            let index = requests.count
            requests.append(request)
            let handler = self.handler
            lock.unlock()
            guard let handler else { throw TestFailure(description: "Unexpected mock request") }
            return try handler(request, index)
        }

        func fail(_ message: String) {
            lock.lock(); defer { lock.unlock() }
            failures.append(message)
        }

        func snapshot() -> ([URLRequest], [String]) {
            lock.lock(); defer { lock.unlock() }
            return (requests, failures)
        }
    }

    static let state = State()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var captured = request
        if captured.httpBody == nil, let stream = captured.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(contentsOf: buffer.prefix(count))
            }
            captured.httpBody = data
        }
        do {
            guard let reply = try Self.state.handle(captured) else { return } // Pending until cancelled.
            let response = HTTPURLResponse(url: captured.url!, statusCode: reply.status,
                                           httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: reply.data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            if let failure = error as? TestFailure { Self.state.fail(failure.description) }
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
    override func stopLoading() {}
}

private actor Recorder {
    private var calls: [RemoteToolCall] = []
    func execute(_ call: RemoteToolCall, result: String = "fixture result") -> String {
        calls.append(call)
        return result
    }
    func snapshot() -> [RemoteToolCall] { calls }
}

private actor Latch {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        opened = true
        let pending = waiters
        waiters = []
        for waiter in pending { waiter.resume() }
    }
}

/// Synchronous invalidation inside a mocked network response, with async checks
/// on MainActor like the harness. No timing sleeps or live networking are needed.
private final class RequestValidity: @unchecked Sendable {
    private let lock = NSLock()
    private var current = true
    private var checks = 0
    private let invalidAtCheck: Int?

    init(invalidAtCheck: Int? = nil) { self.invalidAtCheck = invalidAtCheck }

    func invalidate() {
        lock.lock(); defer { lock.unlock() }
        current = false
    }

    func check() -> Bool {
        lock.lock(); defer { lock.unlock() }
        checks += 1
        if checks == invalidAtCheck { current = false }
        return current
    }

    var callback: @Sendable () async -> Bool {
        { await MainActor.run { self.check() } }
    }
}

@main
private struct RemoteRuntimeTests {
    static let fakeKey = "unit-test-key-NOT-A-REAL-CREDENTIAL"
    static let providers = ["OpenAI", "Anthropic", "Gemini"]
    static let definition = RemoteToolDefinition(
        name: "lookup", description: "Look up fixture data",
        parametersJSON: #"{"type":"object","properties":{"value":{"type":"integer"}},"required":["value"],"additionalProperties":false}"#
    )

    static func context(_ provider: String = "OpenAI", endpoint: String = "https://unit.invalid",
                        model: String = "test-model", history: [HarnessTurn] = []) -> RemoteGideonRequestContext {
        RemoteGideonRequestContext(endpoint: URL(string: endpoint)!, apiKey: fakeKey,
                                  modelIdentifier: model, provider: provider, maxNewTokens: 32,
                                  userMessage: "Current question\nsecond line", history: history,
                                  systemInstruction: "Harness instruction\nUse approved tools only.", tools: [definition])
    }

    static func session(_ handler: @escaping @Sendable (URLRequest, Int) throws -> MockReply?) -> URLSession {
        MockURLProtocol.state.install(handler)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        config.urlCache = nil
        config.httpCookieStorage = nil
        return URLSession(configuration: config)
    }

    static func assertRequests(_ count: Int) throws -> [URLRequest] {
        let (requests, failures) = MockURLProtocol.state.snapshot()
        try expect(failures.isEmpty, failures.joined(separator: "; "))
        try expect(requests.count == count, "Expected \(count) requests, got \(requests.count)")
        return requests
    }

    static func finalReply(_ provider: String, text: String = "Done") -> [String: Any] {
        switch provider {
        case "Anthropic": return ["content": [["type": "thinking", "thinking": "private"], ["type": "text", "text": text]], "stop_reason": "end_turn"]
        case "Gemini": return ["candidates": [["content": ["role": "model", "parts": [["thought": true, "text": "private"], ["text": text]]], "finishReason": "STOP"]]]
        default: return ["choices": [["message": ["role": "assistant", "content": text], "finish_reason": "stop"]]]
        }
    }

    static func toolReply(_ provider: String, round: Int = 0, count: Int = 1) -> [String: Any] {
        let calls: [[String: Any]] = (0..<count).map { index in
            let id = "call-\(round)-\(index)"
            switch provider {
            case "Anthropic":
                return ["type": "tool_use", "id": id, "name": "lookup", "input": ["value": index]]
            case "Gemini":
                var function: [String: Any] = ["name": "lookup", "args": ["value": index]]
                if index % 2 == 0 { function["id"] = id }
                return ["functionCall": function, "thoughtSignature": "opaque-signature-\(round)-\(index)"]
            default:
                return ["id": id, "type": "function", "function": ["name": "lookup", "arguments": "{\"value\":\(index)}"]]
            }
        }
        switch provider {
        case "Anthropic":
            return ["content": [["type": "thinking", "thinking": "private", "signature": "opaque"],
                                ["type": "redacted_thinking", "data": "opaque-data"],
                                ["type": "text", "text": "Checking\nnow"]] + calls, "stop_reason": "tool_use"]
        case "Gemini":
            return ["candidates": [["content": ["role": "model", "parts": [["thought": true, "text": "private", "thoughtSignature": "opaque-thought"],
                                                                                 ["text": "Checking\nnow"]] + calls], "finishReason": "STOP"]]]
        default:
            return ["choices": [["message": ["role": "assistant", "content": "Checking\nnow", "reasoning_content": "opaque reasoning", "refusal": NSNull(), "tool_calls": calls], "finish_reason": "tool_calls"]]]
        }
    }

    static func missingModel() -> [String: Any] {
        ["error": ["type": "not_found_error", "status": "NOT_FOUND", "message": "Requested model not found"]]
    }

    static func messages(_ payload: [String: Any], _ provider: String) -> [[String: Any]] {
        payload[provider == "Gemini" ? "contents" : "messages"] as? [[String: Any]] ?? []
    }

    static func text(_ message: [String: Any], _ provider: String) -> String {
        if provider == "OpenAI" { return message["content"] as? String ?? "" }
        return (message[provider == "Gemini" ? "parts" : "content"] as? [[String: Any]] ?? [])
            .compactMap { $0["text"] as? String }.joined(separator: "\n")
    }

    static func defaultSessionIsolation() async throws {
        // Inspect the same nonsecret configuration factory used by both production consumers.
        // No shared cookie jar or credential store is read or modified by this regression.
        let configuration = ProviderNetworkSession.makeConfiguration()
        let network = URLSession(configuration: configuration)
        defer { network.invalidateAndCancel() }
        for config in [configuration, network.configuration] {
            try expect(!config.httpShouldSetCookies, "Automatic cookies must be disabled")
            try expect(config.httpCookieStorage == nil, "No cookie storage across users")
            try expect(config.urlCredentialStorage == nil, "No implicit credential storage across users")
            try expect(config.urlCache == nil, "No cached provider responses across users")
            try expect(config.requestCachePolicy == .reloadIgnoringLocalCacheData, "Bypass local response caches")
            try expect(config.identifier == nil, "Not a persistent background session")
        }
        configuration.httpShouldSetCookies = true
        let fresh = ProviderNetworkSession.makeConfiguration()
        try expect(fresh !== configuration && !fresh.httpShouldSetCookies, "Each caller gets an independent hardened configuration")
    }

    static func schemasAndHistory() async throws {
        for provider in providers {
            for length in [1_000, 3_000] {
                let history = (0..<20).map { HarnessTurn(role: $0 % 2 == 0 ? .user : .assistant,
                                                       text: "turn-\($0)\n" + String(repeating: "x", count: length)) }
                let network = session { _, _ in try MockReply(finalReply(provider)) }
                defer { network.invalidateAndCancel() }
                let result = await RemoteGideonRuntime(session: network).generateReply(context: context(provider, history: history))
                try expect(result == "Done", "Plain response for \(provider)")
                let request = try assertRequests(1)[0]
                let payload = try body(request)
                let system: String
                switch provider {
                case "Anthropic":
                    system = payload["system"] as? String ?? ""
                    let schema = (payload["tools"] as? [[String: Any]])?.first?["input_schema"] as? [String: Any]
                    try expect(schema?["type"] as? String == "object", "Anthropic input_schema")
                    try expect(request.value(forHTTPHeaderField: "x-api-key") == fakeKey, "Anthropic key header")
                    try expect(request.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01", "Anthropic version")
                    try expect(request.url?.path == "/v1/messages", "Anthropic route")
                case "Gemini":
                    system = ((payload["systemInstruction"] as? [String: Any])?["parts"] as? [[String: Any]])?.first?["text"] as? String ?? ""
                    let declarations = ((payload["tools"] as? [[String: Any]])?.first?["functionDeclarations"] as? [[String: Any]])
                    try expect((declarations?.first?["parametersJsonSchema"] as? [String: Any])?["type"] as? String == "object", "Gemini JSON schema")
                    try expect((payload["generationConfig"] as? [String: Any])?["maxOutputTokens"] as? Int == 4096, "Thinking budget")
                    try expect(request.value(forHTTPHeaderField: "x-goog-api-key") == fakeKey, "Gemini key header")
                    try expect(request.url?.path == "/v1beta/models/test-model:generateContent", "Gemini default route")
                default:
                    system = messages(payload, provider).first?["content"] as? String ?? ""
                    let function = (payload["tools"] as? [[String: Any]])?.first?["function"] as? [String: Any]
                    try expect((function?["parameters"] as? [String: Any])?["type"] as? String == "object", "OpenAI function schema")
                    try expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(fakeKey)", "OpenAI bearer header")
                    try expect(request.url?.path == "/v1/chat/completions", "OpenAI route")
                }
                try expect(system.contains("Harness instruction\nUse approved tools only."), "Shared system instruction")
                try expect(system.contains(provider) && system.contains("test-model") && system.contains("Never fabricate actions"), "Identity and action truthfulness")
                let turns = messages(payload, provider).filter { $0["role"] as? String != "system" }
                let old = turns.dropLast()
                try expect(old.count <= 16 && !old.isEmpty, "History turn bound")
                try expect(old.map { text($0, provider).count }.reduce(0, +) <= 32_000, "History character bound")
                if length == 1_000 { try expect(old.count == 16, "All 16 retained turns") }
                try expect(old.allSatisfy { text($0, provider).contains("\n") }, "History preserves newlines")
                try expect(text(old.last!, provider).hasPrefix("turn-19\n"), "Newest history retained")
                try expect(text(turns.last!, provider) == "Current question\nsecond line", "Current message intact")
                try expect(!(String(data: request.httpBody!, encoding: .utf8) ?? "").contains(fakeKey), "No prompt credentials")
            }
        }
    }

    static func nativeRoundTrips() async throws {
        for provider in providers {
            let recorder = Recorder()
            let network = session { _, index in
                if index < 2 { return try MockReply(toolReply(provider, round: index, count: index == 0 ? 2 : 1)) }
                try expect(index == 2, "Unexpected extra tool round")
                return try MockReply(finalReply(provider, text: "Done\nConfirmed"))
            }
            defer { network.invalidateAndCancel() }
            let result = await RemoteGideonRuntime(session: network).generateReply(context: context(provider)) {
                await recorder.execute($0)
            }
            try expect(result == "Done\nConfirmed", "Final non-thought text for \(provider)")
            let requests = try assertRequests(3)
            let calls = await recorder.snapshot()
            try expect(calls.count == 3, "Three native tool executions")
            try expect(calls[0].id == "call-0-0" && calls[0].name == "lookup", "Call identity")
            try expect(calls[0].argumentsJSON == #"{"value":0}"#, "Call arguments")
            for round in 0..<2 {
                let payload = try body(requests[round + 1])
                let transcript = messages(payload, provider)
                let assistants = transcript.filter { ["assistant", "model"].contains($0["role"] as? String ?? "") }
                try expect(assistants.count == round + 1, "All native assistant turns retained")
                let source = toolReply(provider, round: round, count: round == 0 ? 2 : 1)
                let expected: [String: Any]
                switch provider {
                case "Anthropic": expected = ["role": "assistant", "content": source["content"]!]
                case "Gemini": expected = ((source["candidates"] as! [[String: Any]])[0]["content"] as! [String: Any])
                default: expected = ((source["choices"] as! [[String: Any]])[0]["message"] as! [String: Any])
                }
                try expect(try equalJSON(assistants.last!, expected), "Full native content/signatures preserved")
                if provider == "OpenAI" {
                    let tools = transcript.filter { $0["role"] as? String == "tool" }
                    try expect(tools.count == (round == 0 ? 2 : 3), "OpenAI results retained")
                    try expect(tools.last?["content"] as? String == "fixture result", "OpenAI result text")
                    try expect(tools.last?["tool_call_id"] as? String == "call-\(round)-\(round == 0 ? 1 : 0)", "OpenAI native result ID")
                } else {
                    let results = transcript.last![provider == "Gemini" ? "parts" : "content"] as! [[String: Any]]
                    try expect(results.count == (round == 0 ? 2 : 1), "Parallel result grouping")
                    try expect(transcript.last?["role"] as? String == "user", "Native results user role")
                    if provider == "Gemini" {
                        let response = results[0]["functionResponse"] as! [String: Any]
                        try expect(response["id"] as? String == "call-\(round)-0", "Gemini native ID")
                        try expect(response["name"] as? String == "lookup", "Gemini native name")
                        try expect((response["response"] as? [String: Any])?["result"] as? String == "fixture result", "Gemini result object")
                        if round == 0 { try expect((results[1]["functionResponse"] as? [String: Any])?["id"] == nil, "No invented Gemini wire ID") }
                    } else {
                        try expect(results[0]["tool_use_id"] as? String == "call-\(round)-0", "Anthropic result ID")
                        try expect(results[0]["is_error"] as? Bool == false, "Anthropic success marker")
                    }
                }
            }
        }
    }

    static func toolLimits() async throws {
        for provider in providers {
            let recorder = Recorder()
            let network = session { _, index in try MockReply(toolReply(provider, round: index)) }
            let result = await RemoteGideonRuntime(session: network).generateReply(context: context(provider)) { await recorder.execute($0) }
            try expect(result.contains("round limit"), "Six-round limit")
            let calls = await recorder.snapshot()
            try expect(calls.count == 6, "Only six rounds executed")
            _ = try assertRequests(7)
            network.invalidateAndCancel()
        }
        for initialCount in [8, 9] {
            let recorder = Recorder()
            let network = session { _, index in try MockReply(toolReply("OpenAI", round: index, count: index == 0 ? initialCount : 1)) }
            let result = await RemoteGideonRuntime(session: network).generateReply(context: context()) { await recorder.execute($0) }
            try expect(result.contains("call limit"), "Eight-call limit")
            let calls = await recorder.snapshot()
            try expect(calls.count == (initialCount == 8 ? 8 : 0), "No partial over-budget batch")
            _ = try assertRequests(initialCount == 8 ? 2 : 1)
            network.invalidateAndCancel()
        }
    }

    static func toolFailuresAndDeduplication() async throws {
        let recorder = Recorder()
        let network = session { _, index in
            if index == 0 {
                return try MockReply(["choices": [["message": ["role": "assistant", "content": NSNull(), "tool_calls": [
                    ["id": "unknown", "type": "function", "function": ["name": "run_shell", "arguments": "{}"]],
                    ["id": "invalid", "type": "function", "function": ["name": "lookup", "arguments": "["]],
                    ["id": "array", "type": "function", "function": ["name": "lookup", "arguments": "[]"]]
                ]]]]])
            }
            return try MockReply(finalReply("OpenAI"))
        }
        _ = await RemoteGideonRuntime(session: network).generateReply(context: context()) { await recorder.execute($0) }
        let requests = try assertRequests(2)
        let failures = messages(try body(requests[1]), "OpenAI").filter { $0["role"] as? String == "tool" }
        try expect(failures.count == 3 && failures.allSatisfy { ($0["content"] as? String ?? "").contains("not executed") }, "Native validation failures")
        let calls = await recorder.snapshot()
        try expect(calls.isEmpty, "No unapproved or malformed tool execution")
        network.invalidateAndCancel()

        let duplicateRecorder = Recorder()
        let duplicateNetwork = session { _, index in
            if index == 3 { return try MockReply(finalReply("OpenAI")) }
            let arguments = index == 0 ? #"{"value":0}"# : (index == 1 ? #"{ "value" : 0 }"# : #"{"value":1}"#)
            return try MockReply(["choices": [["message": ["role": "assistant", "tool_calls": [
                ["id": "same-id", "type": "function", "function": ["name": "lookup", "arguments": arguments]]
            ]]]]])
        }
        _ = await RemoteGideonRuntime(session: duplicateNetwork).generateReply(context: context()) { await duplicateRecorder.execute($0) }
        let duplicates = try assertRequests(4)
        let executed = await duplicateRecorder.snapshot()
        try expect(executed.count == 1, "Duplicate IDs never reexecute")
        let last = messages(try body(duplicates[3]), "OpenAI").last!
        try expect((last["content"] as? String ?? "").contains("reused call ID"), "Conflicting ID safely rejected")
        duplicateNetwork.invalidateAndCancel()

        for provider in providers {
            let unavailable = session { _, index in try MockReply(index == 0 ? toolReply(provider) : finalReply(provider)) }
            _ = await RemoteGideonRuntime(session: unavailable).generateReply(context: context(provider))
            let wire = String(data: try assertRequests(2)[1].httpBody!, encoding: .utf8)!
            try expect(wire.contains("no executor is available"), "Missing executor becomes native error")
            if provider == "Anthropic" { try expect(wire.contains("\"is_error\":true"), "Anthropic is_error") }
            unavailable.invalidateAndCancel()
        }
    }

    static func redactionAndBoundedResults() async throws {
        for provider in providers {
            let network = session { _, index in try MockReply(index == 0 ? toolReply(provider) : finalReply(provider, text: fakeKey + " finished")) }
            var input = context(provider)
            input.systemInstruction += fakeKey
            input.tools = [RemoteToolDefinition(name: "lookup", description: fakeKey, parametersJSON: definition.parametersJSON)]
            let result = await RemoteGideonRuntime(session: network).generateReply(context: input) { _ in
                "Tool failed: " + fakeKey + "\n" + String(repeating: "x", count: 10_000)
            }
            try expect(!result.contains(fakeKey) && result.contains("[REDACTED]"), "Final response redaction")
            let requests = try assertRequests(2)
            for request in requests {
                try expect(!String(data: request.httpBody!, encoding: .utf8)!.contains(fakeKey), "No key in prompts or tool result")
            }
            let transcript = messages(try body(requests[1]), provider)
            let resultText: String
            if provider == "OpenAI" { resultText = transcript.last!["content"] as! String }
            else if provider == "Anthropic" { resultText = (transcript.last!["content"] as! [[String: Any]])[0]["content"] as! String }
            else {
                let response = (transcript.last!["parts"] as! [[String: Any]])[0]["functionResponse"] as! [String: Any]
                resultText = (response["response"] as! [String: Any])["result"] as! String
            }
            try expect(resultText.count == 8_000 && resultText.hasSuffix("[Tool result truncated]"), "Bounded tool text")
            try expect(resultText.contains("Tool failed:") && resultText.contains("\n"), "Executor error text preserved")
            network.invalidateAndCancel()
        }
    }

    static func geminiErrors() async throws {
        let cases: [(Int, String, String)] = [
            (400, "API key not valid", "API key rejected"), (401, "unauthenticated", "API key rejected"),
            (403, "permission denied", "Permission denied"), (429, "resource_exhausted", "Quota or rate limit"),
            (500, "internal", "server error"), (503, "unavailable", "server error"),
            (408, "deadline", "timed out"), (504, "deadline", "timed out"),
            (400, "model not found", "Invalid request"), (400, "invalid schema", "Invalid request"),
            (404, "route not found", "API route not found"), (404, "model schema not found", "API route not found"),
            (404, "model not found quota exhausted", "Quota or rate limit")
        ]
        for (status, message, expected) in cases {
            let network = session { _, index in
                try expect(index == 0, "No discovery for schema, quota or non-model error")
                return try MockReply(["error": ["message": message + " https://unit.invalid?key=" + fakeKey]], status: status)
            }
            let result = await RemoteGideonRuntime(session: network).generateReply(context: context("Gemini"))
            try expect(result.contains(expected) && result.contains("\(status)"), "Useful HTTP classification: \(status) / \(expected)")
            try expect(!result.contains(fakeKey) && !result.contains("https://"), "No raw errors or URL leakage")
            _ = try assertRequests(1)
            network.invalidateAndCancel()
        }
        let timeout = session { _, _ in
            throw URLError(.timedOut, userInfo: [NSURLErrorFailingURLErrorKey: URL(string: "https://unit.invalid?key=" + fakeKey)!])
        }
        let result = await RemoteGideonRuntime(session: timeout).generateReply(context: context("Gemini"))
        try expect(result.contains("timed out") && !result.contains(fakeKey), "Sanitized network timeout")
        _ = try assertRequests(1)
        timeout.invalidateAndCancel()
    }

    static func geminiEmptyResponses() async throws {
        let cases: [([String: Any], String)] = [
            (["candidates": [["finishReason": "MAX_TOKENS", "content": ["parts": [["thought": true, "text": "private"]]]]]], "MAX_TOKENS"),
            (["candidates": [["finishReason": "SAFETY"]]], "safety"),
            (["promptFeedback": ["blockReason": "PROHIBITED_CONTENT"]], "safety"),
            (["candidates": [["finishReason": "RECITATION"]]], "safety"),
            (["candidates": [["finishReason": "MALFORMED_FUNCTION_CALL"]]], "invalid tool call"),
            (["candidates": []], "no usable non-thought text")
        ]
        for (fixture, expected) in cases {
            let data = try json(fixture)
            let network = session { _, _ in try MockReply(JSONSerialization.jsonObject(with: data)) }
            let result = await RemoteGideonRuntime(session: network).generateReply(context: context("Gemini"))
            try expect(result.contains(expected) && !result.contains("private"), "Useful empty-response reason")
            _ = try assertRequests(1)
            network.invalidateAndCancel()
        }
        let recorder = Recorder()
        let blocked = session { _, _ in
            var fixture = toolReply("Gemini")
            var candidates = fixture["candidates"] as! [[String: Any]]
            candidates[0]["finishReason"] = "SAFETY"
            fixture["candidates"] = candidates
            return try MockReply(fixture)
        }
        let result = await RemoteGideonRuntime(session: blocked).generateReply(context: context("Gemini")) { await recorder.execute($0) }
        let calls = await recorder.snapshot()
        try expect(result.contains("safety") && calls.isEmpty, "Blocked candidate cannot trigger actions")
        _ = try assertRequests(1)
        blocked.invalidateAndCancel()
    }

    static func geminiRoutes() async throws {
        let cases = [
            ("", "/v1beta"), ("/v1", "/v1"), ("/v1beta/", "/v1beta"),
            ("/v1/models", "/v1"), ("/v1/models/old:generateContent", "/v1"),
            ("/proxy/v1beta/models/old:generateContent", "/proxy/v1beta"), ("/proxy", "/proxy/v1beta")
        ]
        for (suffix, prefix) in cases {
            let network = session { _, _ in try MockReply(finalReply("Gemini")) }
            _ = await RemoteGideonRuntime(session: network).generateReply(context: context("Gemini", endpoint: "https://unit.invalid" + suffix + "?key=legacy", model: "models/gemini-text-preview"))
            let request = try assertRequests(1)[0]
            try expect(request.url?.path == prefix + "/models/gemini-text-preview:generateContent", "Explicit API version and proxy prefix preserved")
            try expect(request.url?.query == nil, "No query authentication")
            try expect(request.value(forHTTPHeaderField: "x-goog-api-key") == fakeKey, "Header authentication")
            network.invalidateAndCancel()
        }
    }

    static func geminiFallback() async throws {
        let recorder = Recorder()
        let network = session { request, index in
            try expect(request.value(forHTTPHeaderField: "x-goog-api-key") == fakeKey, "Fallback/discovery header authentication")
            try expect(!(request.url?.absoluteString ?? "").contains(fakeKey), "No URL credentials")
            switch index {
            case 0: return try MockReply(missingModel(), status: 404)
            case 1:
                try expect(request.httpMethod == "GET" && request.url?.path == "/proxy/v1/models", "Discovery replaces full generation route, keeps v1")
                try expect(request.url?.query == nil, "First discovery no key query")
                return try MockReply(["models": [
                    ["name": "models/gemini-image-preview", "supportedGenerationMethods": ["generateContent"]],
                    ["name": "models/gemini-tts", "supportedGenerationMethods": ["generateContent"]],
                    ["name": "models/gemini-embedding", "supportedGenerationMethods": ["embedContent"]],
                    ["name": "models/gemini-4-flash", "supportedGenerationMethods": ["countTokens"]]
                ], "nextPageToken": "next-page"])
            case 2:
                try expect(request.url?.query == "pageToken=next-page", "Discovery pagination")
                return try MockReply(["models": [
                    ["name": "models/gemini-3-flash-preview", "supportedGenerationMethods": ["generateContent"]],
                    ["name": "models/gemini-2.5-flash-preview", "supportedGenerationMethods": ["generateContent"]],
                    ["name": "models/gemini-2.5-flash-preview", "supportedGenerationMethods": ["generateContent"]]
                ]])
            case 3:
                try expect(request.url?.path == "/proxy/v1/models/gemini-3-flash-preview:generateContent", "Text preview model allowed")
                return try MockReply(missingModel(), status: 404)
            case 4:
                try expect(request.url?.path == "/proxy/v1/models/gemini-2.5-flash-preview:generateContent", "Second distinct fallback")
                return try MockReply(toolReply("Gemini"))
            case 5: return try MockReply(finalReply("Gemini"))
            default: throw TestFailure(description: "Unexpected fallback request")
            }
        }
        let result = await RemoteGideonRuntime(session: network).generateReply(
            context: context("Gemini", endpoint: "https://unit.invalid/proxy/v1/models/old:generateContent?key=legacy", model: "gemini-old")
        ) { await recorder.execute($0) }
        try expect(result == "Done\n\n[Used fallback model: gemini-2.5-flash-preview]", "Successful fallback disclosed")
        let calls = await recorder.snapshot()
        try expect(calls.count == 1, "Fallback tool executes once")
        let requests = try assertRequests(6)
        try expect(String(data: requests[4].httpBody!, encoding: .utf8)!.contains("Harness instruction"), "Fallback retains system and tools")
        network.invalidateAndCancel()
    }

    static func boundedFallbackAndDiscoveryErrors() async throws {
        let network = session { request, index in
            if request.httpMethod == "GET" {
                return try MockReply(["models": (0..<10).map {
                    ["name": "models/gemini-flash-\($0)", "supportedGenerationMethods": ["generateContent"]] as [String: Any]
                }, "nextPageToken": "page-\(index)"])
            }
            return try MockReply(missingModel(), status: 404)
        }
        let result = await RemoteGideonRuntime(session: network).generateReply(context: context("Gemini", model: "gemini-old"))
        try expect(result.contains("Model not found"), "Exhausted fallback diagnostic")
        let requests = try assertRequests(9) // Original + three pages + five alternatives.
        let posts = requests.filter { $0.httpMethod == "POST" }
        try expect(Set(posts.map { $0.url!.path }).count == 6, "No duplicate fallback models")
        try expect(requests.filter { $0.httpMethod == "GET" }.count == 3, "Discovery page limit")
        network.invalidateAndCancel()

        for failDuringDiscovery in [true, false] {
            let failure = session { request, index in
                if index == 0 { return try MockReply(missingModel(), status: 404) }
                if request.httpMethod == "GET" && !failDuringDiscovery {
                    return try MockReply(["models": [["name": "models/gemini-new", "supportedGenerationMethods": ["generateContent"]]]])
                }
                return try MockReply(["error": ["status": "RESOURCE_EXHAUSTED", "message": "quota"]], status: 429)
            }
            let result = await RemoteGideonRuntime(session: failure).generateReply(context: context("Gemini"))
            try expect(result.contains("Quota or rate limit"), "Discovery/fallback quota errors preserved")
            _ = try assertRequests(failDuringDiscovery ? 2 : 3)
            failure.invalidateAndCancel()
        }
    }

    static func otherProviderFallbacks() async throws {
        for provider in ["Anthropic", "OpenAI"] {
            let model = provider == "Anthropic" ? "claude-haiku-new" : "gpt-text-new"
            let network = session { request, index in
                if index == 0 { return try MockReply(missingModel(), status: 404) }
                if index == 1 {
                    try expect(request.httpMethod == "GET" && request.url?.path == "/proxy/v1/models", "Native models discovery path")
                    let header = provider == "Anthropic" ? "x-api-key" : "Authorization"
                    let value = provider == "Anthropic" ? fakeKey : "Bearer \(fakeKey)"
                    try expect(request.value(forHTTPHeaderField: header) == value, "Discovery authentication")
                    return try MockReply(["data": [["id": model]]])
                }
                try expect(index == 2, "One fallback only")
                try expect(try body(request)["model"] as? String == model, "Fallback model body")
                return try MockReply(finalReply(provider))
            }
            let endpoint = "https://unit.invalid/proxy/v1/" + (provider == "Anthropic" ? "messages" : "chat/completions")
            let result = await RemoteGideonRuntime(session: network).generateReply(context: context(provider, endpoint: endpoint, model: "old"))
            try expect(result.contains("Used fallback model: \(model)"), "Fallback disclosure")
            _ = try assertRequests(3)
            network.invalidateAndCancel()
        }
    }

    static func noFallbackAfterExecution() async throws {
        for provider in providers {
            let recorder = Recorder()
            let network = session { _, index in
                index == 0 ? try MockReply(toolReply(provider)) : try MockReply(missingModel(), status: 404)
            }
            let result = await RemoteGideonRuntime(session: network).generateReply(context: context(provider)) { await recorder.execute($0) }
            try expect(result.contains("Model not found"), "Post-action HTTP failure returned")
            _ = try assertRequests(2)
            let calls = await recorder.snapshot()
            try expect(calls.count == 1, "No tool replay or fallback after action")
            network.invalidateAndCancel()
        }
    }

    static func cancellation() async throws {
        let before = Latch()
        let network = session { _, _ in throw TestFailure(description: "Cancelled task must not request") }
        let runtime = RemoteGideonRuntime(session: network)
        let pending = Task { await before.wait(); return await runtime.generateReply(context: context()) }
        pending.cancel()
        await before.open()
        let beforeResult = await pending.value
        try expect(beforeResult == "Request cancelled.", "Pre-request cancellation")
        _ = try assertRequests(0)
        network.invalidateAndCancel()

        let started = Latch()
        let inFlight = session { _, _ in Task { await started.open() }; return nil }
        let inFlightRuntime = RemoteGideonRuntime(session: inFlight)
        let task = Task { await inFlightRuntime.generateReply(context: context()) }
        await started.wait()
        task.cancel()
        let inFlightResult = await task.value
        try expect(inFlightResult == "Request cancelled.", "In-flight URLSession cancellation")
        _ = try assertRequests(1)
        inFlight.invalidateAndCancel()

        let entered = Latch(), release = Latch()
        let recorder = Recorder()
        let executing = session { _, _ in try MockReply(toolReply("OpenAI", count: 2)) }
        let executingRuntime = RemoteGideonRuntime(session: executing)
        let actionTask = Task {
            await executingRuntime.generateReply(context: context()) { call in
                _ = await recorder.execute(call)
                await entered.open()
                await release.wait()
                return "committed"
            }
        }
        await entered.wait()
        actionTask.cancel()
        await release.open()
        let actionResult = await actionTask.value
        try expect(actionResult == "Request cancelled.", "Cancellation after executor returns")
        let executed = await recorder.snapshot()
        try expect(executed.count == 1, "Cancellation prevents next parallel call")
        _ = try assertRequests(1)
        executing.invalidateAndCancel()
    }

    static func invalidationBeforeInitialRequest() async throws {
        // Check 1 is entry; check 2 is the final fence after request construction.
        for invalidAtCheck in [1, 2] {
            let validity = RequestValidity(invalidAtCheck: invalidAtCheck)
            let network = session { _, _ in throw TestFailure(description: "Invalid request must not dispatch") }
            defer { network.invalidateAndCancel() }
            var input = context()
            input.isRequestValid = validity.callback
            let result = await RemoteGideonRuntime(session: network).generateReply(context: input)
            try expect(result == "Request cancelled.", "Invalidation before initial dispatch")
            _ = try assertRequests(0)
        }

        // Cancellation while the async callback is suspended must be rechecked,
        // even if the callback itself returns true.
        let entered = Latch(), release = Latch()
        let network = session { _, _ in throw TestFailure(description: "Cancelled validity await must not dispatch") }
        defer { network.invalidateAndCancel() }
        let runtime = RemoteGideonRuntime(session: network)
        var input = context()
        input.isRequestValid = {
            await entered.open()
            await release.wait()
            return true
        }
        let captured = input
        let task = Task { await runtime.generateReply(context: captured) }
        await entered.wait()
        task.cancel()
        await release.open()
        let result = await task.value
        try expect(result == "Request cancelled.", "Cancellation after validity callback await")
        _ = try assertRequests(0)
    }

    static func invalidationDuringGeneration() async throws {
        for provider in providers {
            for response in ["tools", "text", "missing model", "unsupported tools", "network error"] {
                let validity = RequestValidity()
                let recorder = Recorder()
                let network = session { _, index in
                    try expect(index == 0, "Invalidation must prevent followup, discovery, and retry")
                    validity.invalidate()
                    switch response {
                    case "tools": return try MockReply(toolReply(provider, count: 2))
                    case "text": return try MockReply(finalReply(provider, text: "Stale account response"))
                    case "missing model": return try MockReply(missingModel(), status: 404)
                    case "unsupported tools":
                        return try MockReply(["error": ["message": "This model does not support tools"]], status: 400)
                    default: throw URLError(.timedOut)
                    }
                }
                defer { network.invalidateAndCancel() }
                var input = context(provider)
                input.isRequestValid = validity.callback
                let result = await RemoteGideonRuntime(session: network).generateReply(context: input) {
                    await recorder.execute($0)
                }
                try expect(result == "Request cancelled.", "Discard stale \(provider) \(response)")
                let calls = await recorder.snapshot()
                try expect(calls.isEmpty, "Invalidated generation cannot execute tools")
                _ = try assertRequests(1)
            }
        }
    }

    static func discoveryReply(_ provider: String, morePages: Bool) throws -> MockReply {
        if provider == "Gemini" {
            var reply: [String: Any] = ["models": [["name": "models/gemini-new", "supportedGenerationMethods": ["generateContent"]]]]
            if morePages { reply["nextPageToken"] = "next-page" }
            return try MockReply(reply)
        }
        return try MockReply(["data": [["id": provider == "Anthropic" ? "claude-new" : "gpt-new"]],
                              "has_more": morePages, "last_id": "next-page"])
    }

    static func invalidationDuringDiscovery() async throws {
        for provider in providers {
            for response in ["more pages", "last page", "network error", "HTTP error"] {
                let validity = RequestValidity()
                let recorder = Recorder()
                let network = session { request, index in
                    if index == 0 { return try MockReply(missingModel(), status: 404) }
                    try expect(index == 1 && request.httpMethod == "GET", "No discovery pages or retries after invalidation")
                    validity.invalidate()
                    if response == "network error" { throw URLError(.timedOut) }
                    if response == "HTTP error" { return try MockReply(["error": ["message": "quota"]], status: 429) }
                    return try discoveryReply(provider, morePages: response == "more pages")
                }
                defer { network.invalidateAndCancel() }
                var input = context(provider)
                input.isRequestValid = validity.callback
                let result = await RemoteGideonRuntime(session: network).generateReply(context: input) {
                    await recorder.execute($0)
                }
                try expect(result == "Request cancelled.", "Discard stale \(provider) discovery \(response)")
                let calls = await recorder.snapshot()
                try expect(calls.isEmpty, "Invalidated discovery cannot execute tools")
                _ = try assertRequests(2)
            }
        }
    }

    static func invalidationAtDispatchBoundaries() async throws {
        // Invalidate only after earlier post-await checks succeeded. This tests
        // the separate final fence, not just dropping an in-flight response.
        // Checks: entry=1, initial dispatch=2, generation response=3,
        // discovery dispatch=4, discovery response=5, discovery return=6,
        // fallback dispatch=7 (or next page dispatch=6 when paginating).
        let cases: [(String, Int, Int)] = [
            ("tool dispatch", 4, 1), ("text-only retry", 4, 1),
            ("discovery dispatch", 4, 1), ("next page", 6, 2),
            ("discovery return", 6, 2), ("fallback retry", 7, 2)
        ]
        for provider in providers {
            for (boundary, check, expectedRequests) in cases {
                if provider == "OpenAI" && boundary == "next page" { continue }
                let validity = RequestValidity(invalidAtCheck: check)
                let recorder = Recorder()
                let network = session { request, index in
                    try expect(index < expectedRequests, "No late request at \(boundary)")
                    if request.httpMethod == "GET" {
                        return try discoveryReply(provider, morePages: boundary == "next page")
                    }
                    if boundary == "tool dispatch" { return try MockReply(toolReply(provider)) }
                    if boundary == "text-only retry" {
                        return try MockReply(["error": ["message": "This model does not support tools"]], status: 400)
                    }
                    return try MockReply(missingModel(), status: 404)
                }
                defer { network.invalidateAndCancel() }
                var input = context(provider)
                input.isRequestValid = validity.callback
                let result = await RemoteGideonRuntime(session: network).generateReply(context: input) {
                    await recorder.execute($0)
                }
                try expect(result == "Request cancelled.", "Fence \(provider) \(boundary)")
                let calls = await recorder.snapshot()
                try expect(calls.isEmpty, "No late tool dispatch")
                _ = try assertRequests(expectedRequests)
            }
        }
    }

    static func invalidationDuringToolExecution() async throws {
        for provider in providers {
            let validity = RequestValidity()
            let recorder = Recorder()
            let network = session { _, index in
                try expect(index == 0, "No followup after tool invalidation")
                return try MockReply(toolReply(provider, count: 2))
            }
            defer { network.invalidateAndCancel() }
            var input = context(provider)
            input.isRequestValid = validity.callback
            let result = await RemoteGideonRuntime(session: network).generateReply(context: input) { call in
                let text = await recorder.execute(call)
                validity.invalidate()
                return text
            }
            try expect(result == "Request cancelled.", "Fence executor return for \(provider)")
            let calls = await recorder.snapshot()
            try expect(calls.count == 1, "No second tool or followup after scope changes")
            _ = try assertRequests(1)
        }
    }

    static func defaultsAndInvalidSchemas() async throws {
        for provider in providers {
            let network = session { _, _ in try MockReply(finalReply(provider)) }
            // Original memberwise API remains source compatible; tools and systemInstruction default.
            let input = RemoteGideonRequestContext(endpoint: URL(string: "https://unit.invalid")!, apiKey: "",
                                                  modelIdentifier: "", provider: provider, maxNewTokens: 10,
                                                  userMessage: "Hello", history: [])
            let result = await RemoteGideonRuntime(session: network).generateReply(context: input)
            try expect(result == "Done", "Original API still works")
            let payload = try body(assertRequests(1)[0])
            try expect(payload["tools"] == nil, "Omit empty tool definitions")
            network.invalidateAndCancel()
        }
        let network = session { _, _ in throw TestFailure(description: "Invalid schema should not send") }
        var input = context()
        input.tools = [RemoteToolDefinition(name: "bad", description: "", parametersJSON: "[]")]
        let result = await RemoteGideonRuntime(session: network).generateReply(context: input)
        try expect(result.contains("JSON object schemas"), "Invalid schema rejected locally")
        _ = try assertRequests(0)
        input.tools = [definition, definition]
        let duplicate = await RemoteGideonRuntime(session: network).generateReply(context: input)
        try expect(duplicate.contains("unique"), "Duplicate definitions rejected locally")
        _ = try assertRequests(0)
        network.invalidateAndCancel()
    }

    static func compatibility() async throws {
        for model in ["o3-mini", "o1", "o4-mini", "gpt-5-mini", "gpt-4o"] {
            let network = session { request, _ in
                let payload = try body(request)
                if model == "gpt-4o" {
                    try expect(payload["max_tokens"] != nil && payload["temperature"] != nil, "Standard sampling preserved")
                } else {
                    try expect(payload["max_tokens"] == nil && payload["temperature"] == nil, "Reasoning models omit unsupported parameters")
                    try expect(payload["max_completion_tokens"] as? Int == 4096, "Reasoning budget provided")
                }
                return try MockReply(["choices": [["message": ["role": "assistant", "content": "Done", "tool_calls": NSNull()]]]])
            }
            let reply = await RemoteGideonRuntime(session: network).generateReply(context: context(model: model))
            try expect(reply == "Done", "Null tool calls preserve final answer")
            _ = try assertRequests(1)
            network.invalidateAndCancel()
        }
        let network = session { request, index in
            let payload = try body(request)
            if index == 0 {
                try expect(payload["tools"] != nil, "Try advertised tools first")
                return try MockReply(["error": ["message": "This model does not support tools"]], status: 400)
            }
            try expect(payload["tools"] == nil, "Text-only retry omits tools")
            return try MockReply(finalReply("OpenAI"))
        }
        let reply = await RemoteGideonRuntime(session: network).generateReply(context: context())
        try expect(reply.contains("Done") && reply.contains("Text-only"), "Tool limitation disclosed")
        _ = try assertRequests(2)
        network.invalidateAndCancel()

        let afterTool = session { _, index in
            if index == 0 { return try MockReply(toolReply("OpenAI")) }
            return try MockReply(["error": ["message": "This model does not support tools"]], status: 400)
        }
        let recorder = Recorder()
        let stopped = await RemoteGideonRuntime(session: afterTool).generateReply(context: context(), executeTool: { await recorder.execute($0) })
        try expect(stopped.contains("HTTP 400"), "Never retry without tools after execution")
        _ = try assertRequests(2)
        afterTool.invalidateAndCancel()
    }

    static func main() async {
        let tests: [(String, () async throws -> Void)] = [
            ("default sessions disable cookies, credential storage, and caching", defaultSessionIsolation),
            ("schemas, shared instructions, and bounded history", schemasAndHistory),
            ("native multi-step roundtrips for all providers", nativeRoundTrips),
            ("six-round and eight-call limits", toolLimits),
            ("tool failures, unavailable executors, and deduplication", toolFailuresAndDeduplication),
            ("credential redaction and bounded tool results", redactionAndBoundedResults),
            ("Gemini HTTP errors and network timeout", geminiErrors),
            ("Gemini empty, thinking, and safety responses", geminiEmptyResponses),
            ("Gemini explicit versions, routes, and headers", geminiRoutes),
            ("Gemini paginated native fallback", geminiFallback),
            ("bounded fallback, pagination, and discovery errors", boundedFallbackAndDiscoveryErrors),
            ("Anthropic and OpenAI fallback", otherProviderFallbacks),
            ("no model fallback after tool execution", noFallbackAfterExecution),
            ("cancellation before, during network, and during executor", cancellation),
            ("scope invalidation before initial request and cancellation during validity await", invalidationBeforeInitialRequest),
            ("scope invalidation during generation suppresses tools, responses, and retries", invalidationDuringGeneration),
            ("scope invalidation during discovery stops pagination and fallback", invalidationDuringDiscovery),
            ("async validity fences immediately before tool, page, and retry dispatch", invalidationAtDispatchBoundaries),
            ("scope invalidation during tool execution stops batch and followup", invalidationDuringToolExecution),
            ("default API and invalid tool schemas", defaultsAndInvalidSchemas),
            ("nullable calls, reasoning parameters and text-only models", compatibility)
        ]
        var failures = 0
        for (name, test) in tests {
            do { try await test(); print("PASS: \(name)") }
            catch { failures += 1; print("FAIL: \(name): \(error)") }
        }
        print("\(tests.count - failures)/\(tests.count) test groups passed; all HTTP traffic mocked.")
        if failures > 0 { exit(1) }
    }
}