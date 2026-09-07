import Foundation
import Synchronization

// Standalone runner: compile with GideonAgentTools.swift and RemoteGideonRuntime.swift only.
// Store fixtures intentionally mirror the live MainActor interfaces; no UI or real credentials.
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
@MainActor enum SessionIsolation {
    private(set) static var current = SessionScope(userID: nil, mode: "cloud", generation: UUID())
    static func activate(userID: String?, mode: String) {
        current = SessionScope(userID: userID?.lowercased(), mode: mode, generation: UUID())
    }
}

struct HarnessTurn: Sendable {
    enum Role: Sendable { case user, assistant }
    let role: Role
    let text: String
}
struct AccountRecord: Sendable {
    let id: UUID
    var service: String
    var baseURL = ""
    var name = "Test account"
}
@MainActor final class AccountStore {
    static let shared = AccountStore()
    var accounts: [AccountRecord] = []
    var tokens: [UUID: String] = [:]
    var refreshTokens: [UUID: String] = [:]
    func apiKey(for record: AccountRecord, expectedScope: SessionScope? = nil) -> String? {
        guard (expectedScope ?? .current).isCurrent else { return nil }
        return tokens[record.id]
    }
    func refreshToken(for record: AccountRecord, expectedScope: SessionScope? = nil) -> String? {
        guard (expectedScope ?? .current).isCurrent else { return nil }
        return refreshTokens[record.id]
    }
    func updateAccessToken(_ token: String, for record: AccountRecord, expectedScope: SessionScope? = nil) {
        guard (expectedScope ?? .current).isCurrent else { return }
        tokens[record.id] = token
    }
}
enum ProjectStage: String { case active }
struct ProjectRecord {
    let id: UUID
    var name: String
    var detail: String
    var summary: String
    var stage = ProjectStage.active
}
enum ActivityState: String { case completed, blocked }
struct ActivityRecord {
    let id = UUID()
    var title: String
    var detail: String
    var state: ActivityState
    var projectID: UUID?
}
@MainActor final class AppProjectStore {
    static let shared = AppProjectStore()
    var projects: [ProjectRecord] = []
}
@MainActor final class AppActivityStore {
    static let shared = AppActivityStore()
    var items: [ActivityRecord] = []
    func add(title: String, detail: String, state: ActivityState) {
        items.append(ActivityRecord(title: title, detail: detail, state: state))
    }
}
@MainActor final class GoogleOAuthService {
    static let shared = GoogleOAuthService()
    static let clientID = "test-client"
}

private struct Failure: Error { let message: String }
private let assertions = Mutex(0)
private func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    assertions.withLock { $0 += 1 }
    if !condition() { throw Failure(message: message) }
}
private func rejects(_ action: () throws -> Void) throws {
    assertions.withLock { $0 += 1 }
    do { try action() } catch { return }
    throw Failure(message: "Expected rejection")
}
private func call(_ name: String, _ args: [String: String] = [:]) -> RemoteToolCall {
    // Model arguments are not tool output: do not apply the output-clipping codec here.
    RemoteToolCall(id: "call-id", name: name, argumentsJSON: String(decoding: try! JSONEncoder().encode(args), as: UTF8.self))
}
private func data(_ object: Any) throws -> Data { try JSONSerialization.data(withJSONObject: object) }
private func object(_ string: String) throws -> [String: Any] {
    guard let value = try JSONSerialization.jsonObject(with: Data(string.utf8)) as? [String: Any] else { throw Failure(message: "Expected JSON object") }
    return value
}
private func base64url(_ text: String) -> String {
    Data(text.utf8).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
}
private actor Network {
    var requests: [URLRequest] = []
    var replies: [(Data, Int)] = []
    var failures: [Int: URLError.Code] = [:]
    var hook: (@Sendable (URLRequest) async -> Void)?
    func install(_ replies: [(Data, Int)]) { self.replies = replies; requests = []; failures = [:]; hook = nil }
    func fail(at requestNumber: Int, code: URLError.Code) { failures[requestNumber] = code }
    func setHook(_ hook: @escaping @Sendable (URLRequest) async -> Void) { self.hook = hook }
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        try Task.checkCancellation()
        requests.append(request)
        let number = requests.count
        if let hook { await hook(request) }
        if let code = failures[number] { throw URLError(code) }
        guard !replies.isEmpty else { throw Failure(message: "Unexpected request; real network is disabled") }
        return replies.removeFirst()
    }
    var transport: GideonAgentToolTransport { .init { try await self.send($0) } }
}

private final class TestClock: Sendable {
    private let date = Mutex(Date(timeIntervalSince1970: 1_800_000_000))
    func now() -> Date { date.withLock { $0 } }
    func advance(_ seconds: TimeInterval) { date.withLock { $0.addTimeInterval(seconds) } }
}

/// Deterministically hold a network await open without sleeps or scheduling assumptions.
private actor Gate {
    private var entered = false
    private var observers: [CheckedContinuation<Void, Never>] = []
    private var blocked: CheckedContinuation<Void, Never>?
    func pause() async {
        entered = true
        for observer in observers { observer.resume() }
        observers = []
        await withCheckedContinuation { blocked = $0 }
    }
    func waitUntilEntered() async {
        if !entered { await withCheckedContinuation { observers.append($0) } }
    }
    func release() { blocked?.resume(); blocked = nil }
}

@main struct GideonAgentToolsTests {
    static func main() async throws {
        try validators()
        try parsers()
        try await sessions()
        try sendValidatorsAndMIME()
        try await sendLifecycle()
        try await sendAccountChecks()
        try await sendHTTPOutcomes()
        try await sendConcurrency()
        try await generationFencing()
        print("GideonAgentTools: \(assertions.withLock { $0 }) assertions passed across 9 suites; 9 tool definitions; mocked network only")
    }

