import SwiftUI

struct ActivityView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header.
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Eyebrow(text: "Task Queue", size: 12)
                    PageTitle(text: "Activity")
                }
                Spacer()
                Image(systemName: "plus")
                    .font(.system(size: 18, weight: .regular))
                    .foregroundStyle(AppTheme.textPrimary)
                    .padding(.top, 6)
            }
            .padding(.horizontal, 22)
            .padding(.top, 8)

            // ACTIVE.
            SectionRowHeader(title: "Active")
                .padding(.horizontal, 22)
                .padding(.top, 18)
            taskCard(title: "No active tasks", subtitle: "Gideon will add tasks here")
                .padding(.horizontal, 22)
                .padding(.top, 10)

            // NEXT.
            SectionRowHeader(title: "Next")
                .padding(.horizontal, 22)
                .padding(.top, 18)
            taskCard(title: "No next tasks yet", subtitle: "Ask Gideon to plan the next step")
                .padding(.horizontal, 22)
                .padding(.top, 10)

            // COMPLETED / BLOCKED (collapsed).
            SectionRowHeader(title: "Completed", collapsed: true)
                .padding(.horizontal, 22)
                .padding(.top, 18)
            SectionRowHeader(title: "Blocked", collapsed: true)
                .padding(.horizontal, 22)
                .padding(.top, 14)

            Spacer()
        }
        .padding(.top, 18)
        .padding(.bottom, 90)
    }

    private func taskCard(title: String, subtitle: String) -> some View {
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
