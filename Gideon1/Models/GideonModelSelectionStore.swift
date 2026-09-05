import Foundation

enum GideonReasoningMode: String, CaseIterable {
    case quick
    case balanced
    case deep

    var displayName: String {
        switch self {
        case .quick:
            return "Quick"
        case .balanced:
            return "Balanced"
        case .deep:
            return "Deep"
        }
    }

    var promptInstruction: String {
        switch self {
        case .quick:
            return "Use minimal reasoning. Prefer the shortest correct answer."
        case .balanced:
            return "Use balanced reasoning depth. Keep answers concise and complete."
        case .deep:
            return "Reason more thoroughly when needed, but stay practical and direct."
        }
    }
}

enum ModelProviderPreset: String, CaseIterable, Identifiable {
    case openAI
    case anthropic
    case openRouter
    case mistral
    case gemini
    case deepSeek
    case perplexity
    case grok

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .openAI: return "OpenAI"
        case .anthropic: return "Anthropic"
        case .openRouter: return "OpenRouter"
        case .mistral: return "Mistral"
        case .gemini: return "Gemini"
        case .deepSeek: return "DeepSeek"
        case .perplexity: return "Perplexity"
        case .grok: return "Grok"
        }
    }

    var defaultConnectionName: String {
        switch self {
        case .openAI: return "GPT"
        case .anthropic: return "Claude"
        case .openRouter: return "OpenRouter"
        case .mistral: return "Mistral"
        case .gemini: return "Gemini"
        case .deepSeek: return "DeepSeek"
        case .perplexity: return "Perplexity"
        case .grok: return "Grok"
        }
    }

    var providerKey: String {
        switch self {
        case .openAI: return "OpenAI"
        case .anthropic: return "Anthropic"
        case .openRouter: return "OpenRouter"
        case .mistral: return "Mistral"
        case .gemini: return "Gemini"
        case .deepSeek: return "DeepSeek"
        case .perplexity: return "Perplexity"
        case .grok: return "Grok"
        }
    }

    var baseURL: String {
        switch self {
        case .openAI: return "https://api.openai.com"
        case .anthropic: return "https://api.anthropic.com"
        case .openRouter: return "https://openrouter.ai/api"
        case .mistral: return "https://api.mistral.ai"
        case .gemini: return "https://generativelanguage.googleapis.com"
        case .deepSeek: return "https://api.deepseek.com"
        case .perplexity: return "https://api.perplexity.ai"
        case .grok: return "https://api.x.ai/v1"
        }
    }

    var models: [String] {
        switch self {
        case .openAI:
            return ["gpt-4.1", "gpt-4.1-mini", "gpt-4o", "gpt-4o-mini"]
        case .anthropic:
            return ["claude-3-7-sonnet-20250219", "claude-3-5-sonnet-20241022", "claude-3-5-haiku-20241022"]
        case .openRouter:
            return ["openai/gpt-4o-mini", "anthropic/claude-3.5-sonnet", "google/gemini-2.0-flash-001"]
        case .mistral:
            return ["mistral-small-latest", "mistral-large-latest", "codestral-latest"]
        case .gemini:
            return ["gemini-2.0-flash-001", "gemini-1.5-pro", "gemini-1.5-flash"]
        case .deepSeek:
            return ["deepseek-chat", "deepseek-reasoner"]
        case .perplexity:
            return ["llama-3.1-sonar-small-128k-online", "llama-3.1-sonar-large-128k-online"]
        case .grok:
            return ["grok-2", "grok-2-mini", "grok-beta"]
        }
    }

    var defaultModelID: String {
        models[0]
    }

    static func preset(for providerKey: String) -> ModelProviderPreset? {
        let normalized = providerKey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        if normalized.contains("anthropic") || normalized.contains("claude") {
            return .anthropic
        }
        if normalized.contains("openrouter") {
            return .openRouter
        }
        if normalized.contains("mistral") {
            return .mistral
        }
        if normalized.contains("gemini") || normalized.contains("google") {
            return .gemini
        }
        if normalized.contains("deepseek") {
            return .deepSeek
        }
        if normalized.contains("perplexity") {
            return .perplexity
        }
        if normalized.contains("grok") || normalized.contains("xai") {
            return .grok
        }
        if normalized.contains("openai") || normalized.contains("chatgpt") {
            return .openAI
        }
        return nil
    }
}

struct GideonAPIProviderProfile: Identifiable, Codable, Hashable {
    let id: UUID
    let name: String
    let provider: String
    let baseURL: String
    let customModelIdentifiers: [String]
    let createdAt: Date
}

struct GideonModelOption: Identifiable, Hashable {
    enum Backend: String, Hashable {
        case localQwen
        case gideonServer
        case apiModel
    }

    let id: String
    let title: String
    let subtitle: String
    let detail: String
    let backend: Backend
    let isAvailable: Bool
    let statusLabel: String
}

struct GideonModelVariantOption: Identifiable, Hashable {
    let id: String
    let title: String
    let subtitle: String
    let detail: String
    let isAvailable: Bool
}

private struct LegacyGideonAPIModelProfile: Codable {
    let id: UUID
    let name: String
    let provider: String
    let baseURL: String
    let modelIdentifier: String
    let createdAt: Date
}

private struct LoadedAPIProvidersState {
    let profiles: [GideonAPIProviderProfile]
    let migratedSelectionID: String?
}