    static func validators() throws {
        let id = UUID().uuidString
        for service in ["gmail", "Google Mail", "google-mail", "GOOGLE", " Gmail "] {
            try expect(GideonAgentToolCodec.service(service) == "gmail", "Exact Gmail alias")
        }
        for service in ["Google Calendar", "Google Drive", "gmail calendar", "github enterprise", "notgmail"] {
            try expect(GideonAgentToolCodec.service(service) == nil, "Unsupported service must not match")
        }
        for base in ["http://api.github.com", "https://api.github.com.evil", "https://api.github.com/user", "https://x@api.github.com", "https://evil.example"] {
            try expect(!GideonAgentToolCodec.standardBase(base, service: "github"), "Custom base must be blocked")
        }
        for spec in GideonAgentToolCodec.specs {
            var args: [String: String] = [:]
            for key in spec.required { args[key] = key == "repo" ? "owner/repo" : key == "message_id" ? "abc123" : key == "to" ? "user@example.com" : id }
            _ = try GideonAgentToolCodec.arguments(call(spec.name, args))
            var extra = args; extra["url"] = "https://evil.example"
            try rejects { _ = try GideonAgentToolCodec.arguments(call(spec.name, extra)) }
            for key in spec.required {
                var missing = args; missing.removeValue(forKey: key)
                try rejects { _ = try GideonAgentToolCodec.arguments(call(spec.name, missing)) }
            }
        }
        try rejects { _ = try GideonAgentToolCodec.arguments(call("github_create_issue")) }
        for raw in ["[]", "null", "{\"id\":1}", "{\"id\":null}", "{", "{\"id\":\"bad\"}"] {
            try rejects { _ = try GideonAgentToolCodec.arguments(RemoteToolCall(id: "", name: "project_read", argumentsJSON: raw)) }
        }
        for repo in ["../repo", "owner/..", "/owner/repo", "owner/repo?x=y", "owner/repo#f", "owner/repo%2f", "owner/repo/extra", "https://github.com/owner/repo", "owner/r\nepo"] {
            try rejects { _ = try GideonAgentToolCodec.arguments(call("github_issues", ["account_id": id, "repo": repo])) }
        }
        for path in ["../secret", "/root", "a/../b", "a//b", "a/", "a%2Fb", "a\\b", "a?x=y", "a#b", "https:evil"] {
            try rejects { _ = try GideonAgentToolCodec.arguments(call("github_contents", ["account_id": id, "repo": "o/r", "path": path])) }
        }
        _ = try GideonAgentToolCodec.arguments(call("github_contents", ["account_id": id, "repo": "o/r", "path": "folder/a file ü.swift"]))
        let query = "from:user+tag@example.com subject:hello &maxResults=999#fragment?x=1"
        _ = try GideonAgentToolCodec.arguments(call("gmail_inbox", ["account_id": id, "query": query]))
        let url = try GideonAgentToolCodec.url(host: "gmail.googleapis.com", segments: ["gmail", "v1"], query: [("q", query)])
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        try expect(components.queryItems?.count == 1 && components.queryItems?.first?.value == query, "Gmail search stays one encoded query value")
        try expect(url.absoluteString.contains("%2B") && url.fragment == nil, "Plus and fragment cannot inject request parameters")
        try rejects { _ = try GideonAgentToolCodec.url(host: "evil.example", segments: []) }
    }

    static func parsers() throws {
        let text = "Hello 🐈\nSwift"
        let file: [String: Any] = ["type": "file", "size": text.utf8.count, "encoding": "base64", "content": Data(text.utf8).base64EncodedString(), "path": "test"]
        try expect(tryValue { try object(GideonAgentToolCodec.contents(file))["text"] as? String } == text, "UTF8 file decoded")
        for override in [["size": 102401], ["type": "symlink"], ["encoding": "none"], ["content": "%%%"], ["content": Data([0, 1, 2]).base64EncodedString()], ["target": "secret"]] as [[String: Any]] {
            try rejects { _ = try GideonAgentToolCodec.contents(file.merging(override) { _, new in new }) }
        }
        let exact = Data(repeating: 65, count: 102400)
        let large: [String: Any] = ["type": "file", "size": exact.count, "encoding": "base64", "content": exact.base64EncodedString()]
        let truncated = try GideonAgentToolCodec.contents(large)
        try expect(truncated.utf8.count <= GideonAgentToolCodec.outputLimit && truncated.hasSuffix("[TRUNCATED]"), "100KB accepted with marked bounded output")
        try rejects { _ = try GideonAgentToolCodec.utf8(Data([0xff])) }
        let mail: [String: Any] = ["id": "a1", "payload": ["mimeType": "multipart/mixed", "parts": [
            ["mimeType": "multipart/alternative", "parts": [
                ["mimeType": "text/plain", "body": ["data": base64url(text)]],
                ["mimeType": "text/html", "body": ["data": base64url("HTML-SECRET")]]]],
            ["mimeType": "text/plain", "filename": "private.txt", "body": ["data": base64url("ATTACHMENT-SECRET")]],
            ["mimeType": "text/plain", "body": ["attachmentId": "attachment-id"]]
        ]]]
        let parsed = try object(GideonAgentToolCodec.mail(mail))
        try expect(parsed["text"] as? String == text && parsed["attachments_not_read"] as? Int == 2, "Recursive plain text only, attachments omitted")
        try expect(parsed["html_not_read"] as? Bool == true && parsed["html_only"] as? Bool == false, "Mixed MIME reporting")
        let html = try GideonAgentToolCodec.mail(["payload": ["mimeType": "text/html", "body": ["data": base64url("HTML-SECRET")]]])
        try expect(!html.contains("HTML-SECRET") && tryValue { try object(html)["html_only"] as? Bool } == true, "HTML-only reported, not read")
        let invalid = try object(GideonAgentToolCodec.mail(["payload": ["mimeType": "text/plain", "body": ["data": "%%%"]]]))
        try expect(invalid["parts_omitted"] as? Bool == true, "Invalid base64 reported")
        var nested: [String: Any] = ["mimeType": "text/plain", "body": ["data": base64url("TOO-DEEP")]]
        for _ in 0..<25 { nested = ["mimeType": "multipart/mixed", "parts": [nested]] }
        let bounded = try GideonAgentToolCodec.mail(["payload": nested])
        try expect(!bounded.contains("TOO-DEEP") && bounded.contains("parts_omitted\":true"), "MIME recursion bounded")
    }

    private static func tryValue<T>(_ body: () throws -> T?) -> T? { try? body() }

    private static let sender = "actual.sender@gmail.com"
    private static let to = "taylor.olsen@outlook.com, aaronhorowitz97@gmail.com"
    private static let benchmark = "Gideon email test 1."

    private static func sendArgs(_ id: UUID, subject: String = benchmark, body: String = benchmark) -> [String: String] {
        ["account_id": id.uuidString, "to": to, "subject": subject, "body": body]
    }

    private static func profileData(_ address: String = sender) throws -> Data { try data(["emailAddress": address]) }

    private struct SendFixture: Sendable {
        let account: AccountRecord
        let session: GideonAgentToolSession
        let network: Network
        let clock: TestClock
        let pending: PendingGmailSend
    }

