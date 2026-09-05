import SwiftUI

struct ActivityView: View {
    @StateObject private var activityStore = AppActivityStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header.
            ZStack(alignment: .top) {
                PageTitle(text: "Activity", size: 30)
                    .padding(.top, -2)

                HStack(alignment: .top) {
                    HeaderMenuButton()
                    Spacer()
                    Button {
                        // Placeholder action until Activity-specific entry points are wired up.
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
                    // ACTIVE.
                SectionRowHeader(title: "Active")
                    .padding(.horizontal, 22)
                    .padding(.top, 18)
                stateSection(.active, emptyTitle: "No active tasks", emptySubtitle: "Gideon will add tasks here")

                // NEXT.
                SectionRowHeader(title: "Next")
                    .padding(.horizontal, 22)
                    .padding(.top, 18)
                stateSection(.next, emptyTitle: "No next tasks yet", emptySubtitle: "Ask Gideon to plan the next step")

                // COMPLETED / BLOCKED (collapsed).
                SectionRowHeader(title: "Completed", collapsed: true)
                    .padding(.horizontal, 22)
                    .padding(.top, 18)
                stateSection(.completed, emptyTitle: "No completed tasks", emptySubtitle: "Completed items will show up here")
                SectionRowHeader(title: "Blocked", collapsed: true)
                    .padding(.horizontal, 22)
                    .padding(.top, 14)
                stateSection(.blocked, emptyTitle: "No blocked tasks", emptySubtitle: "Blocked items will appear here")

                    Color.clear.frame(height: 96)
                }
                .padding(.top, 10)
            }
            .scrollBounceBehavior(.basedOnSize)
            .safeAreaPadding(.bottom, 12)
        }
    }

    @ViewBuilder
    private func stateSection(_ state: ActivityState, emptyTitle: String, emptySubtitle: String) -> some View {
        let entries = activityStore.list(state: state)
        if entries.isEmpty {
            taskCard(title: emptyTitle, subtitle: emptySubtitle, source: nil)
                .padding(.horizontal, 22)
                .padding(.top, 10)
        } else {
            ForEach(entries.prefix(6)) { item in
                taskCard(title: item.title, subtitle: item.detail, source: item.source)
                    .padding(.horizontal, 22)
                    .padding(.top, 10)
            }
        }
    }

    private func taskCard(title: String, subtitle: String, source: String?) -> some View {
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
                if let source, !source.isEmpty {
                    GlassPill(title: source)
                }
            }
        }
    }
}

#Preview { RootView() }
