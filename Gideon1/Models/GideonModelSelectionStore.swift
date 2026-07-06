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

struct GideonAPIModelProfile: Identifiable, Codable, Hashable {
    let id: UUID
    let name: String
    let provider: String
    let baseURL: String
    let modelIdentifier: String
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

@MainActor
final class GideonModelSelectionStore: ObservableObject {
    static let shared = GideonModelSelectionStore()

    static let tokenRange = 16...128

    @Published var selectedModelID: String {
        didSet { UserDefaults.standard.set(selectedModelID, forKey: Self.storageKey) }
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

    @Published private(set) var apiModels: [GideonAPIModelProfile]

    var options: [GideonModelOption] {
        Self.makeOptions(local: LocalModelRegistry.current, apiModels: apiModels)
    }

    private static let storageKey = "gideon.selectedModelID"
    private static let tokensStorageKey = "gideon.maxNewTokens"
    private static let reasoningStorageKey = "gideon.reasoningMode"
    private static let apiModelsStorageKey = "gideon.apiModels.v1"
    private static let apiModelKeyPrefix = "gideon.api.model.key."

    init() {
        let loadedAPIModels = Self.loadAPIModels()
        let availableOptions = Self.makeOptions(local: LocalModelRegistry.current, apiModels: loadedAPIModels)

        let selectedID: String
        if let saved = UserDefaults.standard.string(forKey: Self.storageKey),
           availableOptions.contains(where: { $0.id == saved }) {
            selectedID = saved
        } else {
            selectedID = availableOptions.first?.id ?? "local-qwen"
            UserDefaults.standard.set(selectedID, forKey: Self.storageKey)
        }

        let storedTokens = UserDefaults.standard.integer(forKey: Self.tokensStorageKey)
        let tokenLimit: Int
        if storedTokens == 0 {
            tokenLimit = 40
            UserDefaults.standard.set(40, forKey: Self.tokensStorageKey)
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

        self.apiModels = loadedAPIModels
        self.selectedModelID = selectedID
        self.maxNewTokens = tokenLimit
        self.reasoningModeRawValue = reasoningRaw
    }

    var selectedOption: GideonModelOption {
        options.first(where: { $0.id == selectedModelID }) ?? options[0]
    }

    var selectedOptionIndex: Int {
        options.firstIndex(where: { $0.id == selectedModelID }) ?? 0
    }

    func select(_ option: GideonModelOption) {
        selectedModelID = option.id
    }

    var reasoningMode: GideonReasoningMode {
        get { GideonReasoningMode(rawValue: reasoningModeRawValue) ?? .balanced }
        set { reasoningModeRawValue = newValue.rawValue }
    }

    func addAPIModel(name: String, provider: String, baseURL: String, modelIdentifier: String, apiKey: String) -> Bool {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedProvider = provider.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedModelID = modelIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedAPIKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedName.isEmpty,
              !trimmedProvider.isEmpty,
              !trimmedURL.isEmpty,
              !trimmedModelID.isEmpty,
              !trimmedAPIKey.isEmpty,
              Self.normalizeURL(trimmedURL) != nil else {
            return false
        }

        let profile = GideonAPIModelProfile(
            id: UUID(),
            name: trimmedName,
            provider: trimmedProvider,
            baseURL: trimmedURL,
            modelIdentifier: trimmedModelID,
            createdAt: Date()
        )

        do {
            try SecureKeyStore.shared.write(key: Self.apiKeyLookupKey(for: profile.id), value: trimmedAPIKey)
        } catch {
            return false
        }

        apiModels.append(profile)
        persistAPIModels()
        objectWillChange.send()
        return true
    }

    func resolveAPIModelConfig(for optionID: String) -> (endpoint: URL, apiKey: String, modelID: String, provider: String)? {
        guard let profile = apiModelProfile(for: optionID) else {
            return nil
        }

        guard let endpoint = Self.normalizeURL(profile.baseURL) else {
            return nil
        }

        guard let apiKey = try? SecureKeyStore.shared.read(key: Self.apiKeyLookupKey(for: profile.id)),
              !apiKey.isEmpty else {
            return nil
        }

        return (endpoint, apiKey, profile.modelIdentifier, profile.provider)
    }

    private func apiModelProfile(for optionID: String) -> GideonAPIModelProfile? {
        guard optionID.hasPrefix("api-") else { return nil }
        let raw = String(optionID.dropFirst(4))
        guard let id = UUID(uuidString: raw) else { return nil }
        return apiModels.first(where: { $0.id == id })
    }

    private static func optionID(for model: GideonAPIModelProfile) -> String {
        "api-\(model.id.uuidString.lowercased())"
    }

    private static func apiKeyLookupKey(for modelID: UUID) -> String {
        "\(apiModelKeyPrefix)\(modelID.uuidString.lowercased())"
    }

    private static func loadAPIModels() -> [GideonAPIModelProfile] {
        guard let data = UserDefaults.standard.data(forKey: apiModelsStorageKey),
              let decoded = try? JSONDecoder().decode([GideonAPIModelProfile].self, from: data) else {
            return []
        }
        return decoded
    }

    private func persistAPIModels() {
        guard let data = try? JSONEncoder().encode(apiModels) else { return }
        UserDefaults.standard.set(data, forKey: Self.apiModelsStorageKey)
    }

    private static func normalizeURL(_ rawValue: String) -> URL? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let url = URL(string: trimmed), url.scheme != nil {
            return url
        }
        return URL(string: "https://\(trimmed)")
    }

    private static func clampTokenLimit(_ value: Int) -> Int {
        min(max(value, tokenRange.lowerBound), tokenRange.upperBound)
    }

    private static func makeOptions(local: BundledModelInfo, apiModels: [GideonAPIModelProfile]) -> [GideonModelOption] {
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

        let mapped = apiModels.map { model in
            let keyExists = (try? SecureKeyStore.shared.read(key: Self.apiKeyLookupKey(for: model.id)))?.isEmpty == false
            let urlValid = Self.normalizeURL(model.baseURL) != nil
            let providerLower = model.provider.lowercased()
            let displayTitle: String
            let displaySubtitle: String
            if providerLower.contains("openai") || providerLower.contains("chatgpt") {
                displayTitle = "ChatGPT (Server)"
                displaySubtitle = "OpenAI"
            } else {
                displayTitle = "\(model.provider) (Server)"
                displaySubtitle = model.provider
            }
            return GideonModelOption(
                id: Self.optionID(for: model),
                title: displayTitle,
                subtitle: displaySubtitle,
                detail: model.modelIdentifier,
                backend: .apiModel,
                isAvailable: keyExists && urlValid,
                statusLabel: (keyExists && urlValid) ? "Server" : "Needs Key"
            )
        }

        base.append(contentsOf: mapped)
        return base
    }
}
