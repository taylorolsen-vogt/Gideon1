import AuthenticationServices
import SwiftUI

@MainActor
struct ConnectionsView: View {
    @Environment(\.openURL) private var openURL
    @EnvironmentObject private var modelSelection: GideonModelSelectionStore
    @StateObject private var connectionStore = ProviderConnectionStore.shared
    @StateObject private var accountStore = AccountStore.shared
    @State private var showingAddModelSheet = false
    @State private var connectTarget: ConnectTarget?
    @State private var connectAuthType: ConnectAuthType = .apiKey
    @State private var connectServicePreset: String = ""
    @State private var connectAPIKeyInput = ""
    @State private var connectBaseURLInput = ""
    @State private var modelDraft = AddModelDraft()
    @State private var modelSaveStatus = ""
    @State private var accountSaveStatus = ""
    @State private var isVerifyingModel = false
    @State private var isConnectingAccount = false
    @State private var connectPlatformInput = ""
    @State private var connectNotesInput = ""
    @State private var portalURL: ScopedConnectionPortal?
    @State private var modelPendingDeletion: GideonAPIProviderProfile?
    @State private var modelDeletionScope: SessionScope?
    @State private var formScope = SessionScope.current

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                ZStack(alignment: .top) {
                    PageTitle(text: "Connections", size: 30)
                        .padding(.top, -2)

                    HStack(alignment: .top) {
                        HeaderMenuButton()
                        Spacer()
                    }
                }
                .padding(.horizontal, 22)
                .padding(.top, 8)
                .padding(.bottom, 8)
                .background(AppTheme.background.opacity(0.96))

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

