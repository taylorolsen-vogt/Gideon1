import SwiftUI

struct ConnectionsView: View {
    @EnvironmentObject private var modelSelection: GideonModelSelectionStore
    @StateObject private var connectionStore = ProviderConnectionStore.shared
    @StateObject private var accountStore = AccountStore.shared
    @State private var showingAddModelSheet = false
    @State private var connectTarget: ConnectTarget?
    @State private var connectAuthType: ConnectAuthType = .apiKey
    @State private var connectServicePreset: String = ""
    @State private var connectAPIKeyInput = ""
    @State private var connectBaseURLInput = ""
    @State private var modelNameInput = ""
    @State private var modelProviderInput = ""
    @State private var modelBaseURLInput = ""
    @State private var modelIdentifierInput = ""
    @State private var modelAPIKeyInput = ""
    @State private var modelSaveStatus = ""
    @State private var isVerifyingModel = false
    @State private var connectPlatformInput = ""
    @State private var connectNotesInput = ""
    @State private var portalURL: PortalSheetItem?

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 4) {
                    Eyebrow(text: "Gideon", size: 12)
                    PageTitle(text: "Connections")
                }
                .padding(.horizontal, 22)
                .padding(.top, 8)

                modelsSection
                    .padding(.top, 22)

                accountsSection
                    .padding(.top, 16)

                profileSection(
                    title: "Sites",
                    value: "No sites connected yet",
                    showsAdd: true,
                    onAdd: { presentConnectModal(for: .sites) }
                )
                    .padding(.horizontal, 22)
                    .padding(.top, 14)

                profileSection(
                    title: "Plugins",
                    value: "No plugins connected yet",
                    showsAdd: true,
                    onAdd: { presentConnectModal(for: .plugins) }
                )
                    .padding(.horizontal, 22)
                    .padding(.top, 14)

                Color.clear.frame(height: 100)
            }
            .padding(.top, 18)
            .padding(.bottom, 90)
        }
        .sheet(isPresented: $showingAddModelSheet) {
            NavigationStack {
                Form {
                    Section("Model") {
                        TextField("Display Name", text: $modelNameInput)
                        TextField("Provider (OpenAI, Anthropic, etc.)", text: $modelProviderInput)
                        TextField("Model ID", text: $modelIdentifierInput)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                    Section("Endpoint") {
                        TextField("https://api.provider.com", text: $modelBaseURLInput)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                    Section("Credentials") {
                        SecureField("API key", text: $modelAPIKeyInput)
                        Text("Key is stored in Keychain.")
                            .font(.system(size: 12))
                            .foregroundStyle(AppTheme.textSecondary)
                    }
                }
                .navigationTitle("Add API Model")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") {
                            resetAddModelForm()
                            showingAddModelSheet = false
                        }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(isVerifyingModel ? "Verifying..." : "Save") {
                            Task { await verifyAndSaveModel() }
                        }
                        .disabled(isVerifyingModel ||
                            modelNameInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                            modelProviderInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                            modelIdentifierInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                            modelBaseURLInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                            modelAPIKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        )
                    }
                }
            }
            .presentationDetents([.large])
        }
        .sheet(item: $connectTarget) { target in
            NavigationStack {
                Form {
                    Section("Service") {
                        Picker("Service", selection: $connectServicePreset) {
                            Text("Choose a service…").tag("")
                            ForEach(Self.servicePresets, id: \.self) { preset in
                                Text(preset).tag(preset)
                            }
                            Text("Other…").tag("__other__")
                        }
                        .onChange(of: connectServicePreset) { _, value in
                            if value != "__other__" {
                                connectPlatformInput = value
                            } else {
                                connectPlatformInput = ""
                            }
                        }

                        if connectServicePreset == "__other__" {
                            TextField("Service name", text: $connectPlatformInput)
                        }
                    }

                    Section("Auth method") {
                        Picker("Auth type", selection: $connectAuthType) {
                            ForEach(ConnectAuthType.allCases, id: \.self) { type in
                                Text(type.rawValue).tag(type)
                            }
                        }
                        .pickerStyle(.segmented)
                    }

                    if connectAuthType == .apiKey {
                        Section("Credentials") {
                            SecureField("API key or token", text: $connectAPIKeyInput)
                            TextField("Base URL (optional)", text: $connectBaseURLInput)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                        }
                    } else if connectAuthType == .oauth {
                        Section("Authorization") {
                            Button("Open authorization page") {
                                let name = connectPlatformInput.trimmingCharacters(in: .whitespacesAndNewlines)
                                let fallback = name.isEmpty ? "Provider" : name
                                portalURL = PortalSheetItem(url: connectionStore.portalURL(for: fallback))
                                connectionStore.markManualStep(providerName: fallback, detail: "OAuth flow opened")
                            }
                            .disabled(connectPlatformInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }

                    Section {
                        TextField("Notes (optional)", text: $connectNotesInput)
                    }
                }
                .navigationTitle(target.modalTitle)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") {
                            connectTarget = nil
                        }
                    }

                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") {
                            saveManualConnection(for: target)
                        }
                        .disabled(connectServicePreset.isEmpty || (connectServicePreset == "__other__" && connectPlatformInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
                    }
                }
            }
            .presentationDetents([.large])
        }
        .sheet(item: $portalURL, onDismiss: {
            let provider = modelProviderInput.isEmpty
                ? (connectPlatformInput.isEmpty ? "Provider" : connectPlatformInput)
                : modelProviderInput
            connectionStore.markManualStep(providerName: provider, detail: "Provider flow opened. Finish setup manually if needed.")
        }) { item in
            SafariSheetView(url: item.url)
        }
    }

    private var accountsSection: some View {
        GlassCard(corner: 18, padding: 14) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Eyebrow(text: "Accounts", size: 8.5)
                    Spacer()
                    if !accountStore.accounts.isEmpty {
                        Text("\(accountStore.accounts.count) connected")
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(AppTheme.statusGreen)
                    }
                    Button {
                        presentConnectModal(for: .accounts)
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color.white)
                            .frame(width: 24, height: 24)
                            .background(Circle().fill(AppTheme.textPrimary.opacity(0.92)))
                    }
                    .buttonStyle(.plain)
                }

                if accountStore.accounts.isEmpty {
                    Text("No accounts connected yet")
                        .font(.system(size: 14, weight: .regular))
                        .foregroundStyle(AppTheme.textPrimary.opacity(0.42))
                } else {
                    ForEach(accountStore.accounts) { account in
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(account.name)
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(AppTheme.textPrimary)
                                Text(account.service)
                                    .font(.system(size: 11.5, weight: .regular))
                                    .foregroundStyle(AppTheme.textSecondary)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 8)
                            Text(account.authType.rawValue)
                                .font(.system(size: 10.5, weight: .semibold))
                                .foregroundStyle(AppTheme.statusGreen)
                            Button {
                                accountStore.remove(id: account.id)
                            } label: {
                                Image(systemName: "xmark.circle")
                                    .font(.system(size: 14, weight: .regular))
                                    .foregroundStyle(AppTheme.textTertiary)
                            }
                            .buttonStyle(.plain)
                        }
                        if account.id != accountStore.accounts.last?.id {
                            Rectangle().fill(AppTheme.divider).frame(height: 1)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 22)
    }

    private var modelsSection: some View {
        GlassCard(corner: 18, padding: 14) {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Eyebrow(text: "Models", size: 8.5)
                    Spacer()
                    Button {
                        modelSaveStatus = ""
                        showingAddModelSheet = true
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color.white)
                            .frame(width: 24, height: 24)
                            .background(Circle().fill(AppTheme.textPrimary.opacity(0.92)))
                    }
                    .buttonStyle(.plain)
                }
                VStack(spacing: 10) {
                    ForEach(modelSelection.options) { option in
                        Button {
                            modelSelection.select(option)
                        } label: {
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(option.title)
                                        .font(.system(size: 14.5, weight: .semibold))
                                        .foregroundStyle(AppTheme.textPrimary)
                                    Text(option.detail)
                                        .font(.system(size: 12, weight: .regular))
                                        .foregroundStyle(AppTheme.textSecondary)
                                        .lineLimit(2)
                                }
                                Spacer(minLength: 6)
                                VStack(alignment: .trailing, spacing: 4) {
                                    Text(option.statusLabel)
                                        .font(.system(size: 10.5, weight: .semibold))
                                        .foregroundStyle(option.isAvailable ? Color(red: 0.04, green: 0.58, blue: 0.25) : AppTheme.statusOrange)
                                    Text(option.subtitle)
                                        .font(.system(size: 10.5, weight: .regular))
                                        .foregroundStyle(AppTheme.textTertiary)
                                        .lineLimit(1)
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 12)
                            .background(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .fill(modelSelection.selectedOption.id == option.id ? AppTheme.textPrimary.opacity(0.05) : Color.white.opacity(0.42))
                            )
                        }
                        .buttonStyle(.plain)
                        .disabled(!option.isAvailable)
                    }
                    if !modelSaveStatus.isEmpty {
                        Text(modelSaveStatus)
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(AppTheme.textSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 4)
                    }
                }
            }
        }
        .padding(.horizontal, 22)
    }

    private func profileSection(
        title: String,
        value: String,
        showsAdd: Bool = false,
        disabled: Bool = false,
        onAdd: (() -> Void)? = nil
    ) -> some View {
        GlassCard(corner: 18, padding: 14) {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .center) {
                    Eyebrow(text: title, size: 8.5)
                    Spacer()
                    if showsAdd {
                        Button {
                            onAdd?()
                        } label: {
                            Image(systemName: "plus")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Color.white)
                                .frame(width: 24, height: 24)
                                .background(Circle().fill(AppTheme.textPrimary.opacity(disabled ? 0.28 : 0.92)))
                        }
                        .buttonStyle(.plain)
                        .disabled(disabled || onAdd == nil)
                    }
                }
                Text(value)
                    .font(.system(size: 15, weight: .regular))
                    .foregroundStyle(AppTheme.textPrimary.opacity(0.42))
                    .lineLimit(1)
            }
        }
    }

    private func connectionColor(_ state: ProviderConnectionRecord.State) -> Color {
        switch state {
        case .connected:   return AppTheme.statusGreen
        case .manualStep:  return AppTheme.statusOrange
        case .error:       return Color(red: 0.78, green: 0.24, blue: 0.21)
        case .notConnected: return AppTheme.textTertiary
        }
    }

    private func verifyAndSaveModel() async {
        isVerifyingModel = true
        defer { isVerifyingModel = false }

        let provider = modelProviderInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let verify = await connectionStore.verifyConnection(
            providerName: provider,
            endpoint: modelBaseURLInput,
            apiKey: modelAPIKeyInput,
            modelIdentifier: modelIdentifierInput
        )
        guard verify.ok else {
            connectionStore.markError(providerName: provider, detail: verify.message)
            modelSaveStatus = "Verification failed: \(verify.message)"
            return
        }
        let added = modelSelection.addAPIModel(
            name: modelNameInput,
            provider: provider,
            baseURL: modelBaseURLInput,
            modelIdentifier: modelIdentifierInput,
            apiKey: modelAPIKeyInput
        )
        guard added else {
            connectionStore.markError(providerName: provider, detail: "Model save failed")
            modelSaveStatus = "Model save failed"
            return
        }
        connectionStore.markConnected(providerName: provider, detail: verify.message)
        modelSaveStatus = "Model added and verified"
        resetAddModelForm()
        showingAddModelSheet = false
    }

    private func resetAddModelForm() {
        modelNameInput = ""
        modelProviderInput = ""
        modelBaseURLInput = ""
        modelIdentifierInput = ""
        modelAPIKeyInput = ""
    }

    private func presentConnectModal(for target: ConnectTarget) {
        connectServicePreset = ""
        connectPlatformInput = ""
        connectNotesInput = ""
        connectAPIKeyInput = ""
        connectBaseURLInput = ""
        connectAuthType = .apiKey
        connectTarget = target
    }

    private static let servicePresets: [String] = [
        "GitHub", "GitLab", "Bitbucket",
        "Notion", "Airtable", "Linear", "Jira",
        "Slack", "Discord", "Microsoft Teams",
        "Gmail", "Outlook",
        "Google Calendar", "Google Drive",
        "OpenAI", "Anthropic", "Mistral",
        "Figma", "Stripe", "Shopify", "Twilio", "Zapier",
    ]

    private func saveManualConnection(for target: ConnectTarget) {
        let service = connectServicePreset == "__other__"
            ? connectPlatformInput.trimmingCharacters(in: .whitespacesAndNewlines)
            : connectServicePreset
        guard !service.isEmpty else { return }

        let authType: AccountRecord.AuthType
        switch connectAuthType {
        case .apiKey: authType = .apiKey
        case .oauth:  authType = .oauth
        case .manual: authType = .manual
        }

        accountStore.add(
            name: service,
            service: service,
            authType: authType,
            baseURL: connectBaseURLInput.trimmingCharacters(in: .whitespacesAndNewlines),
            notes: connectNotesInput.trimmingCharacters(in: .whitespacesAndNewlines),
            apiKey: connectAPIKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        connectTarget = nil
    }
}

private enum ConnectAuthType: String, CaseIterable {
    case apiKey = "API Key"
    case oauth = "OAuth"
    case manual = "Manual"
}

private enum ConnectTarget: String, Identifiable {
    case accounts = "Account"
    case sites = "Site"
    case plugins = "Plugin"

    var id: String { rawValue }

    var modalTitle: String {
        switch self {
        case .accounts:
            return "Connect Account"
        case .sites:
            return "Add Site"
        case .plugins:
            return "Add Plugin"
        }
    }

}
