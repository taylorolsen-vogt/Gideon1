import Foundation

struct AccountRecord: Identifiable, Codable {
    enum AuthType: String, Codable, CaseIterable {
        case apiKey = "API Key"
        case oauth  = "OAuth"
        case manual = "Manual"
    }

    let id: UUID
    let name: String       // user-given label, e.g. "Work GitHub"
    let service: String    // platform, e.g. "GitHub"
    let authType: AuthType
    let baseURL: String    // optional base URL override
    let notes: String
    let addedAt: Date

    /// Key used to store the API key / token in Keychain.
    var keychainKey: String { "gideon.account.\(id.uuidString)" }
}

@MainActor
final class AccountStore: ObservableObject {
    static let shared = AccountStore()

    @Published private(set) var accounts: [AccountRecord] = []

    private static let storageKey = "gideon.accounts.v1"

    private init() { load() }

    // MARK: - Public API

    func add(
        name: String,
        service: String,
        authType: AccountRecord.AuthType,
        baseURL: String,
        notes: String,
        apiKey: String
    ) {
        let record = AccountRecord(
            id: UUID(),
            name: name.isEmpty ? service : name,
            service: service,
            authType: authType,
            baseURL: baseURL,
            notes: notes,
            addedAt: Date()
        )
        if !apiKey.isEmpty {
            try? SecureKeyStore.shared.write(key: record.keychainKey, value: apiKey)
        }
        accounts.append(record)
        persist()
    }

    func remove(id: UUID) {
        guard let record = accounts.first(where: { $0.id == id }) else { return }
        try? SecureKeyStore.shared.delete(key: record.keychainKey)
        accounts.removeAll { $0.id == id }
        persist()
    }

    /// Reads the stored API key / token for an account from Keychain.
    func apiKey(for record: AccountRecord) -> String? {
        try? SecureKeyStore.shared.read(key: record.keychainKey)
    }

    // MARK: - Persistence

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: Self.storageKey),
              let decoded = try? JSONDecoder().decode([AccountRecord].self, from: data) else { return }
        accounts = decoded
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(accounts) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }
}