                Color.clear.frame(height: 100)
            }
            .padding(.top, 18)
            .padding(.bottom, 90)
        }
        .sheet(isPresented: $showingAddModelSheet) {
            NavigationStack {
                Form {
                    Section("Provider") {
                        TextField("Display Name", text: $modelDraft.name)
                            .foregroundStyle(sheetPrimaryText)
                        Picker("Provider", selection: providerSelectionBinding) {
                            ForEach(ModelProviderPreset.allCases) { provider in
                                Text(provider.displayName).tag(provider)
                            }
                        }
                    }
                    Section("Endpoint") {
                        TextField("https://api.provider.com", text: $modelDraft.baseURL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .foregroundStyle(sheetPrimaryText)
                    }
                    Section("Models") {
                        TextField("Optional extra model IDs", text: $modelDraft.customModelsText, axis: .vertical)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .foregroundStyle(sheetPrimaryText)
                        Text("Gideon fetches available models automatically when the provider supports it. Add IDs here only if a model is missing.")
                            .font(.system(size: 12))
                            .foregroundStyle(sheetSecondaryText)
                    }
                    Section("Credentials") {
                        SecureField(apiKeyIsRequiredForDraft ? "API key" : "API key (optional for local server)", text: $modelDraft.apiKey)
                            .foregroundStyle(sheetPrimaryText)
                        Text(apiKeyIsRequiredForDraft ? "Key is stored in Keychain." : "Key is stored in Keychain when provided. Local endpoints on your Mac or LAN can be saved without one.")
                            .font(.system(size: 12))
                            .foregroundStyle(sheetSecondaryText)
                    }

                    if !modelSaveStatus.isEmpty {
                        Section {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(modelSaveStatus.contains("failed") || modelSaveStatus.contains("Failed") ? "Verification issue" : "Status")
                                    .font(.system(size: 11.5, weight: .semibold))
                                    .foregroundStyle(modelSaveStatus.contains("failed") || modelSaveStatus.contains("Failed") ? AppTheme.statusOrange : AppTheme.statusGreen)
                                Text(modelSaveStatus)
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(AppTheme.textPrimary)
                            }
                        }
                    }
                }
                .scrollContentBackground(.hidden)
                .background(sheetBackground)
                .tint(sheetPrimaryText)
                .toolbarColorScheme(.dark, for: .navigationBar)
                .navigationTitle("Add API Provider")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") {
                            resetAddModelForm()
                            showingAddModelSheet = false
                        }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(isVerifyingModel ? "Verifying..." : (modelSaveStatus.contains("failed") || modelSaveStatus.contains("Failed") ? "Try again" : "Save")) {
                            let scope = SessionScope.current
                            guard formScope == scope else { return }
                            let draft = modelDraft
                            Task { await verifyAndSaveModel(draft, scope: scope) }
                        }
                        .disabled(isVerifyingModel ||
                            modelDraft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                            modelDraft.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                            (apiKeyIsRequiredForDraft && modelDraft.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        )
                    }
                }
            }
            .preferredColorScheme(.dark)
            .presentationDetents([.large])
        }
        .sheet(item: $connectTarget) { target in
            NavigationStack {
                Form {
                    Section("Service") {
                        Picker("Service", selection: $connectServicePreset) {
                            Text("Choose a service…").tag("")
                            ForEach(AccountServiceFamily.allCases) { family in
                                Section(family.rawValue) {
                                    ForEach(AccountServicePreset.catalog.filter { $0.family == family }) { preset in
                                        Label(preset.name, systemImage: preset.icon).tag(preset.name)
                                    }
                                }
                            }
                            Text("Other…").tag("__other__")
                        }
                        .onChange(of: connectServicePreset) { _, value in
                            if value != "__other__" {
                                connectPlatformInput = value
                                connectAuthType = selectedAccountService?.authType ?? .apiKey
                                connectBaseURLInput = selectedAccountService?.defaultBaseURL ?? ""
                            } else {
                                connectPlatformInput = ""
                                connectBaseURLInput = ""
                            }
                        }

                        if connectServicePreset == "__other__" {
                            TextField("Service name", text: $connectPlatformInput)
                                .foregroundStyle(sheetPrimaryText)
                        }

                        if let service = selectedAccountService, target == .accounts {
                            Label(service.summary, systemImage: service.icon)
                                .font(.system(size: 12))
                                .foregroundStyle(sheetSecondaryText)
                        } else if target == .sites {
                            TextField("Site URL", text: $connectBaseURLInput)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .keyboardType(.URL)
                                .foregroundStyle(sheetPrimaryText)
                        }
                    }

                    Section("Account details") {
                        TextField("Display name", text: $connectPlatformInput)
                            .textInputAutocapitalization(.words)
                            .autocorrectionDisabled()
                            .foregroundStyle(sheetPrimaryText)

                        if target == .accounts && (selectedAccountService?.requiresBaseURL == true || connectServicePreset == "__other__") {
                            TextField(selectedAccountService?.baseURLLabel ?? "Account URL (optional)", text: $connectBaseURLInput)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .keyboardType(.URL)
                                .foregroundStyle(sheetPrimaryText)
                        }
                    }

                    if target != .accounts || connectServicePreset == "__other__" {
                        Section("Auth method") {
                            Picker("Auth type", selection: $connectAuthType) {
                                ForEach(ConnectAuthType.allCases, id: \.self) { type in
                                    Text(type.rawValue).tag(type)
                                }
                            }
                            .pickerStyle(.segmented)
                        }
                    } else if let service = selectedAccountService {
                        Section("Authentication") {
                            LabeledContent("Method", value: service.authType.rawValue)
                        }
                    }

                    if let service = selectedAccountService, service.usesNativeGoogleOAuth, target == .accounts {
                        Section("Authorization") {
                            Button {
                                let scope = SessionScope.current
                                guard formScope == scope else { return }
                                let draft = connectionDraft
                                Task { await connectGoogleAccount(service, draft: draft, scope: scope) }
                            } label: {
                                HStack {
                                    Image(systemName: "person.crop.circle.badge.checkmark")
                                    Text(isConnectingAccount ? "Connecting…" : "Continue with Google")
                                }
                                .frame(maxWidth: .infinity)
                            }
                            .disabled(isConnectingAccount)

                            Text("Google will show Gideon's consent screen. Your access and refresh tokens are stored in Keychain.")
                                .font(.system(size: 12))
                                .foregroundStyle(sheetSecondaryText)
                        }
                    } else if connectAuthType == .apiKey || (connectAuthType == .oauth && target == .accounts) {
                        Section("Credentials") {
                            SecureField(selectedAccountService?.credentialLabel ?? "API key or token", text: $connectAPIKeyInput)
                                .foregroundStyle(sheetPrimaryText)
                            Text(selectedAccountService?.credentialHint ?? credentialHint(for: connectServicePreset == "__other__" ? connectPlatformInput : connectServicePreset))
                                .font(.system(size: 12))
                                .foregroundStyle(sheetSecondaryText)

                            if let service = selectedAccountService {
                                Button(service.setupButtonTitle) {
                                    openSetupPage(for: service)
                                }
                            }
                        }
                    } else if connectAuthType == .oauth {
                        Section("Authorization") {
                            Button("Open authorization page") {
                                let scope = SessionScope.current
                                guard formScope == scope, scope.isCurrent else { return }
                                let name = connectPlatformInput.trimmingCharacters(in: .whitespacesAndNewlines)
                                let fallback = name.isEmpty ? "Provider" : name
                                let portal = ScopedConnectionPortal(
                                    url: connectionStore.portalURL(for: fallback),
                                    provider: fallback,
                                    scope: scope
                                )
                                connectTarget = nil
                                DispatchQueue.main.async {
                                    guard scope.isCurrent else { return }
                                    portalURL = portal
                                }
                                connectionStore.markManualStep(providerName: fallback, detail: "OAuth flow opened")
                            }
                            .disabled(connectPlatformInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }

                    Section {
                        TextField("Notes (optional)", text: $connectNotesInput)
                            .foregroundStyle(sheetPrimaryText)
                    }
                }
                .scrollContentBackground(.hidden)
                .background(sheetBackground)
                .tint(sheetPrimaryText)
                .toolbarColorScheme(.dark, for: .navigationBar)
                .navigationTitle(target.modalTitle)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") {
                            connectTarget = nil
                        }
                    }

                    if selectedAccountService?.usesNativeGoogleOAuth != true {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Save") {
                                let scope = SessionScope.current
                                guard formScope == scope else { return }
                                let draft = connectionDraft
                                Task { await saveManualConnection(draft, scope: scope) }
                            }
                            .disabled(!canSaveConnection)
                        }
                    }
                }
            }
            .presentationDetents([.large])
        }
        .sheet(item: $portalURL) { item in
            SafariSheetView(url: item.url)
                .onDisappear {
                    guard item.scope.isCurrent else { return }
                    connectionStore.markManualStep(providerName: item.provider, detail: "Provider flow opened. Finish setup manually if needed.")
                }
        }
        .alert("Delete model provider?", isPresented: Binding(
            get: { modelPendingDeletion != nil },
            set: { if !$0 { modelPendingDeletion = nil } }
        ), presenting: modelPendingDeletion) { profile in
            Button("Delete", role: .destructive) {
                guard let scope = modelDeletionScope, scope.isCurrent else { return }
                modelPendingDeletion = nil
                modelDeletionScope = nil
                Task {
                    guard scope.isCurrent else { return }
                    await modelSelection.removeAPIProvider(id: profile.id)
                }
            }
            Button("Cancel", role: .cancel) {
                modelPendingDeletion = nil
            }
        } message: { profile in
            Text("This removes \(profile.name), its API key, and its synchronized connection from your Gideon account on all devices.")
        }
        .onReceive(NotificationCenter.default.publisher(for: .gideonSessionChanged)) { _ in
            clearFormsForSessionChange()
        }
        .onReceive(NotificationCenter.default.publisher(for: .gideonDataModeChanged)) { _ in
            clearFormsForSessionChange()
        }
        .onAppear {
            if formScope != SessionScope.current {
                clearFormsForSessionChange()
            }
        }
    }

    private var accountsSection: some View {
        GlassCard(corner: 18, padding: 14) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Eyebrow(text: "Accounts", size: 8.5)
                    Spacer()
                    if !accountStore.accounts.isEmpty {
                        Text("\(accountStore.accounts.count) saved")
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

                if !accountSaveStatus.isEmpty {
                    Text(accountSaveStatus)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(AppTheme.textSecondary)
                }
            }
            .preferredColorScheme(.dark)
        }
        .padding(.horizontal, 22)
    }

    private var modelsSection: some View {
        GlassCard(corner: 18, padding: 14) {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Eyebrow(text: "Provider Models", size: 8.5)
                    Spacer()
                    Button {
                        resetAddModelForm()
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
                    ForEach(modelSelection.providerOptions) { option in
                        let profile = modelSelection.apiProvider(for: option)
                        HStack(spacing: 8) {
                            Button {
                                modelSelection.selectProvider(option)
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
                            }
                            .buttonStyle(.plain)
                            .disabled(!option.isAvailable)

                            if let profile {
                                Button {
                                    modelDeletionScope = SessionScope.current
                                    modelPendingDeletion = profile
                                } label: {
                                    Image(systemName: "xmark.circle")
                                        .font(.system(size: 14, weight: .regular))
                                        .foregroundStyle(AppTheme.textTertiary)
                                        .frame(width: 28, height: 28)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Delete \(option.title)")
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 12)
                        .background(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(modelSelection.selectedProviderOption.id == option.id ? AppTheme.textPrimary.opacity(0.05) : Color.white.opacity(0.42))
                        )
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

    private func verifyAndSaveModel(_ draft: AddModelDraft, scope: SessionScope) async {
        guard scope.isCurrent else { return }
        isVerifyingModel = true
        modelSaveStatus = "Verifying..."
        defer { if scope.isCurrent { isVerifyingModel = false } }

        let provider = draft.selectedProvider.providerKey
        let verify = await connectionStore.verifyConnection(
            providerName: provider,
            endpoint: draft.baseURL,
            apiKey: draft.apiKey,
            modelIdentifier: draft.selectedProvider.defaultModelID,
            expectedScope: scope
        )
        guard scope.isCurrent else { return }
        guard verify.ok else {
            connectionStore.markError(providerName: provider, detail: verify.message)
            modelSaveStatus = "Verification failed: \(verify.message)"
            return
        }
        let added = await modelSelection.addAPIProvider(
            name: draft.name,
            provider: provider,
            baseURL: draft.baseURL,
            apiKey: draft.apiKey,
            customModelIdentifiers: parseCustomModelIDs(from: draft.customModelsText)
        )
        guard scope.isCurrent else { return }
        guard added else {
            connectionStore.markError(providerName: provider, detail: "Provider save failed")
            modelSaveStatus = "Provider save failed"
            return
        }
        connectionStore.markConnected(providerName: provider, detail: verify.message)
        modelSaveStatus = "Provider added and verified"
        resetAddModelForm()
        showingAddModelSheet = false
    }

    private func resetAddModelForm() {
        let provider = modelDraft.selectedProvider
        modelDraft = AddModelDraft(
            name: provider.defaultConnectionName,
            selectedProvider: provider,
            providerKey: provider.providerKey,
            baseURL: provider.baseURL,
            apiKey: "",
            customModelsText: ""
        )
        modelSaveStatus = ""
    }

    // Notifications arrive after the new generation is activated, including
    // logout/re-login of the same user. Keep this on the presenting view so
    // sensitive bindings are cleared even while a sheet covers it.
    private func clearFormsForSessionChange() {
        modelDraft = AddModelDraft()
        connectServicePreset = ""
        connectPlatformInput = ""
        connectNotesInput = ""
        connectAPIKeyInput = ""
        connectBaseURLInput = ""
        connectAuthType = .apiKey
        modelSaveStatus = ""
        accountSaveStatus = ""
        isVerifyingModel = false
        isConnectingAccount = false
        modelPendingDeletion = nil
        modelDeletionScope = nil
        showingAddModelSheet = false
        connectTarget = nil
        portalURL = nil
        formScope = SessionScope.current
    }

    private var connectionDraft: ConnectionDraft {
        ConnectionDraft(
            service: connectServicePreset == "__other__"
                ? connectPlatformInput.trimmingCharacters(in: .whitespacesAndNewlines)
                : connectServicePreset,
            displayName: connectPlatformInput.trimmingCharacters(in: .whitespacesAndNewlines),
            authType: connectAuthType,
            apiKey: connectAPIKeyInput.trimmingCharacters(in: .whitespacesAndNewlines),
            baseURL: connectBaseURLInput.trimmingCharacters(in: .whitespacesAndNewlines),
            notes: connectNotesInput.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    private var providerSelectionBinding: Binding<ModelProviderPreset> {
        Binding(
            get: { modelDraft.selectedProvider },
            set: { provider in
                applyProviderPreset(provider)
            }
        )
    }

    private var apiKeyIsRequiredForDraft: Bool {
        !isLikelyLocalEndpoint(modelDraft.baseURL)
    }

    private var sheetBackground: Color {
        Color(red: 0.11, green: 0.11, blue: 0.12)
    }

    private var sheetPrimaryText: Color {
        Color.white.opacity(0.94)
    }

    private var sheetSecondaryText: Color {
        Color.white.opacity(0.72)
    }

    private var selectedAccountService: AccountServicePreset? {
        AccountServicePreset.catalog.first { $0.name == connectServicePreset }
    }

    private var canSaveConnection: Bool {
        guard !isVerifyingModel,
              !connectServicePreset.isEmpty,
              connectServicePreset != "__other__" || !connectPlatformInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        if let service = selectedAccountService {
            if service.requiresBaseURL && connectBaseURLInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return false
            }
            return !connectAPIKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return true
    }

    private func presentConnectModal(for target: ConnectTarget) {
        connectServicePreset = ""
        connectPlatformInput = ""
        connectNotesInput = ""
        connectAPIKeyInput = ""
        connectBaseURLInput = ""
        connectAuthType = .apiKey
        accountSaveStatus = ""
        connectTarget = target
    }

    private func openSetupPage(for service: AccountServicePreset) {
        let scope = SessionScope.current
        guard formScope == scope, scope.isCurrent else { return }
        openURL(service.setupURL)
        guard scope.isCurrent else { return }
        connectionStore.markManualStep(providerName: service.name, detail: "Credential setup opened")
    }

    private func connectGoogleAccount(_ service: AccountServicePreset, draft: ConnectionDraft, scope: SessionScope) async {
        guard scope.isCurrent else { return }
        isConnectingAccount = true
        defer { if scope.isCurrent { isConnectingAccount = false } }

        do {
            let tokens = try await GoogleOAuthService.shared.authorize(scopes: service.oauthScopes)
            guard scope.isCurrent else { return }
            accountStore.add(
                name: draft.displayName.isEmpty ? service.name : draft.displayName,
                service: service.name,
                authType: .oauth,
                baseURL: "",
                notes: draft.notes,
                apiKey: tokens.accessToken,
                refreshToken: tokens.refreshToken ?? ""
            )
            connectionStore.markConnected(providerName: service.name, detail: "Connected with Google OAuth")
            accountSaveStatus = "\(service.name) connected"
            connectTarget = nil
        } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
            guard scope.isCurrent else { return }
            accountSaveStatus = "Google sign-in canceled"
        } catch {
            guard scope.isCurrent else { return }
            accountSaveStatus = "Google sign-in failed: \(error.localizedDescription)"
        }
    }

    private func applyProviderPreset(_ provider: ModelProviderPreset) {
        let currentName = modelDraft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let knownPresetNames = Set(
            ModelProviderPreset.allCases.flatMap { [$0.displayName, $0.defaultConnectionName] }
        )
        let shouldUpdateName = currentName.isEmpty || knownPresetNames.contains(currentName)

        modelDraft.selectedProvider = provider
        modelDraft.providerKey = provider.providerKey
        modelDraft.baseURL = provider.baseURL
        if shouldUpdateName {
            modelDraft.name = provider.defaultConnectionName
        }
        modelSaveStatus = ""
    }

    private func parseCustomModelIDs(from rawValue: String) -> [String] {
        rawValue
            .split(whereSeparator: { $0 == "," || $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func isLikelyLocalEndpoint(_ rawValue: String) -> Bool {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        let parsed = URL(string: trimmed)?.scheme == nil ? URL(string: "http://\(trimmed)") : URL(string: trimmed)
        guard let host = parsed?.host?.lowercased() else {
            return false
        }

        if host == "localhost" || host == "127.0.0.1" || host == "::1" || host.hasSuffix(".local") {
            return true
        }
        if host.hasPrefix("10.") || host.hasPrefix("192.168.") {
            return true
        }
        if host.hasPrefix("172."),
           let secondOctet = host.split(separator: ".").dropFirst().first,
           let value = Int(secondOctet),
           (16...31).contains(value) {
            return true
        }

        return false
    }

    private func credentialHint(for service: String) -> String {
        let lower = service.lowercased()
        if lower.contains("github") {
            return "GitHub uses a Personal Access Token (PAT), not username/password."
        }
        if lower.contains("gmail") || lower.contains("google") {
            return "Gmail should use OAuth. API keys/tokens here are advanced/manual only."
        }
        if lower.contains("openai") || lower.contains("anthropic") {
            return "Use the provider API key from your developer console."
        }
        return "Credentials vary by provider. API key/token is most common."
    }

    private func saveManualConnection(_ draft: ConnectionDraft, scope: SessionScope) async {
        guard scope.isCurrent else { return }
        let service = draft.service
        guard !service.isEmpty else { return }

        isVerifyingModel = true
        defer { if scope.isCurrent { isVerifyingModel = false } }

        // Reuse the provider verifier for service integrations so we can track real connectivity.
        let verification = await connectionStore.verifyConnection(
            providerName: service,
            endpoint: draft.baseURL,
            apiKey: draft.apiKey,
            modelIdentifier: "",
            expectedScope: scope
        )
        guard scope.isCurrent else { return }

        let authType: AccountRecord.AuthType
        switch draft.authType {
        case .apiKey: authType = .apiKey
        case .oauth:  authType = .oauth
        case .manual: authType = .manual
        }

        accountStore.add(
            name: service,
            service: service,
            authType: authType,
            baseURL: draft.baseURL,
            notes: draft.notes,
            apiKey: draft.apiKey
        )

        if verification.ok {
            connectionStore.markConnected(providerName: service, detail: verification.message)
            accountSaveStatus = "\(service) verified and connected"
        } else {
            connectionStore.markManualStep(providerName: service, detail: verification.message)
            accountSaveStatus = "\(service) credentials saved. Verification: \(verification.message)"
        }

        connectTarget = nil
    }
}

private struct ScopedConnectionPortal: Identifiable {
    let id = UUID()
    let url: URL
    let provider: String
    let scope: SessionScope
}

private struct ConnectionDraft {
    let service: String
    let displayName: String
    let authType: ConnectAuthType
    let apiKey: String
    let baseURL: String
    let notes: String
}

private struct AddModelDraft {
    var name: String = ""
    var selectedProvider: ModelProviderPreset = .openAI
    var providerKey: String = ""
    var baseURL: String = ""
    var apiKey: String = ""
    var customModelsText: String = ""
}

private enum ConnectAuthType: String, CaseIterable {
    case apiKey = "API Key"
    case oauth = "OAuth"
    case manual = "Manual"
}

private enum AccountServiceFamily: String, CaseIterable, Identifiable {
    case google = "Google"
    case developer = "Developer"
    case communication = "Communication"
    case knowledge = "Knowledge & Files"
    case creative = "Creative"

    var id: String { rawValue }
}

private struct AccountServicePreset: Identifiable {
    let name: String
    let family: AccountServiceFamily
    let icon: String
    let authType: ConnectAuthType
    let summary: String
    let credentialLabel: String
    let credentialHint: String
    let setupButtonTitle: String
    let setupURL: URL
    var oauthScopes: [String] = []
    var requiresBaseURL = false
    var baseURLLabel = "Workspace URL"
    var defaultBaseURL = ""

    var id: String { name }
    var usesNativeGoogleOAuth: Bool { family == .google && !oauthScopes.isEmpty }

    static let catalog: [AccountServicePreset] = [
        AccountServicePreset(
            name: "Gmail", family: .google, icon: "envelope", authType: .oauth,
            summary: "Read messages and create drafts.", credentialLabel: "OAuth access token",
            credentialHint: "Gmail requires a Google OAuth token with Gmail scopes. Tokens are stored in Keychain.",
            setupButtonTitle: "Set up Google OAuth", setupURL: URL(string: "https://console.cloud.google.com/auth/clients")!,
            oauthScopes: [
                "openid", "email", "profile",
                "https://www.googleapis.com/auth/gmail.readonly",
                "https://www.googleapis.com/auth/gmail.compose"
            ]
        ),
        AccountServicePreset(
            name: "Google Calendar", family: .google, icon: "calendar", authType: .oauth,
            summary: "Read calendars and manage events.", credentialLabel: "OAuth access token",
            credentialHint: "Use the same Google OAuth client with Calendar scopes.",
            setupButtonTitle: "Set up Google OAuth", setupURL: URL(string: "https://console.cloud.google.com/auth/clients")!,
            oauthScopes: [
                "openid", "email", "profile",
                "https://www.googleapis.com/auth/calendar.readonly",
                "https://www.googleapis.com/auth/calendar.events"
            ]
        ),
        AccountServicePreset(
            name: "Google Drive", family: .google, icon: "externaldrive", authType: .oauth,
            summary: "Find and work with files in Drive.", credentialLabel: "OAuth access token",
            credentialHint: "Use a Google OAuth token with the minimum Drive scopes Gideon needs.",
            setupButtonTitle: "Set up Google OAuth", setupURL: URL(string: "https://console.cloud.google.com/auth/clients")!,
            oauthScopes: [
                "openid", "email", "profile",
                "https://www.googleapis.com/auth/drive.metadata.readonly",
                "https://www.googleapis.com/auth/drive.file"
            ]
        ),
        AccountServicePreset(
            name: "YouTube", family: .google, icon: "play.rectangle", authType: .oauth,
            summary: "Inspect channels, videos, and creator activity.", credentialLabel: "OAuth access token",
            credentialHint: "Use a Google OAuth token with YouTube read scopes.",
            setupButtonTitle: "Set up Google OAuth", setupURL: URL(string: "https://console.cloud.google.com/auth/clients")!,
            oauthScopes: [
                "openid", "email", "profile",
                "https://www.googleapis.com/auth/youtube.readonly"
            ]
        ),
        AccountServicePreset(
            name: "GitHub", family: .developer, icon: "chevron.left.forwardslash.chevron.right", authType: .apiKey,
            summary: "Work with repositories, issues, and projects.", credentialLabel: "Personal access token",
            credentialHint: "Use a fine-grained token limited to the repositories and actions Gideon needs.",
            setupButtonTitle: "Create GitHub token", setupURL: URL(string: "https://github.com/settings/personal-access-tokens/new")!
        ),
        AccountServicePreset(
            name: "GitLab", family: .developer, icon: "shippingbox", authType: .apiKey,
            summary: "Work with GitLab projects and issues.", credentialLabel: "Personal access token",
            credentialHint: "Create a GitLab token with API access for the projects you want to use.",
            setupButtonTitle: "Create GitLab token", setupURL: URL(string: "https://gitlab.com/-/user_settings/personal_access_tokens")!
        ),
        AccountServicePreset(
            name: "Linear", family: .developer, icon: "line.3.horizontal.decrease.circle", authType: .apiKey,
            summary: "Read and manage engineering issues.", credentialLabel: "Personal API key",
            credentialHint: "Create a personal API key in Linear security settings.",
            setupButtonTitle: "Open Linear API settings", setupURL: URL(string: "https://linear.app/settings/api")!
        ),
        AccountServicePreset(
            name: "Jira", family: .developer, icon: "checklist", authType: .apiKey,
            summary: "Work with Jira projects and tickets.", credentialLabel: "Atlassian API token",
            credentialHint: "Enter an Atlassian API token and your workspace URL. Jira also needs the account email when its tool adapter is enabled.",
            setupButtonTitle: "Create Atlassian token", setupURL: URL(string: "https://id.atlassian.com/manage-profile/security/api-tokens")!,
            requiresBaseURL: true, baseURLLabel: "Jira workspace URL", defaultBaseURL: ""
        ),
        AccountServicePreset(
            name: "Slack", family: .communication, icon: "number", authType: .oauth,
            summary: "Search channels and participate in team conversations.", credentialLabel: "Bot or user OAuth token",
            credentialHint: "Create a Slack app, install it to a workspace, then paste its least-privileged OAuth token.",
            setupButtonTitle: "Create Slack app", setupURL: URL(string: "https://api.slack.com/apps")!
        ),
        AccountServicePreset(
            name: "Discord", family: .communication, icon: "bubble.left.and.bubble.right", authType: .apiKey,
            summary: "Work with Discord communities and channels.", credentialLabel: "Bot token",
            credentialHint: "Create a Discord application and bot. Never share its token outside Gideon's Keychain storage.",
            setupButtonTitle: "Create Discord application", setupURL: URL(string: "https://discord.com/developers/applications")!
        ),
        AccountServicePreset(
            name: "Notion", family: .knowledge, icon: "doc.text", authType: .oauth,
            summary: "Search pages, databases, and team knowledge.", credentialLabel: "Integration token",
            credentialHint: "Create an integration and share only the pages Gideon should access.",
            setupButtonTitle: "Create Notion integration", setupURL: URL(string: "https://www.notion.so/profile/integrations")!
        ),
        AccountServicePreset(
            name: "Airtable", family: .knowledge, icon: "square.grid.3x3", authType: .apiKey,
            summary: "Read and update structured workspace data.", credentialLabel: "Personal access token",
            credentialHint: "Create a scoped Airtable token for only the bases Gideon should access.",
            setupButtonTitle: "Create Airtable token", setupURL: URL(string: "https://airtable.com/create/tokens")!
        ),
        AccountServicePreset(
            name: "Dropbox", family: .knowledge, icon: "shippingbox", authType: .oauth,
            summary: "Find and organize files in Dropbox.", credentialLabel: "OAuth access token",
            credentialHint: "Create a Dropbox app and grant the smallest file scope needed.",
            setupButtonTitle: "Create Dropbox app", setupURL: URL(string: "https://www.dropbox.com/developers/apps")!
        ),
        AccountServicePreset(
            name: "Figma", family: .creative, icon: "paintbrush", authType: .apiKey,
            summary: "Inspect design files, comments, and components.", credentialLabel: "Personal access token",
            credentialHint: "Create a personal access token in Figma settings.",
            setupButtonTitle: "Open Figma settings", setupURL: URL(string: "https://www.figma.com/settings")!
        ),
        AccountServicePreset(
            name: "Canva", family: .creative, icon: "wand.and.stars", authType: .oauth,
            summary: "Connect creative assets and design workflows.", credentialLabel: "OAuth access token",
            credentialHint: "Create a Canva integration before connecting an account.",
            setupButtonTitle: "Open Canva developer portal", setupURL: URL(string: "https://www.canva.dev/docs/connect/")!
        )
    ]
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