private struct SupabaseModelPreferenceDTO: Codable {
    let userID: String
    let selectedModelID: String
    let apiProfilesJSON: String
    let updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case selectedModelID = "selected_model_id"
        case apiProfilesJSON = "api_profiles_json"
        case updatedAt = "updated_at"
    }

    init(userID: String, selectedModelID: String, apiProfilesJSON: String, updatedAt: Date) {
        self.userID = userID
        self.selectedModelID = selectedModelID
        self.apiProfilesJSON = apiProfilesJSON
        self.updatedAt = updatedAt
    }
}

@MainActor
final class GideonModelSelectionStore: ObservableObject {
    static let shared = GideonModelSelectionStore()

    static let tokenRange = 32...512

    @Published var selectedModelID: String {
        didSet {
            UserDefaults.standard.set(selectedModelID, forKey: Self.storageKey)
            Task { [selectedModelID] in
                await self.persistCloudSelection(selectedModelID)
            }
        }
    }

    @Published var maxNewTokens: Int {
        didSet {
            let clamped = Self.clampTokenLimit(maxNewTokens)
            if clamped != maxNewTokens {
                maxNewTokens = clamped
                return
            }
            UserDefaults.standard.set(maxNewTokens, forKey: Self.tokensStorageKey)
        }
    }

    @Published var reasoningModeRawValue: String {
        didSet {
            if GideonReasoningMode(rawValue: reasoningModeRawValue) == nil {
                reasoningModeRawValue = GideonReasoningMode.balanced.rawValue
                return
            }
            UserDefaults.standard.set(reasoningModeRawValue, forKey: Self.reasoningStorageKey)
        }
    }

    @Published private(set) var apiProviders: [GideonAPIProviderProfile]

    var apiProviderCount: Int {
        apiProviders.count
    }

    var options: [GideonModelOption] {
        Self.makeOptions(local: LocalModelRegistry.current, apiProviders: apiProviders)
    }

    var providerOptions: [GideonModelOption] {
        Self.makeProviderOptions(local: LocalModelRegistry.current, apiProviders: apiProviders)
    }

    var selectedOption: GideonModelOption {
        options.first(where: { $0.id == selectedModelID }) ?? options[0]
    }

    var selectedProviderOption: GideonModelOption {
        let providerID = Self.providerSelectionID(from: selectedModelID)
        return providerOptions.first(where: { $0.id == providerID }) ?? providerOptions[0]
    }

    var modelVariantsForSelectedProvider: [GideonModelVariantOption] {
        Self.makeModelVariants(
            for: selectedProviderOption.id,
            local: LocalModelRegistry.current,
            apiProviders: apiProviders,
            selectedModelID: selectedModelID
        )
    }

    var selectedModelVariant: GideonModelVariantOption {
        modelVariantsForSelectedProvider.first(where: { $0.id == selectedModelID }) ?? modelVariantsForSelectedProvider[0]
    }

    private static let storageKey = "gideon.selectedModelID"
    private static let tokensStorageKey = "gideon.maxNewTokens"
    private static let reasoningStorageKey = "gideon.reasoningMode"
    private static let apiProvidersStorageKey = "gideon.apiProviders.v1"
    private static let legacyAPIModelsStorageKey = "gideon.apiModels.v1"
    private static let apiProviderKeyPrefix = "gideon.api.provider.key."
    private static let legacyAPIModelKeyPrefix = "gideon.api.model.key."

    init() {
        let loadedState = Self.loadAPIProvidersState()
        let availableOptions = Self.makeOptions(local: LocalModelRegistry.current, apiProviders: loadedState.profiles)

        let selectedID: String
        if let saved = UserDefaults.standard.string(forKey: Self.storageKey),
           availableOptions.contains(where: { $0.id == saved }) {
            selectedID = saved
        } else if let migrated = loadedState.migratedSelectionID,
                  availableOptions.contains(where: { $0.id == migrated }) {
            selectedID = migrated
            UserDefaults.standard.set(migrated, forKey: Self.storageKey)
        } else {
            let preferred = availableOptions.first(where: { $0.backend != .localQwen }) ?? availableOptions.first
            selectedID = preferred?.id ?? "local-qwen"
            UserDefaults.standard.set(selectedID, forKey: Self.storageKey)
        }

        let storedTokens = UserDefaults.standard.integer(forKey: Self.tokensStorageKey)
        let tokenLimit: Int
        if storedTokens == 0 {
            tokenLimit = 96
            UserDefaults.standard.set(96, forKey: Self.tokensStorageKey)
        } else {
            tokenLimit = Self.clampTokenLimit(storedTokens)
        }

        let storedMode = UserDefaults.standard.string(forKey: Self.reasoningStorageKey)
        let reasoningRaw: String
        if let storedMode, GideonReasoningMode(rawValue: storedMode) != nil {
            reasoningRaw = storedMode
        } else {
            reasoningRaw = GideonReasoningMode.balanced.rawValue
            UserDefaults.standard.set(reasoningRaw, forKey: Self.reasoningStorageKey)
        }

        self.apiProviders = loadedState.profiles
        self.selectedModelID = selectedID
        self.maxNewTokens = tokenLimit
        self.reasoningModeRawValue = reasoningRaw

        Task { await refreshDiscoveredModels() }
    }

    var selectedOptionIndex: Int {
        options.firstIndex(where: { $0.id == selectedModelID }) ?? 0
    }

    func select(_ option: GideonModelOption) {
        selectedModelID = option.id
    }

