import Foundation

struct ProviderConnectionRecord: Identifiable, Codable {
    enum State: String, Codable {
        case notConnected
        case manualStep
        case connected
        case error

        var displayLabel: String {
            switch self {
            case .notConnected:
                return "Not Connected"
            case .manualStep:
                return "Manual Step"
            case .connected:
                return "Connected"
            case .error:
                return "Error"
            }
        }
    }

    let id: String
    var title: String
    var state: State
    var detail: String
    var lastUpdated: Date
}

@MainActor
final class ProviderConnectionStore: ObservableObject {
    static let shared = ProviderConnectionStore()

    @Published private(set) var records: [ProviderConnectionRecord]

    private static let storageKey = "gideon.providerConnections.v1"

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.storageKey),
           let decoded = try? JSONDecoder().decode([ProviderConnectionRecord].self, from: data),
           !decoded.isEmpty {
            self.records = decoded
        } else {
            self.records = Self.defaultRecords
            persist()
        }
    }

    var connectedCount: Int {
        records.filter { $0.state == .connected }.count
    }

    var manualStepCount: Int {
        records.filter { $0.state == .manualStep }.count
    }

    func record(for providerName: String) -> ProviderConnectionRecord {
        let key = normalizedID(for: providerName)
        if let existing = records.first(where: { $0.id == key }) {
            return existing
        }

        let created = ProviderConnectionRecord(
            id: key,
            title: normalizedTitle(for: providerName),
            state: .notConnected,
            detail: "Not configured",
            lastUpdated: Date()
        )
        records.append(created)
        persist()
        return created
    }

    func markManualStep(providerName: String, detail: String) {
        update(providerName: providerName, state: .manualStep, detail: detail)
    }

    func markConnected(providerName: String, detail: String) {
        update(providerName: providerName, state: .connected, detail: detail)
    }

    func markError(providerName: String, detail: String) {
        update(providerName: providerName, state: .error, detail: detail)
    }

    func verifyConnection(providerName: String, endpoint: String, apiKey: String, modelIdentifier: String) async -> (ok: Bool, message: String) {
        let providerID = normalizedID(for: providerName)
        let trimmedEndpoint = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedEndpoint.isEmpty else {
            return (false, "Missing endpoint")
        }
        guard !trimmedKey.isEmpty else {
            return (false, "Missing API key")
        }

        guard let baseURL = makeURL(trimmedEndpoint) else {
            return (false, "Invalid endpoint URL")
        }

        if providerID.contains("anthropic") || providerID.contains("claude") {
            return await verifyAnthropic(baseURL: baseURL, apiKey: trimmedKey, modelIdentifier: modelIdentifier)
        }

        return await verifyChatCompletions(baseURL: baseURL, apiKey: trimmedKey)
    }

    func portalURL(for providerName: String) -> URL {
        let key = normalizedID(for: providerName)

        if key.contains("openai") || key.contains("chatgpt") {
            return URL(string: "https://platform.openai.com/settings/organization/api-keys")!
        }
        if key.contains("anthropic") || key.contains("claude") {
            return URL(string: "https://console.anthropic.com/settings/keys")!
        }
        if key.contains("github") {
            return URL(string: "https://github.com/settings/tokens")!
        }
        if key.contains("railway") {
            return URL(string: "https://railway.app/account/tokens")!
        }
        if key.contains("firebase") || key.contains("google") {
            return URL(string: "https://console.firebase.google.com/")!
        }
        if key.contains("twitter") || key == "x" {
            return URL(string: "https://developer.x.com/en/portal/dashboard")!
        }

        return URL(string: "https://\(providerName)") ?? URL(string: "https://example.com")!
    }

    private func update(providerName: String, state: ProviderConnectionRecord.State, detail: String) {
        let key = normalizedID(for: providerName)
        if let index = records.firstIndex(where: { $0.id == key }) {
            records[index].state = state
            records[index].detail = detail
            records[index].lastUpdated = Date()
        } else {
            records.append(
                ProviderConnectionRecord(
                    id: key,
                    title: normalizedTitle(for: providerName),
                    state: state,
                    detail: detail,
                    lastUpdated: Date()
                )
            )
        }
        persist()
    }

    private func verifyChatCompletions(baseURL: URL, apiKey: String) async -> (ok: Bool, message: String) {
        guard let verifyURL = chatCompletionsURL(from: baseURL) else {
            return (false, "Invalid chat endpoint")
        }

        var request = URLRequest(url: verifyURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let payload: [String: Any] = [
            "model": "gpt-4o-mini",
            "messages": [["role": "user", "content": "ping"]],
            "max_tokens": 4
        ]

        guard let body = try? JSONSerialization.data(withJSONObject: payload) else {
            return (false, "Failed to encode verification payload")
        }
        request.httpBody = body

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return (false, "Invalid verification response")
            }
            if (200..<300).contains(http.statusCode) {
                return (true, "Verified with provider")
            }
            return (false, "Provider responded with \(http.statusCode)")
        } catch {
            return (false, "Verification failed: \(error.localizedDescription)")
        }
    }

    private func verifyAnthropic(baseURL: URL, apiKey: String, modelIdentifier: String) async -> (ok: Bool, message: String) {
        guard let verifyURL = anthropicMessagesURL(from: baseURL) else {
            return (false, "Invalid Anthropic endpoint")
        }

        var request = URLRequest(url: verifyURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

        let model = modelIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "claude-3-5-haiku-latest" : modelIdentifier
        let payload: [String: Any] = [
            "model": model,
            "max_tokens": 8,
            "messages": [["role": "user", "content": [["type": "text", "text": "ping"]]]]
        ]

        guard let body = try? JSONSerialization.data(withJSONObject: payload) else {
            return (false, "Failed to encode Anthropic verification payload")
        }
        request.httpBody = body

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return (false, "Invalid verification response")
            }
            if (200..<300).contains(http.statusCode) {
                return (true, "Verified with Anthropic")
            }
            return (false, "Provider responded with \(http.statusCode)")
        } catch {
            return (false, "Verification failed: \(error.localizedDescription)")
        }
    }

    private func makeURL(_ raw: String) -> URL? {
        if let parsed = URL(string: raw), parsed.scheme != nil {
            return parsed
        }
        return URL(string: "https://\(raw)")
    }

    private func chatCompletionsURL(from baseURL: URL) -> URL? {
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

    private func anthropicMessagesURL(from baseURL: URL) -> URL? {
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

    private func normalizedID(for providerName: String) -> String {
        providerName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: " ", with: "-")
    }

    private func normalizedTitle(for providerName: String) -> String {
        let trimmed = providerName.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return "Provider"
        }
        return trimmed
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(records) else {
            return
        }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }

    private static let defaultRecords: [ProviderConnectionRecord] = [
        ProviderConnectionRecord(id: "openai", title: "OpenAI", state: .notConnected, detail: "Not configured", lastUpdated: Date()),
        ProviderConnectionRecord(id: "anthropic", title: "Anthropic", state: .notConnected, detail: "Not configured", lastUpdated: Date()),
        ProviderConnectionRecord(id: "github", title: "GitHub", state: .notConnected, detail: "Not configured", lastUpdated: Date()),
        ProviderConnectionRecord(id: "railway", title: "Railway", state: .notConnected, detail: "Not configured", lastUpdated: Date()),
        ProviderConnectionRecord(id: "firebase", title: "Firebase", state: .notConnected, detail: "Not configured", lastUpdated: Date()),
        ProviderConnectionRecord(id: "twitter", title: "X / Twitter", state: .notConnected, detail: "Not configured", lastUpdated: Date())
    ]
}
