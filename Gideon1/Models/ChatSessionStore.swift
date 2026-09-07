import Foundation

struct ChatMessage: Identifiable {
    enum Role {
        case user
        case assistant
    }

    let id = UUID()
    let role: Role
    let text: String
    let timestamp: Date = Date()
}

@MainActor
final class ChatSessionStore: ObservableObject {
    @Published var composerText: String = ""
    @Published var thread: [ChatMessage] = []
    @Published var isGenerating: Bool = false

    private var generationTask: Task<Void, Never>?
    private var observerTokens: [NSObjectProtocol] = []
    private var loadedScope = SessionScope.current

    init() {
        for name in [Notification.Name.gideonSessionChanged, .gideonDataModeChanged] {
            observerTokens.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.resetForCurrentScope() }
            })
        }
    }

    private func resetForCurrentScope() {
        generationTask?.cancel()
        generationTask = nil
        composerText = ""
        thread = []
        isGenerating = false
        loadedScope = .current
    }

    isolated deinit {
        generationTask?.cancel()
        for token in observerTokens { NotificationCenter.default.removeObserver(token) }
    }

    func sendCurrentMessage() {
        guard loadedScope.isCurrent else {
            resetForCurrentScope()
            return
        }
        let scope = SessionScope.current
        let prompt = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, !isGenerating else { return }

        composerText = ""
        thread.append(.init(role: .user, text: prompt))
        isGenerating = true

        // Exclude the current user message since `prompt` carries it separately.
        let historyTurns = thread.dropLast().map { item in
            HarnessTurn(role: item.role == .user ? .user : .assistant, text: item.text)
        }

        generationTask?.cancel()
        generationTask = Task { [weak self] in
            guard let self, scope.isCurrent else { return }
            let result = await GideonAgentHarness.shared.respond(to: prompt, history: historyTurns)
            guard scope.isCurrent else { return }
            self.thread.append(.init(role: .assistant, text: result.text))
            self.isGenerating = false
        }
    }
}

enum ProjectStage: String, CaseIterable, Codable, Identifiable {
    case active
    case inDesign
    case ventures
    case whenTimePermits
    case ideas
    case completed

    var id: String { rawValue }

    var title: String {
        switch self {
        case .active:
            return "Active"
        case .inDesign:
            return "In Design"
        case .ventures:
            return "Ventures"
        case .whenTimePermits:
            return "When Time Permits"
        case .ideas:
            return "Ideas"
        case .completed:
            return "Completed"
        }
    }
}

enum ActivityState: String, Codable {
    case active
    case backlog
    case next
    case completed
    case blocked
}

struct ProjectRecord: Identifiable, Codable {
    let id: UUID
    var name: String
    var detail: String
    var summary: String
    var stage: ProjectStage
    var groupName: String?
    var source: String
    var createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case detail
        case summary
        case stage
        case groupName
        case source
        case createdAt
    }

    init(id: UUID, name: String, detail: String, summary: String, stage: ProjectStage, groupName: String?, source: String, createdAt: Date) {
        self.id = id
        self.name = name
        self.detail = detail
        self.summary = summary
        self.stage = stage
        self.groupName = groupName
        self.source = source
        self.createdAt = createdAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        detail = try container.decode(String.self, forKey: .detail)
        summary = try container.decodeIfPresent(String.self, forKey: .summary) ?? "No summary yet."
        stage = try container.decode(ProjectStage.self, forKey: .stage)
        groupName = try container.decodeIfPresent(String.self, forKey: .groupName)
        source = try container.decode(String.self, forKey: .source)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(detail, forKey: .detail)
        try container.encode(summary, forKey: .summary)
        try container.encode(stage, forKey: .stage)
        try container.encodeIfPresent(groupName, forKey: .groupName)
        try container.encode(source, forKey: .source)
        try container.encode(createdAt, forKey: .createdAt)
    }
}