    func selectProvider(_ option: GideonModelOption) {
        if option.backend != .apiModel {
            selectedModelID = option.id
            return
        }

        let variants = Self.makeModelVariants(
            for: option.id,
            local: LocalModelRegistry.current,
            apiProviders: apiProviders,
            selectedModelID: selectedModelID
        )
        guard let next = variants.first(where: \.isAvailable) ?? variants.first else {
            return
        }
        selectedModelID = next.id
    }

    func selectModelVariant(_ option: GideonModelVariantOption) {
        selectedModelID = option.id
    }

    func apiProvider(for option: GideonModelOption) -> GideonAPIProviderProfile? {
        Self.apiProviderProfile(forProviderOptionID: option.id, from: apiProviders)
    }

    func removeAPIProvider(id: UUID) async {
        guard apiProviders.contains(where: { $0.id == id }) else { return }

        apiProviders.removeAll { $0.id == id }
        try? SecureKeyStore.shared.delete(key: Self.apiKeyLookupKey(for: id))

        if Self.parseAPIModelOptionID(selectedModelID)?.providerID == id {
            let replacement = options.first(where: { $0.backend == .apiModel && $0.isAvailable })
                ?? options.first(where: \.isAvailable)
                ?? options.first
            if let replacement {
                selectedModelID = replacement.id
            }
        }

        persistAPIProviders()
        await CloudCredentialStore.shared.remove(ownerID: id.uuidString, kind: "api_key")
        objectWillChange.send()
    }

    var reasoningMode: GideonReasoningMode {
        get { GideonReasoningMode(rawValue: reasoningModeRawValue) ?? .balanced }
        set { reasoningModeRawValue = newValue.rawValue }
    }

    func addAPIProvider(
        name: String,
        provider: String,
        baseURL: String,
        apiKey: String,
        customModelIdentifiers: [String]
    ) async -> Bool {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedProvider = provider.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedAPIKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedURL = Self.normalizeURL(trimmedURL)

        guard !trimmedName.isEmpty,
              !trimmedProvider.isEmpty,
              !trimmedURL.isEmpty,
              normalizedURL != nil else {
            return false
        }

        let normalizedCustomModels = Self.normalizeCustomModels(customModelIdentifiers)
        let requiresAPIKey = normalizedURL.map(Self.requiresAPIKey(for:)) ?? true
        guard !requiresAPIKey || !trimmedAPIKey.isEmpty else {
            return false
        }

        let discoveredModels = await ProviderConnectionStore.shared.availableModelIdentifiers(
            providerName: trimmedProvider,
            endpoint: trimmedURL,
            apiKey: trimmedAPIKey
        )
        let effectiveModels = Self.normalizeCustomModels(discoveredModels + normalizedCustomModels)

        let profile = GideonAPIProviderProfile(
            id: UUID(),
            name: trimmedName,
            provider: trimmedProvider,
            baseURL: trimmedURL,
            customModelIdentifiers: effectiveModels,
            createdAt: Date()
        )

        do {
            if trimmedAPIKey.isEmpty {
                try SecureKeyStore.shared.delete(key: Self.apiKeyLookupKey(for: profile.id))
            } else {
                try SecureKeyStore.shared.write(key: Self.apiKeyLookupKey(for: profile.id), value: trimmedAPIKey)
            }
        } catch {
            return false
        }

        apiProviders.append(profile)
        persistAPIProviders()
        await CloudCredentialStore.shared.store(
            ownerID: profile.id.uuidString,
            kind: "api_key",
            value: trimmedAPIKey
        )
        objectWillChange.send()
        return true
    }

    func refreshDiscoveredModels() async {
        guard !apiProviders.isEmpty else { return }

        var updatedProfiles = apiProviders
        var didChange = false

        for index in updatedProfiles.indices {
            let profile = updatedProfiles[index]
            let apiKey = (try? SecureKeyStore.shared.read(key: Self.apiKeyLookupKey(for: profile.id))) ?? nil
            let trimmedAPIKey = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let discoveredModels = await ProviderConnectionStore.shared.availableModelIdentifiers(
                providerName: profile.provider,
                endpoint: profile.baseURL,
                apiKey: trimmedAPIKey
            )
            guard !discoveredModels.isEmpty else {
                continue
            }

            let refreshedModels = Self.normalizeCustomModels(discoveredModels)
            if refreshedModels != profile.customModelIdentifiers {
                updatedProfiles[index] = GideonAPIProviderProfile(
                    id: profile.id,
                    name: profile.name,
                    provider: profile.provider,
                    baseURL: profile.baseURL,
                    customModelIdentifiers: refreshedModels,
                    createdAt: profile.createdAt
                )
                didChange = true
            }
        }

        if didChange {
            apiProviders = updatedProfiles
        }
        let previousSelection = selectedModelID
        reconcileSelectedModel()
        guard didChange || previousSelection != selectedModelID else { return }
        if didChange {
            persistAPIProviders()
        }
        objectWillChange.send()
    }

    private func reconcileSelectedModel() {
        guard !options.contains(where: { $0.id == selectedModelID }),
              let parsed = Self.parseAPIModelOptionID(selectedModelID),
              let profile = apiProviders.first(where: { $0.id == parsed.providerID }) else {
            return
        }

        let variants = Self.makeModelVariants(
            for: Self.providerOptionID(for: profile),
            local: LocalModelRegistry.current,
            apiProviders: apiProviders,
            selectedModelID: selectedModelID
        )
        if let replacement = variants.first(where: \.isAvailable) ?? variants.first {
            selectedModelID = replacement.id
        }
    }

