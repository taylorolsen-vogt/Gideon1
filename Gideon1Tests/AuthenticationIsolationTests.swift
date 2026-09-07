import Foundation
import XCTest
@testable import Gideon1

/// Hosted, serial MainActor tests of the production auth methods and JSON decoder.
/// Requires the Debug --isolation-tests host bypass. No shared auth instance,
/// real token keys, standard defaults, default notifications, or live HTTP.
@MainActor
final class AuthenticationIsolationTests: XCTestCase {
    func testLogoutRejectsDelayedLoginSuccess() async throws {
        try await assertLogoutRejectsSuccess(.login)
    }

    func testLogoutRejectsDelayedSignupSuccess() async throws {
        try await assertLogoutRejectsSuccess(.signup)
    }

    func testLogoutRejectsDelayedRecoveryNotice() async throws {
        try await assertLogoutRejectsSuccess(.recover)
    }

    private func assertLogoutRejectsSuccess(_ action: Action) async throws {
        let fixture = Fixture()
        defer { fixture.cleanup() }
        let (task, reply) = fixture.start(action)
        try await reply.waitUntilStarted()
        XCTAssertTrue(fixture.store.isAuthenticating)
        fixture.store.logout()
        let signedOut = SessionScope.current
        XCTAssertFalse(fixture.store.isAuthenticating)
        XCTAssertEqual(fixture.events.count, 1)

        reply.succeed(userID: fixture.userA)
        await task.value

        fixture.assertNoAuthentication()
        XCTAssertEqual(SessionScope.current, signedOut)
        XCTAssertEqual(fixture.events.count, 1, "Stale success must not publish a session change")
        XCTAssertFalse(fixture.store.isAuthenticating)
    }