struct ActivityRecord: Identifiable, Codable {
    let id: UUID
    var title: String
    var detail: String
    var state: ActivityState
    var source: String
    var assignee: String?
    var projectID: UUID?
    var createdAt: Date

    var normalizedState: ActivityState {
        state == .next ? .backlog : state
    }
}

private struct SupabaseProjectDTO: Codable {
    let id: UUID
    let userID: String
    let name: String
    let detail: String
    let summary: String?
    let stage: String
    let groupName: String?
    let source: String
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case userID = "user_id"
        case name
        case detail
        case summary
        case stage
        case groupName = "group_name"
        case source
        case createdAt = "created_at"
    }

    init(record: ProjectRecord, userID: String) {
        self.id = record.id
        self.userID = userID
        self.name = record.name
        self.detail = record.detail
        self.summary = record.summary
        self.stage = record.stage.rawValue
        self.groupName = record.groupName
        self.source = record.source
        self.createdAt = record.createdAt
    }

    func toRecord() -> ProjectRecord {
        ProjectRecord(
            id: id,
            name: name,
            detail: detail,
            summary: summary ?? detail,
            stage: ProjectStage(rawValue: stage) ?? .active,
            groupName: groupName,
            source: source,
            createdAt: createdAt
        )
    }
}

private struct SupabaseActivityDTO: Codable {
    let id: UUID
    let userID: String
    let title: String
    let detail: String
    let state: String
    let source: String?
    let assignee: String?
    let projectID: UUID?
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case userID = "user_id"
        case title
        case detail
        case state
        case source
        case assignee
        case projectID = "project_id"
        case createdAt = "created_at"
    }

    init(record: ActivityRecord, userID: String) {
        self.id = record.id
        self.userID = userID
        self.title = record.title
        self.detail = record.detail
        self.state = record.state == .next ? ActivityState.backlog.rawValue : record.state.rawValue
        self.source = record.source
        self.assignee = record.assignee
        self.projectID = record.projectID
        self.createdAt = record.createdAt
    }

    func toRecord() -> ActivityRecord {
        ActivityRecord(
            id: id,
            title: title,
            detail: detail,
            state: ActivityState(rawValue: state) ?? .active,
            source: source ?? "Gideon",
            assignee: assignee,
            projectID: projectID,
            createdAt: createdAt
        )
    }
}

@MainActor
final class AppProjectStore: ObservableObject {
    static let shared = AppProjectStore()

    @Published private(set) var projects: [ProjectRecord] = []
    private static let storageKey = "gideon.projects.v2"
    private static let demoCleanupKey = "gideon.projects.demoCleanup.v1"
    private var observerTokens: [NSObjectProtocol] = []
    private var loadedScope: SessionScope?

    private init() {
        load()
        removeDemoDataIfNeeded()
        registerObservers()
        let scope = SessionScope.current
        Task { await reloadFromCurrentMode(expectedScope: scope) }
    }

    func createProject(name: String, detail: String, stage: ProjectStage = .active, source: String = "Gideon") {
        createProject(name: name, detail: detail, stage: stage, groupName: nil, source: source)
    }

    func createProject(name: String, detail: String, stage: ProjectStage = .active, groupName: String?, source: String = "Gideon") {
        guard loadedScope?.isCurrent == true else { return }
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty else { return }

        let cleanDetail = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanGroup = groupName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let canonicalGroup = canonicalGroupName(for: cleanGroup)
        let finalGroup = canonicalGroup.isEmpty ? nil : canonicalGroup

        if let existingIndex = projects.firstIndex(where: { $0.name.caseInsensitiveCompare(cleanName) == .orderedSame }) {
            projects[existingIndex].detail = cleanDetail.isEmpty ? "Created from chat" : cleanDetail
            if projects[existingIndex].summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                projects[existingIndex].summary = defaultSummary(for: cleanName, groupName: finalGroup)
            }
            projects[existingIndex].stage = stage
            projects[existingIndex].groupName = finalGroup
            projects[existingIndex].source = source
            persist()
            return
        }

