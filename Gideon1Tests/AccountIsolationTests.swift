import Foundation
import XCTest
@testable import Gideon1

/// Hosted integration tests: all assertions exercise production stores, not stubs.
/// Keep each test synchronous on MainActor: notification resets are synchronous,
/// and queued reload/discovery/warmup tasks must become stale before yielding.
/// The host still needs a DEBUG --isolation-tests boot bypass to prevent its own
/// pre-test session restoration/network activity. The scheme supplies the flag;
/// these tests cannot suppress work already started by the application host.
@MainActor
final class AccountIsolationTests: XCTestCase {
    func testProductionStoresRestoreAAfterVisitingEmptyThenPopulatedB() throws {
        let fixture = Fixture()
        defer { fixture.cleanup() }
        let a = try fixture.seed(label: "A")
        let cacheA = fixture.snapshot()
        fixture.messages.message = "A unsent draft"

        let bScope = fixture.activate(fixture.userB)
        fixture.assertEmpty()
        XCTAssertFalse(a.scope.isCurrent)
        XCTAssertNil(AccountStore.shared.apiKey(for: a.account))
        XCTAssertNil(AccountStore.shared.refreshToken(for: a.account))
        XCTAssertNotEqual(a.accessKey, a.account.keychainKey)
        XCTAssertNotEqual(a.refreshKey, a.account.refreshTokenKey)
        XCTAssertEqual(a.account.keychainKey, bScope.key("gideon.account.\(a.account.id.uuidString)"))
        XCTAssertNil(try SecureKeyStore.shared.read(key: a.account.keychainKey))
        XCTAssertNil(try SecureKeyStore.shared.read(key: a.account.refreshTokenKey))
        XCTAssertEqual(try SecureKeyStore.shared.read(key: a.accessKey), a.accessToken)

        let b = try fixture.seed(label: "B")
        let cacheB = fixture.snapshot()
        fixture.activate(fixture.userA)
        fixture.assertRestored(a)
        XCTAssertEqual(fixture.snapshot(), cacheA)
        XCTAssertFalse(a.scope.isCurrent, "Returning to A must not revive old work")
        XCTAssertFalse(b.scope.isCurrent)
        XCTAssertNil(AccountStore.shared.apiKey(for: a.account, expectedScope: a.scope))
        XCTAssertNil(AccountStore.shared.apiKey(for: b.account))
        AccountStore.shared.updateAccessToken("synthetic-stale-write", for: a.account, expectedScope: a.scope)
        XCTAssertEqual(AccountStore.shared.apiKey(for: a.account), a.accessToken)

        fixture.activate(fixture.userB)
        fixture.assertRestored(b)
        XCTAssertEqual(fixture.snapshot(), cacheB)
    }

    func testSameUserNewGenerationReloadsStoresAndRejectsOldCredentials() throws {
        let fixture = Fixture()
        defer { fixture.cleanup() }
        let a = try fixture.seed(label: "A")
        let cacheA = fixture.snapshot()
        fixture.messages.message = "Discard this draft on reauthentication"
        fixture.messages.isGenerating = true
        fixture.messages.isPreparingModel = true

        let next = fixture.activate(fixture.userA)
        XCTAssertEqual(next.userID, a.scope.userID)
        XCTAssertNotEqual(next.generation, a.scope.generation)
        XCTAssertFalse(a.scope.isCurrent)
        fixture.assertRestored(a)
        XCTAssertEqual(fixture.snapshot(), cacheA)
        XCTAssertEqual(a.account.keychainKey, a.accessKey)
        XCTAssertEqual(a.account.refreshTokenKey, a.refreshKey)
        XCTAssertNil(AccountStore.shared.apiKey(for: a.account, expectedScope: a.scope))
        XCTAssertNil(AccountStore.shared.refreshToken(for: a.account, expectedScope: a.scope))
        AccountStore.shared.updateAccessToken("synthetic-rejected-token", for: a.account, expectedScope: a.scope)
        XCTAssertEqual(AccountStore.shared.apiKey(for: a.account, expectedScope: next), a.accessToken)
        AccountStore.shared.updateAccessToken("synthetic-current-token", for: a.account, expectedScope: next)
        XCTAssertEqual(AccountStore.shared.apiKey(for: a.account), "synthetic-current-token")
    }

    func testMissingBCachesResetProductionStoresWithoutChangingA() throws {
        try assertUnavailableBCache(corrupt: false)
    }

    func testCorruptBCachesResetProductionStoresWithoutChangingA() throws {
        try assertUnavailableBCache(corrupt: true)
    }