    @MainActor private static func sendFixture(subject: String = benchmark, body: String = benchmark) async throws -> SendFixture {
        SessionIsolation.activate(userID: "user-a", mode: "cloud")
        let account = AccountRecord(id: UUID(), service: "Gmail", name: "not.the.sender@example.com")
        AccountStore.shared.accounts = [account]
        AccountStore.shared.tokens = [account.id: "ACCESS-SECRET"]
        AccountStore.shared.refreshTokens = [account.id: "REFRESH-SECRET"]
        AppActivityStore.shared.items = []
        let network = Network(), clock = TestClock()
        await network.install([(try profileData(), 200)])
        let session = GideonAgentToolSession(transport: await network.transport, now: { clock.now() })
        let context = await session.prepare()
        try expect(context.definitions.contains { $0.name == "gmail_prepare_send" }, "Prepare tool registered for Gmail")
        try expect(!context.definitions.contains { ["gmail_send", "gmail_confirm_send", "confirmSend"].contains($0.name) }, "No model-callable send or confirm")
        try expect(context.systemContext.contains("NO model-callable") && context.systemContext.contains("Never pretend a draft") && context.systemContext.contains("native UI confirmation"), "Context documents real capabilities and confirmation boundary")
        let definition = context.definitions.first { $0.name == "gmail_prepare_send" }!
        let schema = try object(definition.parametersJSON)
        try expect(Set(schema["required"] as? [String] ?? []) == Set(["account_id", "to", "subject", "body"]), "Exact required send string keys")
        try expect(definition.description.contains("16000") && definition.description.contains("15 minutes") && definition.description.contains("ASCII"), "Tool documentation covers limits and expiration")
        let result = await session.execute(call("gmail_prepare_send", sendArgs(account.id, subject: subject, body: body)))
        guard let pending = await session.pendingSend else { throw Failure(message: "Missing proposal: \(result)") }
        try expect(pending.sender == sender && pending.sender != account.name, "Real sender comes from profile, never account label")
        try expect(pending.body == body && pending.subject == subject && pending.preparedAt == clock.now(), "Immutable proposal preserves approved content and clock")
        try expect(pending.recipients == ["taylor.olsen@outlook.com", "aaronhorowitz97@gmail.com"], "Both benchmark recipients preserved")
        try expect(result.contains("in memory ONLY") && result.contains("not sent") && result.contains(pending.id.uuidString), "Preparation never claims Gmail draft or send")
        let requests = await network.requests
        try expect(requests.count == 1 && requests[0].httpMethod == "GET" && requests[0].url?.path == "/gmail/v1/users/me/profile", "Preparation is profile GET only, no external write")
        return SendFixture(account: account, session: session, network: network, clock: clock, pending: pending)
    }

