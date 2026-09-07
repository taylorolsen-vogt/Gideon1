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
    @MainActor var keychainKey: String { SessionScope.current.key("gideon.account.\(id.uuidString)") }
    @MainActor var refreshTokenKey: String { SessionScope.current.key("gideon.account.\(id.uuidString).refreshToken") }
}

@MainActor
final class AccountStore: ObservableObject {
    static let shared = AccountStore()

    @Published private(set) var accounts: [AccountRecord] = []
    private var observerTokens: [NSObjectProtocol] = []
    private var loadedScope: SessionScope?

    private static let storageKey = "gideon.accounts.v1"

    private init() {
        loadLocal()
        registerObservers()
        let scope = SessionScope.current
        Task { await reloadFromCurrentMode(expectedScope: scope) }
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
        if loadedScope?.isCurrent != true { loadLocal() }
        let scope = SessionScope.current
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
            guard scope.isCurrent else { return }
            await CloudCredentialStore.shared.store(ownerID: record.id.uuidString, kind: "access_token", value: apiKey, expectedScope: scope)
            guard scope.isCurrent else { return }
            await CloudCredentialStore.shared.store(ownerID: record.id.uuidString, kind: "refresh_token", value: refreshToken, expectedScope: scope)
        }
        return record
    }

    func remove(id: UUID) {
        let scope = SessionScope.current
        guard loadedScope?.isCurrent == true,
              let record = accounts.first(where: { $0.id == id }) else { return }
        try? SecureKeyStore.shared.delete(key: record.keychainKey)
        try? SecureKeyStore.shared.delete(key: record.refreshTokenKey)
        accounts.removeAll { $0.id == id }
        persist()
        Task {
            guard scope.isCurrent else { return }
            await deleteCloud(id: id, scope: scope)
            guard scope.isCurrent else { return }
            await CloudCredentialStore.shared.remove(ownerID: id.uuidString, kind: "access_token", expectedScope: scope)
            guard scope.isCurrent else { return }
            await CloudCredentialStore.shared.remove(ownerID: id.uuidString, kind: "refresh_token", expectedScope: scope)
        }
    }

    /// Reads the stored API key / token for an account from Keychain.
    func apiKey(for record: AccountRecord, expectedScope: SessionScope? = nil) -> String? {
        guard (expectedScope ?? .current).isCurrent,
              loadedScope?.isCurrent == true, accounts.contains(where: { $0.id == record.id }) else { return nil }
        return try? SecureKeyStore.shared.read(key: record.keychainKey)
    }

    func refreshToken(for record: AccountRecord, expectedScope: SessionScope? = nil) -> String? {
        guard (expectedScope ?? .current).isCurrent,
              loadedScope?.isCurrent == true, accounts.contains(where: { $0.id == record.id }) else { return nil }
        return try? SecureKeyStore.shared.read(key: record.refreshTokenKey)
    }

    func updateAccessToken(_ token: String, for record: AccountRecord, expectedScope: SessionScope? = nil) {
        let scope = expectedScope ?? .current
        guard scope.isCurrent, loadedScope?.isCurrent == true,
              accounts.contains(where: { $0.id == record.id }) else { return }
        try? SecureKeyStore.shared.write(key: record.keychainKey, value: token)
        Task {
            guard scope.isCurrent else { return }
            await CloudCredentialStore.shared.store(ownerID: record.id.uuidString, kind: "access_token", value: token, expectedScope: scope)
        }
    }

    // MARK: - Persistence

    private func loadLocal() {
        accounts = []
        loadedScope = .current
        guard let data = ScopedDefaults.standard.data(forKey: Self.storageKey),
              let decoded = try? JSONDecoder().decode([AccountRecord].self, from: data) else { return }
        accounts = decoded
    }

    private func persist() {
        guard loadedScope?.isCurrent == true else { return }
        let scope = SessionScope.current
        persistLocal()
        if scope.canSyncCloud {
            Task { [snapshot = accounts] in
                guard scope.isCurrent else { return }
                await persistCloud(snapshot: snapshot, scope: scope)
            }
        }
    }

    private func persistLocal() {
        guard loadedScope?.isCurrent == true, let data = try? JSONEncoder().encode(accounts) else { return }
        ScopedDefaults.standard.set(data, forKey: Self.storageKey)
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
            guard scope.isCurrent else { return }
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return
            }

            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let rows = try decoder.decode([SupabaseAccountDTO].self, from: data)
            let cloudAccounts = rows.filter { $0.userID.lowercased() == userID.lowercased() }.compactMap { $0.toRecord() }

            accounts = cloudAccounts
            persistLocal()
            await CloudCredentialStore.shared.reconcile(
                cloudAccounts.flatMap { account in
                    [
                        CloudCredentialBinding(ownerID: account.id.uuidString, kind: "access_token", keychainKey: account.keychainKey),
                        CloudCredentialBinding(ownerID: account.id.uuidString, kind: "refresh_token", keychainKey: account.refreshTokenKey)
                    ]
                }, expectedScope: scope
            )
            guard scope.isCurrent else { return }
        } catch {
            // Keep local cache if cloud fetch fails.
        }
    }

    private func persistCloud(snapshot: [AccountRecord], scope: SessionScope) async {
        guard scope.isCurrent, scope.canSyncCloud,
              let userID = scope.userID,
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
            guard scope.isCurrent else { return }
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else {
                print("[Gideon] account cloud insert failed for user \(userID)")
                return
            }
        } catch {
            print("[Gideon] account cloud sync error: \(error.localizedDescription)")
        }
    }

    private func deleteCloud(id: UUID, scope: SessionScope) async {
        guard scope.isCurrent, scope.canSyncCloud,
              let userID = scope.userID,
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
        guard scope.isCurrent else { return }
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