    func testSessionChangesNeverDeleteSeededState() throws {
        let fixture = Fixture()
        defer { fixture.cleanup() }
        let a = try fixture.seed(label: "A")
        let before = fixture.snapshot()

        fixture.activate(fixture.userB)
        fixture.assertEmpty()

        fixture.activate(fixture.userA)
        fixture.assertRestored(a)
        XCTAssertEqual(fixture.snapshot(), before, "Session changes must restore scoped state, not delete it")
        XCTAssertEqual(AppProjectStore.shared.projects.count, 1)
        XCTAssertEqual(AppActivityStore.shared.items.count, 1)
        XCTAssertEqual(GideonModelSelectionStore.shared.apiProviders.count, 1)
    }

    private func assertUnavailableBCache(corrupt: Bool) throws {
        let fixture = Fixture()
        defer { fixture.cleanup() }
        let a = try fixture.seed(label: "A")
        let cacheA = fixture.snapshot()
        fixture.messages.message = "A private draft"
        fixture.messages.isGenerating = true

        // Seed only the randomly allocated B namespace, without changing the
        // active scope; no unscoped/legacy key or real user's cache is touched.
        let bCache = ScopedDefaults(defaults: .standard, scope: fixture.scopeB)
        for key in Fixture.collectionKeys {
            XCTAssertNil(bCache.object(forKey: key))
            if corrupt { bCache.set(Data("{invalid-json".utf8), forKey: key) }
        }
        if corrupt {
            bCache.set("not-a-model", forKey: "gideon.selectedModelID")
            bCache.set("not-a-reasoning-mode", forKey: "gideon.reasoningMode")
            bCache.set("not-a-uuid", forKey: "gideon.chatSessions.selected.v1")
        }
        fixture.activate(fixture.userB)
        fixture.assertEmpty()
        XCTAssertNil(AccountStore.shared.apiKey(for: a.account))
        XCTAssertNil(AccountStore.shared.refreshToken(for: a.account))
        XCTAssertNil(try SecureKeyStore.shared.read(key: a.account.keychainKey))

        // Repeat reset in B too: neither a missing nor malformed cache may
        // inherit the previous owner's in-memory collections or preferences.
        fixture.activate(fixture.userB)
        fixture.assertEmpty()
        fixture.activate(fixture.userA)
        fixture.assertRestored(a)
        XCTAssertEqual(fixture.snapshot(), cacheA)
    }

    @MainActor
    private final class Fixture {
        static let collectionKeys = [
            "gideon.accounts.v1", "gideon.projects.v2", "gideon.activity.v2",
            "gideon.providerConnections.v1", "gideon.apiProviders.v1",
            "gideon.chatSessions.v2"
        ]

        let originalScope: SessionScope
        let userA = UUID().uuidString.lowercased()
        let userB = UUID().uuidString.lowercased()
        let messages: MessagesSessionStore
        private var credentialKeys: Set<String> = []

        var scopeB: SessionScope {
            SessionScope(userID: userB, mode: "local", generation: UUID())
        }

        init() {
            originalScope = .current
            SessionIsolation.activate(userID: userA, mode: "local")
            // Private singleton initializers require using the actual shared
            // instances; force their first access only after scope injection.
            _ = AccountStore.shared
            _ = AppProjectStore.shared
            _ = AppActivityStore.shared
            _ = ProviderConnectionStore.shared
            _ = GideonModelSelectionStore.shared
            NotificationCenter.default.post(name: .gideonSessionChanged, object: nil)
            messages = MessagesSessionStore()
            // init unconditionally enqueues local-model warmup. Revoke its
            // captured generation before MainActor can run that queued task.
            activate(userA)
        }

        @discardableResult
        func activate(_ userID: String) -> SessionScope {
            precondition(userID == userA || userID == userB)
            SessionIsolation.activate(userID: userID, mode: "local")
            let scope = SessionScope.current
            NotificationCenter.default.post(name: .gideonSessionChanged, object: nil)
            XCTAssertEqual(SessionScope.current, scope)
            XCTAssertFalse(scope.canSyncCloud)
            return scope
        }

        struct Seed {
            let scope: SessionScope
            let account: AccountRecord
            let projectID: UUID
            let activityID: UUID
            let providerID: String
            let profileID: UUID
            let modelID: String
            let chatIDs: [UUID]
            let selectedChatID: UUID
            let label: String
            let accessKey: String
            let refreshKey: String
            var accessToken: String { "synthetic-access-\(label)" }
            var refreshToken: String { "synthetic-refresh-\(label)" }
        }

