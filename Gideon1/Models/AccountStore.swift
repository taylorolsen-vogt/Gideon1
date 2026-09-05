import Foundation

struct AccountRecord: Identifiable, Codable, Sendable {
    enum AuthType: String, Codable, CaseIterable, Sendable {
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
    var refreshTokenKey: String { "\(keychainKey).refreshToken" }
}

@MainActor
final class AccountStore: ObservableObject {
    static let shared = AccountStore()

    @Published private(set) var accounts: [AccountRecord] = []
    private var observerTokens: [NSObjectProtocol] = []

    private static let storageKey = "gideon.accounts.v1"

    private init() {
        loadLocal()
        registerObservers()
        Task { await reloadFromCurrentMode() }
    }

    // MARK: - Public API

    @discardableResult
    func add(
        name: String,
        service: String,
        authType: AccountRecord.AuthType,
        baseURL: String,
        notes: String,
        apiKey: String,
        refreshToken: String = ""
    ) -> AccountRecord {
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
        if !refreshToken.isEmpty {
            try? SecureKeyStore.shared.write(key: record.refreshTokenKey, value: refreshToken)
        }
        accounts.append(record)
        persist()
        Task {
            await CloudCredentialStore.shared.store(ownerID: record.id.uuidString, kind: "access_token", value: apiKey)
            await CloudCredentialStore.shared.store(ownerID: record.id.uuidString, kind: "refresh_token", value: refreshToken)
        }
        return record
    }

    func remove(id: UUID) {
        guard let record = accounts.first(where: { $0.id == id }) else { return }
        try? SecureKeyStore.shared.delete(key: record.keychainKey)
        try? SecureKeyStore.shared.delete(key: record.refreshTokenKey)
        accounts.removeAll { $0.id == id }
        persist()
        Task {
            await deleteCloud(id: id)
            await CloudCredentialStore.shared.remove(ownerID: id.uuidString, kind: "access_token")
            await CloudCredentialStore.shared.remove(ownerID: id.uuidString, kind: "refresh_token")
        }
    }

    /// Reads the stored API key / token for an account from Keychain.
    func apiKey(for record: AccountRecord) -> String? {
        try? SecureKeyStore.shared.read(key: record.keychainKey)
    }

    func refreshToken(for record: AccountRecord) -> String? {
        try? SecureKeyStore.shared.read(key: record.refreshTokenKey)
    }

    func updateAccessToken(_ token: String, for record: AccountRecord) {
        try? SecureKeyStore.shared.write(key: record.keychainKey, value: token)
        Task {
            await CloudCredentialStore.shared.store(ownerID: record.id.uuidString, kind: "access_token", value: token)
        }
    }

    // MARK: - Persistence

    private func loadLocal() {
        guard let data = UserDefaults.standard.data(forKey: Self.storageKey),
              let decoded = try? JSONDecoder().decode([AccountRecord].self, from: data) else { return }
        accounts = decoded
    }

    private func persist() {
        switch AppDataModeStore.shared.mode {
        case .local:
            persistLocal()
        case .cloud:
            persistLocal()
            Task { [snapshot = accounts] in
                await persistCloud(snapshot: snapshot)
            }
        }
    }

    private func persistLocal() {
        guard let data = try? JSONEncoder().encode(accounts) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }

    private func registerObservers() {
        let center = NotificationCenter.default
        observerTokens.append(
            center.addObserver(forName: .gideonDataModeChanged, object: nil, queue: .main) { [weak self] _ in
                guard let self else { return }
                Task { await self.reloadFromCurrentMode() }
            }
        )
        observerTokens.append(
            center.addObserver(forName: .gideonSessionChanged, object: nil, queue: .main) { [weak self] _ in
                guard let self else { return }
                Task { await self.reloadFromCurrentMode() }
            }
        )
    }

    func reloadFromCurrentMode() async {
        loadLocal()
        switch AppDataModeStore.shared.mode {
        case .local:
            loadLocal()
        case .cloud:
            await loadCloud()
        }
    }

    private func loadCloud() async {
        guard let userID = AppSessionStore.shared.currentUserID,
              let token = AppSessionStore.shared.currentAccessToken,
              let url = URL(string: "\(AppSessionStore.supabaseRESTURL)/accounts?user_id=eq.\(userID)&select=*&order=added_at.desc") else {
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
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return
            }

            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let rows = try decoder.decode([SupabaseAccountDTO].self, from: data)
            let cloudAccounts = rows.compactMap { $0.toRecord() }

            accounts = cloudAccounts
            persistLocal()
            await CloudCredentialStore.shared.reconcile(
                cloudAccounts.flatMap { account in
                    [
                        CloudCredentialBinding(ownerID: account.id.uuidString, kind: "access_token", keychainKey: account.keychainKey),
                        CloudCredentialBinding(ownerID: account.id.uuidString, kind: "refresh_token", keychainKey: account.refreshTokenKey)
                    ]
                }
            )
        } catch {
            // Keep local cache if cloud fetch fails.
        }
    }

    private func persistCloud(snapshot: [AccountRecord]) async {
        guard let userID = AppSessionStore.shared.currentUserID,
              let token = AppSessionStore.shared.currentAccessToken,
              !snapshot.isEmpty,
              let insertURL = URL(string: "\(AppSessionStore.supabaseRESTURL)/accounts?on_conflict=user_id,id") else {
            return
        }

        do {
            let payload = snapshot.map { SupabaseAccountDTO(record: $0, userID: userID) }
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

            let (_, response) = try await URLSession.shared.data(for: insertRequest)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else {
                print("[Gideon] account cloud insert failed for user \(userID)")
                return
            }
        } catch {
            print("[Gideon] account cloud sync error: \(error.localizedDescription)")
        }
    }

    private func deleteCloud(id: UUID) async {
        guard AppDataModeStore.shared.mode == .cloud,
              let userID = AppSessionStore.shared.currentUserID,
              let token = AppSessionStore.shared.currentAccessToken,
              let url = URL(string: "\(AppSessionStore.supabaseRESTURL)/accounts?user_id=eq.\(userID)&id=eq.\(id.uuidString)") else {
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.timeoutInterval = 30
        request.setValue(AppSessionStore.supabasePublishableKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        _ = try? await URLSession.shared.data(for: request)
    }
}

private struct SupabaseAccountDTO: Codable {
    let id: UUID
    let userID: String
    let name: String
    let service: String
    let authType: String
    let baseURL: String
    let notes: String
    let addedAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case userID = "user_id"
        case name
        case service
        case authType = "auth_type"
        case baseURL = "base_url"
        case notes
        case addedAt = "added_at"
    }

    init(record: AccountRecord, userID: String) {
        self.id = record.id
        self.userID = userID
        self.name = record.name
        self.service = record.service
        self.authType = record.authType.rawValue
        self.baseURL = record.baseURL
        self.notes = record.notes
        self.addedAt = record.addedAt
    }

    func toRecord() -> AccountRecord? {
        guard let auth = AccountRecord.AuthType(rawValue: authType) else {
            return nil
        }
        return AccountRecord(
            id: id,
            name: name,
            service: service,
            authType: auth,
            baseURL: baseURL,
            notes: notes,
            addedAt: addedAt
        )
    }
}
