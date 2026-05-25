import SwiftUI

struct AgentView: View {
    @State private var showingGideonProfile = false

    var body: some View {
        Group {
            if showingGideonProfile {
                GideonProfileView {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.88)) {
                        showingGideonProfile = false
                    }
                }
            } else {
                agentList
            }
        }
        .transition(.opacity)
    }

    private var agentList: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Eyebrow header.
            HStack {
                Eyebrow(text: "Agents", size: 12)
                Spacer()
                Image(systemName: "plus")
                    .font(.system(size: 18, weight: .regular))
                    .foregroundStyle(AppTheme.textPrimary)
            }
            .padding(.horizontal, 22)
            .padding(.top, 10)

            // PRIMARY section.
            SectionRowHeader(title: "Primary")
                .padding(.horizontal, 22)
                .padding(.top, 18)

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

            Spacer()
        }
        .padding(.top, 18)
        .padding(.bottom, 90)
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
                        Text("Autonomous agent ⓘ Qwen2.5-3B-Instruct (in-app core)")
                            .font(.system(size: 12.5))
                            .foregroundStyle(AppTheme.textSecondary)
                            .lineLimit(2)
                    }
                    Spacer(minLength: 6)
                    Circle()
                        .fill(AppTheme.statusGreen)
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
                    Text("Add subagents when you are ready")
                        .font(.system(size: 12.5))
                        .foregroundStyle(AppTheme.textSecondary)
                }
                Spacer(minLength: 6)
                Circle()
                    .fill(AppTheme.textTertiary)
                    .frame(width: 7, height: 7)
            }
        }
    }
}

private struct GideonProfileView: View {
    let onBack: () -> Void

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

                    Circle()
                        .fill(AppTheme.statusGreen)
                        .frame(width: 6, height: 6)
                }
                .padding(.horizontal, 22)
                .padding(.top, 10)

                Eyebrow(text: "Primary Autonomous Agent", size: 9)
                    .padding(.horizontal, 22)
                    .padding(.top, 24)

                Text("Gideon")
                    .font(.system(size: 20, weight: .semibold))
                    .tracking(3.2)
                    .textCase(.uppercase)
                    .foregroundStyle(AppTheme.textPrimary)
                    .padding(.horizontal, 22)
                    .padding(.top, 10)

                Text("Qwen2.5-3B-Instruct - in-app Core ML")
                    .font(.system(size: 10, weight: .regular))
                    .foregroundStyle(AppTheme.textSecondary)
                    .padding(.horizontal, 22)
                    .padding(.top, 22)

                Text("Currently active")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(AppTheme.textPrimary.opacity(0.56))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .background(
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .fill(AppTheme.textMuted.opacity(0.18))
                    )
                    .padding(.horizontal, 22)
                    .padding(.top, 22)

                profileSection(title: "Memories", value: "No memories yet")
                    .padding(.top, 16)
                profileSection(title: "Skills", value: "No skills connected yet")
                    .padding(.top, 14)
                profileSection(title: "Models", value: "Qwen2.5-3B-Instruct", detail: "(Qwen2.5-3B-Instruct)", status: "Active", showsAdd: true)
                    .padding(.top, 14)
                profileSection(title: "Accounts", value: "No accounts connected yet", showsAdd: true)
                    .padding(.top, 14)
                profileSection(title: "Sites", value: "No sites connected yet", showsAdd: true)
                    .padding(.top, 14)
                profileSection(title: "Plugins", value: "No plugins connected yet", showsAdd: true, disabled: true)
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
                            .foregroundStyle(Color(red: 0.04, green: 0.58, blue: 0.25))
                    }
                }
            }
        }
        .padding(.horizontal, 22)
    }
}

#Preview { RootView() }