        projects.insert(
            ProjectRecord(
                id: UUID(),
                name: cleanName,
                detail: cleanDetail.isEmpty ? "Created from chat" : cleanDetail,
                summary: defaultSummary(for: cleanName, groupName: finalGroup),
                stage: stage,
                groupName: finalGroup,
                source: source,
                createdAt: Date()
            ),
            at: 0
        )
        persist()
    }

    func project(id: UUID) -> ProjectRecord? {
        guard loadedScope?.isCurrent == true else { return nil }
        return projects.first(where: { $0.id == id })
    }

    func updateProject(id: UUID, name: String, detail: String, summary: String, groupName: String?) {
        guard loadedScope?.isCurrent == true else { return }
        guard let index = projects.firstIndex(where: { $0.id == id }) else { return }
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty else { return }

        let cleanDetail = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanSummary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanGroup = groupName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let canonicalGroup = canonicalGroupName(for: cleanGroup)
        projects[index].name = cleanName
        projects[index].detail = cleanDetail.isEmpty ? "Updated from Projects" : cleanDetail
        projects[index].summary = cleanSummary.isEmpty ? defaultSummary(for: cleanName, groupName: canonicalGroup.isEmpty ? nil : canonicalGroup) : cleanSummary
        projects[index].groupName = canonicalGroup.isEmpty ? nil : canonicalGroup
        persist()
    }

    func markCompleted(id: UUID) {
        guard loadedScope?.isCurrent == true else { return }
        guard let index = projects.firstIndex(where: { $0.id == id }) else { return }
        projects[index].stage = .completed
        persist()
    }

    func deleteProject(id: UUID) {
        guard loadedScope?.isCurrent == true else { return }
        projects.removeAll { $0.id == id }
        persist()
    }

    func activeProjects() -> [ProjectRecord] {
        guard loadedScope?.isCurrent == true else { return [] }
        return projects
            .filter { $0.stage == .active }
            .sorted { $0.createdAt > $1.createdAt }
    }

    func groups() -> [String] {
        let grouped = activeProjects().compactMap { project -> String? in
            guard let raw = project.groupName?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
                return nil
            }
            return raw
        }
        return Array(Set(grouped)).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    func projects(inGroup groupName: String) -> [ProjectRecord] {
        let target = groupName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else { return [] }
        return activeProjects()
            .filter { ($0.groupName ?? "").caseInsensitiveCompare(target) == .orderedSame }
            .sorted { $0.createdAt > $1.createdAt }
    }

    private func canonicalGroupName(for candidate: String) -> String {
        let clean = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return "" }
        if let existing = projects.compactMap(\.groupName).first(where: { $0.caseInsensitiveCompare(clean) == .orderedSame }) {
            return existing
        }
        return clean
    }

    private func defaultSummary(for name: String, groupName: String?) -> String {
        if let groupName, !groupName.isEmpty {
            return "\(name) is part of \(groupName), with shared context across related projects."
        }
        return "\(name) is an active standalone project in Gideon."
    }

    private func persist() {
        guard loadedScope?.isCurrent == true else { return }
        let scope = SessionScope.current
        persistLocal()
        if scope.canSyncCloud {
            Task { [snapshot = projects] in
                guard scope.isCurrent else { return }
                await persistCloud(snapshot: snapshot, scope: scope)
            }
        }
    }

    private func load() {
        projects = []
        loadedScope = .current
        guard let data = ScopedDefaults.standard.data(forKey: Self.storageKey),
              let decoded = try? JSONDecoder().decode([ProjectRecord].self, from: data) else {
            return
        }
        projects = decoded
    }

    private func persistLocal() {
        guard loadedScope?.isCurrent == true, let data = try? JSONEncoder().encode(projects) else { return }
        ScopedDefaults.standard.set(data, forKey: Self.storageKey)
    }

    private func registerObservers() {
        let center = NotificationCenter.default
        observerTokens.append(
            center.addObserver(forName: .gideonDataModeChanged, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.load()
                    self.removeDemoDataIfNeeded()
                    let scope = SessionScope.current
                    Task { await self.reloadFromCurrentMode(expectedScope: scope) }
                }
            }
        )
        observerTokens.append(
            center.addObserver(forName: .gideonSessionChanged, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.load()
                    self.removeDemoDataIfNeeded()
                    let scope = SessionScope.current
                    Task { await self.reloadFromCurrentMode(expectedScope: scope) }
                }
            }
        )
    }

    func reloadFromCurrentMode(expectedScope: SessionScope? = nil) async {
        let scope = expectedScope ?? .current
        guard scope.isCurrent else { return }
        load()
        removeDemoDataIfNeeded()
        if scope.canSyncCloud { await loadCloud(scope: scope) }
    }

    private func loadCloud(scope: SessionScope) async {
        guard scope.isCurrent, scope.canSyncCloud,
              let userID = scope.userID,
              let token = AppSessionStore.shared.currentAccessToken,
              let url = URL(string: "\(AppSessionStore.supabaseRESTURL)/projects?user_id=eq.\(userID)&select=*&order=created_at.desc") else {
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
            let rows = try decoder.decode([SupabaseProjectDTO].self, from: data)
            let cloudProjects = rows.filter { $0.userID.lowercased() == userID.lowercased() }.map { $0.toRecord() }
            projects = cloudProjects.filter { !Self.looksLikeDemoProject($0) }
            persistLocal()
        } catch {
            // Keep local cache if cloud read fails.
        }
    }

    private func removeDemoDataIfNeeded() {
        guard loadedScope?.isCurrent == true else { return }
        if ScopedDefaults.standard.bool(forKey: Self.demoCleanupKey) {
            return
        }

        let cleaned = projects.filter { !Self.looksLikeDemoProject($0) }
        if cleaned.count != projects.count {
            projects = cleaned
            persistLocal()
        }

        ScopedDefaults.standard.set(true, forKey: Self.demoCleanupKey)
    }

    private static func looksLikeDemoProject(_ record: ProjectRecord) -> Bool {
        let source = record.source.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if ["demo", "sample", "placeholder", "mock"].contains(source) {
            return true
        }

        let name = record.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if name.hasPrefix("demo ") || name.hasPrefix("sample ") || name.contains("placeholder") {
            return true
        }
        return false
    }

    private func persistCloud(snapshot: [ProjectRecord], scope: SessionScope) async {
        guard scope.isCurrent, scope.canSyncCloud,
              let userID = scope.userID,
              let token = AppSessionStore.shared.currentAccessToken,
              !snapshot.isEmpty,
              let insertURL = URL(string: "\(AppSessionStore.supabaseRESTURL)/projects?on_conflict=user_id,id") else {
            return
        }

        do {
            let payload = snapshot.map { SupabaseProjectDTO(record: $0, userID: userID) }
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
                print("[Gideon] project cloud insert failed for user \(userID)")
                return
            }
        } catch {
            print("[Gideon] project cloud sync error: \(error.localizedDescription)")
        }
    }
}

