import Foundation

@main
struct SessionScopeTests {
    @MainActor static func main() async {
        let suite = "gideon.tests.scope." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let key = "gideon.accounts.v1"
        defaults.set("preserved legacy data", forKey: key)
        SessionIsolation.activate(userID: "USER-A", mode: "cloud")
        let a = SessionScope.current
        let cacheA = ScopedDefaults(defaults: defaults, scope: a)
        precondition(cacheA.string(forKey: key) == nil, "Must not claim unowned legacy data")
        cacheA.set("A records", forKey: key)
        precondition(a.canSyncCloud && a.isCurrent)
        SessionIsolation.activate(userID: "user-b", mode: "cloud")
        let b = SessionScope.current
        let cacheB = ScopedDefaults(defaults: defaults, scope: b)
        precondition(!a.isCurrent && b.isCurrent)
        precondition(cacheB.string(forKey: key) == nil, "New B must be empty, including offline")
        precondition(a.key("credential") != b.key("credential"))
        cacheB.set("B records", forKey: key)
        SessionIsolation.activate(userID: nil, mode: "cloud")
        let signedOut = SessionScope.current
        precondition(!signedOut.canSyncCloud && !b.isCurrent)
        precondition(ScopedDefaults(defaults: defaults, scope: signedOut).string(forKey: key) == nil)
        SessionIsolation.activate(userID: "user-a", mode: "cloud")
        let returningA = SessionScope.current
        precondition(!a.isCurrent, "A→B→A must not reauthorize old work")
        precondition(a.key(key) == returningA.key(key), "Same owner restores the same cache")
        precondition(ScopedDefaults(defaults: defaults, scope: returningA).string(forKey: key) == "A records")
        precondition(cacheB.string(forKey: key) == "B records")
        SessionIsolation.activate(userID: "user-a", mode: "local")
        let localA = SessionScope.current
        precondition(!returningA.isCurrent && !localA.canSyncCloud)
        precondition(localA.key(key) == returningA.key(key), "Mode changes preserve owner data")
        SessionIsolation.activate(userID: "user-a", mode: "local")
        precondition(!localA.isCurrent, "Same-user re-login revokes old approvals")
        precondition(defaults.string(forKey: key) == "preserved legacy data")
        let current = SessionScope.current
        let cancelled = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            return current.isCurrent
        }
        let cancelledIsCurrent = await cancelled.value
        precondition(!cancelledIsCurrent, "Cancelled work must be rejected")
        print("PASS: owner namespaces, empty/offline B, signed-out separation, A→B→A, mode/re-login invalidation, legacy preservation, cancellation (18 checks)")
    }
}