    func testDuplicateAndCrossMethodSubmitsAreSingleFlightBeforeValidation() async throws {
        for action in Action.allCases {
            let fixture = Fixture()
            defer { fixture.cleanup() }
            let (task, reply) = fixture.start(action)
            try await reply.waitUntilStarted()
            fixture.store.authError = "Keep existing error"
            fixture.store.authNotice = "Keep existing notice"

            // Includes repeated keyboard submits, switching auth modes, and
            // invalid input: none may mutate UI state or issue another request.
            for duplicate in Action.allCases {
                await duplicate.run(fixture.store, email: fixture.email)
                await duplicate.run(fixture.store, email: "", password: "")
            }
            XCTAssertEqual(fixture.network.requestCount, 1)
            XCTAssertEqual(fixture.store.authError, "Keep existing error")
            XCTAssertEqual(fixture.store.authNotice, "Keep existing notice")
            XCTAssertTrue(fixture.store.isAuthenticating)
            let request = try XCTUnwrap(fixture.network.requests.first)
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, action.path)
            if action == .login {
                XCTAssertEqual(request.url?.query, "grant_type=password")
            }
            fixture.store.authError = ""
            fixture.store.authNotice = ""
            reply.succeed(userID: fixture.userA)
            await task.value

            XCTAssertFalse(fixture.store.isAuthenticating)
            if action == .recover {
                XCTAssertFalse(fixture.store.authNotice.isEmpty)
                XCTAssertNil(fixture.store.currentAccessToken)
                XCTAssertFalse(fixture.store.isAuthenticated)
                XCTAssertEqual(fixture.events.count, 0)
            } else {
                try fixture.assertAuthenticated(as: fixture.userA)
                XCTAssertEqual(fixture.events.count, 1)
            }
        }
    }

    func testOldCompletionCannotClearOrOverwriteNewOperation() async throws {
        for staleFailure in [false, true] {
            let fixture = Fixture()
            defer { fixture.cleanup() }
            let (oldTask, oldReply) = fixture.start(.login)
            try await oldReply.waitUntilStarted()
            fixture.store.logout()
            let (newTask, newReply) = fixture.start(.signup)
            try await newReply.waitUntilStarted()

            if staleFailure { oldReply.fail() }
            else { oldReply.succeed(userID: fixture.userA) }
            await oldTask.value
            fixture.assertNoAuthentication()
            XCTAssertTrue(fixture.store.isAuthenticating, "Old defer must not clear the new operation")
            XCTAssertEqual(fixture.events.count, 1)

            newReply.succeed(userID: fixture.userB)
            await newTask.value
            try fixture.assertAuthenticated(as: fixture.userB)
            XCTAssertFalse(fixture.store.isAuthenticating)
            XCTAssertEqual(fixture.events.count, 2)
        }
    }

    func testOldSuccessCannotOverwriteCompletedNewLogin() async throws {
        let fixture = Fixture()
        defer { fixture.cleanup() }
        let (oldTask, oldReply) = fixture.start(.signup)
        try await oldReply.waitUntilStarted()
        fixture.store.logout()
        let (newTask, newReply) = fixture.start(.login)
        try await newReply.waitUntilStarted()
        newReply.succeed(userID: fixture.userB)
        await newTask.value
        let authenticatedScope = SessionScope.current

        oldReply.succeed(userID: fixture.userA)
        await oldTask.value
        try fixture.assertAuthenticated(as: fixture.userB)
        XCTAssertEqual(SessionScope.current, authenticatedScope)
        XCTAssertEqual(fixture.events.count, 2)
    }

    func testScopeChangesRejectSuccessWithoutLogout() async throws {
        for action in Action.allCases {
            for transition in 0..<3 {
                let fixture = Fixture()
                defer { fixture.cleanup() }
                let (task, reply) = fixture.start(action)
                try await reply.waitUntilStarted()
                // Same user/new generation, different user, or changed mode.
                SessionIsolation.activate(
                    userID: transition == 1 ? fixture.userB : fixture.userA,
                    mode: transition == 2 ? "cloud" : "local"
                )
                let changedScope = SessionScope.current
                reply.succeed(userID: fixture.userA)
                await task.value
                fixture.assertNoAuthentication()
                XCTAssertFalse(fixture.store.isAuthenticating)
                XCTAssertEqual(SessionScope.current, changedScope)
                XCTAssertEqual(fixture.events.count, 0)
            }
        }
    }

    func testStaleTransportAndHTTPFailuresDoNotPublishErrors() async throws {
        for action in Action.allCases {
            for transportFailure in [false, true] {
                let fixture = Fixture()
                defer { fixture.cleanup() }
                let (task, reply) = fixture.start(action)
                try await reply.waitUntilStarted()
                fixture.store.logout()
                if transportFailure { reply.fail() }
                else { reply.respond(status: 400, data: Data(#"{"message":"Synthetic rejection"}"#.utf8)) }
                await task.value
                fixture.assertNoAuthentication()
                XCTAssertFalse(fixture.store.isAuthenticating)
                XCTAssertEqual(fixture.events.count, 1)
            }
        }
    }

    func testCancellationDoesNotPublishErrorsOrCredentials() async throws {
        for action in Action.allCases {
            let fixture = Fixture()
            defer { fixture.cleanup() }
            let (task, reply) = fixture.start(action)
            try await reply.waitUntilStarted()
            let scope = SessionScope.current
            task.cancel()
            await task.value
            fixture.assertNoAuthentication()
            XCTAssertFalse(fixture.store.isAuthenticating)
            XCTAssertEqual(SessionScope.current, scope)
            XCTAssertEqual(fixture.events.count, 0)

            // A cancelled task must also be rejected before starting a request.
            let cancelled = Task { @MainActor in
                withUnsafeCurrentTask { $0?.cancel() }
                await action.run(fixture.store, email: fixture.email)
            }
            await cancelled.value
            XCTAssertEqual(fixture.network.requestCount, 1)
            fixture.assertNoAuthentication()
        }
    }

    private enum Action: CaseIterable {
        case login, signup, recover

        var path: String {
            switch self {
            case .login: "/auth/v1/token"
            case .signup: "/auth/v1/signup"
            case .recover: "/auth/v1/recover"
            }
        }

        @MainActor func run(_ store: AppSessionStore, email: String, password: String = "synthetic-password") async {
            switch self {
            case .login: await store.login(email: email, password: password)
            case .signup: await store.signUp(email: email, password: password)
            case .recover: await store.recoverPassword(email: email)
            }
        }
    }

    @MainActor
    private final class Fixture {
        let originalScope = SessionScope.current
        let userA = UUID().uuidString.lowercased()
        let userB = UUID().uuidString.lowercased()
        let namespace = "gideon.tests.auth.\(UUID().uuidString)"
        let defaults: UserDefaults
        let session: URLSession
        let store: AppSessionStore
        let network = AuthenticationNetwork()
        let events = AuthenticationEventCounter()
        let notifications = NotificationCenter()
        private var observer: NSObjectProtocol?
        private var tasks: [Task<Void, Never>] = []

        var email: String { "\(userA)@example.invalid" }
        var tokenKey: String { "\(namespace).gideon.session.token" }
        var userKey: String { "\(namespace).gideon.session.user.v1" }

        init() {
            defaults = UserDefaults(suiteName: namespace)!
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpCookieStorage = nil
            configuration.httpShouldSetCookies = false
            configuration.urlCredentialStorage = nil
            configuration.urlCache = nil
            configuration.protocolClasses = [AuthenticationURLProtocol.self]
            configuration.httpAdditionalHeaders = [AuthenticationURLProtocol.fixtureHeader: namespace]
            session = URLSession(configuration: configuration)
            store = AppSessionStore(session: session, defaults: defaults, storageNamespace: namespace,
                                    notificationCenter: notifications)
            AuthenticationURLProtocol.registry.install(network, for: namespace)
            SessionIsolation.activate(userID: userA, mode: "local")
            let events = events
            observer = notifications.addObserver(forName: .gideonSessionChanged, object: nil, queue: nil) { _ in
                events.increment()
            }
        }

        func start(_ action: Action) -> (Task<Void, Never>, AuthenticationReply) {
            let reply = network.enqueue()
            let task = Task { await action.run(store, email: email) }
            tasks.append(task)
            return (task, reply)
        }

        func assertNoAuthentication(file: StaticString = #filePath, line: UInt = #line) {
            XCTAssertNil(store.currentUser, file: file, line: line)
            XCTAssertFalse(store.isAuthenticated, file: file, line: line)
            XCTAssertNil(store.currentAccessToken, file: file, line: line)
            XCTAssertNil(defaults.object(forKey: userKey), file: file, line: line)
            XCTAssertEqual(store.authError, "", file: file, line: line)
            XCTAssertEqual(store.authNotice, "", file: file, line: line)
        }

        func assertAuthenticated(as userID: String, file: StaticString = #filePath, line: UInt = #line) throws {
            XCTAssertTrue(store.isAuthenticated, file: file, line: line)
            XCTAssertEqual(store.currentUserID, userID, file: file, line: line)
            XCTAssertEqual(store.currentAccessToken, "synthetic-token-\(userID)", file: file, line: line)
            let data = try XCTUnwrap(defaults.data(forKey: userKey), file: file, line: line)
            XCTAssertEqual(try JSONDecoder().decode(SessionUser.self, from: data).id, userID, file: file, line: line)
            XCTAssertEqual(SessionScope.current.userID, userID, file: file, line: line)
            XCTAssertEqual(SessionScope.current.mode, "local", file: file, line: line)
            XCTAssertEqual(store.authError, "", file: file, line: line)
        }

        func cleanup() {
            tasks.forEach { $0.cancel() }
            session.invalidateAndCancel()
            AuthenticationURLProtocol.registry.remove(namespace)
            if let observer { notifications.removeObserver(observer) }
            // Restore identity/mode with a NEW generation; never revive stale
            // work or broadcast a real-user reload to the disposable host.
            SessionIsolation.activate(userID: originalScope.userID, mode: originalScope.mode)
            XCTAssertNoThrow(try SecureKeyStore.shared.delete(key: tokenKey))
            defaults.removePersistentDomain(forName: namespace)
        }
    }
}

/// Lock-protected helpers are used by URLSession callbacks off MainActor.
private final class AuthenticationEventCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    func increment() { lock.lock(); defer { lock.unlock() }; value += 1 }
}

private final class AuthenticationReply: @unchecked Sendable {
    let started = XCTestExpectation(description: "Production auth request intercepted")
    private let lock = NSLock()
    private var loading: AuthenticationURLProtocol?

    func attach(_ loading: AuthenticationURLProtocol) {
        lock.lock()
        self.loading = loading
        lock.unlock()
        started.fulfill()
    }

    @MainActor func waitUntilStarted() async throws {
        let result = await XCTWaiter.fulfillment(of: [started], timeout: 3)
        XCTAssertEqual(result, .completed)
        if result != .completed { throw URLError(.timedOut) }
    }

    private func take() -> AuthenticationURLProtocol? {
        lock.lock(); defer { lock.unlock() }
        defer { loading = nil }
        return loading
    }

    func succeed(userID: String) {
        let data = Data("""
        {"access_token":"synthetic-token-\(userID)","user":{"id":"\(userID)","email":"\(userID)@example.invalid","name":"Synthetic Test"}}
        """.utf8)
        respond(status: 200, data: data)
    }

    func respond(status: Int, data: Data) { take()?.respond(status: status, data: data) }
    func fail() { take()?.fail() }
}

private final class AuthenticationNetwork: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [AuthenticationReply] = []
    private var captured: [URLRequest] = []
    var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return captured }
    var requestCount: Int { requests.count }

    func enqueue() -> AuthenticationReply {
        lock.lock(); defer { lock.unlock() }
        let reply = AuthenticationReply()
        pending.append(reply)
        return reply
    }

    func receive(_ loading: AuthenticationURLProtocol) {
        lock.lock()
        captured.append(loading.request)
        let reply = pending.isEmpty ? nil : pending.removeFirst()
        lock.unlock()
        // Unexpected duplicates fail immediately, never hang or reach the wire.
        guard let reply else { loading.fail(); return }
        reply.attach(loading)
    }
}