    func resolveAPIModelConfig(for optionID: String) -> (endpoint: URL, apiKey: String, modelID: String, provider: String)? {
        guard let parsed = Self.parseAPIModelOptionID(optionID),
              let profile = apiProviders.first(where: { $0.id == parsed.providerID }) else {
            return nil
        }

        guard let endpoint = Self.normalizeURL(profile.baseURL) else {
            return nil
        }

        let apiKey = (try? SecureKeyStore.shared.read(key: Self.apiKeyLookupKey(for: profile.id))) ?? nil
        let trimmedAPIKey = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmedAPIKey.isEmpty && Self.requiresAPIKey(for: endpoint) {
            return nil
        }

        return (endpoint, trimmedAPIKey, parsed.modelIdentifier, profile.provider)
    }

    private static func loadAPIProvidersState() -> LoadedAPIProvidersState {
        if let data = UserDefaults.standard.data(forKey: apiProvidersStorageKey),
           let decoded = try? JSONDecoder().decode([GideonAPIProviderProfile].self, from: data) {
            return LoadedAPIProvidersState(profiles: decoded, migratedSelectionID: nil)
        }

        return migrateLegacyAPIModels()
    }

    private static func migrateLegacyAPIModels() -> LoadedAPIProvidersState {
        guard let data = UserDefaults.standard.data(forKey: legacyAPIModelsStorageKey),
              let decoded = try? JSONDecoder().decode([LegacyGideonAPIModelProfile].self, from: data),
              !decoded.isEmpty else {
            return LoadedAPIProvidersState(profiles: [], migratedSelectionID: nil)
        }

        var grouped: [String: [LegacyGideonAPIModelProfile]] = [:]
        var selectionMap: [String: String] = [:]

        for legacyModel in decoded {
            let storedKey = (try? SecureKeyStore.shared.read(key: legacyAPIKeyLookupKey(for: legacyModel.id))) ?? nil
            let trimmedKey = storedKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let groupKey = [legacyModel.provider.lowercased(), legacyModel.baseURL.lowercased(), trimmedKey].joined(separator: "|")
            grouped[groupKey, default: []].append(legacyModel)
        }

        var migratedProfiles: [GideonAPIProviderProfile] = []

        for models in grouped.values {
            let sortedModels = models.sorted { $0.createdAt < $1.createdAt }
            guard let first = sortedModels.first else { continue }

            let preset = ModelProviderPreset.preset(for: first.provider)
            let presetModels = preset?.models ?? []
            let normalizedModelIDs = normalizeCustomModels(sortedModels.map(\ .modelIdentifier))
            let customModels = normalizedModelIDs.filter { !presetModels.contains($0) }
            let profile = GideonAPIProviderProfile(
                id: UUID(),
                name: preset?.defaultConnectionName ?? providerLabel(for: first.provider.lowercased()),
                provider: first.provider,
                baseURL: first.baseURL,
                customModelIdentifiers: customModels,
                createdAt: first.createdAt
            )

            let storedKey = (try? SecureKeyStore.shared.read(key: legacyAPIKeyLookupKey(for: first.id))) ?? nil
            let trimmedKey = storedKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !trimmedKey.isEmpty {
                try? SecureKeyStore.shared.write(key: apiKeyLookupKey(for: profile.id), value: trimmedKey)
            }

            for model in sortedModels {
                let legacyOptionID = legacyModelOptionID(for: model.id)
                let migratedOptionID = modelOptionID(for: profile, modelIdentifier: model.modelIdentifier)
                selectionMap[legacyOptionID] = migratedOptionID
            }

            migratedProfiles.append(profile)
        }

        if let encoded = try? JSONEncoder().encode(migratedProfiles) {
            UserDefaults.standard.set(encoded, forKey: apiProvidersStorageKey)
        }

        let savedSelection = UserDefaults.standard.string(forKey: storageKey)
        return LoadedAPIProvidersState(
            profiles: migratedProfiles.sorted { $0.createdAt < $1.createdAt },
            migratedSelectionID: savedSelection.flatMap { selectionMap[$0] }
        )
    }

    func reloadFromCurrentMode() async {
        let localProfiles = Self.loadAPIProvidersState().profiles
        if AppDataModeStore.shared.mode == .local {
            apiProviders = localProfiles
            return
        }

        guard AppSessionStore.shared.isAuthenticated,
              AppSessionStore.shared.currentUserID != nil else {
            apiProviders = localProfiles
            return
        }

        await loadCloud()
    }

    private func persistAPIProviders() {
        guard let data = try? JSONEncoder().encode(apiProviders) else { return }
        UserDefaults.standard.set(data, forKey: Self.apiProvidersStorageKey)
        Task { [profiles = apiProviders] in
            await self.persistCloudProfiles(profiles)
        }
    }

