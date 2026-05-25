import SwiftUI

struct HealthView: View {
    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                // Header.
                VStack(alignment: .leading, spacing: 4) {
                    Eyebrow(text: "Gideon", size: 12)
                    PageTitle(text: "Agent Health")
                }
                .padding(.horizontal, 22)
                .padding(.top, 8)

                // Operating efficiency.
                efficiency
                    .padding(.horizontal, 22)
                    .padding(.top, 22)

                // Stats card.
                statsCard
                    .padding(.horizontal, 22)
                    .padding(.top, 20)

                // Capabilities card.
                capabilitiesCard
                    .padding(.horizontal, 22)
                    .padding(.top, 16)

                // Audit card.
                auditCard
                    .padding(.horizontal, 22)
                    .padding(.top, 16)

                Color.clear.frame(height: 100)
            }
            .padding(.top, 18)
        }
    }

    private var efficiency: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Eyebrow(text: "Operating Efficiency", size: 11)
                Spacer()
                Text("80%")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(AppTheme.textPrimary)
            }

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(AppTheme.textMuted.opacity(0.4)).frame(height: 3)
                    Capsule().fill(AppTheme.textPrimary).frame(width: proxy.size.width * 0.8, height: 3)
                }
            }
            .frame(height: 3)

            Text("Task completion 47/52 (90%) +36 ⓘ 3 blocked tasks – 15 ⓘ 3 self-edits today +3 ⓘ 2 unfinished functions – 4")
                .font(.system(size: 12))
                .foregroundStyle(AppTheme.textSecondary)
        }
    }

    private var statsCard: some View {
        GlassCard(corner: 22, padding: 4) {
            VStack(spacing: 0) {
                statRow("Uptime", "4h 32m")
                divider
                statRow("Tasks completed", "47 today")
                divider
                statRow("Active ⓘ Blocked", "3 active ⓘ 2 blocked")
                divider
                statRow("Self-edits", "3 today ⓘ 11 total")
                divider
                statRow("Memory", "14.2 / 48 GB")

                // Memory progress bar inside card.
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(AppTheme.textMuted.opacity(0.3)).frame(height: 3)
                        Capsule().fill(AppTheme.textPrimary).frame(width: proxy.size.width * 0.30, height: 3)
                    }
                }
                .frame(height: 3)
                .padding(.horizontal, 14)
                .padding(.bottom, 10)
                .padding(.top, 2)
            }
        }
    }

    private var capabilitiesCard: some View {
        GlassCard(corner: 22, padding: 16) {
            VStack(alignment: .leading, spacing: 0) {
                Eyebrow(text: "Capabilities", size: 11)
                    .padding(.bottom, 12)

                capRow("GitHub ⓘ PR review + diff analysis", status: "Active", green: true)
                divider
                capRow("File system ⓘ scoped read/write", status: "Active", green: true)
                divider
                capRow("selfWrite ⓘ source modification", status: "Active", green: true)
                divider
                capRow("Telegram interface", status: "Active", green: true)
                divider
                capRow("Gmail MCP", status: "Needs credentials", green: false)
                divider
                capRow("Calendar MCP", status: "Needs credentials", green: false)
            }
        }
    }

    private var auditCard: some View {
        GlassCard(corner: 22, padding: 16) {
            VStack(alignment: .leading, spacing: 0) {
                Eyebrow(text: "Last Audit ⓘ 09:14", size: 11)
                    .padding(.bottom, 12)

                capRow("Self-audit", status: "Pass", green: true)
                divider
                capRow("Git state", status: "Clean ⓘ 3 commits", green: true)
                divider
                capRow("Unfinished functions", status: "2 remaining", green: false)
                    .opacity(0.55)
            }
        }
    }

    private func statRow(_ leading: String, _ trailing: String) -> some View {
        HStack {
            Text(leading)
                .font(.system(size: 14))
                .foregroundStyle(AppTheme.textPrimary)
            Spacer()
            Text(trailing)
                .font(.system(size: 14))
                .foregroundStyle(AppTheme.textPrimary)
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 14)
    }

    private func capRow(_ leading: String, status: String, green: Bool) -> some View {
        HStack {
            Text(leading)
                .font(.system(size: 14))
                .foregroundStyle(AppTheme.textPrimary)
            Spacer()
            Text(status)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(green ? AppTheme.statusGreen : AppTheme.statusOrange)
        }
        .padding(.vertical, 10)
    }

    private var divider: some View {
        Rectangle().fill(AppTheme.divider).frame(height: 1)
    }
}

#Preview { RootView() }