    private static func decodedMIME(_ request: URLRequest) throws -> String {
        let json = try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: String]
        guard let raw = json?["raw"], json?.count == 1 else { throw Failure(message: "Expected raw-only Gmail send JSON") }
        try expect(!raw.contains("=") && !raw.contains("+") && !raw.contains("/") && !raw.contains("\n"), "Raw is unpadded base64url")
        var encoded = raw.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
        guard let bytes = Data(base64Encoded: encoded), let mime = String(data: bytes, encoding: .utf8) else { throw Failure(message: "Invalid raw MIME") }
        return mime
    }

    private static func checkMIME(_ mime: String, pending: PendingGmailSend) throws {
        let sections = mime.components(separatedBy: "\r\n\r\n")
        try expect(sections.count == 2, "Single MIME header/body boundary")
        let header = sections[0], lines = sections[1].components(separatedBy: "\r\n")
        try expect(header.contains("From: \(pending.sender)\r\n"), "MIME actual From")
        try expect(header.contains("To: taylor.olsen@outlook.com,\r\n aaronhorowitz97@gmail.com\r\n"), "MIME exact benchmark To recipients")
        try expect(header.contains("Message-ID: <\(pending.id.uuidString)@gideon.local>"), "Stable unique correlation Message-ID")
        try expect(header.contains("Date:") && header.contains("MIME-Version: 1.0") && header.contains("Content-Type: text/plain; charset=UTF-8") && header.contains("Content-Transfer-Encoding: base64"), "Complete text MIME headers")
        try expect(lines.allSatisfy { $0.utf8.count <= 76 } && lines.dropLast(2).allSatisfy { $0.count == 76 }, "Base64 body wrapped at 76 characters")
        let bodyData = Data(base64Encoded: lines.joined())
        let normalized = pending.body.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").replacingOccurrences(of: "\n", with: "\r\n")
        try expect(bodyData.flatMap { String(data: $0, encoding: .utf8) } == normalized, "Body decodes to exact content with canonical line endings")
        let subjectSection = header.components(separatedBy: "Subject: ")[1].components(separatedBy: "\r\nDate:")[0]
        var subject = ""
        for word in subjectSection.components(separatedBy: "\r\n ") {
            try expect(word.count <= 75 && word.hasPrefix("=?UTF-8?B?") && word.hasSuffix("?="), "Valid bounded RFC2047 encoded word")
            guard let bytes = Data(base64Encoded: String(word.dropFirst(10).dropLast(2))), let text = String(data: bytes, encoding: .utf8) else { throw Failure(message: "Subject word splits UTF8 scalar") }
            subject += text
        }
        try expect(subject == pending.subject, "Folded subject decodes without inserted spaces or corruption")
        try expect(header.components(separatedBy: "\r\n").allSatisfy { $0.utf8.count <= 76 }, "Benchmark MIME headers use <=76 character lines")
        try expect(!mime.replacingOccurrences(of: "\r\n", with: "").contains("\n"), "No bare LF in MIME")
    }

    static func sendValidatorsAndMIME() throws {
        let id = UUID(), args = sendArgs(UUID())
        for name in ["gmail_send", "gmail_confirm_send", "gmail_messages_send", "confirmSend"] {
            try rejects { _ = try GideonAgentToolCodec.arguments(call(name, args)) }
        }
        for address in ["", "a@example.com,", ",a@example.com", "a@example.com,,b@example.com", "Name <a@example.com>", "a@example.com; b@example.com", "a@localhost", "a@@example.com", ".a@example.com", "a..b@example.com", "a.@example.com", "a b@example.com", "ü@example.com", "a@éxample.com", "a@-example.com", "a@example-.com", "a@exa_mple.com", "a@ex..com", "a@example.com\r\nBcc: b@example.com", String(repeating: "a", count: 65) + "@example.com", Array(repeating: "a@example.com", count: 11).joined(separator: ",")] {
            var invalid = args; invalid["to"] = address
            try rejects { _ = try GideonAgentToolCodec.arguments(call("gmail_prepare_send", invalid)) }
        }
        for key in ["subject", "to", "account_id"] {
            for injection in ["\r\nBcc: evil@example.com", "\nInjected", "\rInjected", "\u{0}", "\t"] {
                var invalid = args; invalid[key]! += injection
                try rejects { _ = try GideonAgentToolCodec.arguments(call("gmail_prepare_send", invalid)) }
            }
        }
        for body in [String(repeating: "a", count: 16001), String(repeating: "🐈", count: 4001), "text\u{0}", "text\u{7}"] {
            var invalid = args; invalid["body"] = body
            try rejects { _ = try GideonAgentToolCodec.arguments(call("gmail_prepare_send", invalid)) }
        }
        var valid = args
        valid["body"] = String(repeating: "🐈", count: 4000)
        valid["subject"] = String(repeating: "é", count: 512)
        valid["to"] = Array(repeating: "a.b+tag@example-domain.com", count: 10).joined(separator: ", ")
        _ = try GideonAgentToolCodec.arguments(call("gmail_prepare_send", valid))
        try expect(tryValue { try GideonAgentToolCodec.recipients(valid["to"]!).count } == 10, "Ten bare recipients allowed")
        valid["subject"]! += "a"
        try rejects { _ = try GideonAgentToolCodec.arguments(call("gmail_prepare_send", valid)) }
        valid = args; valid["body"] = String(repeating: "\n", count: 16000)
        _ = try GideonAgentToolCodec.arguments(call("gmail_prepare_send", valid))
        valid["body"] = "line1\nline2\r\nline3\rline4\tvalue"
        _ = try GideonAgentToolCodec.arguments(call("gmail_prepare_send", valid))
        let pending = PendingGmailSend(id: id, accountID: UUID(), sender: sender,
            recipients: ["taylor.olsen@outlook.com", "aaronhorowitz97@gmail.com"],
            subject: String(repeating: "é🐈 long subject ", count: 30), body: valid["body"]! + String(repeating: "🧪", count: 300), preparedAt: Date(timeIntervalSince1970: 1_800_000_000))
        try checkMIME(GideonAgentToolCodec.mime(pending), pending: pending)
        try expect(GideonAgentToolCodec.mime(pending) == GideonAgentToolCodec.mime(pending), "Immutable MIME is deterministic")
    }

    @MainActor static func sendLifecycle() async throws {
        let f = try await sendFixture()
        let repeated = await f.session.execute(call("gmail_prepare_send", sendArgs(f.account.id)))
        let same = await f.session.pendingSend
        try expect(same == f.pending && repeated.contains(f.pending.id.uuidString), "Repeated preparation returns same immutable proposal")
        for key in ["to", "subject", "body"] {
            var args = sendArgs(f.account.id); args[key] = key == "to" ? "other@example.com" : "changed"
            let result = await f.session.execute(call("gmail_prepare_send", args))
            try expect(result.contains("immutable") && result.contains("new user request/session"), "Changed proposal refused, never silently replaced")
        }
        let mismatch = await f.session.confirmSend(id: UUID())
        try expect(mismatch.status == .rejected, "Wrong approval ID refused")
        await f.session.discardPendingSend(id: UUID())
        let stillPending = await f.session.pendingSend
        try expect(stillPending == f.pending, "Wrong confirm/discard IDs preserve pending")
        for name in ["gmail_send", "gmail_confirm_send", "confirmSend"] {
            let blocked = await f.session.execute(call(name, sendArgs(f.account.id)))
            try expect(blocked.contains("Unrecognized"), "Direct send cannot execute as a tool")
        }
        let prepareRequests = await f.network.requests
        try expect(prepareRequests.count == 1, "Repeats, changes and wrong IDs do not touch network")
        await f.network.install([(try profileData(), 200), (try data(["id": "19abc123", "threadId": "unused"]), 200)])
        let accepted = await f.session.confirmSend(id: f.pending.id)
        try expect(accepted.status == .accepted && accepted.messageID == "19abc123", "Valid Gmail acceptance and message ID")
        try expect(accepted.text.contains("Gmail accepted for sending") && accepted.text.contains("delivery is not verified"), "Acceptance never claims delivery")
        try expect(accepted.text.contains(sender) && accepted.text.contains("taylor.olsen@outlook.com") && accepted.text.contains("aaronhorowitz97@gmail.com") && accepted.text.contains(f.pending.id.uuidString) && accepted.text.contains("19abc123"), "Persistable outcome contains sender, recipients and IDs")
        let sent = await f.network.requests
        try expect(sent.count == 2 && sent[0].httpMethod == "GET" && sent[1].httpMethod == "POST", "Confirmation verifies profile then performs exactly one POST")
        try expect(sent[1].url?.absoluteString == "https://gmail.googleapis.com/gmail/v1/users/me/messages/send" && sent[1].timeoutInterval == 20, "Fixed bounded Gmail send endpoint")
        try expect(sent[1].value(forHTTPHeaderField: "Content-Type") == "application/json" && sent[1].value(forHTTPHeaderField: "Authorization") == "Bearer ACCESS-SECRET", "Send auth stays at HTTP boundary")
        try checkMIME(decodedMIME(sent[1]), pending: f.pending)
        let double = await f.session.confirmSend(id: f.pending.id)
        let pending = await f.session.pendingSend
        try expect(double.status == .rejected && pending == nil, "Approval consumed and double confirmation refused")
        let recreate = await f.session.execute(call("gmail_prepare_send", sendArgs(f.account.id)))
        try expect(recreate.contains("already consumed"), "Only one proposal per session even after success")
        let afterDouble = await f.network.requests
        try expect(afterDouble.count == 2, "Double confirmation never resends")
        try auditIsPrivate()

        let discarded = try await sendFixture()
        await discarded.session.discardPendingSend(id: discarded.pending.id)
        let discardResult = await discarded.session.confirmSend(id: discarded.pending.id)
        let discardedRepeat = await discarded.session.execute(call("gmail_prepare_send", sendArgs(discarded.account.id)))
        try expect(discardResult.status == .rejected && discardedRepeat.contains("already consumed"), "Discard permanently closes this session's proposal")

        let expired = try await sendFixture()
        expired.clock.advance(900)
        await expired.network.install([])
        let expiry = await expired.session.confirmSend(id: expired.pending.id)
        let expiryRequests = await expired.network.requests
        try expect(expiry.status == .rejected && expiry.text.contains("expired") && expiry.text.contains("no send POST") && expiryRequests.isEmpty, "Exactly 15 minutes expires without network")
        let repeatExpiry = try await sendFixture()
        repeatExpiry.clock.advance(901)
        let expiryPreparation = await repeatExpiry.session.execute(call("gmail_prepare_send", sendArgs(repeatExpiry.account.id)))
        let expiredPending = await repeatExpiry.session.pendingSend
        try expect(expiryPreparation.contains("expired") && expiredPending == nil, "Repeated expired proposal cannot revive approval")

        let near = try await sendFixture()
        near.clock.advance(899)
        await near.network.install([(try profileData(), 200), (try data(["id": "abc123"]), 200)])
        let nearResult = await near.session.confirmSend(id: near.pending.id)
        try expect(nearResult.status == .accepted, "Approval just before expiry is valid")
    }

    @MainActor private static func auditIsPrivate() throws {
        for item in AppActivityStore.shared.items {
            try expect(["completed", "blocked"].contains(item.detail), "Audit contains only completion state")
            for forbidden in ["SECRET", "@", benchmark] {
                try expect(!item.title.contains(forbidden) && !item.detail.contains(forbidden), "No contents, addresses or credentials in audit")
            }
        }
    }

    @MainActor static func sendAccountChecks() async throws {
        let preparation = try await sendFixture()
        for reply in [(try profileData("bad\r\nBcc: evil@example.com"), 200), (try data(["wrong": "value"]), 200), (Data(), 503)] {
            let session = GideonAgentToolSession(transport: await preparation.network.transport)
            _ = await session.prepare()
            await preparation.network.install([reply])
            _ = await session.execute(call("gmail_prepare_send", sendArgs(preparation.account.id)))
            let pending = await session.pendingSend
            let requests = await preparation.network.requests
            try expect(pending == nil && requests.count == 1 && requests[0].httpMethod == "GET", "Failed/invalid preparation profile creates no proposal or send")
            await preparation.network.install([(try profileData(), 200)])
            _ = await session.execute(call("gmail_prepare_send", sendArgs(preparation.account.id)))
            let recovered = await session.pendingSend
            try expect(recovered != nil, "Failed profile lookup releases preparation reservation")
        }
        let invalidSession = GideonAgentToolSession(transport: await preparation.network.transport)
        _ = await invalidSession.prepare()
        await preparation.network.install([])
        var injection = sendArgs(preparation.account.id); injection["subject"] = "test\r\nBcc: evil@example.com"
        let invalidResult = await invalidSession.execute(call("gmail_prepare_send", injection))
        let invalidRequests = await preparation.network.requests
        try expect(invalidResult.contains("control") && invalidRequests.isEmpty, "Header injection refused before profile request")
        let refreshSession = GideonAgentToolSession(transport: await preparation.network.transport)
        _ = await refreshSession.prepare()
        await preparation.network.install([(Data(), 401), (try data(["access_token": "PREPARED-REFRESH-SECRET"]), 200), (try profileData(), 200)])
        _ = await refreshSession.execute(call("gmail_prepare_send", sendArgs(preparation.account.id)))
        let refreshedPending = await refreshSession.pendingSend
        let preparationRequests = await preparation.network.requests
        try expect(refreshedPending?.sender == sender && preparationRequests.count == 3, "Preparation uses existing bounded GET refresh mechanism")
        try expect(preparationRequests.filter { $0.httpMethod == "POST" }.allSatisfy { $0.url?.host == "oauth2.googleapis.com" }, "Preparation may refresh OAuth but never POST a Gmail write")

        for mutation in ["removed", "calendar", "substring", "base", "missing", "invalid"] {
            let f = try await sendFixture()
            switch mutation {
            case "removed": AccountStore.shared.accounts = []
            case "calendar": AccountStore.shared.accounts[0].service = "Google Calendar"
            case "substring": AccountStore.shared.accounts[0].service = "gmail calendar"
            case "base": AccountStore.shared.accounts[0].baseURL = "https://evil.example"
            case "missing": AccountStore.shared.tokens[f.account.id] = nil
            default: AccountStore.shared.tokens[f.account.id] = "bad\r\nInjected: token"
            }
            await f.network.install([])
            let outcome = await f.session.confirmSend(id: f.pending.id)
            let requests = await f.network.requests
            try expect(outcome.status == .rejected && outcome.text.contains("no send POST") && requests.isEmpty, "Recheck account/token before any network: \(mutation)")
        }
        for address in ["different@gmail.com", "bad\r\nBcc: evil@example.com", "Display <real@gmail.com>"] {
            let f = try await sendFixture()
            await f.network.install([(try profileData(address), 200)])
            let outcome = await f.session.confirmSend(id: f.pending.id)
            let requests = await f.network.requests
            try expect(outcome.status == .rejected && requests.count == 1 && requests[0].httpMethod == "GET", "Changed/invalid profile sender prevents POST")
        }
        for mutation in ["token", "remove", "expiry"] {
            let f = try await sendFixture()
            await f.network.install([(try profileData(), 200)])
            await f.network.setHook { _ in
                if mutation == "expiry" { f.clock.advance(900) }
                else { await MainActor.run {
                    if mutation == "token" { AccountStore.shared.tokens[f.account.id] = "REPLACED-SECRET" }
                    else { AccountStore.shared.accounts = [] }
                } }
            }
            let outcome = await f.session.confirmSend(id: f.pending.id)
            let requests = await f.network.requests
            try expect(outcome.status == .rejected && outcome.text.contains("no send POST") && requests.count == 1, "Changes during profile await block POST: \(mutation)")
        }
        let refreshed = try await sendFixture()
        await refreshed.network.install([(Data(), 401), (try data(["access_token": "REFRESHED-SECRET"]), 200), (try profileData(), 200), (try data(["id": "abc123"]), 200)])
        let refreshOutcome = await refreshed.session.confirmSend(id: refreshed.pending.id)
        let refreshRequests = await refreshed.network.requests
        try expect(refreshOutcome.status == .accepted && refreshRequests.count == 4, "Pre-send GET refreshes expired access token then sends")
        try expect(refreshRequests.map { $0.httpMethod! } == ["GET", "POST", "GET", "POST"] && refreshRequests[1].url?.host == "oauth2.googleapis.com", "Only GET 401 invokes bounded OAuth refresh")
        try expect(refreshRequests[3].value(forHTTPHeaderField: "Authorization") == "Bearer REFRESHED-SECRET", "Send uses token actually verified by profile")
        try expect(!refreshOutcome.text.contains("SECRET"), "Refresh credentials absent from outcome")

        for kind in ["refreshUnavailable", "refreshRejected", "second401", "profile403", "profileMalformed", "profileOversize", "timeout", "cancelled"] {
            let f = try await sendFixture()
            switch kind {
            case "refreshUnavailable":
                AccountStore.shared.refreshTokens[f.account.id] = nil
                await f.network.install([(Data(), 401)])
            case "refreshRejected": await f.network.install([(Data(), 401), (Data("REFRESH-SECRET".utf8), 400)])
            case "second401": await f.network.install([(Data(), 401), (try data(["access_token": "NEW-SECRET"]), 200), (Data(), 401)])
            case "profile403": await f.network.install([(Data("ACCESS-SECRET".utf8), 403)])
            case "profileMalformed": await f.network.install([(try data(["wrong": "ACCESS-SECRET"]), 200)])
            case "profileOversize": await f.network.install([(Data(repeating: 65, count: GideonAgentToolCodec.bodyLimit + 1), 200)])
            default:
                await f.network.install([])
                await f.network.fail(at: 1, code: kind == "timeout" ? .timedOut : .cancelled)
            }
            let outcome = await f.session.confirmSend(id: f.pending.id)
            let requests = await f.network.requests
            try expect(outcome.status == .rejected && outcome.text.contains("no send POST") && !outcome.text.contains("SECRET"), "Pre-POST failure known not sent and sanitized: \(kind)")
            try expect(!requests.contains { $0.url?.path.hasSuffix("/messages/send") == true }, "No send on failed preflight: \(kind)")
        }
        let cancelled = try await sendFixture()
        await cancelled.network.install([])
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await cancelled.session.confirmSend(id: cancelled.pending.id)
        }
        let result = await task.value
        let requests = await cancelled.network.requests
        try expect(result.status == .rejected && requests.isEmpty, "Cancellation before preflight consumes approval without sending")
    }

    @MainActor static func sendHTTPOutcomes() async throws {
        for code in [400, 401, 403, 429, 500, 502, 503, 301, 307, 408] {
            let f = try await sendFixture()
            await f.network.install([(try profileData(), 200), (Data("ACCESS-SECRET REFRESH-SECRET private-error@example.com".utf8), code)])
            let outcome = await f.session.confirmSend(id: f.pending.id)
            let requests = await f.network.requests
            try expect(requests.count == 2 && requests.filter { $0.httpMethod == "POST" }.count == 1, "Never refresh or retry send POST on HTTP \(code)")
            try expect(outcome.messageID == nil && !outcome.text.contains("SECRET") && !outcome.text.contains("private-error"), "Provider error body never leaks")
            if [400, 401, 403, 429].contains(code) {
                try expect(outcome.status == .rejected && outcome.text.contains("HTTP \(code)") && outcome.text.contains("no automatic retry"), "Definitive HTTP rejection actionable")
                if code == 403 { try expect(outcome.text.contains("scope") && outcome.text.contains("Reconnect"), "Permission rejection explains reconnect/scope") }
                if code == 401 { try expect(outcome.text.contains("Reconnect"), "401 reconnect instead of retry") }
            } else {
                try expect(outcome.status == .unknown && outcome.text.contains("Check Gmail Sent") && !outcome.text.contains("Not sent"), "Ambiguous HTTP never claims nothing sent")
                try expect(outcome.text.contains(f.pending.id.uuidString + "@gideon.local") && outcome.text.contains("does not guarantee idempotency"), "Unknown outcome has visible non-idempotent correlation")
            }
            _ = await f.session.confirmSend(id: f.pending.id)
            let finalRequests = await f.network.requests
            try expect(finalRequests.count == 2, "HTTP failure approval cannot be reused")
        }
        for invalid in [Data(), Data("bad json ACCESS-SECRET".utf8), try data(["id": ""]), try data(["id": "bad\r\nid"]), try data(["id": 123]), try data(["id": "ACCESS-SECRET"]), try data(["id": "REFRESH-SECRET"]), try data(["threadId": "abc"]), Data(repeating: 65, count: GideonAgentToolCodec.bodyLimit + 1)] {
            let f = try await sendFixture()
            await f.network.install([(try profileData(), 200), (invalid, 200)])
            let outcome = await f.session.confirmSend(id: f.pending.id)
            let requests = await f.network.requests
            try expect(outcome.status == .unknown && outcome.messageID == nil && outcome.text.contains("Check Gmail Sent") && !outcome.text.contains("SECRET"), "Invalid 2xx is unknown, not success or rejection")
            try expect(requests.count == 2, "Invalid successful response does not resend")
        }
        for code in [URLError.Code.timedOut, .networkConnectionLost, .cancelled] {
            let f = try await sendFixture()
            await f.network.install([(try profileData(), 200)])
            await f.network.fail(at: 2, code: code)
            let outcome = await f.session.confirmSend(id: f.pending.id)
            try expect(outcome.status == .unknown && outcome.text.contains("Check Gmail Sent") && !outcome.text.contains("Not sent"), "Transport error after POST is ambiguous")
            _ = await f.session.confirmSend(id: f.pending.id)
            let requests = await f.network.requests
            try expect(requests.count == 2, "Timeout/lost connection/cancellation never retries POST")
        }
    }

    @MainActor static func sendConcurrency() async throws {
        let f = try await sendFixture(), gate = Gate()
        await f.network.install([(try profileData(), 200), (try data(["id": "abc123"]), 200)])
        await f.network.setHook { request in if request.httpMethod == "GET" { await gate.pause() } }
        let first = Task { await f.session.confirmSend(id: f.pending.id) }
        await gate.waitUntilEntered()
        let consumed = await f.session.pendingSend
        try expect(consumed == nil, "Pending consumed synchronously before first await")
        let second = await f.session.confirmSend(id: f.pending.id)
        try expect(second.status == .rejected && second.text.contains("earlier confirmation may still be processing"), "Concurrent approval refused without claiming first send failed")
        let blocked = await f.session.execute(call("gmail_prepare_send", sendArgs(f.account.id)))
        try expect(blocked.contains("already consumed"), "Cannot replace proposal during in-flight send")
        await gate.release()
        let accepted = await first.value
        let requests = await f.network.requests
        try expect(accepted.status == .accepted && requests.count == 2, "Concurrent confirmations cause exactly one POST")

        let cancelled = try await sendFixture(), postGate = Gate()
        await cancelled.network.install([(try profileData(), 200), (try data(["id": "abc123"]), 202)])
        await cancelled.network.setHook { request in if request.httpMethod == "POST" { await postGate.pause() } }
        let sending = Task { await cancelled.session.confirmSend(id: cancelled.pending.id) }
        await postGate.waitUntilEntered()
        sending.cancel()
        await postGate.release()
        let outcome = await sending.value
        try expect(outcome.status == .unknown && outcome.messageID == nil && !outcome.text.contains(sender), "Cancelled task suppresses acceptance details; dispatched send is not recalled or retried")

        let preparing = try await sendFixture(), preparationGate = Gate()
        let session = GideonAgentToolSession(transport: await preparing.network.transport)
        _ = await session.prepare()
        await preparing.network.install([(try profileData(), 200)])
        await preparing.network.setHook { _ in await preparationGate.pause() }
        let firstPreparation = Task { await session.execute(call("gmail_prepare_send", sendArgs(preparing.account.id))) }
        await preparationGate.waitUntilEntered()
        let competing = await session.execute(call("gmail_prepare_send", sendArgs(preparing.account.id, body: "different")))
        try expect(competing.contains("being prepared"), "Concurrent changed preparation cannot replace reserved proposal")
        await preparationGate.release()
        let firstText = await firstPreparation.value
        let pending = await session.pendingSend
        let sameText = await session.execute(call("gmail_prepare_send", sendArgs(preparing.account.id)))
        let preparationRequests = await preparing.network.requests
        try expect(pending?.body == benchmark && firstText == sameText && preparationRequests.count == 1, "Concurrent preparation preserves one immutable proposal, later identical repeats reuse it")
    }

    @MainActor static func sessions() async throws {
        let github = AccountRecord(id: UUID(), service: "GitHub")
        let gmail = AccountRecord(id: UUID(), service: "Gmail")
        let calendar = AccountRecord(id: UUID(), service: "Google Calendar")
        let custom = AccountRecord(id: UUID(), service: "GitHub", baseURL: "https://private.example")
        let missing = AccountRecord(id: UUID(), service: "Gmail")
        AccountStore.shared.accounts = [github, gmail, calendar, custom, missing]
        for record in [github, gmail, calendar, custom] { AccountStore.shared.tokens[record.id] = "SECRET-" + record.id.uuidString }
        AccountStore.shared.refreshTokens[gmail.id] = "REFRESH-SECRET"
        let project = ProjectRecord(id: UUID(), name: "Untrusted name", detail: "Project detail", summary: "Project summary")
        AppProjectStore.shared.projects = [project]
        AppActivityStore.shared.items = [ActivityRecord(title: "Linked work", detail: "Linked detail", state: .completed, projectID: project.id)]
        let network = Network()
        let session = GideonAgentToolSession(transport: await network.transport)
        let before = await session.execute(call("projects_list"))
        try expect(before.contains("unavailable"), "Must prepare first")
        let prepared = await session.prepare()
        try expect(prepared.definitions.count == 9, "Eight read tools plus one preparation tool available with saved credentials")
        try expect(!prepared.systemContext.contains("SECRET") && !prepared.systemContext.contains("private.example") && !prepared.systemContext.contains("Project detail"), "No credentials, endpoints or detail in prompt")
        try expect(prepared.systemContext.contains("untrusted data") && prepared.systemContext.contains("scopes unverified"), "Untrusted content and scope caveats")
        let listed = await session.execute(call("projects_list"))
        try expect(listed.contains(project.id.uuidString) && !listed.contains("Project detail"), "Brief project index")
        let read = await session.execute(call("project_read", ["id": project.id.uuidString]))
        try expect(read.contains("Project detail") && read.contains("Project summary") && read.contains("Linked work"), "Local detail and linked activity")
        let used = await session.usedTool
        try expect(used, "Successful execution marks usedTool")
        let fresh = AccountRecord(id: UUID(), service: "GitHub")
        AccountStore.shared.accounts.append(fresh); AccountStore.shared.tokens[fresh.id] = "LATE-SECRET"
        for record in [calendar, custom, missing, fresh] {
            let result = await session.execute(call("github_repos", ["account_id": record.id.uuidString]))
            try expect(result.contains("not authorized"), "No unsupported, custom, missing or post-prepare account access")
        }
        let crossService = await session.execute(call("github_repos", ["account_id": gmail.id.uuidString]))
        try expect(crossService.contains("not authorized"), "Account service must match tool")
        let initialRequests = await network.requests
        try expect(initialRequests.isEmpty, "Blocked calls never touch network")
        await network.install([(try data([["id": 1, "full_name": "owner/repo", "private": true, "token": "BODY-SECRET"]]), 200)])
        let repos = await session.execute(call("github_repos", ["account_id": github.id.uuidString]))
        try expect(repos.contains("owner/repo") && !repos.contains("BODY-SECRET"), "Curated repository output")
        let repoRequests = await network.requests
        try expect(repoRequests.first?.url?.host == "api.github.com" && repoRequests.first?.url?.path == "/user/repos", "Fixed GitHub endpoint")
        try expect(repoRequests.first?.httpMethod == "GET" && repoRequests.first?.timeoutInterval == 20, "Read-only bounded request")
        await network.install([(try data(["workflow_runs": [["id": 2, "status": "completed", "conclusion": "success", "html_url": "https://github.com/o/r/actions/runs/2"]]]), 200)])
        let runs = await session.execute(call("github_runs", ["account_id": github.id.uuidString, "repo": "o/r"]))
        try expect(runs.contains("success") && runs.contains("completed") && runs.contains("html_url"), "Run conclusion/status/URL")
        let metadata: [String: Any] = ["id": "a1", "payload": ["headers": [["name": "Subject", "value": "PRIVATE-SUBJECT"]]]]
        await network.install([(try data(["messages": [["id": "a1"]], "nextPageToken": "OPAQUE-SECRET"]), 200), (try data(metadata), 200)])
        let inbox = await session.execute(call("gmail_inbox", ["account_id": gmail.id.uuidString, "query": "from:a+b@example.com &maxResults=99"]))
        try expect(inbox.contains("PRIVATE-SUBJECT") && !inbox.contains("OPAQUE-SECRET"), "Metadata only, no opaque pagination token")
        let inboxRequests = await network.requests
        try expect(inboxRequests.count == 2 && inboxRequests.allSatisfy { $0.url?.host == "gmail.googleapis.com" }, "Metadata fetched only from Gmail")
        let listQuery = URLComponents(url: inboxRequests[0].url!, resolvingAgainstBaseURL: false)!.queryItems!
        try expect(listQuery.first { $0.name == "maxResults" }?.value == "5", "Query cannot override inbox limit")
        await network.install([(Data("PRIVATE-ERROR-BODY".utf8), 401), (try data(["access_token": "NEW-SECRET"]), 200), (try data(["messages": []]), 200)])
        let refreshed = await session.execute(call("gmail_inbox", ["account_id": gmail.id.uuidString]))
        try expect(refreshed.contains("messages") && !refreshed.contains("SECRET"), "401 refresh and retry")
        let refreshRequests = await network.requests
        try expect(refreshRequests.count == 3 && refreshRequests[1].url?.host == "oauth2.googleapis.com", "Google refresh fixed endpoint")
        try expect(refreshRequests[1].httpMethod == "POST" && refreshRequests[1].value(forHTTPHeaderField: "Authorization") == nil, "Only internal refresh uses POST; no forwarded bearer")
        try expect(refreshRequests[2].value(forHTTPHeaderField: "Authorization") == "Bearer NEW-SECRET", "Retry resolves updated Keychain credential")
        await network.install([(Data(), 401), (Data("SECRET-ERROR".utf8), 400)])
        let failedRefresh = await session.execute(call("gmail_inbox", ["account_id": gmail.id.uuidString]))
        try expect(failedRefresh.contains("Reconnect") && !failedRefresh.contains("SECRET"), "Refresh failures actionable and sanitized")
        for code in [301, 302, 307, 401, 403, 404, 429, 500] {
            await network.install([(Data("SECRET-ERROR-BODY".utf8), code)])
            let error = await session.execute(call("github_repos", ["account_id": github.id.uuidString]))
            try expect(error.contains("HTTP \(code)") && !error.contains("SECRET"), "Sanitized useful HTTP status")
        }
        await network.install([(Data(repeating: 65, count: GideonAgentToolCodec.bodyLimit + 1), 200)])
        let oversized = await session.execute(call("github_repos", ["account_id": github.id.uuidString]))
        try expect(oversized.contains("1 MB"), "Body cap also enforced on injected transports")
        AccountStore.shared.accounts.removeAll { $0.id == github.id }
        await network.install([])
        let deleted = await session.execute(call("github_repos", ["account_id": github.id.uuidString]))
        try expect(deleted.contains("removed"), "Account existence rechecked on execution")
        AppProjectStore.shared.projects = []
        let deletedProject = await session.execute(call("project_read", ["id": project.id.uuidString]))
        try expect(deletedProject.contains("no longer exists"), "Deleted project not read")
        let cancelled = Task { () -> String in
            withUnsafeCurrentTask { $0?.cancel() }
            return await session.execute(call("gmail_inbox", ["account_id": gmail.id.uuidString]))
        }
        let cancelledResult = await cancelled.value
        try expect(cancelledResult.contains("cancelled"), "Cooperative cancellation")
        let noRequests = await network.requests
        try expect(noRequests.isEmpty, "Removal/cancellation never initiate request")
        _ = await session.execute(call("SECRET-MALICIOUS-TOOL-NAME"))
        try expect(AppActivityStore.shared.items.last?.title == "unrecognized_tool", "Unknown names are not logged verbatim")
        for item in AppActivityStore.shared.items.dropFirst() {
            try expect(!item.title.contains("SECRET") && !item.detail.contains("SECRET") && !item.detail.contains("PRIVATE-SUBJECT"), "Audit never logs credentials or message content")
            try expect(["completed", "blocked"].contains(item.detail), "Minimal audit states")
        }
        AccountStore.shared.accounts = [calendar]
        let unsupported = GideonAgentToolSession(transport: await network.transport)
        let localOnly = await unsupported.prepare()
        try expect(localOnly.definitions.map(\.name) == ["projects_list", "project_read"], "Unsupported accounts create no fake remote capabilities")
    }

    @MainActor static func generationFencing() async throws {
        // Preserve account UUIDs/tokens deliberately: equality of credentials or
        // user IDs must not accidentally revive a previous login's authority.
        for transition in ["identity", "aba", "relogin", "mode", "logout"] {
            let f = try await sendFixture()
            let old = SessionScope.current
            switch transition {
            case "identity": SessionIsolation.activate(userID: "user-b", mode: "cloud")
            case "aba":
                SessionIsolation.activate(userID: "user-b", mode: "cloud")
                SessionIsolation.activate(userID: "user-a", mode: "cloud")
            case "mode": SessionIsolation.activate(userID: "user-a", mode: "local")
            case "logout": SessionIsolation.activate(userID: nil, mode: "cloud")
            default: SessionIsolation.activate(userID: "user-a", mode: "cloud")
            }
            try expect(!old.isCurrent, "Full generation invalidated: \(transition)")
            AppActivityStore.shared.items = []
            await f.network.install([])
            // Confirm before reading pendingSend, so rejection cannot depend on
            // the UI having first cleared a stale proposal.
            let confirmation = await f.session.confirmSend(id: f.pending.id)
            let context = await f.session.prepare()
            let read = await f.session.execute(call("projects_list"))
            let prepare = await f.session.execute(call("gmail_prepare_send", sendArgs(f.account.id)))
            let pending = await f.session.pendingSend
            let requests = await f.network.requests
            try expect(confirmation.status == .rejected && confirmation.messageID == nil && !confirmation.text.contains(sender), "Old approval cannot send or reveal sender: \(transition)")
            try expect(context.definitions.isEmpty && !context.systemContext.contains(f.account.id.uuidString), "Reprepare cannot rebind old snapshot: \(transition)")
            try expect(read.contains("session") && prepare.contains("session") && pending == nil, "Stale reads and proposals fenced: \(transition)")
            try expect(requests.isEmpty && AppActivityStore.shared.items.isEmpty, "Old tasks cannot dispatch or audit under new scope: \(transition)")
        }

        // Separate prepare/execute boundary, without any existing proposal.
        let f = try await sendFixture()
        let session = GideonAgentToolSession(transport: await f.network.transport)
        _ = await session.prepare()
        SessionIsolation.activate(userID: "user-b", mode: "cloud")
        AppActivityStore.shared.items = []
        await f.network.install([])
        let stale = await session.execute(call("gmail_prepare_send", sendArgs(f.account.id)))
        let staleRequests = await f.network.requests
        try expect(stale.contains("session") && staleRequests.isEmpty && AppActivityStore.shared.items.isEmpty, "Identity switch between prepare and first execution")

        // Changes during initial profile, 401 response, OAuth refresh, inbox
        // listing, confirmation profile, and already-dispatched send.
        for phase in ["prepareProfile", "profile401", "refresh", "inbox", "confirmProfile", "post", "postFailure"] {
            let fixture = try await sendFixture(), gate = Gate()
            let preparing = ["prepareProfile", "profile401", "refresh", "inbox"].contains(phase)
            let active: GideonAgentToolSession
            if preparing {
                active = GideonAgentToolSession(transport: await fixture.network.transport)
                _ = await active.prepare()
            } else { active = fixture.session }
            if phase == "refresh" {
                await fixture.network.install([(Data(), 401), (try data(["access_token": "STALE-REFRESH-SECRET"]), 200)])
            } else if phase == "profile401" {
                await fixture.network.install([(Data(), 401)])
            } else if phase == "inbox" {
                await fixture.network.install([(try data(["messages": [["id": "old-message"]]]), 200)])
            } else if phase.hasPrefix("post") {
                await fixture.network.install([(try profileData(), 200), (try data(["id": "old-private-message-id"]), 200)])
                if phase == "postFailure" { await fixture.network.fail(at: 2, code: .networkConnectionLost) }
            } else {
                await fixture.network.install([(try profileData(), 200)])
            }
            await fixture.network.setHook { request in
                let shouldPause = phase == "refresh" ? request.url?.host == "oauth2.googleapis.com"
                    : phase.hasPrefix("post") ? request.httpMethod == "POST" : true
                if shouldPause { await gate.pause() }
            }
            let task = Task { () -> (String, GmailSendOutcome.Status?) in
                if preparing {
                    let request = phase == "inbox" ? call("gmail_inbox", ["account_id": fixture.account.id.uuidString])
                        : call("gmail_prepare_send", sendArgs(fixture.account.id))
                    return (await active.execute(request), nil)
                }
                let outcome = await active.confirmSend(id: fixture.pending.id)
                try expect(outcome.messageID == nil, "No old message ID published: \(phase)")
                return (outcome.text, outcome.status)
            }
            await gate.waitUntilEntered()
            SessionIsolation.activate(userID: "user-b", mode: "cloud")
            SessionIsolation.activate(userID: "user-a", mode: "cloud")
            AppActivityStore.shared.items = []
            // Refresh deliberately retains identical credentials: token equality
            // alone would accept this stale response after A -> B -> A.
            let currentToken = phase == "refresh" ? "ACCESS-SECRET" : "NEW-OWNER-SECRET"
            AccountStore.shared.tokens[fixture.account.id] = currentToken
            await gate.release()
            let (text, status) = try await task.value
            let requests = await fixture.network.requests
            let pending = await active.pendingSend
            let expectedCount = phase == "refresh" || phase.hasPrefix("post") ? 2 : 1
            try expect(requests.count == expectedCount, "No follow-up requests after generation change: \(phase)")
            try expect(AppActivityStore.shared.items.isEmpty && pending == nil, "No old proposal or new-user audit: \(phase)")
            try expect(AccountStore.shared.tokens[fixture.account.id] == currentToken, "Stale refresh cannot overwrite new-owner credentials: \(phase)")
            try expect(!text.contains(sender) && !text.contains("old-private-message-id") && !text.contains("SECRET"), "Stale result sanitized: \(phase)")
            if phase.hasPrefix("post") {
                try expect(status == .unknown, "Already-dispatched send never claimed recalled or accepted for new user")
                _ = await active.confirmSend(id: fixture.pending.id)
                let afterRetry = await fixture.network.requests
                try expect(afterRetry.count == 2, "Old send cannot be retried")
            } else if !preparing { try expect(status == .rejected, "Changed confirmation profile prevents POST") }
        }

        // Exercise the final transport boundary independently of preflight.
        SessionIsolation.activate(userID: "user-a", mode: "cloud")
        let old = SessionScope.current, network = Network()
        let transport = await network.transport
        SessionIsolation.activate(userID: "user-a", mode: "cloud")
        do {
            _ = try await transport.send(URLRequest(url: URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages/send")!), scope: old)
            throw Failure(message: "Stale scope authorized final dispatch")
        } catch is Failure { throw Failure(message: "Final dispatch fence failed") }
        catch { /* Expected scope rejection, not a mock network failure. */ }
        let finalRequests = await network.requests
        try expect(finalRequests.isEmpty, "Last MainActor authorization rejects stale generation before transport dispatch")
    }

}