    private func loadCloud() async {
        guard let userID = AppSessionStore.shared.currentUserID,
              let token = AppSessionStore.shared.currentAccessToken,
              let url = URL(string: "\(AppSessionStore.supabaseRESTURL)/user_model_preferences?user_id=eq.\(userID)&select=*&limit=1") else {
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        request.setValue(AppSessionStore.supabasePublishableKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else {
                return
            }

            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let rows = try decoder.decode([SupabaseModelPreferenceDTO].self, from: data)
            guard let row = rows.first else {
                return
            }

            let profilesData = row.apiProfilesJSON.data(using: .utf8) ?? Data()
            let profiles = (try? JSONDecoder().decode([GideonAPIProviderProfile].self, from: profilesData)) ?? []
            if !profiles.isEmpty {
                apiProviders = profiles
                if let encoded = try? JSONEncoder().encode(profiles) {
                    UserDefaults.standard.set(encoded, forKey: Self.apiProvidersStorageKey)
                }
            }

            if !row.selectedModelID.isEmpty,
               Self.makeOptions(local: LocalModelRegistry.current, apiProviders: apiProviders)
                   .contains(where: { $0.id == row.selectedModelID }) {
                selectedModelID = row.selectedModelID
                UserDefaults.standard.set(row.selectedModelID, forKey: Self.storageKey)
            }

            await CloudCredentialStore.shared.reconcile(
                apiProviders.map { profile in
                    CloudCredentialBinding(
                        ownerID: profile.id.uuidString,
                        kind: "api_key",
                        keychainKey: Self.apiKeyLookupKey(for: profile.id)
                    )
                }
            )
            objectWillChange.send()
        } catch {
            // Keep local state if cloud data is unavailable.
        }
    }

    private func persistCloudSelection(_ modelID: String) async {
        guard let userID = AppSessionStore.shared.currentUserID,
              let token = AppSessionStore.shared.currentAccessToken,
              let url = URL(string: "\(AppSessionStore.supabaseRESTURL)/user_model_preferences?on_conflict=user_id") else {
            return
        }

        let apiProfilesJSON = (try? JSONEncoder().encode(apiProviders)).flatMap { data in
            String(data: data, encoding: .utf8)
        } ?? "[]"

        let payload = SupabaseModelPreferenceDTO(
            userID: userID,
            selectedModelID: modelID,
            apiProfilesJSON: apiProfilesJSON,
            updatedAt: Date()
        )

        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.timeoutInterval = 30
            request.setValue(AppSessionStore.supabasePublishableKey, forHTTPHeaderField: "apikey")
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("return=minimal, resolution=merge-duplicates", forHTTPHeaderField: "Prefer")
            request.httpBody = try encoder.encode(payload)
            _ = try await URLSession.shared.data(for: request)
        } catch {
            // Keep local state if cloud sync is unavailable; local cache remains source-of-truth.
        }
    }

    private func persistCloudProfiles(_ profiles: [GideonAPIProviderProfile]) async {
        await persistCloudSelection(selectedModelID)
    }

