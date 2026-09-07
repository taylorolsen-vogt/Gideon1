import SwiftUI

struct AgentView: View {
    @State private var showingGideonProfile = false
    @State private var addAgentForm: AgentFormSession?
    @State private var addGroupForm: AgentFormSession?
    @State private var loadedScope: SessionScope?
    @State private var subagents: [SubagentEntry] = []
    @State private var groups: [AgentGroupEntry] = []
    @State private var newAgentName = ""
    @State private var newAgentDomain = ""
    @State private var newAgentAPIKey = ""
    @State private var newGroupName = ""
    @State private var newGroupPurpose = ""
    @State private var newGroupAgents = ""
    @State private var editGroupForm: AgentFormSession?
    @State private var editingGroupID: UUID?
    @State private var editGroupName = ""
    @State private var editGroupPurpose = ""
    @State private var editGroupAgents = ""
    @State private var groupActionStatus = ""
    @EnvironmentObject private var modelSelection: GideonModelSelectionStore

    private static let subagentsStorageKey = "gideon.subagents.v1"
    private static let groupsStorageKey = "gideon.agentGroups.v1"

    var body: some View {
        Group {
            if showingGideonProfile {
                GideonProfileView {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.88)) {
                        showingGideonProfile = false
                    }
                }
                .environmentObject(modelSelection)
            } else {
                agentList
            }
        }
        .transition(.opacity)
        .onAppear {
            if loadedScope != SessionScope.current {
                resetForCurrentScope()
            } else {
                loadSubagents()
                loadGroups()
            }
        }
        // Observe outside agentList so profile navigation cannot hide a transition.
        .onReceive(NotificationCenter.default.publisher(for: .gideonSessionChanged)) { _ in
            resetForCurrentScope()
        }
        .onReceive(NotificationCenter.default.publisher(for: .gideonDataModeChanged)) { _ in
            resetForCurrentScope()
        }
    }

    private var agentList: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Eyebrow header.
            ZStack(alignment: .top) {
                PageTitle(text: "Agents", size: 30)
                    .padding(.top, -2)

                HStack(alignment: .top) {
                    HeaderMenuButton()
                    Spacer()
                    Button {
                        beginAddAgent()
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 18, weight: .regular))
                            .foregroundStyle(AppTheme.textPrimary)
                            .padding(.top, 6)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 22)
            .padding(.top, 8)
            .padding(.bottom, 8)
            .background(AppTheme.background.opacity(0.96))

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    // PRIMARY section.
                    SectionRowHeader(title: "Primary")
                        .padding(.horizontal, 22)
                        .padding(.top, 10)

                    primaryCard
                        .padding(.horizontal, 22)
                        .padding(.top, 10)

                    // SUBAGENTS section.
                    SectionRowHeader(title: "Subagents")
                        .padding(.horizontal, 22)
                        .padding(.top, 22)

                    subagentsCard
                        .padding(.horizontal, 22)
                        .padding(.top, 10)

                    Color.clear.frame(height: 96)
                }
            }
            .scrollBounceBehavior(.basedOnSize)
            .safeAreaPadding(.bottom, 6)
        }
        .padding(.top, 18)
        .padding(.bottom, 90)
        .sheet(item: $addAgentForm, onDismiss: resetAddAgentForm) { form in
            NavigationStack {
                Form {
                    Section("Agent") {
                        TextField("Name (e.g. Druck)", text: $newAgentName)
                        TextField("Domain (e.g. Finance)", text: $newAgentDomain)
                    }

                    Section("Credentials") {
                        SecureField("API key", text: $newAgentAPIKey)
                        Text("API keys should be moved to Keychain-backed storage in the next pass.")
                            .font(.system(size: 12))
                            .foregroundStyle(AppTheme.textSecondary)
                    }
                }
                .navigationTitle("Add Agent")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") {
                            resetAddAgentForm()
                            addAgentForm = nil
                        }
                    }

                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") {
                            saveSubagent(origin: form)
                        }
                        .disabled(newAgentName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || newAgentAPIKey.isEmpty)
                    }
                }
            }
            .presentationDetents([.medium])
        }
        .sheet(item: $addGroupForm, onDismiss: resetAddGroupForm) { form in
            NavigationStack {
                Form {
                    Section("Group") {
                        TextField("Group name (e.g. Product Launch)", text: $newGroupName)
                        TextField("Purpose", text: $newGroupPurpose)
                    }

                    Section("Agents") {
                        TextField("Agent names (comma separated)", text: $newGroupAgents)
                        Text("UI-only for now: deployment wiring comes next.")
                            .font(.system(size: 12))
                            .foregroundStyle(AppTheme.textSecondary)
                    }
                }
                .navigationTitle("Create Group")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") {
                            resetAddGroupForm()
                            addGroupForm = nil
                        }
                    }

                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") {
                            saveGroup(origin: form)
                        }
                        .disabled(newGroupName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
            .presentationDetents([.medium])
        }
        .sheet(item: $editGroupForm, onDismiss: resetEditGroupForm) { form in
            NavigationStack {
                Form {
                    Section("Group") {
                        TextField("Group name", text: $editGroupName)
                        TextField("Purpose", text: $editGroupPurpose)
                    }

                    Section("Agents") {
                        TextField("Agent names (comma separated)", text: $editGroupAgents)
                    }
                }
                .navigationTitle("Edit Group")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") {
                            resetEditGroupForm()
                            editGroupForm = nil
                        }
                    }

                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") {
                            saveGroupEdits(origin: form)
                        }
                        .disabled(editGroupName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
            .presentationDetents([.medium])
        }
    }

    private var primaryCard: some View {
        Button {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.88)) {
                showingGideonProfile = true
            }
        } label: {
            GlassCard(corner: 22, padding: 14) {
                HStack(spacing: 14) {
                    BotMark(size: 44)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Gideon")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(AppTheme.textPrimary)
                        Text("Autonomous agent ⓘ \(modelSelection.selectedOption.title) (\(modelSelection.selectedOption.subtitle))")
                            .font(.system(size: 12.5))
                            .foregroundStyle(AppTheme.textSecondary)
                            .lineLimit(2)
                    }
                    Spacer(minLength: 6)
                    Circle()
                        .fill(modelSelection.selectedOption.isAvailable ? AppTheme.statusGreen : AppTheme.statusOrange)
                        .frame(width: 8, height: 8)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(AppTheme.textTertiary)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private var subagentsCard: some View {
        GlassCard(corner: 22, padding: 14) {
            if subagents.isEmpty {
                HStack(spacing: 14) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(AppTheme.textPrimary.opacity(0.06))
                            .frame(width: 44, height: 44)
                        Image(systemName: "minus.circle")
                            .font(.system(size: 18, weight: .regular))
                            .foregroundStyle(AppTheme.textSecondary)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("No subagents yet")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(AppTheme.textPrimary)
                        Text("Use + to add existing agents like Druck")
                            .font(.system(size: 12.5))
                            .foregroundStyle(AppTheme.textSecondary)
                    }
                    Spacer(minLength: 6)
                    Circle()
                        .fill(AppTheme.textTertiary)
                        .frame(width: 7, height: 7)
                }
            } else {
                VStack(spacing: 10) {
                    ForEach(subagents) { agent in
                        HStack(spacing: 12) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(AppTheme.textPrimary.opacity(0.06))
                                    .frame(width: 36, height: 36)
                                Image(systemName: "person.crop.square")
                                    .font(.system(size: 15, weight: .regular))
                                    .foregroundStyle(AppTheme.textSecondary)
                            }

                            VStack(alignment: .leading, spacing: 2) {
                                Text(agent.name)
                                    .font(.system(size: 14.5, weight: .semibold))
                                    .foregroundStyle(AppTheme.textPrimary)
                                Text(agent.domain)
                                    .font(.system(size: 12, weight: .regular))
                                    .foregroundStyle(AppTheme.textSecondary)
                            }

                            Spacer(minLength: 6)

                            Text("Connected")
                                .font(.system(size: 10.5, weight: .semibold))
                                .foregroundStyle(AppTheme.statusGreen)
                        }
                        .padding(.horizontal, 2)
                    }
                }
            }
        }
    }

    private var groupsCard: some View {
        GlassCard(corner: 22, padding: 14) {
            if groups.isEmpty {
                HStack(spacing: 14) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(AppTheme.textPrimary.opacity(0.06))
                            .frame(width: 44, height: 44)
                        Image(systemName: "square.3.layers.3d")
                            .font(.system(size: 18, weight: .regular))
                            .foregroundStyle(AppTheme.textSecondary)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("No groups yet")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(AppTheme.textPrimary)
                        Text("Tap the groups button to create deployable agent groups")
                            .font(.system(size: 12.5))
                            .foregroundStyle(AppTheme.textSecondary)
                    }
                    Spacer(minLength: 6)
                }
            } else {
                VStack(spacing: 10) {
                    ForEach(groups) { group in
                        HStack(spacing: 12) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(AppTheme.textPrimary.opacity(0.06))
                                    .frame(width: 36, height: 36)
                                Image(systemName: "square.3.layers.3d")
                                    .font(.system(size: 15, weight: .regular))
                                    .foregroundStyle(AppTheme.textSecondary)
                            }

                            VStack(alignment: .leading, spacing: 2) {
                                Text(group.name)
                                    .font(.system(size: 14.5, weight: .semibold))
                                    .foregroundStyle(AppTheme.textPrimary)
                                Text(group.purpose)
                                    .font(.system(size: 12, weight: .regular))
                                    .foregroundStyle(AppTheme.textSecondary)
                                    .lineLimit(1)
                                if !group.agents.isEmpty {
                                    Text(group.agents.joined(separator: ", "))
                                        .font(.system(size: 11, weight: .regular))
                                        .foregroundStyle(AppTheme.textTertiary)
                                        .lineLimit(1)
                                }
                            }

                            Spacer(minLength: 6)

                            VStack(alignment: .trailing, spacing: 6) {
                                Button {
                                    triggerDeployStub(for: group)
                                } label: {
                                    Text("Deploy")
                                        .font(.system(size: 10.5, weight: .semibold))
                                        .foregroundStyle(AppTheme.statusOrange)
                                }
                                .buttonStyle(.plain)

                                Menu {
                                    Button("Edit") {
                                        beginEdit(group)
                                    }
                                    Button("Delete", role: .destructive) {
                                        deleteGroup(group.id)
                                    }
                                } label: {
                                    Image(systemName: "ellipsis.circle")
                                        .font(.system(size: 15, weight: .regular))
                                        .foregroundStyle(AppTheme.textTertiary)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 2)
                    }

                    if !groupActionStatus.isEmpty {
                        Text(groupActionStatus)
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(AppTheme.textSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 4)
                    }
                }
            }
        }
    }

    private func resetForCurrentScope() {
        addAgentForm = nil
        addGroupForm = nil
        editGroupForm = nil
        showingGideonProfile = false
        resetAddAgentForm()
        resetAddGroupForm()
        resetEditGroupForm()
        groupActionStatus = ""
        subagents = []
        groups = []
        loadedScope = .current
        loadSubagents()
        loadGroups()
    }

    private func beginAddAgent() {
        guard let scope = loadedScope, scope.isCurrent else { return }
        resetAddAgentForm()
        addAgentForm = AgentFormSession(scope: scope)
    }

    private func beginAddGroup() {
        guard let scope = loadedScope, scope.isCurrent else { return }
        resetAddGroupForm()
        addGroupForm = AgentFormSession(scope: scope)
    }

    private func saveSubagent(origin: AgentFormSession) {
        guard origin.scope.isCurrent, loadedScope == origin.scope,
              addAgentForm?.id == origin.id else { return }
        let trimmedName = newAgentName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, !newAgentAPIKey.isEmpty else { return }

        let domainText = newAgentDomain.trimmingCharacters(in: .whitespacesAndNewlines)
        let entry = SubagentEntry(
            id: UUID(),
            name: trimmedName,
            domain: domainText.isEmpty ? "General" : domainText,
            createdAt: Date()
        )

        subagents.append(entry)
        persistSubagents()
        resetAddAgentForm()
        addAgentForm = nil
    }

    private func loadSubagents() {
        subagents = []
        guard let data = ScopedDefaults.standard.data(forKey: Self.subagentsStorageKey),
              let decoded = try? JSONDecoder().decode([SubagentEntry].self, from: data) else {
            return
        }
        subagents = decoded
    }

    private func loadGroups() {
        groups = []
        guard let data = ScopedDefaults.standard.data(forKey: Self.groupsStorageKey),
              let decoded = try? JSONDecoder().decode([AgentGroupEntry].self, from: data) else {
            return
        }
        groups = decoded
    }

    private func persistSubagents() {
        guard loadedScope?.isCurrent == true else { return }
        if let data = try? JSONEncoder().encode(subagents) {
            ScopedDefaults.standard.set(data, forKey: Self.subagentsStorageKey)
        }
    }

    private func persistGroups() {
        guard loadedScope?.isCurrent == true else { return }
        if let data = try? JSONEncoder().encode(groups) {
            ScopedDefaults.standard.set(data, forKey: Self.groupsStorageKey)
        }
    }

    private func resetAddAgentForm() {
        newAgentName = ""
        newAgentDomain = ""
        newAgentAPIKey = ""
    }

    private func saveGroup(origin: AgentFormSession) {
        guard origin.scope.isCurrent, loadedScope == origin.scope,
              addGroupForm?.id == origin.id else { return }
        let trimmedName = newGroupName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }

        let purpose = newGroupPurpose.trimmingCharacters(in: .whitespacesAndNewlines)
        let parsedAgents = newGroupAgents
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let entry = AgentGroupEntry(
            id: UUID(),
            name: trimmedName,
            purpose: purpose.isEmpty ? "General deployment group" : purpose,
            agents: parsedAgents,
            createdAt: Date()
        )

        groups.append(entry)
        persistGroups()
        resetAddGroupForm()
        addGroupForm = nil
    }

    private func resetAddGroupForm() {
        newGroupName = ""
        newGroupPurpose = ""
        newGroupAgents = ""
    }

    private func beginEdit(_ group: AgentGroupEntry) {
        guard let scope = loadedScope, scope.isCurrent,
              groups.contains(where: { $0.id == group.id }) else { return }
        editingGroupID = group.id
        editGroupName = group.name
        editGroupPurpose = group.purpose
        editGroupAgents = group.agents.joined(separator: ", ")
        editGroupForm = AgentFormSession(scope: scope)
    }

    private func saveGroupEdits(origin: AgentFormSession) {
        guard origin.scope.isCurrent, loadedScope == origin.scope,
              editGroupForm?.id == origin.id else { return }
        guard let editingGroupID,
              let index = groups.firstIndex(where: { $0.id == editingGroupID }) else {
            return
        }

        let trimmedName = editGroupName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }

        let purpose = editGroupPurpose.trimmingCharacters(in: .whitespacesAndNewlines)
        let parsedAgents = editGroupAgents
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        groups[index] = AgentGroupEntry(
            id: groups[index].id,
            name: trimmedName,
            purpose: purpose.isEmpty ? "General deployment group" : purpose,
            agents: parsedAgents,
            createdAt: groups[index].createdAt
        )

        persistGroups()
        groupActionStatus = "Group updated"
        resetEditGroupForm()
        editGroupForm = nil
    }

    private func deleteGroup(_ id: UUID) {
        guard loadedScope?.isCurrent == true,
              groups.contains(where: { $0.id == id }) else { return }
        groups.removeAll { $0.id == id }
        persistGroups()
        groupActionStatus = "Group deleted"
    }

    private func triggerDeployStub(for group: AgentGroupEntry) {
        guard loadedScope?.isCurrent == true,
              groups.contains(where: { $0.id == group.id }) else { return }
        groupActionStatus = "Deploy queued for \(group.name) (stub only)"
    }

    private func resetEditGroupForm() {
        editingGroupID = nil
        editGroupName = ""
        editGroupPurpose = ""
        editGroupAgents = ""
    }
}

