import SwiftUI

struct ProjectView: View {
    @StateObject private var projectStore = AppProjectStore.shared
    @StateObject private var activityStore = AppActivityStore.shared

    @State private var showingAddSheet = false
    @State private var projectNameInput = ""
    @State private var projectDetailInput = ""
    @State private var projectGroupInput = ""
    @State private var activeSheet: ActiveSheet?

    private enum ActiveSheet: Identifiable {
        case project(UUID)
        case group(String)

        var id: String {
            switch self {
            case .project(let id):
                return "project-\(id.uuidString)"
            case .group(let name):
                return "group-\(name.lowercased())"
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header.
            ZStack(alignment: .top) {
                PageTitle(text: "Projects", size: 30)
                    .padding(.top, -2)

                HStack(alignment: .top) {
                    HeaderMenuButton()
                    Spacer()
                    Button {
                        showingAddSheet = true
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
                    SectionRowHeader(title: "Active")
                        .padding(.horizontal, 22)
                        .padding(.top, 10)
                    activeProjectsContent

                    SectionRowHeader(title: "Groups")
                        .padding(.horizontal, 22)
                        .padding(.top, 18)
                    groupsContent

                    Color.clear.frame(height: 100)
                }
            }
            .scrollBounceBehavior(.basedOnSize)
            .safeAreaPadding(.bottom, 6)
        }
        .sheet(isPresented: $showingAddSheet) {
            addProjectSheet
        }
        .sheet(item: $activeSheet) { item in
            NavigationStack {
                switch item {
                case .project(let id):
                    ProjectDetailView(projectID: id)
                case .group(let name):
                    GroupDetailView(groupName: name)
                }
            }
        }
    }

    @ViewBuilder
    private var activeProjectsContent: some View {
        let entries = projectStore.activeProjects()
        if entries.isEmpty {
            projectCard(title: "No active projects", subtitle: "Projects will appear here when you add them", source: "System")
                .padding(.horizontal, 22)
                .padding(.top, 10)
        } else {
            ForEach(entries) { project in
                projectCard(title: project.name, subtitle: project.detail, source: project.source) {
                    activeSheet = .project(project.id)
                }
                .padding(.horizontal, 22)
                .padding(.top, 10)
            }
        }
    }

    @ViewBuilder
    private var groupsContent: some View {
        let groups = projectStore.groups()
        if groups.isEmpty {
            projectCard(title: "No groups yet", subtitle: "Add a group when creating a project", source: "System")
                .padding(.horizontal, 22)
                .padding(.top, 10)
        } else {
            ForEach(groups, id: \.self) { groupName in
                let groupProjects = projectStore.projects(inGroup: groupName)
                let summary = groupSummary(for: groupProjects)
                projectCard(title: groupName, subtitle: summary, source: "Group") {
                    activeSheet = .group(groupName)
                }
                .padding(.horizontal, 22)
                .padding(.top, 10)
            }
        }
    }

    private func groupSummary(for projects: [ProjectRecord]) -> String {
        guard !projects.isEmpty else { return "No projects in this group yet" }
        if projects.count == 1 {
            return "1 project: \(projects[0].name)"
        }
        let sample = projects.prefix(3).map(\.name).joined(separator: ", ")
        if projects.count <= 3 {
            return "\(projects.count) related projects: \(sample)"
        }
        return "\(projects.count) related projects: \(sample), ..."
    }

    @ViewBuilder
    private func projectCard(title: String, subtitle: String, source: String, onTap: (() -> Void)? = nil) -> some View {
        if let onTap {
            Button(action: onTap) {
                cardBody(title: title, subtitle: subtitle, source: source)
            }
            .buttonStyle(.plain)
        } else {
            cardBody(title: title, subtitle: subtitle, source: source)
        }
    }

    private func cardBody(title: String, subtitle: String, source: String) -> some View {
        GlassCard(corner: 22, padding: 16) {
            HStack(alignment: .top, spacing: 12) {
                Circle()
                    .fill(AppTheme.textPrimary)
                    .frame(width: 6, height: 6)
                    .padding(.top, 6)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(AppTheme.textPrimary)
                    Text(subtitle)
                        .font(.system(size: 12.5))
                        .foregroundStyle(AppTheme.textSecondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 6)
                GlassPill(title: source)
            }
        }
    }

    private var addProjectSheet: some View {
        NavigationStack {
            Form {
                Section("Project") {
                    TextField("Name", text: $projectNameInput)
                    TextField("Detail", text: $projectDetailInput)
                    TextField("Group (optional)", text: $projectGroupInput)
                }
            }
            .navigationTitle("New Project")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        resetForm()
                        showingAddSheet = false
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        createProjectFromForm()
                    }
                    .disabled(projectNameInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func createProjectFromForm() {
        let name = projectNameInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }

        let detail = projectDetailInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let group = projectGroupInput.trimmingCharacters(in: .whitespacesAndNewlines)
        projectStore.createProject(
            name: name,
            detail: detail.isEmpty ? "Created from Projects" : detail,
            stage: .active,
            groupName: group.isEmpty ? nil : group,
            source: "User"
        )
        if let created = projectStore.activeProjects().first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            activityStore.add(
                title: "Project created",
                detail: group.isEmpty ? "Added \(name) to Active" : "Added \(name) to group: \(group)",
                state: .completed,
                source: "User",
                projectID: created.id
            )
        }
        resetForm()
        showingAddSheet = false
    }

    private func resetForm() {
        projectNameInput = ""
        projectDetailInput = ""
        projectGroupInput = ""
    }
}

private struct ProjectDetailView: View {
    let projectID: UUID