@MainActor
final class AppActivityStore: ObservableObject {
    static let shared = AppActivityStore()

    @Published private(set) var items: [ActivityRecord] = []
    private static let storageKey = "gideon.activity.v2"
    private static let demoCleanupKey = "gideon.activity.demoCleanup.v1"
    private var observerTokens: [NSObjectProtocol] = []
    private var loadedScope: SessionScope?

    private init() {
        load()
        removeDemoDataIfNeeded()
        registerObservers()
        let scope = SessionScope.current
        Task { await reloadFromCurrentMode(expectedScope: scope) }
    }

    func add(title: String, detail: String, state: ActivityState = .active, source: String = "Gideon", assignee: String? = nil, projectID: UUID? = nil) {
        guard loadedScope?.isCurrent == true else { return }
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTitle.isEmpty else { return }
        let cleanSource = source.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalSource = cleanSource.isEmpty ? "Gideon" : cleanSource
        let cleanAssignee = assignee?.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalState: ActivityState = state == .next ? .backlog : state

        items.insert(
            ActivityRecord(
                id: UUID(),
                title: cleanTitle,
                detail: detail,
                state: finalState,
                source: finalSource,
                assignee: cleanAssignee?.isEmpty == true ? nil : cleanAssignee,
                projectID: projectID,
                createdAt: Date()
            ),
            at: 0
        )
        persist()
    }