        func seed(label: String) throws -> Seed {
            XCTAssertFalse(SessionScope.current.canSyncCloud)
            // addAPIProvider performs discovery even in local mode. Restore a
            // Codable production profile instead; an empty endpoint also makes
            // discovery return before HTTP if this fixture ever gains a yield.
            let profile = GideonAPIProviderProfile(
                id: UUID(), name: "Isolation \(label)", provider: "Isolation",
                baseURL: "", customModelIdentifiers: ["synthetic-model-\(label)"], createdAt: Date()
            )
            ScopedDefaults.standard.set(try JSONEncoder().encode([profile]), forKey: "gideon.apiProviders.v1")
            activate(try XCTUnwrap(SessionScope.current.userID))
            let models = GideonModelSelectionStore.shared
            let option = try XCTUnwrap(models.options.first { $0.backend == .apiModel })
            models.select(option)
            models.maxNewTokens = label == "A" ? 128 : 256
            models.reasoningMode = label == "A" ? .deep : .quick

            let account = AccountStore.shared.add(
                name: "Isolation \(label)", service: "Isolation", authType: .apiKey,
                baseURL: "", notes: "Synthetic hosted-test account",
                apiKey: "synthetic-access-\(label)", refreshToken: "synthetic-refresh-\(label)"
            )
            credentialKeys.formUnion([account.keychainKey, account.refreshTokenKey])
            AppProjectStore.shared.createProject(name: "Isolation \(label)", detail: "Project \(label)", source: "XCTest")
            let project = try XCTUnwrap(AppProjectStore.shared.projects.first)
            AppActivityStore.shared.add(
                title: "Isolation \(label)", detail: "Activity \(label)", state: .backlog,
                source: "XCTest", assignee: "Synthetic tester", projectID: project.id
            )
            let activity = try XCTUnwrap(AppActivityStore.shared.items.first)
            let providerName = "Isolation \(label)"
            ProviderConnectionStore.shared.markConnected(providerName: providerName, detail: "Synthetic \(label)")
            let provider = ProviderConnectionStore.shared.record(for: providerName)

            // Create/select via production APIs; never send a prompt or infer.
            // Select an older chat so restoration cannot pass by choosing first.
            messages.createNewChat()
            let selectedID = try XCTUnwrap(messages.selectedChatID)
            messages.createNewChat()
            messages.selectChat(id: selectedID)
            // Appending through sendCurrentMessage would invoke inference/tools.
            // Use the production Codable cache for historical content instead.
            var savedChats = messages.chats
            let selectedIndex = try XCTUnwrap(savedChats.firstIndex { $0.id == selectedID })
            savedChats[selectedIndex].messages = [ChatItem(role: .user, text: "History \(label)")]
            ScopedDefaults.standard.set(try JSONEncoder().encode(savedChats), forKey: "gideon.chatSessions.v2")
            activate(try XCTUnwrap(SessionScope.current.userID))
            let result = Seed(
                scope: .current, account: account, projectID: project.id, activityID: activity.id,
                providerID: provider.id, profileID: profile.id, modelID: option.id,
                chatIDs: messages.chats.map(\.id), selectedChatID: selectedID, label: label,
                accessKey: account.keychainKey, refreshKey: account.refreshTokenKey
            )
            assertRestored(result)
            return result
        }

        func assertEmpty(file: StaticString = #filePath, line: UInt = #line) {
            XCTAssertFalse(SessionScope.current.canSyncCloud, file: file, line: line)
            XCTAssertTrue(AccountStore.shared.accounts.isEmpty, file: file, line: line)
            XCTAssertTrue(AppProjectStore.shared.projects.isEmpty, file: file, line: line)
            XCTAssertTrue(AppActivityStore.shared.items.isEmpty, file: file, line: line)
            // Built-in provider placeholders are expected, but no configured state.
            let connections = ProviderConnectionStore.shared
            XCTAssertEqual(connections.connectedCount, 0, file: file, line: line)
            XCTAssertEqual(connections.manualStepCount, 0, file: file, line: line)
            XCTAssertTrue(connections.records.allSatisfy { $0.state == .notConnected && $0.detail == "Not configured" }, file: file, line: line)
            XCTAssertFalse(connections.records.contains { $0.id.hasPrefix("isolation-") }, file: file, line: line)
            let models = GideonModelSelectionStore.shared
            XCTAssertTrue(models.apiProviders.isEmpty, file: file, line: line)
            XCTAssertNotEqual(models.selectedOption.backend, .apiModel, file: file, line: line)
            XCTAssertEqual(models.maxNewTokens, 96, file: file, line: line)
            XCTAssertEqual(models.reasoningMode, .balanced, file: file, line: line)
            // Assert the immediate reset, before async reload creates a blank chat.
            XCTAssertTrue(messages.chats.isEmpty, file: file, line: line)
            XCTAssertNil(messages.selectedChatID, file: file, line: line)
            assertTransientStateCleared(file: file, line: line)
        }