    @Environment(\.dismiss) private var dismiss
    @StateObject private var projectStore = AppProjectStore.shared
    @StateObject private var activityStore = AppActivityStore.shared

    @State private var isEditing = false
    @State private var editName = ""
    @State private var editDetail = ""
    @State private var editSummary = ""
    @State private var editGroup = ""

    private var project: ProjectRecord? {
        projectStore.project(id: projectID)
    }

    private var relatedActivity: [ActivityRecord] {
        guard let project else { return [] }
        return activityStore.items
            .filter { $0.projectID == project.id }
            .prefix(8)
            .map { $0 }
    }

    var body: some View {
        GeometryReader { proxy in
            let cardWidth = max(0, proxy.size.width - 44)

            ZStack(alignment: .top) {
                Color(red: 0.965, green: 0.968, blue: 0.978)
                    .ignoresSafeArea()

                ScrollView(showsIndicators: false) {
                    if let project {
                        VStack(alignment: .leading, spacing: 14) {
                    GlassCard(corner: 18, padding: 14, fillWidth: true) {
                        VStack(alignment: .leading, spacing: 10) {
                            if isEditing {
                                TextField("Project name", text: $editName)
                                    .font(.system(size: 16, weight: .semibold))
                                TextField("Detail", text: $editDetail, axis: .vertical)
                                    .lineLimit(3...6)
                                    .font(.system(size: 13.5))
                            } else {
                                Text(project.name)
                                    .font(.system(size: 20, weight: .semibold))
                                    .foregroundStyle(Color.black)
                                Text(project.detail)
                                    .font(.system(size: 13.5))
                                    .foregroundStyle(Color.black.opacity(0.72))
                            }
                        }
                    }
                    .frame(width: cardWidth, alignment: .topLeading)

                    GlassCard(corner: 18, padding: 14, fillWidth: true) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Summary")
                                .font(.system(size: 11.5, weight: .semibold))
                                .foregroundStyle(Color.black.opacity(0.68))
                            if isEditing {
                                TextField("Project summary", text: $editSummary, axis: .vertical)
                                    .lineLimit(4...6)
                                    .font(.system(size: 12.5))
                            } else {
                                Text(generatedSummary(for: project))
                                    .font(.system(size: 12.5))
                                    .foregroundStyle(Color.black)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .frame(width: cardWidth, alignment: .topLeading)

                    GlassCard(corner: 18, padding: 14, fillWidth: true) {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Related Activity")
                                .font(.system(size: 13.5, weight: .semibold))
                                .foregroundStyle(Color.black)
                            if relatedActivity.isEmpty {
                                Text("No tasks linked to this project yet")
                                    .font(.system(size: 12.5))
                                    .foregroundStyle(Color.black.opacity(0.68))
                            } else {
                                ForEach(relatedActivity) { item in
                                    HStack(alignment: .top, spacing: 8) {
                                        Circle()
                                            .fill(Color.black.opacity(0.85))
                                            .frame(width: 5, height: 5)
                                            .padding(.top, 5)
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(item.title)
                                                .font(.system(size: 12.5, weight: .semibold))
                                                .foregroundStyle(Color.black)
                                            Text(item.detail)
                                                .font(.system(size: 11.5))
                                                .foregroundStyle(Color.black.opacity(0.72))
                                        }
                                        Spacer()
                                        GlassPill(title: item.source)
                                    }
                                }
                            }
                        }
                    }
                    .frame(width: cardWidth, alignment: .topLeading)

                    if isEditing {
                        Button(role: .destructive) {
                            deleteProject(project)
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "trash.fill")
                                    .font(.system(size: 16, weight: .bold))
                                Text("Delete Project")
                                    .font(.system(size: 14, weight: .semibold))
                                Spacer()
                            }
                            .foregroundStyle(Color.red)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 12)
                            .background(
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(Color.red.opacity(0.45), lineWidth: 1)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                        }
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.horizontal, 22)
                        .padding(.top, 74)
                        .padding(.bottom, 30)
                        .onAppear {
                            loadEditFields(from: project)
                        }
                    } else {
                        Text("Project not found")
                            .font(.system(size: 14))
                            .foregroundStyle(Color.black.opacity(0.68))
                            .padding(.top, 90)
                    }
                }

                HStack {
                    Button(isEditing ? "Cancel" : "Close") {
                        if isEditing, let project {
                            loadEditFields(from: project)
                            isEditing = false
                            return
                        }
                        dismiss()
                    }

                    Spacer()

                    Text("Project Details")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(Color.black)

                    Spacer()

                    Button {
                        if isEditing {
                            saveEdits()
                        }
                        isEditing.toggle()
                    } label: {
                        Image(systemName: isEditing ? "checkmark" : "pencil")
                            .foregroundStyle(Color.black)
                    }
                }
                .padding(.horizontal, 22)
                .padding(.top, 14)
            }
        }
        .toolbar(.hidden, for: .navigationBar)
    }

