import SwiftUI

struct Eyebrow: View {
    let text: String
    var size: CGFloat = 11
    var color: Color = AppTheme.textTertiary

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: size, weight: .medium))
            .tracking(2.4)
            .foregroundStyle(color)
    }
}

struct PageTitle: View {
    let text: String
    var size: CGFloat = 34

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: size, weight: .light))
            .tracking(1.5)
            .foregroundStyle(AppTheme.textPrimary)
    }
}

struct HeaderMenuButton: View {
    @EnvironmentObject private var session: AppSessionStore
    @EnvironmentObject private var dataMode: AppDataModeStore

    var body: some View {
        Menu {
            userSummary

            Section("Data Mode") {
                Button {
                    dataMode.mode = .cloud
                } label: {
                    Label("Cloud", systemImage: dataMode.mode == .cloud ? "checkmark" : "icloud")
                }

                Button {
                    dataMode.mode = .local
                } label: {
                    Label("Local", systemImage: dataMode.mode == .local ? "checkmark" : "lock")
                }
            }

            Section("Account") {
                Button(role: .destructive) {
                    session.logout()
                } label: {
                    Label("Log Out", systemImage: "rectangle.portrait.and.arrow.right")
                }
            }
        } label: {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 18, weight: .regular))
                .foregroundStyle(AppTheme.textPrimary)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var userSummary: some View {
        let email = session.currentUser?.email ?? "Not signed in"
        let name = session.currentUser?.name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasName = !(name?.isEmpty ?? true)
        let modeLabel = dataMode.mode == .cloud ? "Cloud mode" : "Local mode"

        Section {
            VStack(alignment: .leading, spacing: 4) {
                Text("Signed in as")
                    .font(.system(size: 9.5, weight: .semibold))
                    .tracking(1.2)
                    .foregroundStyle(AppTheme.textTertiary)

                Text(email)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(AppTheme.textPrimary)

                if hasName {
                    Text(name!)
                        .font(.system(size: 11.5, weight: .regular))
                        .foregroundStyle(AppTheme.textSecondary)
                }

                Text(modeLabel)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(AppTheme.textTertiary)
            }
            .padding(.vertical, 2)
        }
    }
}
