import Foundation

/// Immutable identity for work started in one login/data-mode generation.
/// Returning to the same user never makes an old in-flight task valid again.
struct SessionScope: Equatable, Sendable {
    let userID: String?
    let mode: String
    let generation: UUID

    @MainActor static var current: SessionScope { SessionIsolation.current }
    @MainActor var isCurrent: Bool { self == Self.current && !Task.isCancelled }
    var canSyncCloud: Bool { userID != nil && mode == "cloud" }

    func key(_ base: String) -> String {
        let owner = userID.map { "user." + Data($0.lowercased().utf8).base64EncodedString() } ?? "signed-out"
        return "gideon.scoped.v1.\(owner).\(base)"
    }
}

@MainActor
enum SessionIsolation {
    private(set) static var current = SessionScope(userID: nil, mode: "cloud", generation: UUID())

    /// Call before publishing an authentication or mode transition.
    static func activate(userID: String?, mode: String) {
        current = SessionScope(userID: userID?.lowercased(), mode: mode, generation: UUID())
    }
}

/// Old unscoped values are deliberately left untouched for recovery, never assigned
/// to whichever user happens to log in first. Cloud restore supplies owned data.
@MainActor
struct ScopedDefaults {
    static var standard: ScopedDefaults { ScopedDefaults(defaults: .standard, scope: .current) }
    let defaults: UserDefaults
    let scope: SessionScope

    func data(forKey key: String) -> Data? { defaults.data(forKey: scope.key(key)) }
    func string(forKey key: String) -> String? { defaults.string(forKey: scope.key(key)) }
    func integer(forKey key: String) -> Int { defaults.integer(forKey: scope.key(key)) }
    func bool(forKey key: String) -> Bool { defaults.bool(forKey: scope.key(key)) }
    func object(forKey key: String) -> Any? { defaults.object(forKey: scope.key(key)) }
    func set(_ value: Any?, forKey key: String) { defaults.set(value, forKey: scope.key(key)) }
    func removeObject(forKey key: String) { defaults.removeObject(forKey: scope.key(key)) }
}