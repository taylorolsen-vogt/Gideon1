import Foundation

struct RemoteGideonRequestContext {
    let endpoint: URL
    let apiKey: String
    let modelIdentifier: String
    let provider: String
    let maxNewTokens: Int
    let userMessage: String
    let history: [HarnessTurn]
}

actor RemoteGideonRuntime {
    static let shared = RemoteGideonRuntime()

    private enum ProviderProtocol {
        case chatCompletions
        case anthropicMessages
    }

    func generateReply(context: RemoteGideonRequestContext) async -> String {
        let protocolStyle = resolveProtocol(provider: context.provider, endpoint: context.endpoint)

        let request: URLRequest
        do {
            request = try buildRequest(context: context, protocolStyle: protocolStyle)
        } catch {
            return "Could not build provider request: \(error.localizedDescription)"
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return "API route failed: invalid response."
            }

            guard (200..<300).contains(http.statusCode) else {
                let bodyText = String(data: data, encoding: .utf8) ?? ""
                return "API route failed (\(http.statusCode)). \(bodyText.prefix(180))"
            }

            switch protocolStyle {
            case .chatCompletions:
                if let text = parseChatCompletionsResponse(data), !text.isEmpty {
                    return text
                }
            case .anthropicMessages:
                if let text = parseAnthropicMessagesResponse(data), !text.isEmpty {
                    return text
                }
            }

            return "API route returned no text."
        } catch {
            return "API route failed: \(error.localizedDescription)"
        }
    }

    private func buildRequest(context: RemoteGideonRequestContext, protocolStyle: ProviderProtocol) throws -> URLRequest {
        let messages = buildHistoryMessages(
            userMessage: context.userMessage,
            history: context.history,
            provider: context.provider,
            modelIdentifier: context.modelIdentifier
        )

        var request: URLRequest
        let payload: [String: Any]

        switch protocolStyle {
        case .chatCompletions:
            guard let url = resolvedChatCompletionsURL(from: context.endpoint) else {
                throw URLError(.badURL)
            }
            request = URLRequest(url: url)
            request.setValue("Bearer \(context.apiKey)", forHTTPHeaderField: "Authorization")
            payload = [
                "model": context.modelIdentifier,
                "messages": messages,
                "max_tokens": context.maxNewTokens,
                "temperature": 0.2
            ]

        case .anthropicMessages:
            guard let url = resolvedAnthropicMessagesURL(from: context.endpoint) else {
                throw URLError(.badURL)
            }
            request = URLRequest(url: url)
            request.setValue(context.apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

            let anthropicMessages = messages
                .filter { ($0["role"] as? String) != "system" }
                .compactMap { message -> [String: Any]? in
                    guard let role = message["role"] as? String,
                          let content = message["content"] as? String else {
                        return nil
                    }
                    return [
                        "role": role,
                        "content": [["type": "text", "text": content]]
                    ]
                }

            payload = [
                "model": context.modelIdentifier,
                "max_tokens": context.maxNewTokens,
                "system": "You are a connected \(context.provider) assistant in Gideon. Keep answers concise and practical. If asked your identity, say you are model \(context.modelIdentifier) via \(context.provider).",
                "messages": anthropicMessages
            ]
        }

        request.httpMethod = "POST"
        request.timeoutInterval = 45
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        return request
    }

    private func resolveProtocol(provider: String, endpoint: URL) -> ProviderProtocol {
        let normalizedProvider = provider.lowercased()
        let host = endpoint.host?.lowercased() ?? ""

        if normalizedProvider.contains("anthropic") || normalizedProvider.contains("claude") || host.contains("anthropic") {
            return .anthropicMessages
        }

        return .chatCompletions
    }

    private func resolvedChatCompletionsURL(from baseURL: URL) -> URL? {
        if baseURL.path.hasSuffix("/v1/chat/completions") {
            return baseURL
        }

        var normalized = baseURL
        if normalized.path.isEmpty || normalized.path == "/" {
            normalized.append(path: "v1/chat/completions")
            return normalized
        }

        let path = normalized.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if path == "v1" {
            normalized.append(path: "chat/completions")
            return normalized
        }

        normalized.append(path: "v1/chat/completions")
        return normalized
    }

    private func resolvedAnthropicMessagesURL(from baseURL: URL) -> URL? {
        if baseURL.path.hasSuffix("/v1/messages") {
            return baseURL
        }

        var normalized = baseURL
        if normalized.path.isEmpty || normalized.path == "/" {
            normalized.append(path: "v1/messages")
            return normalized
        }

        let path = normalized.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if path == "v1" {
            normalized.append(path: "messages")
            return normalized
        }

        normalized.append(path: "v1/messages")
        return normalized
    }

    private func buildHistoryMessages(
        userMessage: String,
        history: [HarnessTurn],
        provider: String,
        modelIdentifier: String
    ) -> [[String: Any]] {
        var messages: [[String: Any]] = [
            [
                "role": "system",
                "content": "You are a connected \(provider) assistant in Gideon. Keep answers concise and practical. If asked your identity, say you are model \(modelIdentifier) via \(provider)."
            ]
        ]

        for turn in history.suffix(4) {
            messages.append([
                "role": turn.role == .user ? "user" : "assistant",
                "content": String(turn.text.prefix(320))
            ])
        }

        messages.append([
            "role": "user",
            "content": userMessage
        ])

        return messages
    }

    private func parseChatCompletionsResponse(_ data: Data) -> String? {
        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let choices = root["choices"] as? [[String: Any]],
            let first = choices.first,
            let message = first["message"] as? [String: Any],
            let content = message["content"] as? String
        else {
            return nil
        }

        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func parseAnthropicMessagesResponse(_ data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let contentArray = root["content"] as? [[String: Any]] else {
            return nil
        }

        let parts = contentArray.compactMap { item -> String? in
            guard let type = item["type"] as? String, type == "text" else {
                return nil
            }
            return item["text"] as? String
        }

        let text = parts.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}