    private func saveEdits() {
        let cleanName = editName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty else { return }
        let cleanDetail = editDetail.trimmingCharacters(in: .whitespacesAndNewlines)

        projectStore.updateProject(
            id: projectID,
            name: cleanName,
            detail: cleanDetail,
            summary: editSummary,
            groupName: project?.groupName
        )
        activityStore.add(
            title: "Project edited",
            detail: "Updated \(cleanName)",
            state: .completed,
            source: "User",
            projectID: projectID
        )
    }

    private func deleteProject(_ project: ProjectRecord) {
        projectStore.deleteProject(id: project.id)
        activityStore.removeAll(forProjectID: project.id)
        activityStore.add(
            title: "Project deleted",
            detail: "Removed \(project.name)",
            state: .completed,
            source: "User"
        )
        dismiss()
    }

    private func loadEditFields(from project: ProjectRecord) {
        editName = project.name
        editDetail = project.detail
        editSummary = generatedSummary(for: project)
    }

    private func generatedSummary(for project: ProjectRecord) -> String {
        let cleanDetail = project.detail.trimmingCharacters(in: .whitespacesAndNewlines)
        let groupText = project.groupName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        var lines: [String] = []
        lines.append("\(project.name) is an active initiative in Gideon.")

        if !cleanDetail.isEmpty {
            lines.append("Current focus: \(cleanDetail)")
        }

        if !groupText.isEmpty {
            lines.append("This project is part of the \(groupText) group, so execution should stay aligned with related work.")
        }

        lines.append("Status is \(project.stage.title.lowercased()), with activity tracked directly in Related Activity tasks.")
        return lines.joined(separator: " ")
    }

