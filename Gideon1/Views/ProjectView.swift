import SwiftUI

struct ProjectView: View {
    private struct Section: Identifiable {
        let id = UUID()
        let label: String
        let title: String
        let subtitle: String
        var collapsed: Bool = false
    }

    private let sections: [Section] = [
        .init(label: "Active",            title: "No active projects",    subtitle: "Projects will appear here when you add them"),
        .init(label: "In Design",         title: "No in-design projects", subtitle: "Add a project to see it here"),
        .init(label: "Ventures",          title: "No ventures listed",    subtitle: "Use Add to create one"),
        .init(label: "When Time Permits", title: "No saved ideas yet",    subtitle: "Ideas will show up here"),
        .init(label: "Ideas",             title: "No ideas saved",        subtitle: "Use Gideon to generate one")
    ]

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                // Header.
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Eyebrow(text: "Work", size: 12)
                        PageTitle(text: "Projects")
                    }
                    Spacer()
                    Image(systemName: "plus")
                        .font(.system(size: 18, weight: .regular))
                        .foregroundStyle(AppTheme.textPrimary)
                        .padding(.top, 6)
                }
                .padding(.horizontal, 22)
                .padding(.top, 8)

                ForEach(sections) { section in
                    SectionRowHeader(title: section.label)
                        .padding(.horizontal, 22)
                        .padding(.top, 18)
                    projectCard(title: section.title, subtitle: section.subtitle)
                        .padding(.horizontal, 22)
                        .padding(.top, 10)
                }

                SectionRowHeader(title: "Completed", collapsed: true)
                    .padding(.horizontal, 22)
                    .padding(.top, 18)

                Color.clear.frame(height: 100)
            }
            .padding(.top, 18)
        }
    }

    private func projectCard(title: String, subtitle: String) -> some View {
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
                }
                Spacer(minLength: 6)
                GlassPill(title: "Gideon")
            }
        }
    }
}

#Preview { RootView() }