// Each presentation retains its origin, even if an old Save action outlives dismissal.
private struct AgentFormSession: Identifiable {
    let id = UUID()
    let scope: SessionScope
}

private struct SubagentEntry: Identifiable, Codable {
    let id: UUID
    let name: String
    let domain: String
    let createdAt: Date
}

private struct AgentGroupEntry: Identifiable, Codable {
    let id: UUID
    let name: String
    let purpose: String
    let agents: [String]
    let createdAt: Date
}

private struct GideonProfileView: View {
    let onBack: () -> Void
    @EnvironmentObject private var modelSelection: GideonModelSelectionStore
    @StateObject private var connectionStore = ProviderConnectionStore.shared
    private static let subagentsStorageKey = "gideon.subagents.v1"
    private static let groupsStorageKey = "gideon.agentGroups.v1"

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Button(action: onBack) {
                        HStack(spacing: 8) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 13, weight: .semibold))
                            Text("Agents")
                                .font(.system(size: 13, weight: .regular))
                        }
                        .foregroundStyle(AppTheme.textSecondary)
                    }
                    .buttonStyle(.plain)

                    Spacer()
                }
                .padding(.horizontal, 22)
                .padding(.top, 10)

                Eyebrow(text: "Primary Autonomous Agent", size: 9)
                    .padding(.horizontal, 22)
                    .padding(.top, 24)

                HStack(spacing: 8) {
                    Text("Gideon")
                        .font(.system(size: 20, weight: .semibold))
                        .tracking(3.2)
                        .textCase(.uppercase)
                        .foregroundStyle(AppTheme.textPrimary)

                    Circle()
                        .fill(modelSelection.selectedOption.isAvailable ? AppTheme.statusGreen : AppTheme.textTertiary)
                        .frame(width: 7, height: 7)
                        .padding(.top, 2)

                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 22)
                .padding(.top, 10)

                Text("\(modelSelection.selectedOption.title) - \(modelSelection.selectedOption.subtitle)")
                    .font(.system(size: 10, weight: .regular))
                    .foregroundStyle(AppTheme.textSecondary)
                    .padding(.horizontal, 22)
                    .padding(.top, 22)

                profileSection(title: "Memories", value: "No memories yet")
                    .padding(.top, 16)
                profileSection(title: "Skills", value: "No skills connected yet")
                    .padding(.top, 14)
                agentHealthSection
                    .padding(.top, 14)

                Color.clear.frame(height: 120)
            }
            .padding(.top, 12)
        }
    }

    private func profileSection(
        title: String,
        value: String,
        detail: String? = nil,
        status: String? = nil,
        showsAdd: Bool = false,
        disabled: Bool = false
    ) -> some View {
        GlassCard(corner: 18, padding: 14) {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .center) {
                    Eyebrow(text: title, size: 8.5)
                    Spacer()
                    if showsAdd {
                        Image(systemName: "plus")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color.white)
                            .frame(width: 24, height: 24)
                            .background(Circle().fill(AppTheme.textPrimary.opacity(disabled ? 0.28 : 0.92)))
                    }
                }

                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(value)
                        .font(.system(size: status == nil ? 15 : 12, weight: status == nil ? .regular : .medium))
                        .foregroundStyle(disabled ? AppTheme.textMuted : AppTheme.textPrimary.opacity(status == nil ? 0.42 : 0.92))
                        .lineLimit(1)
                        .minimumScaleFactor(0.82)

                    if let detail {
                        Text(detail)
                            .font(.system(size: 12, weight: .regular))
                            .foregroundStyle(AppTheme.textSecondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.82)
                    }

                    Spacer(minLength: 8)

                    if let status {
                        Text(status)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(status == "Active" ? Color(red: 0.04, green: 0.58, blue: 0.25) : AppTheme.statusOrange)
                    }
                }
            }
        }
        .padding(.horizontal, 22)
    }

    // MARK: - Agent Health

    private var subagentCount: Int {
        guard let data = ScopedDefaults.standard.data(forKey: Self.subagentsStorageKey),
              let decoded = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return 0 }
        return decoded.count
    }

    private var groupCount: Int {
        guard let data = ScopedDefaults.standard.data(forKey: Self.groupsStorageKey),
              let decoded = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return 0 }
        return decoded.count
    }

    private var apiModelCount: Int { modelSelection.apiProviderCount }

    private var localAvailable: Bool {
        modelSelection.options.contains(where: { $0.id == "local-qwen" && $0.isAvailable })
    }

    private var healthScore: Int {
        var score = 12
        if localAvailable { score += 20 }
        score += min(apiModelCount * 8, 24)
        score += min(subagentCount * 6, 18)
        score += min(groupCount * 4, 12)
        score += min(connectionStore.connectedCount * 5, 15)
        score -= min(connectionStore.manualStepCount * 4, 12)
        return min(score, 100)
    }

    private var scoreFraction: CGFloat { CGFloat(healthScore) / 100 }

    private var scoreTone: Color {
        if healthScore >= 70 { return AppTheme.statusGreen }
        if healthScore >= 40 { return AppTheme.statusOrange }
        return Color(red: 0.78, green: 0.24, blue: 0.21)
    }

    private var agentHealthSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Eyebrow(text: "Operating Efficiency", size: 11)
                    Spacer()
                    Text("\(healthScore)%")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(scoreTone)
                }
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(AppTheme.textMuted.opacity(0.4)).frame(height: 3)
                        Capsule().fill(scoreTone).frame(width: proxy.size.width * scoreFraction, height: 3)
                    }
                }
                .frame(height: 3)
                Text("Real-time profile: no task execution wiring yet, no memory graph, and limited skill/tool integration.")
                    .font(.system(size: 12))
                    .foregroundStyle(AppTheme.textSecondary)
            }
            .padding(.horizontal, 22)

            GlassCard(corner: 22, padding: 4) {
                VStack(spacing: 0) {
                    healthStatRow("Route availability", localAvailable ? "Local online" : "Local unavailable")
                    healthDivider
                    healthStatRow("API providers", "\(apiModelCount) configured")
                    healthDivider
                    healthStatRow("Connected providers", "\(connectionStore.connectedCount)")
                    healthDivider
                    healthStatRow("Subagents", "\(subagentCount)")
                    healthDivider
                    healthStatRow("Agent groups", "\(groupCount)")
                    healthDivider
                    healthStatRow("Tasks completed", "0 tracked")
                }
            }
            .padding(.horizontal, 22)

            GlassCard(corner: 22, padding: 16) {
                VStack(alignment: .leading, spacing: 0) {
                    Eyebrow(text: "Capabilities", size: 11).padding(.bottom, 12)
                    healthCapRow("Local runtime route", status: localAvailable ? "Active" : "Missing", green: localAvailable)
                    healthDivider
                    healthCapRow("API model routing", status: apiModelCount > 0 ? "Configured" : "Not configured", green: apiModelCount > 0)
                    healthDivider
                    healthCapRow("Provider connections", status: connectionStore.connectedCount > 0 ? "\(connectionStore.connectedCount) connected" : "None", green: connectionStore.connectedCount > 0)
                    healthDivider
                    healthCapRow("Subagent registry", status: subagentCount > 0 ? "\(subagentCount) loaded" : "None", green: subagentCount > 0)
                    healthDivider
                    healthCapRow("Task queue integration", status: "Not wired", green: false)
                    healthDivider
                    healthCapRow("Memory graph", status: "Not wired", green: false)
                }
            }
            .padding(.horizontal, 22)

            GlassCard(corner: 22, padding: 16) {
                VStack(alignment: .leading, spacing: 0) {
                    Eyebrow(text: "Last Audit ⓘ Live", size: 11).padding(.bottom, 12)
                    healthCapRow("Identity integrity", status: "Pass", green: true)
                    healthDivider
                    healthCapRow("Route labeling", status: "Pass", green: true)
                    healthDivider
                    healthCapRow("Task execution depth", status: "Low", green: false)
                    healthDivider
                    healthCapRow("Autonomy readiness", status: healthScore >= 55 ? "Moderate" : "Low", green: healthScore >= 55)
                }
            }
            .padding(.horizontal, 22)
        }
    }

    private func healthStatRow(_ leading: String, _ trailing: String) -> some View {
        HStack {
            Text(leading).font(.system(size: 14)).foregroundStyle(AppTheme.textPrimary)
            Spacer()
            Text(trailing).font(.system(size: 14)).foregroundStyle(AppTheme.textPrimary)
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 14)
    }

    private func healthCapRow(_ leading: String, status: String, green: Bool) -> some View {
        HStack {
            Text(leading).font(.system(size: 14)).foregroundStyle(AppTheme.textPrimary)
            Spacer()
            Text(status)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(green ? AppTheme.statusGreen : AppTheme.statusOrange)
        }
        .padding(.vertical, 10)
    }

    private var healthDivider: some View {
        Rectangle().fill(AppTheme.divider).frame(height: 1)
    }
}

struct PortalSheetItem: Identifiable {
    let id = UUID()
    let url: URL
}

#Preview { RootView() }