    func createTask(title: String, summary: String, state: ActivityState, assignee: String?, source: String = "User") {
        add(title: title, detail: summary, state: state, source: source, assignee: assignee, projectID: nil)
    }

    func list(state: ActivityState) -> [ActivityRecord] {
        guard loadedScope?.isCurrent == true else { return [] }
        return items.filter {
            if state == .backlog {
                return $0.state == .backlog || $0.state == .next
            }
            return $0.state == state
        }
    }

    func backlogItems() -> [ActivityRecord] {
        list(state: .backlog)
    }

    func activeItems() -> [ActivityRecord] {
        list(state: .active)
    }

    func completedItems() -> [ActivityRecord] {
        list(state: .completed)
    }

    func blockedItems() -> [ActivityRecord] {
        list(state: .blocked)
    }

    func updateState(id: UUID, to state: ActivityState) {
        guard loadedScope?.isCurrent == true else { return }
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].state = (state == .next ? .backlog : state)
        if items[index].state == .blocked, (items[index].assignee ?? "").isEmpty {
            items[index].assignee = "Human"
        }
        persist()
    }

    func completeTask(named title: String) -> Bool {
        guard loadedScope?.isCurrent == true else { return false }
        let target = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !target.isEmpty else { return false }

        if let exact = items.firstIndex(where: { $0.title.lowercased() == target }) {
            items[exact].state = .completed
            persist()
            return true
        }
        if let fuzzy = items.firstIndex(where: { $0.title.lowercased().contains(target) }) {
            items[fuzzy].state = .completed
            persist()
            return true
        }
        return false
    }

    func completeTask(id: UUID) {
        updateState(id: id, to: .completed)
    }

    func activateTask(id: UUID) {
        updateState(id: id, to: .active)
    }

    func moveToBacklog(id: UUID) {
        updateState(id: id, to: .backlog)
    }

    func blockTask(named title: String, assignee: String = "Human") -> Bool {
        guard loadedScope?.isCurrent == true else { return false }
        let target = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !target.isEmpty else { return false }

        if let exact = items.firstIndex(where: { $0.title.lowercased() == target }) {
            items[exact].state = .blocked
            items[exact].assignee = assignee
            persist()
            return true
        }
        if let fuzzy = items.firstIndex(where: { $0.title.lowercased().contains(target) }) {
            items[fuzzy].state = .blocked
            items[fuzzy].assignee = assignee
            persist()
            return true
        }
        return false
    }

    func related(to project: ProjectRecord) -> [ActivityRecord] {
          guard loadedScope?.isCurrent == true,
              AppProjectStore.shared.project(id: project.id) != nil else { return [] }
        let keyed = items.filter { $0.projectID == project.id }
        if !keyed.isEmpty {
            return keyed
        }

        let token = project.name.lowercased()
        return items.filter {
            $0.title.lowercased().contains(token) || $0.detail.lowercased().contains(token)
        }
    }

    func removeAll(forProjectID projectID: UUID) {
        guard loadedScope?.isCurrent == true else { return }
        items.removeAll { $0.projectID == projectID }
        persist()
    }

    private func persist() {
        guard loadedScope?.isCurrent == true else { return }
        let scope = SessionScope.current
        persistLocal()
        if scope.canSyncCloud {
            Task { [snapshot = items] in
                guard scope.isCurrent else { return }
                await persistCloud(snapshot: snapshot, scope: scope)
            }
        }
    }

    private func load() {
        items = []
        loadedScope = .current
        guard let data = ScopedDefaults.standard.data(forKey: Self.storageKey),
              let decoded = try? JSONDecoder().decode([ActivityRecord].self, from: data) else {
            return
        }
        items = decoded
    }

    private func persistLocal() {
        guard loadedScope?.isCurrent == true, let data = try? JSONEncoder().encode(items) else { return }
        ScopedDefaults.standard.set(data, forKey: Self.storageKey)
    }

    private func registerObservers() {
        let center = NotificationCenter.default
        observerTokens.append(
            center.addObserver(forName: .gideonDataModeChanged, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.load()
                    self.removeDemoDataIfNeeded()
                    let scope = SessionScope.current
                    Task { await self.reloadFromCurrentMode(expectedScope: scope) }
                }
            }
        )
        observerTokens.append(
            center.addObserver(forName: .gideonSessionChanged, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.load()
                    self.removeDemoDataIfNeeded()
                    let scope = SessionScope.current
                    Task { await self.reloadFromCurrentMode(expectedScope: scope) }
                }
            }
        )
    }

    private func reloadFromCurrentMode(expectedScope: SessionScope? = nil) async {
        let scope = expectedScope ?? .current
        guard scope.isCurrent else { return }
        load()
        removeDemoDataIfNeeded()
        if scope.canSyncCloud { await loadCloud(scope: scope) }
    }

    private func loadCloud(scope: SessionScope) async {
        guard scope.isCurrent, scope.canSyncCloud,
              let userID = scope.userID,
              let token = AppSessionStore.shared.currentAccessToken,
              let url = URL(string: "\(AppSessionStore.supabaseRESTURL)/activity_items?user_id=eq.\(userID)&select=*&order=created_at.desc") else {
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
            let rows = try decoder.decode([SupabaseActivityDTO].self, from: data)
            items = rows.filter { $0.userID.lowercased() == userID.lowercased() }.map { $0.toRecord() }
            items = items.filter { !Self.looksLikeDemoActivity($0) }
            persistLocal()
        } catch {
            // Keep local cache if cloud read fails.
        }
    }

    private func removeDemoDataIfNeeded() {
        guard loadedScope?.isCurrent == true else { return }
        if ScopedDefaults.standard.bool(forKey: Self.demoCleanupKey) {
            return
        }

        let cleaned = items.filter { !Self.looksLikeDemoActivity($0) }
        if cleaned.count != items.count {
            items = cleaned
            persistLocal()
        }

        ScopedDefaults.standard.set(true, forKey: Self.demoCleanupKey)
    }

    private static func looksLikeDemoActivity(_ record: ActivityRecord) -> Bool {
        let source = record.source.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if ["demo", "sample", "placeholder", "mock"].contains(source) {
            return true
        }

        let title = record.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if title.hasPrefix("demo ") || title.hasPrefix("sample ") || title.contains("placeholder") {
            return true
        }
        return false
    }

    private func persistCloud(snapshot: [ActivityRecord], scope: SessionScope) async {
        guard scope.isCurrent, scope.canSyncCloud,
              let userID = scope.userID,
              let token = AppSessionStore.shared.currentAccessToken,
              !snapshot.isEmpty,
              let insertURL = URL(string: "\(AppSessionStore.supabaseRESTURL)/activity_items?on_conflict=user_id,id") else {
            return
        }

        do {
            let payload = snapshot.map { SupabaseActivityDTO(record: $0, userID: userID) }
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
                print("[Gideon] activity cloud insert failed for user \(userID)")
                return
            }
        } catch {
            print("[Gideon] activity cloud sync error: \(error.localizedDescription)")
        }
    }
}