    private func detailRow(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(AppTheme.textSecondary)
            Text(value)
                .font(.system(size: 12.5))
                .foregroundStyle(AppTheme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func dateText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

private struct GroupDetailView: View {
    let groupName: String

    @Environment(\.dismiss) private var dismiss
    @StateObject private var projectStore = AppProjectStore.shared

    private var projects: [ProjectRecord] {
        projectStore.projects(inGroup: groupName)
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 14) {
                GlassCard(corner: 18, padding: 14) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(groupName)
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(AppTheme.textPrimary)
                        Text(groupSummary)
                            .font(.system(size: 13.5))
                            .foregroundStyle(AppTheme.textSecondary)
                    }
                }

                GlassCard(corner: 18, padding: 14) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Relationship Network")
                            .font(.system(size: 13.5, weight: .semibold))
                            .foregroundStyle(AppTheme.textPrimary)
                        GroupNetworkView(groupName: groupName, projects: projects)
                            .frame(height: 220)
                    }
                }

                GlassCard(corner: 18, padding: 14) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Projects")
                            .font(.system(size: 13.5, weight: .semibold))
                            .foregroundStyle(AppTheme.textPrimary)
                        if projects.isEmpty {
                            Text("No projects currently in this group")
                                .font(.system(size: 12.5))
                                .foregroundStyle(AppTheme.textSecondary)
                        } else {
                            ForEach(projects) { project in
                                HStack(alignment: .top, spacing: 8) {
                                    Circle()
                                        .fill(AppTheme.textPrimary)
                                        .frame(width: 5, height: 5)
                                        .padding(.top, 5)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(project.name)
                                            .font(.system(size: 12.5, weight: .semibold))
                                            .foregroundStyle(AppTheme.textPrimary)
                                        Text(project.detail)
                                            .font(.system(size: 11.5))
                                            .foregroundStyle(AppTheme.textSecondary)
                                    }
                                    Spacer()
                                    GlassPill(title: project.source)
                                }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 14)
            .padding(.bottom, 30)
        }
        .navigationTitle("Group")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Close") { dismiss() }
            }
        }
    }

    private var groupSummary: String {
        if projects.isEmpty {
            return "Group created but currently empty."
        }
        if projects.count == 1 {
            return "This group has one project. Add more projects to build linked context."
        }
        return "\(projects.count) projects share this group, which means they are related by workflow, objective, or domain."
    }
}

private struct GroupNetworkView: View {
    let groupName: String
    let projects: [ProjectRecord]

    var body: some View {
        TimelineView(.animation) { timeline in
            GeometryReader { geo in
                let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
                let radius = min(geo.size.width, geo.size.height) * 0.34
                let time = timeline.date.timeIntervalSinceReferenceDate

                ZStack {
                    Circle()
                        .fill(AppTheme.darkBlock.opacity(0.25))
                        .frame(width: 78, height: 78)
                    Text(groupName.prefix(10).uppercased())
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(AppTheme.textPrimary)

                    ForEach(Array(projects.prefix(8).enumerated()), id: \.offset) { index, project in
                        let angle = (Double(index) / Double(max(projects.prefix(8).count, 1))) * (.pi * 2)
                        let wobble = sin(time * 0.8 + Double(index)) * 9
                        let x = center.x + CGFloat(cos(angle)) * (radius + CGFloat(wobble))
                        let y = center.y + CGFloat(sin(angle)) * (radius + CGFloat(wobble * 0.75))

                        Path { path in
                            path.move(to: center)
                            path.addLine(to: CGPoint(x: x, y: y))
                        }
                        .stroke(AppTheme.textSecondary.opacity(0.35), lineWidth: 1)

                        Circle()
                            .fill(AppTheme.textPrimary.opacity(0.9))
                            .frame(width: 14, height: 14)
                            .position(x: x, y: y)

                        Text(String(project.name.prefix(10)))
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(AppTheme.textSecondary)
                            .position(x: x, y: y + 14)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(AppTheme.darkBlock.opacity(0.18))
        )
    }
}

#Preview { RootView() }