        func assertRestored(_ seed: Seed, file: StaticString = #filePath, line: UInt = #line) {
            XCTAssertFalse(SessionScope.current.canSyncCloud, file: file, line: line)
            XCTAssertEqual(AccountStore.shared.accounts.map(\.id), [seed.account.id], file: file, line: line)
            XCTAssertEqual(AccountStore.shared.apiKey(for: seed.account), seed.accessToken, file: file, line: line)
            XCTAssertEqual(AccountStore.shared.refreshToken(for: seed.account), seed.refreshToken, file: file, line: line)
            XCTAssertEqual(AppProjectStore.shared.projects.map(\.id), [seed.projectID], file: file, line: line)
            XCTAssertEqual(AppProjectStore.shared.projects.first?.detail, "Project \(seed.label)", file: file, line: line)
            XCTAssertEqual(AppActivityStore.shared.items.map(\.id), [seed.activityID], file: file, line: line)
            XCTAssertEqual(AppActivityStore.shared.items.first?.projectID, seed.projectID, file: file, line: line)
            let connections = ProviderConnectionStore.shared
            XCTAssertEqual(connections.records.filter { $0.state == .connected }.map(\.id), [seed.providerID], file: file, line: line)
            XCTAssertEqual(connections.records.first { $0.id == seed.providerID }?.detail, "Synthetic \(seed.label)", file: file, line: line)
            let models = GideonModelSelectionStore.shared
            XCTAssertEqual(models.apiProviders.map(\.id), [seed.profileID], file: file, line: line)
            XCTAssertEqual(models.selectedModelID, seed.modelID, file: file, line: line)
            XCTAssertEqual(models.maxNewTokens, seed.label == "A" ? 128 : 256, file: file, line: line)
            XCTAssertEqual(models.reasoningMode, seed.label == "A" ? .deep : .quick, file: file, line: line)
            XCTAssertEqual(messages.chats.map(\.id), seed.chatIDs, file: file, line: line)
            XCTAssertEqual(messages.selectedChatID, seed.selectedChatID, file: file, line: line)
            XCTAssertEqual(messages.thread.map(\.text), ["History \(seed.label)"], file: file, line: line)
            assertTransientStateCleared(file: file, line: line)
        }

        private func assertTransientStateCleared(file: StaticString, line: UInt) {
            XCTAssertEqual(messages.message, "", file: file, line: line)
            XCTAssertFalse(messages.isGenerating, file: file, line: line)
            XCTAssertFalse(messages.isPreparingModel, file: file, line: line)
            XCTAssertNil(messages.generatingChatID, file: file, line: line)
            XCTAssertNil(messages.reviewingEmail, file: file, line: line)
            XCTAssertNil(messages.pendingEmailForSelectedChat, file: file, line: line)
        }

        func snapshot() -> [String: Data] {
            let prefix = SessionScope.current.key("")
            return UserDefaults.standard.dictionaryRepresentation().reduce(into: [:]) { result, entry in
                guard entry.key.hasPrefix(prefix) else { return }
                // Wrap scalar values so all property-list types can be compared.
                result[entry.key] = try? PropertyListSerialization.data(fromPropertyList: [entry.value], format: .binary, options: 0)
            }
        }

        func cleanup() {
            // Revoke every test task before leaving MainActor. activate is the
            // only production restoration API; it restores user/mode, necessarily
            // with a fresh generation (revoked generations cannot be reinstated).
            SessionIsolation.activate(userID: originalScope.userID, mode: originalScope.mode)
            // Do NOT post a restoration notification: that would start real-user
            // cloud reload/discovery and may migrate/write their local caches.
            // The disposable host exits after testing; auth/mode stores were never
            // changed. Real stores remain fenced until their next session reset.
            for key in credentialKeys {
                XCTAssertNoThrow(try SecureKeyStore.shared.delete(key: key))
            }
            let prefixes = [userA, userB].map {
                SessionScope(userID: $0, mode: "local", generation: UUID()).key("")
            }
            for key in UserDefaults.standard.dictionaryRepresentation().keys
                where prefixes.contains(where: { key.hasPrefix($0) }) {
                UserDefaults.standard.removeObject(forKey: key)
            }
            // Legacy sentinel behavior belongs in the standalone SessionScope
            // suite, not a host with potentially valuable raw gideon.accounts.v1.
            XCTAssertEqual(SessionScope.current.userID, originalScope.userID)
            XCTAssertEqual(SessionScope.current.mode, originalScope.mode)
        }
    }
}