    private static func normalizeURL(_ rawValue: String) -> URL? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let url = URL(string: trimmed), url.scheme != nil {
            return url
        }
        return URL(string: "https://\(trimmed)")
    }

    private static func normalizeCustomModels(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        var ordered: [String] = []

        for value in values {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, isLikelyValidModelIdentifier(trimmed) else { continue }
            let key = trimmed.lowercased()
            if seen.insert(key).inserted {
                ordered.append(trimmed)
            }
        }

        return ordered
    }

    private static func providerLabel(for provider: String) -> String {
        if let preset = ModelProviderPreset.preset(for: provider) {
            return preset.defaultConnectionName
        }
        return provider.capitalized
    }

    private static func resolvedProviderTitle(for provider: GideonAPIProviderProfile) -> String {
        let trimmedName = provider.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let preset = ModelProviderPreset.preset(for: provider.provider) else {
            return trimmedName.isEmpty ? providerLabel(for: provider.provider.lowercased()) : trimmedName
        }

        let presetAliases = Set(ModelProviderPreset.allCases.flatMap { [$0.displayName, $0.defaultConnectionName] })
        if trimmedName.isEmpty || presetAliases.contains(trimmedName) {
            return preset.defaultConnectionName
        }

        return trimmedName
    }

    private static func clampTokenLimit(_ value: Int) -> Int {
        min(max(value, tokenRange.lowerBound), tokenRange.upperBound)
    }

    private static func makeOptions(local: BundledModelInfo, apiProviders: [GideonAPIProviderProfile]) -> [GideonModelOption] {
        var base: [GideonModelOption] = [
            GideonModelOption(
                id: "local-qwen",
                title: "Gideon (Local)",
                subtitle: "On-device",
                detail: "Uses bundled local runtime (currently Qwen-backed)",
                backend: .localQwen,
                isAvailable: local.isAvailable,
                statusLabel: local.isAvailable ? "Local" : local.statusLabel
            ),
            GideonModelOption(
                id: "gideon-server",
                title: "Gideon (Server)",
                subtitle: "Remote orchestrator",
                detail: "Pending mac-side orchestration link",
                backend: .gideonServer,
                isAvailable: false,
                statusLabel: "Server"
            )
        ]

        for provider in apiProviders {
            let storedKey = (try? SecureKeyStore.shared.read(key: apiKeyLookupKey(for: provider.id))) ?? nil
            let keyExists = storedKey?.isEmpty == false
            let endpoint = normalizeURL(provider.baseURL)
            let urlValid = endpoint != nil
            let keyRequired = endpoint.map(requiresAPIKey(for:)) ?? true
            let isAvailable = urlValid && (!keyRequired || keyExists)
            let providerTitle = resolvedProviderTitle(for: provider)

            for modelIdentifier in modelIdentifiers(for: provider) {
                base.append(
                    GideonModelOption(
                        id: modelOptionID(for: provider, modelIdentifier: modelIdentifier),
                        title: "\(providerTitle) • \(shortModelTitle(for: modelIdentifier, provider: provider.provider))",
                        subtitle: providerLabel(for: provider.provider.lowercased()),
                        detail: modelIdentifier,
                        backend: .apiModel,
                        isAvailable: isAvailable,
                        statusLabel: isAvailable ? "Server" : "Needs Key"
                    )
                )
            }
        }

        return base
    }

    private static func makeProviderOptions(local: BundledModelInfo, apiProviders: [GideonAPIProviderProfile]) -> [GideonModelOption] {
        var base: [GideonModelOption] = [
            GideonModelOption(
                id: "local-qwen",
                title: "Gideon",
                subtitle: "Local",
                detail: "Bundled Qwen runtime",
                backend: .localQwen,
                isAvailable: local.isAvailable,
                statusLabel: local.isAvailable ? "Local" : local.statusLabel
            ),
            GideonModelOption(
                id: "gideon-server",
                title: "Gideon Server",
                subtitle: "Remote",
                detail: "Pending mac-side orchestration link",
                backend: .gideonServer,
                isAvailable: false,
                statusLabel: "Server"
            )
        ]

        let mapped = apiProviders.map { provider in
            let storedKey = (try? SecureKeyStore.shared.read(key: apiKeyLookupKey(for: provider.id))) ?? nil
            let keyExists = storedKey?.isEmpty == false
            let endpoint = normalizeURL(provider.baseURL)
            let urlValid = endpoint != nil
            let keyRequired = endpoint.map(requiresAPIKey(for:)) ?? true
            let modelCount = modelIdentifiers(for: provider).count

            return GideonModelOption(
                id: providerOptionID(for: provider),
                title: resolvedProviderTitle(for: provider),
                subtitle: providerLabel(for: provider.provider.lowercased()),
                detail: modelCount == 1 ? "1 model" : "\(modelCount) models",
                backend: .apiModel,
                isAvailable: urlValid && (!keyRequired || keyExists),
                statusLabel: (urlValid && (!keyRequired || keyExists)) ? "Connected" : "Needs Key"
            )
        }

        base.append(contentsOf: mapped)
        return base
    }

    private static func makeModelVariants(
        for providerOptionID: String,
        local: BundledModelInfo,
        apiProviders: [GideonAPIProviderProfile],
        selectedModelID: String
    ) -> [GideonModelVariantOption] {
        if providerOptionID == "local-qwen" {
            return [
                GideonModelVariantOption(
                    id: "local-qwen",
                    title: local.shortLabel,
                    subtitle: local.runtimeLabel,
                    detail: local.detailLabel,
                    isAvailable: local.isAvailable
                )
            ]
        }

        if providerOptionID == "gideon-server" {
            return [
                GideonModelVariantOption(
                    id: "gideon-server",
                    title: "Planned",
                    subtitle: "Remote orchestrator",
                    detail: "Pending mac-side orchestration link",
                    isAvailable: false
                )
            ]
        }

        guard let provider = apiProviderProfile(forProviderOptionID: providerOptionID, from: apiProviders) else {
            return []
        }

        let storedKey = (try? SecureKeyStore.shared.read(key: apiKeyLookupKey(for: provider.id))) ?? nil
        let keyExists = storedKey?.isEmpty == false
        let endpoint = normalizeURL(provider.baseURL)
        let urlValid = endpoint != nil
        let keyRequired = endpoint.map(requiresAPIKey(for:)) ?? true
        let isAvailable = urlValid && (!keyRequired || keyExists)
        let subtitle = providerLabel(for: provider.provider.lowercased())
        let selectedFamily = familyKey(for: selectedModelID, provider: provider.provider)

        return modelIdentifiers(for: provider, selectedModelID: selectedModelID).map { modelIdentifier in
            GideonModelVariantOption(
                id: modelOptionID(for: provider, modelIdentifier: modelIdentifier),
                title: variantTitle(
                    for: modelIdentifier,
                    provider: provider.provider,
                    selectedFamily: selectedFamily
                ),
                subtitle: subtitle,
                detail: variantDetail(for: modelIdentifier),
                isAvailable: isAvailable
            )
        }
    }

    private static func shortModelTitle(for modelIdentifier: String, provider: String) -> String {
        let lower = modelIdentifier.lowercased()

        if lower.contains("claude-3-7-sonnet") { return "Sonnet 3.7" }
        if lower.contains("claude-3-5-sonnet") { return "Sonnet 3.5" }
        if lower.contains("claude-3-5-haiku") { return "Haiku 3.5" }
        if lower.contains("claude-3-opus") { return "Opus 3" }
        if lower.contains("fable") { return "Fable" }
        if lower.contains("sonnet") { return "Sonnet" }
        if lower.contains("haiku") { return "Haiku" }
        if lower.contains("opus") { return "Opus" }
        if lower.contains("gpt-4o-mini") { return "4o Mini" }
        if lower.contains("gpt-4o") { return "4o" }
        if lower.contains("gpt-4.1-mini") { return "4.1 Mini" }
        if lower.contains("gpt-4.1") { return "4.1" }
        if lower.contains("gemini-2.0-flash") || lower.contains("gemini-2.0") { return "2.0 Flash" }
        if lower.contains("gemini-1.5-pro") { return "1.5 Pro" }
        if lower.contains("gemini-1.5-flash") { return "1.5 Flash" }
        if lower.contains("deepseek-reasoner") { return "Reasoner" }
        if lower.contains("deepseek-chat") { return "Chat" }
        if lower.contains("codestral") { return "Codestral" }
        if lower.contains("mistral-large") { return "Large" }
        if lower.contains("mistral-small") { return "Small" }
        if lower.contains("sonar-large") { return "Sonar Large" }
        if lower.contains("sonar-small") { return "Sonar Small" }
        if lower.contains("grok-2-mini") { return "Grok 2 Mini" }
        if lower.contains("grok-2") { return "Grok 2" }

        if let preset = ModelProviderPreset.preset(for: provider), preset == .openRouter,
           let leaf = modelIdentifier.split(separator: "/").last {
            return String(leaf)
        }

        return modelIdentifier
    }

    private static func modelIdentifiers(for provider: GideonAPIProviderProfile) -> [String] {
        modelIdentifiers(for: provider, selectedModelID: nil)
    }

    private static func modelIdentifiers(for provider: GideonAPIProviderProfile, selectedModelID: String?) -> [String] {
        let presetModels = ModelProviderPreset.preset(for: provider.provider)?.models ?? []
        let base = provider.customModelIdentifiers.isEmpty ? presetModels : provider.customModelIdentifiers
        let cleaned = normalizeCustomModels(base)

        guard !cleaned.isEmpty else {
            return normalizeCustomModels(presetModels)
        }

        return curatedModelIdentifiers(cleaned, provider: provider.provider, selectedModelID: selectedModelID)
    }

    private static func curatedModelIdentifiers(
        _ ids: [String],
        provider: String,
        selectedModelID: String?
    ) -> [String] {
        let filtered = filterActiveModelIdentifiers(ids, provider: provider)
        let ranked = sortedModelIdentifiers(filtered, provider: provider)
        let grouped = Dictionary(grouping: ranked) { familyKey(for: $0, provider: provider) }
        let orderedFamilies = grouped.keys.sorted { lhs, rhs in
            let leftRank = familyCapabilityRank(lhs)
            let rightRank = familyCapabilityRank(rhs)
            if leftRank != rightRank {
                return leftRank < rightRank
            }
            if ModelProviderPreset.preset(for: provider) == .gemini {
                return lhs.localizedStandardCompare(rhs) == .orderedDescending
            }
            return lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending
        }

        var result: [String] = []
        for family in orderedFamilies {
            guard let familyModels = grouped[family], !familyModels.isEmpty else { continue }

            result.append(familyModels.first ?? family)
        }

        return normalizeCustomModels(result)
    }

    private static func filterActiveModelIdentifiers(_ ids: [String], provider: String) -> [String] {
        let lowerProvider = provider.lowercased()
        if lowerProvider.contains("gemini") || lowerProvider.contains("google") {
            // Rank before family deduplication so discovery order cannot hide a newer stable model.
            return ids.filter { ProviderConnectionStore.isGeminiTextModelIdentifier($0) }
        }
        let filtered = ids.filter { id in
            let lower = id.lowercased()
            if lower.contains("preview") || lower.contains("experimental") || lower.contains("beta") || lower.contains("nanov") || lower.contains("next") {
                return false
            }
            return true
        }

        var seenFamilies: Set<String> = []
        var kept: [String] = []

        for id in filtered {
            let family = familyKey(for: id, provider: provider)
            if seenFamilies.insert(family).inserted {
                kept.append(id)
            }
        }

        return kept
    }

    private static func sortedModelIdentifiers(_ ids: [String], provider: String) -> [String] {
        ids.sorted { lhs, rhs in
            let leftFamily = familyKey(for: lhs, provider: provider)
            let rightFamily = familyKey(for: rhs, provider: provider)
            if leftFamily != rightFamily {
                let leftRank = familyCapabilityRank(leftFamily)
                let rightRank = familyCapabilityRank(rightFamily)
                if leftRank != rightRank {
                    return leftRank < rightRank
                }
                return leftFamily.localizedCaseInsensitiveCompare(rightFamily) == .orderedAscending
            }

            if ModelProviderPreset.preset(for: provider) == .gemini {
                let previewMarkers = ["preview", "experimental", "exp", "beta"]
                let leftIsPreview = previewMarkers.contains(where: lhs.lowercased().contains)
                let rightIsPreview = previewMarkers.contains(where: rhs.lowercased().contains)
                if leftIsPreview != rightIsPreview { return !leftIsPreview }
                return lhs.localizedStandardCompare(rhs) == .orderedDescending
            }

            let leftDate = modelDateStamp(from: lhs)
            let rightDate = modelDateStamp(from: rhs)
            let leftIsLatest = lhs.lowercased().contains("latest")
            let rightIsLatest = rhs.lowercased().contains("latest")
            if leftIsLatest != rightIsLatest {
                return leftIsLatest
            }
            if leftDate != rightDate {
                return leftDate > rightDate
            }

            return lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending
        }
    }

    private static func familyCapabilityRank(_ family: String) -> Int {
        let lower = family.lowercased()
        if lower.contains("opus") { return 0 }
        if lower.contains("sonnet") { return 1 }
        if lower.contains("fable") { return 2 }
        if lower.contains("haiku") { return 3 }
        if lower.contains("reasoner") { return 4 }
        if lower.contains("pro") { return 5 }
        if lower.contains("flash") || lower.contains("mini") || lower.contains("small") { return 6 }
        return 10
    }

    private static func familyKey(for modelIdentifier: String, provider: String) -> String {
        let lower = modelIdentifier.lowercased()
        if lower.contains("claude") && lower.contains("sonnet") { return "Sonnet" }
        if lower.contains("claude") && lower.contains("haiku") { return "Haiku" }
        if lower.contains("claude") && lower.contains("opus") { return "Opus" }
        if lower.contains("fable") { return "Fable" }
        if lower.contains("gpt-4.1") { return "GPT 4.1" }
        if lower.contains("gpt-4o") { return "GPT 4o" }
        if lower.contains("gemini") {
            let version = lower.range(of: #"\d+\.\d+"#, options: .regularExpression).map { String(lower[$0]) } ?? ""
            if lower.contains("flash-lite") { return "Gemini \(version) Flash Lite" }
            if lower.contains("flash") { return "Gemini \(version) Flash" }
            if lower.contains("pro") { return "Gemini \(version) Pro" }
            return version.isEmpty ? "Gemini" : "Gemini \(version)"
        }
        if lower.contains("deepseek") { return "DeepSeek" }
        if lower.contains("mistral") { return "Mistral" }
        if lower.contains("sonar") { return "Sonar" }
        if lower.contains("grok") { return "Grok" }

        let title = shortModelTitle(for: modelIdentifier, provider: provider)
        return title
    }

    private static func modelDateStamp(from modelIdentifier: String) -> Int {
        let lower = modelIdentifier.lowercased()
        guard let match = lower.range(of: #"\b\d{8}\b"#, options: .regularExpression) else {
            return 0
        }
        return Int(lower[match]) ?? 0
    }

    private static func modelVersionLabel(from modelIdentifier: String) -> String? {
        let lower = modelIdentifier.lowercased()
        if lower.contains("latest") {
            return "latest"
        }

        guard let match = lower.range(of: #"\b\d{8}\b"#, options: .regularExpression) else {
            return nil
        }

        let raw = String(lower[match])
        guard raw.count == 8 else { return nil }
        let year = raw.prefix(4)
        let month = raw.dropFirst(4).prefix(2)
        let day = raw.suffix(2)
        return "\(year)-\(month)-\(day)"
    }

    private static func variantTitle(for modelIdentifier: String, provider: String, selectedFamily: String?) -> String {
        let family = familyKey(for: modelIdentifier, provider: provider)
        let explicit = shortModelTitle(for: modelIdentifier, provider: provider)
        if let selectedFamily, selectedFamily == family {
            return explicit
        }
        return explicit
    }

    private static func variantDetail(for modelIdentifier: String) -> String {
        if let version = modelVersionLabel(from: modelIdentifier) {
            return version
        }
        return modelIdentifier
    }

    private static func isLikelyValidModelIdentifier(_ value: String) -> Bool {
        if value.contains("@") {
            return false
        }

        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._/:")
        if value.rangeOfCharacter(from: allowed.inverted) != nil {
            return false
        }

        return value.rangeOfCharacter(from: .letters) != nil
    }

    private static func modelOptionID(for provider: GideonAPIProviderProfile, modelIdentifier: String) -> String {
        "api-\(provider.id.uuidString.lowercased())::\(modelIdentifier)"
    }

    private static func providerOptionID(for provider: GideonAPIProviderProfile) -> String {
        "api-provider-\(provider.id.uuidString.lowercased())"
    }

    private static func providerSelectionID(from optionID: String) -> String {
        guard let parsed = parseAPIModelOptionID(optionID) else {
            return optionID
        }
        return "api-provider-\(parsed.providerID.uuidString.lowercased())"
    }

    private static func parseAPIModelOptionID(_ optionID: String) -> (providerID: UUID, modelIdentifier: String)? {
        guard optionID.hasPrefix("api-") else { return nil }
        let suffix = optionID.dropFirst(4)
        guard let separatorRange = suffix.range(of: "::") else { return nil }
        let providerRaw = String(suffix[..<separatorRange.lowerBound])
        let modelIdentifier = String(suffix[separatorRange.upperBound...])
        guard let providerID = UUID(uuidString: providerRaw), !modelIdentifier.isEmpty else {
            return nil
        }
        return (providerID, modelIdentifier)
    }

    private static func apiProviderProfile(forProviderOptionID optionID: String, from apiProviders: [GideonAPIProviderProfile]) -> GideonAPIProviderProfile? {
        guard optionID.hasPrefix("api-provider-") else { return nil }
        let raw = String(optionID.dropFirst("api-provider-".count))
        guard let id = UUID(uuidString: raw) else { return nil }
        return apiProviders.first(where: { $0.id == id })
    }

    private static func apiKeyLookupKey(for providerID: UUID) -> String {
        "\(apiProviderKeyPrefix)\(providerID.uuidString.lowercased())"
    }

    private static func legacyAPIKeyLookupKey(for modelID: UUID) -> String {
        "\(legacyAPIModelKeyPrefix)\(modelID.uuidString.lowercased())"
    }

    private static func legacyModelOptionID(for modelID: UUID) -> String {
        "api-\(modelID.uuidString.lowercased())"
    }

    private static func requiresAPIKey(for endpoint: URL) -> Bool {
        !isLikelyLocalEndpoint(endpoint)
    }

    private static func isLikelyLocalEndpoint(_ endpoint: URL) -> Bool {
        guard let host = endpoint.host?.lowercased() else {
            return false
        }

        if host == "localhost" || host == "127.0.0.1" || host == "::1" || host.hasSuffix(".local") {
            return true
        }
        if host.hasPrefix("10.") || host.hasPrefix("192.168.") {
            return true
        }
        if host.hasPrefix("172."),
           let secondOctet = host.split(separator: ".").dropFirst().first,
           let value = Int(secondOctet),
           (16...31).contains(value) {
            return true
        }

        return false
    }
}
