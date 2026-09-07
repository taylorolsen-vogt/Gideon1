import Foundation

struct CloudCredentialBinding: Sendable {
    let ownerID: String
    let kind: String
    let keychainKey: String
}

@MainActor
final class CloudCredentialStore {
    static let shared = CloudCredentialStore()

    private init() {}

    func reconcile(_ bindings: [CloudCredentialBinding], expectedScope: SessionScope? = nil) async {
        let scope = expectedScope ?? .current
        guard scope.isCurrent, scope.canSyncCloud, !bindings.isEmpty else { return }
        // Never read or overwrite legacy/unowned Keychain entries, even if a caller
        // supplies an old binding. Only this user's already-scoped secrets may backfill.
        let bindings = bindings.filter { $0.keychainKey.hasPrefix(scope.key("")) }
        guard !bindings.isEmpty,
              let remoteSecrets = await fetchSecrets(scope: scope), scope.isCurrent else {
            return
        }

        let knownBindings = Dictionary(bindings.map {
            (Self.lookupKey(ownerID: $0.ownerID, kind: $0.kind), $0)
        }, uniquingKeysWith: { first, _ in first })

        for secret in remoteSecrets {
            guard scope.isCurrent else { return }
            let lookupKey = Self.lookupKey(ownerID: secret.ownerID, kind: secret.kind)
            guard let binding = knownBindings[lookupKey], !secret.value.isEmpty else { continue }
            try? SecureKeyStore.shared.write(key: binding.keychainKey, value: secret.value)
        }

        let remoteKeys = Set(remoteSecrets.map { Self.lookupKey(ownerID: $0.ownerID, kind: $0.kind) })
        for binding in bindings where !remoteKeys.contains(Self.lookupKey(ownerID: binding.ownerID, kind: binding.kind)) {
            guard scope.isCurrent else { return }
            guard let localValue = try? SecureKeyStore.shared.read(key: binding.keychainKey),
                  !localValue.isEmpty else {
                continue
            }
            await store(ownerID: binding.ownerID, kind: binding.kind, value: localValue, expectedScope: scope)
            guard scope.isCurrent else { return }
        }
    }

    func store(ownerID: String, kind: String, value: String, expectedScope: SessionScope? = nil) async {
        let scope = expectedScope ?? .current
        guard scope.isCurrent, scope.canSyncCloud,
              !ownerID.isEmpty,
              !kind.isEmpty,
              !value.isEmpty,
              let request = makeRPCRequest(
                function: "gideon_upsert_credential_secret",
                body: ["p_owner_id": ownerID, "p_secret_kind": kind, "p_secret_value": value], scope: scope
              ) else {
            return
        }

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard scope.isCurrent else { return }
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return
            }
        } catch {
            // Keychain remains the local source of truth until cloud sync is available.
        }
    }

    func remove(ownerID: String, kind: String, expectedScope: SessionScope? = nil) async {
        let scope = expectedScope ?? .current
        guard scope.isCurrent, scope.canSyncCloud,
              let request = makeRPCRequest(
                function: "gideon_delete_credential_secret",
                body: ["p_owner_id": ownerID, "p_secret_kind": kind], scope: scope
              ) else {
            return
        }
        _ = try? await URLSession.shared.data(for: request)
        guard scope.isCurrent else { return }
    }

    private func fetchSecrets(scope: SessionScope) async -> [RemoteCredentialSecret]? {
        guard scope.isCurrent, scope.canSyncCloud,
              let request = makeRPCRequest(function: "gideon_get_credential_secrets", body: [:], scope: scope) else {
            return nil
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard scope.isCurrent else { return nil }
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return nil
            }
            return try JSONDecoder().decode([RemoteCredentialSecret].self, from: data)
        } catch {
            return nil
        }
    }

    private func makeRPCRequest(function: String, body: [String: String], scope: SessionScope) -> URLRequest? {
        // RPC ownership is derived server-side from this generation's bearer token.
        guard scope.isCurrent, scope.canSyncCloud,
              let token = AppSessionStore.shared.currentAccessToken,
              let url = URL(string: "\(AppSessionStore.supabaseRESTURL)/rpc/\(function)"),
              let payload = try? JSONSerialization.data(withJSONObject: body) else {
            return nil
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue(AppSessionStore.supabasePublishableKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = payload
        return request
    }

    private static func lookupKey(ownerID: String, kind: String) -> String {
        "\(ownerID.lowercased())|\(kind.lowercased())"
    }
}

private struct RemoteCredentialSecret: Decodable {
    let ownerID: String
    let kind: String
    let value: String

    enum CodingKeys: String, CodingKey {
        case ownerID = "owner_id"
        case kind = "secret_kind"
        case value = "secret_value"
    }
}