private final class AuthenticationURLProtocol: URLProtocol, @unchecked Sendable {
    static let fixtureHeader = "X-Gideon-Auth-Test"
    static let registry = Registry()
    private let completionLock = NSRecursiveLock()
    private var finished = false

    final class Registry: @unchecked Sendable {
        private let lock = NSLock()
        private var networks: [String: AuthenticationNetwork] = [:]
        func install(_ network: AuthenticationNetwork, for key: String) {
            lock.lock(); defer { lock.unlock() }; networks[key] = network
        }
        func remove(_ key: String) {
            lock.lock(); defer { lock.unlock() }; networks.removeValue(forKey: key)
        }
        func network(for key: String) -> AuthenticationNetwork? {
            lock.lock(); defer { lock.unlock() }; return networks[key]
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let key = request.value(forHTTPHeaderField: Self.fixtureHeader),
              let network = Self.registry.network(for: key) else {
            fail()
            return
        }
        network.receive(self)
    }

    override func stopLoading() {
        completionLock.lock(); defer { completionLock.unlock() }
        finished = true
    }

    func respond(status: Int, data: Data) {
        completionLock.lock(); defer { completionLock.unlock() }
        guard !finished else { return }
        finished = true
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    func fail() {
        completionLock.lock(); defer { completionLock.unlock() }
        guard !finished else { return }
        finished = true
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }
}