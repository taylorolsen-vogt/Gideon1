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
    private var observerTokens: [NSObjectProtocol] = []
    private var loadedScope: SessionScope?
    private let session = URLSession(configuration: ProviderNetworkSession.makeConfiguration())

    private static let storageKey = "gideon.providerConnections.v1"

    private init() {
        self.records = Self.loadLocalRecords()
        loadedScope = .current
        registerObservers()
        let scope = SessionScope.current
        Task { await reloadFromCurrentMode(expectedScope: scope) }
    }

    var connectedCount: Int {
        records.filter { $0.state == .connected }.count
    }

    var manualStepCount: Int {
        records.filter { $0.state == .manualStep }.count
    }

    func record(for providerName: String) -> ProviderConnectionRecord {
        if loadedScope?.isCurrent != true { loadLocal() }
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

    func verifyConnection(providerName: String, endpoint: String, apiKey: String, modelIdentifier: String, expectedScope: SessionScope? = nil) async -> (ok: Bool, message: String) {
        let scope = expectedScope ?? .current
        guard scope.isCurrent else { return (false, "Session changed") }
        let result = await verifyConnection(providerName: providerName, endpoint: endpoint, apiKey: apiKey, scope: scope)
        guard scope.isCurrent else { return (false, "Session changed") }
        return result
    }

    private func verifyConnection(providerName: String, endpoint: String, apiKey: String, scope: SessionScope) async -> (ok: Bool, message: String) {
        guard scope.isCurrent else { return (false, "Session changed") }
        let providerID = normalizedID(for: providerName)
        let trimmedEndpoint = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)

        if providerID.contains("github") {
            guard !trimmedKey.isEmpty else {
                return (false, "Missing API key")
            }
            return await verifyGitHubPAT(apiKey: trimmedKey, scope: scope)
        }

        if providerID.contains("gmail") || providerID == "google" || providerID.contains("google-mail") {
            guard !trimmedKey.isEmpty else {
                return (false, "Missing API key")
            }
            return await verifyGmailAccessToken(apiKey: trimmedKey, scope: scope)
        }

        guard !trimmedEndpoint.isEmpty else {
            return (false, "Missing endpoint")
        }

        guard let baseURL = makeURL(trimmedEndpoint) else {
            return (false, "Invalid endpoint URL")
        }

        if providerID.contains("anthropic") || providerID.contains("claude") {
            guard !trimmedKey.isEmpty else {
                return (false, "Missing API key")
            }
            return await verifyAnthropic(baseURL: baseURL, apiKey: trimmedKey, scope: scope)
        }

        if providerID.contains("gemini") || providerID.contains("google") || baseURL.host?.contains("generativelanguage") == true {
            guard !trimmedKey.isEmpty else {
                return (false, "Missing API key")
            }
            return await verifyGemini(baseURL: baseURL, apiKey: trimmedKey, scope: scope)
        }

        return await verifyOpenAICompatible(baseURL: baseURL, apiKey: trimmedKey, scope: scope)
    }

    func availableModelIdentifiers(providerName: String, endpoint: String, apiKey: String, expectedScope: SessionScope? = nil) async -> [String] {
        let scope = expectedScope ?? .current
        guard scope.isCurrent else { return [] }
        let result = await availableModelIdentifiers(providerName: providerName, endpoint: endpoint, apiKey: apiKey, scope: scope)
        guard scope.isCurrent else { return [] }
        return result
    }

    private func availableModelIdentifiers(providerName: String, endpoint: String, apiKey: String, scope: SessionScope) async -> [String] {
        guard scope.isCurrent else { return [] }
        let providerID = normalizedID(for: providerName)
        let trimmedEndpoint = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedEndpoint.isEmpty,
              let baseURL = makeURL(trimmedEndpoint) else {
            return []
        }

        if providerID.contains("anthropic") || providerID.contains("claude") {
            return await fetchAnthropicModelIdentifiers(baseURL: baseURL, apiKey: trimmedKey, scope: scope)
        }

        if providerID.contains("gemini") || providerID.contains("google") || baseURL.host?.contains("generativelanguage") == true {
            return await fetchGeminiModelIdentifiers(baseURL: baseURL, apiKey: trimmedKey, scope: scope)
        }

        return await fetchOpenAICompatibleModelIdentifiers(baseURL: baseURL, apiKey: trimmedKey, scope: scope)
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
        if key.contains("gmail") {
            return URL(string: "https://console.cloud.google.com/apis/credentials")!
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
        if loadedScope?.isCurrent != true { loadLocal() }
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

    private func verifyOpenAICompatible(baseURL: URL, apiKey: String, scope: SessionScope) async -> (ok: Bool, message: String) {
        guard scope.isCurrent else { return (false, "Session changed") }
        guard let verifyURL = modelsURL(from: baseURL) else {
            return (false, "Invalid provider endpoint")
        }

        var request = URLRequest(url: verifyURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 25
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        do {
            let (data, response) = try await session.data(for: request)
            guard scope.isCurrent else { return (false, "Session changed") }
            guard let http = response as? HTTPURLResponse else {
                return (false, "Invalid verification response")
            }
            if (200..<300).contains(http.statusCode) {
                return (true, "Verified with provider")
            }
            if http.statusCode == 401 || http.statusCode == 403 {
                return (false, "The provider rejected the API key or token.")
            }
            if http.statusCode == 429 {
                return (false, interpretedQuotaMessage(data: data, fallback: "The provider rate-limited this request. Please wait and try again."))
            }
            if http.statusCode == 400 {
                return (false, "The provider rejected the request. Check the endpoint and API key.")
            }
            return (false, "Provider responded with \(http.statusCode)")
        } catch {
            return (false, "Verification failed: \(error.localizedDescription)")
        }
    }

    private func fetchOpenAICompatibleModelIdentifiers(baseURL: URL, apiKey: String, scope: SessionScope) async -> [String] {
        guard scope.isCurrent else { return [] }
        guard let verifyURL = modelsURL(from: baseURL) else {
            return []
        }

        var request = URLRequest(url: verifyURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 25
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        do {
            let (data, response) = try await session.data(for: request)
            guard scope.isCurrent else { return [] }
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let rows = root["data"] as? [[String: Any]] else {
                return []
            }

            return rows.compactMap { $0["id"] as? String }
        } catch {
            return []
        }
    }

    private func verifyGitHubPAT(apiKey: String, scope: SessionScope) async -> (ok: Bool, message: String) {
        guard scope.isCurrent else { return (false, "Session changed") }
        guard let verifyURL = URL(string: "https://api.github.com/user") else {
            return (false, "Invalid GitHub verify URL")
        }

        var request = URLRequest(url: verifyURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        do {
            let (_, response) = try await session.data(for: request)
            guard scope.isCurrent else { return (false, "Session changed") }
            guard let http = response as? HTTPURLResponse else {
                return (false, "Invalid GitHub response")
            }
            if (200..<300).contains(http.statusCode) {
                return (true, "Verified with GitHub")
            }
            return (false, "GitHub responded with \(http.statusCode)")
        } catch {
            return (false, "GitHub verification failed: \(error.localizedDescription)")
        }
    }

    private func verifyGmailAccessToken(apiKey: String, scope: SessionScope) async -> (ok: Bool, message: String) {
        guard scope.isCurrent else { return (false, "Session changed") }
        guard let verifyURL = URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/profile") else {
            return (false, "Invalid Gmail verify URL")
        }

        var request = URLRequest(url: verifyURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        do {
            let (_, response) = try await session.data(for: request)
            guard scope.isCurrent else { return (false, "Session changed") }
            guard let http = response as? HTTPURLResponse else {
                return (false, "Invalid Gmail response")
            }
            if (200..<300).contains(http.statusCode) {
                return (true, "Verified with Gmail")
            }
            if http.statusCode == 401 || http.statusCode == 403 {
                return (false, "Gmail token invalid or missing Gmail scope")
            }
            return (false, "Gmail responded with \(http.statusCode)")
        } catch {
            return (false, "Gmail verification failed: \(error.localizedDescription)")
        }
    }

    private func verifyAnthropic(baseURL: URL, apiKey: String, scope: SessionScope) async -> (ok: Bool, message: String) {
        guard scope.isCurrent else { return (false, "Session changed") }
        guard let verifyURL = modelsURL(from: baseURL) else {
            return (false, "Invalid Anthropic endpoint")
        }

        var request = URLRequest(url: verifyURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 25
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

        do {
            let (data, response) = try await session.data(for: request)
            guard scope.isCurrent else { return (false, "Session changed") }
            guard let http = response as? HTTPURLResponse else {
                return (false, "Invalid verification response")
            }
            if (200..<300).contains(http.statusCode) {
                return (true, "Verified with Anthropic")
            }
            if http.statusCode == 401 || http.statusCode == 403 {
                return (false, "Anthropic rejected the API key or token.")
            }
            if http.statusCode == 429 {
                return (false, interpretedQuotaMessage(data: data, fallback: "Anthropic rate-limited this request. Please wait and try again."))
            }
            if http.statusCode == 400 {
                return (false, "Anthropic rejected the request. Check that the endpoint is correct and your account can access the API.")
            }
            return (false, "Anthropic responded with \(http.statusCode)")
        } catch {
            return (false, "Verification failed: \(error.localizedDescription)")
        }
    }

    private func fetchAnthropicModelIdentifiers(baseURL: URL, apiKey: String, scope: SessionScope) async -> [String] {
        guard scope.isCurrent else { return [] }
        guard !apiKey.isEmpty,
              let verifyURL = modelsURL(from: baseURL) else {
            return []
        }

        var request = URLRequest(url: verifyURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 25
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

        do {
            let (data, response) = try await session.data(for: request)
            guard scope.isCurrent else { return [] }
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let rows = root["data"] as? [[String: Any]] else {
                return []
            }

            return rows.compactMap { $0["id"] as? String }
        } catch {
            return []
        }
    }

    private func verifyGemini(baseURL: URL, apiKey: String, scope: SessionScope) async -> (ok: Bool, message: String) {
        guard scope.isCurrent else { return (false, "Session changed") }
        guard let verifyURL = geminiModelsURL(from: baseURL) else {
            return (false, "Invalid Gemini endpoint")
        }

        var request = URLRequest(url: verifyURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 25
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")

        do {
            let (data, response) = try await session.data(for: request)
            guard scope.isCurrent else { return (false, "Session changed") }
            guard let http = response as? HTTPURLResponse else {
                return (false, "Invalid verification response")
            }
            if (200..<300).contains(http.statusCode) {
                guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      root["models"] is [[String: Any]] else {
                    return (false, "Invalid Gemini model listing response")
                }
                // Listing access does not establish selected-model generation access or quota.
                return (true, "Gemini model listing accessible; generation and quota not verified")
            }
            if http.statusCode == 401 || http.statusCode == 403 {
                return (false, "Gemini rejected the API key or token.")
            }
            if http.statusCode == 429 {
                return (false, interpretedQuotaMessage(data: data, fallback: "Gemini rate-limited this request. Please wait and try again."))
            }
            if http.statusCode == 400 {
                return (false, "Gemini rejected the request. Check that the endpoint and API key are correct.")
            }
            return (false, "Gemini responded with \(http.statusCode)")
        } catch {
            return (false, "Gemini verification failed. Check your connection and endpoint settings.")
        }
    }

    private func fetchGeminiModelIdentifiers(baseURL: URL, apiKey: String, scope: SessionScope) async -> [String] {
        guard scope.isCurrent else { return [] }
        guard !apiKey.isEmpty,
              let modelsURL = geminiModelsURL(from: baseURL) else {
            return []
        }

        var identifiers: [String] = []
        var seenIdentifiers: Set<String> = []
        var pageToken: String?
        var seenTokens: Set<String> = []
        do {
            for _ in 0..<3 {
                guard scope.isCurrent else { return [] }
                var components = URLComponents(url: modelsURL, resolvingAgainstBaseURL: false)
                if let pageToken {
                    components?.queryItems = [URLQueryItem(name: "pageToken", value: pageToken)]
                }
                guard let url = components?.url else { return [] }
                var request = URLRequest(url: url)
                request.httpMethod = "GET"
                request.timeoutInterval = 25
                request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")

                let (data, response) = try await session.data(for: request)
                guard scope.isCurrent else { return [] }
                guard let http = response as? HTTPURLResponse,
                      (200..<300).contains(http.statusCode),
                      let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let rows = root["models"] as? [[String: Any]] else {
                    return []
                }

                for row in rows {
                    guard let name = row["name"] as? String,
                          let methods = row["supportedGenerationMethods"] as? [String],
                          methods.contains("generateContent") else { continue }
                    let identifier = name.replacingOccurrences(of: "^models/", with: "", options: .regularExpression)
                    if Self.isGeminiTextModelIdentifier(identifier),
                       seenIdentifiers.insert(identifier.lowercased()).inserted {
                        identifiers.append(identifier)
                    }
                }
                pageToken = root["nextPageToken"] as? String
                guard let next = pageToken, !next.isEmpty, seenTokens.insert(next).inserted else { break }
            }
            return identifiers
        } catch {
            return []
        }
    }

    static func isGeminiTextModelIdentifier(_ identifier: String) -> Bool {
        let lower = identifier.lowercased()
        // Preview/experimental text models remain eligible; specialized modalities do not.
        let unsupportedKinds = [
            "embedding", "imagen", "veo", "image", "tts", "audio", "live",
            "robotics", "computer-use", "aqa", "whisper", "dall-e", "realtime", "moderation"
        ]
        return lower.contains("gemini") && !unsupportedKinds.contains(where: lower.contains)
    }

    private func geminiModelsURL(from baseURL: URL) -> URL? {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false),
              ["https", "http"].contains(components.scheme?.lowercased() ?? ""),
              components.host != nil else { return nil }
        // Match RemoteGideonRuntime routing, including explicit versions and proxy prefixes.
        components.query = nil
        components.fragment = nil
        components.user = nil
        components.password = nil
        var segments = baseURL.path.split(separator: "/").map(String.init)
        if let version = segments.firstIndex(where: { $0 == "v1" || $0 == "v1beta" }) {
            segments = Array(segments.prefix(version + 1))
        } else {
            if let models = segments.firstIndex(of: "models") { segments = Array(segments.prefix(models)) }
            segments.append("v1beta")
        }
        segments.append("models")
        components.path = "/" + segments.joined(separator: "/")
        return components.url
    }

    private func interpretedQuotaMessage(data: Data, fallback: String) -> String {
        guard let body = String(data: data, encoding: .utf8)?.lowercased() else {
            return fallback
        }
        if body.contains("insufficient_quota") || body.contains("insufficient quota") || body.contains("credits") || body.contains("billing") {
            return "The provider reports insufficient credits/quota. Add billing or top up credits, then try again."
        }
        return fallback
    }

    private func makeURL(_ raw: String) -> URL? {
        if let parsed = URL(string: raw), parsed.scheme != nil {
            return parsed
        }
        return URL(string: "https://\(raw)")
    }

    private func modelsURL(from baseURL: URL) -> URL? {
        if baseURL.path.hasSuffix("/v1/models") {
            return baseURL
        }

        var normalized = baseURL
        if normalized.path.isEmpty || normalized.path == "/" {
            normalized.append(path: "v1/models")
            return normalized
        }

        let path = normalized.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if path == "v1" {
            normalized.append(path: "models")
            return normalized
        }

        normalized.append(path: "v1/models")
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
        guard loadedScope?.isCurrent == true else { return }
        let scope = SessionScope.current
        persistLocal()
        if scope.canSyncCloud {
            Task { [snapshot = records] in
                guard scope.isCurrent else { return }
                await persistCloud(snapshot: snapshot, scope: scope)
            }
        }
    }

    private func persistLocal() {
        guard loadedScope?.isCurrent == true, let data = try? JSONEncoder().encode(records) else {
            return
        }
        ScopedDefaults.standard.set(data, forKey: Self.storageKey)
    }

    private static func loadLocalRecords() -> [ProviderConnectionRecord] {
          if let data = ScopedDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([ProviderConnectionRecord].self, from: data) {
            return decoded
        }
        return defaultRecords
    }

    private func loadLocal() {
        records = []
        loadedScope = .current
        records = Self.loadLocalRecords()
    }

    private func registerObservers() {
        let center = NotificationCenter.default
        observerTokens.append(
            center.addObserver(forName: .gideonDataModeChanged, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.loadLocal()
                    let scope = SessionScope.current
                    Task { await self.reloadFromCurrentMode(expectedScope: scope) }
                }
            }
        )
        observerTokens.append(
            center.addObserver(forName: .gideonSessionChanged, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.loadLocal()
                    let scope = SessionScope.current
                    Task { await self.reloadFromCurrentMode(expectedScope: scope) }
                }
            }
        )
    }

    func reloadFromCurrentMode(expectedScope: SessionScope? = nil) async {
        let scope = expectedScope ?? .current
        guard scope.isCurrent else { return }
        loadLocal()
        if scope.canSyncCloud { await loadCloud(scope: scope) }
    }

    private func loadCloud(scope: SessionScope) async {
        guard scope.isCurrent, scope.canSyncCloud else { return }
        guard let userID = scope.userID,
              let token = AppSessionStore.shared.currentAccessToken,
              let url = URL(string: "\(AppSessionStore.supabaseRESTURL)/provider_connections?user_id=eq.\(userID)&select=*&order=last_updated.desc") else {
            loadLocal()
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        request.setValue(AppSessionStore.supabasePublishableKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await session.data(for: request)
            guard scope.isCurrent else { return }
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return
            }

            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let rows = try decoder.decode([SupabaseProviderConnectionDTO].self, from: data)
            let cloudRecords = rows.filter { $0.userID.lowercased() == userID.lowercased() }.compactMap { $0.toRecord() }

            records = cloudRecords
            persistLocal()
        } catch {
            // Keep local cache on cloud read failure.
        }
    }

    private func persistCloud(snapshot: [ProviderConnectionRecord], scope: SessionScope) async {
        guard scope.isCurrent, scope.canSyncCloud,
              let userID = scope.userID,
              let token = AppSessionStore.shared.currentAccessToken,
              !snapshot.isEmpty,
              let insertURL = URL(string: "\(AppSessionStore.supabaseRESTURL)/provider_connections?on_conflict=user_id,id") else {
            return
        }

        do {
            let payload = snapshot.map { SupabaseProviderConnectionDTO(record: $0, userID: userID) }
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601

            var insertRequest = URLRequest(url: insertURL)
            insertRequest.httpMethod = "POST"
            insertRequest.timeoutInterval = 30
            insertRequest.setValue(AppSessionStore.supabasePublishableKey, forHTTPHeaderField: "apikey")
            insertRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            insertRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
            insertRequest.setValue("return=minimal, resolution=merge-duplicates", forHTTPHeaderField: "Prefer")
            insertRequest.httpBody = try encoder.encode(payload)

            let (_, response) = try await session.data(for: insertRequest)
            guard scope.isCurrent else { return }
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else {
                print("[Gideon] provider connection cloud insert failed for user \(userID)")
                return
            }
        } catch {
            print("[Gideon] provider connection cloud sync error: \(error.localizedDescription)")
        }
    }

    private static let defaultRecords: [ProviderConnectionRecord] = [
        ProviderConnectionRecord(id: "openai", title: "OpenAI", state: .notConnected, detail: "Not configured", lastUpdated: Date()),
        ProviderConnectionRecord(id: "anthropic", title: "Anthropic", state: .notConnected, detail: "Not configured", lastUpdated: Date()),
        ProviderConnectionRecord(id: "github", title: "GitHub", state: .notConnected, detail: "Not configured", lastUpdated: Date()),
        ProviderConnectionRecord(id: "gmail", title: "Gmail", state: .notConnected, detail: "Not configured", lastUpdated: Date()),
        ProviderConnectionRecord(id: "railway", title: "Railway", state: .notConnected, detail: "Not configured", lastUpdated: Date()),
        ProviderConnectionRecord(id: "firebase", title: "Firebase", state: .notConnected, detail: "Not configured", lastUpdated: Date()),
        ProviderConnectionRecord(id: "twitter", title: "X / Twitter", state: .notConnected, detail: "Not configured", lastUpdated: Date())
    ]

    private func hasConfiguredLocalRecords(_ snapshot: [ProviderConnectionRecord]) -> Bool {
        snapshot.contains { record in
            record.state != .notConnected || record.detail.caseInsensitiveCompare("Not configured") != .orderedSame
        }
    }

    private func configuredRecordCount(_ snapshot: [ProviderConnectionRecord]) -> Int {
        snapshot.reduce(into: 0) { count, record in
            if record.state != .notConnected || record.detail.caseInsensitiveCompare("Not configured") != .orderedSame {
                count += 1
            }
        }
    }
}

private struct SupabaseProviderConnectionDTO: Codable {
    let id: String
    let userID: String
    let title: String
    let state: String
    let detail: String
    let lastUpdated: Date

    enum CodingKeys: String, CodingKey {
        case id
        case userID = "user_id"
        case title
        case state
        case detail
        case lastUpdated = "last_updated"
    }

    init(record: ProviderConnectionRecord, userID: String) {
        self.id = record.id
        self.userID = userID
        self.title = record.title
        self.state = record.state.rawValue
        self.detail = record.detail
        self.lastUpdated = record.lastUpdated
    }

    func toRecord() -> ProviderConnectionRecord? {
        guard let parsedState = ProviderConnectionRecord.State(rawValue: state) else {
            return nil
        }
        return ProviderConnectionRecord(
            id: id,
            title: title,
            state: parsedState,
            detail: detail,
            lastUpdated: lastUpdated
        )
    }
}
