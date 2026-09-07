import SwiftUI

struct SessionUser: Codable {
    let id: String
    let email: String
    let name: String?
}

enum AppDataMode: String, CaseIterable, Codable {
    case cloud
    case local
}

extension Notification.Name {
    static let gideonDataModeChanged = Notification.Name("gideon.dataMode.changed")
    static let gideonSessionChanged = Notification.Name("gideon.session.changed")
}

@MainActor
final class AppDataModeStore: ObservableObject {
    static let shared = AppDataModeStore()

    @Published var modeRawValue: String {
        didSet {
            guard AppDataMode(rawValue: modeRawValue) != nil else {
                modeRawValue = AppDataMode.cloud.rawValue
                return
            }
            UserDefaults.standard.set(modeRawValue, forKey: Self.storageKey)
            SessionIsolation.activate(userID: AppSessionStore.shared.currentUserID, mode: modeRawValue)
            NotificationCenter.default.post(name: .gideonDataModeChanged, object: nil)
        }
    }

    var mode: AppDataMode {
        get { AppDataMode(rawValue: modeRawValue) ?? .cloud }
        set { modeRawValue = newValue.rawValue }
    }

    private static let storageKey = "gideon.data.mode.v1"

    private init() {
        if let saved = UserDefaults.standard.string(forKey: Self.storageKey),
           AppDataMode(rawValue: saved) != nil {
            modeRawValue = saved
        } else {
            modeRawValue = AppDataMode.cloud.rawValue
            UserDefaults.standard.set(modeRawValue, forKey: Self.storageKey)
        }
    }
}

@MainActor
final class AppSessionStore: ObservableObject {
    static let shared = AppSessionStore()

    @Published private(set) var isAuthenticated = false
    @Published private(set) var currentUser: SessionUser?
    @Published var authError = ""
    @Published var authNotice = ""
    @Published var isAuthenticating = false

    static let supabaseURL = "https://fjlfxnzklhsesiifzuyq.supabase.co"
    static let supabasePublishableKey = "sb_publishable_edeAOO1Mo5E58cygxYgh3w_fc1MCY1m"
    static let authRedirectURL = URL(string: "gideon1://auth/confirmed")!

    private let session: URLSession
    private let defaults: UserDefaults
    private let tokenKey: String
    private let userKey: String
    private let notificationCenter: NotificationCenter
    private var authOperation: UUID?
    private static let seenUsersKey = "gideon.session.seenUsers.v1"
    private static let blankSlateScopedKeys = [
        "gideon.accounts.v1",
        "gideon.projects.v2",
        "gideon.activity.v2",
        "gideon.providerConnections.v1",
        "gideon.selectedModelID",
        "gideon.maxNewTokens",
        "gideon.reasoningMode",
        "gideon.apiProviders.v1",
        "gideon.chatSessions.v2",
        "gideon.chatSessions.selected.v1"
    ]

    private struct AuthAttempt {
        let id: UUID
        let scope: SessionScope
    }

    static var supabaseRESTURL: String { "\(supabaseURL)/rest/v1" }
    var currentUserID: String? { currentUser?.id }
    var currentAccessToken: String? { try? SecureKeyStore.shared.read(key: tokenKey) }

    private init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        session = URLSession(configuration: configuration)
        defaults = .standard
        tokenKey = "gideon.session.token"
        userKey = "gideon.session.user.v1"
        notificationCenter = .default
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--isolation-tests") { return }
        #endif
        SessionIsolation.activate(userID: nil, mode: defaults.string(forKey: "gideon.data.mode.v1") ?? "cloud")
        restoreSession()
    }

    /// Isolated transport/storage for hosted tests; never defaults to live token keys.
    init(session: URLSession, defaults: UserDefaults, storageNamespace: String,
         notificationCenter: NotificationCenter = .default, restore: Bool = false) {
        precondition(!storageNamespace.isEmpty)
        self.session = session
        self.defaults = defaults
        tokenKey = "\(storageNamespace).gideon.session.token"
        userKey = "\(storageNamespace).gideon.session.user.v1"
        self.notificationCenter = notificationCenter
        if restore { restoreSession() }
    }

    private func beginAuthentication() -> AuthAttempt? {
        guard authOperation == nil, !Task.isCancelled else { return nil }
        let attempt = AuthAttempt(id: UUID(), scope: .current)
        authOperation = attempt.id
        isAuthenticating = true
        authError = ""
        authNotice = ""
        return attempt
    }

    private func canComplete(_ attempt: AuthAttempt) -> Bool {
        authOperation == attempt.id && attempt.scope == .current && !Task.isCancelled
    }

    private func finishAuthentication(_ attempt: AuthAttempt) {
        // An old completion must not clear a newer request's busy state.
        guard authOperation == attempt.id else { return }
        authOperation = nil
        isAuthenticating = false
    }

    private func refreshScopedStores(after scope: SessionScope) {
        Task {
            guard scope.isCurrent else { return }
            await AccountStore.shared.reloadFromCurrentMode(expectedScope: scope)
            guard scope.isCurrent else { return }
            await AppProjectStore.shared.reloadFromCurrentMode(expectedScope: scope)
            guard scope.isCurrent else { return }
            await ProviderConnectionStore.shared.reloadFromCurrentMode(expectedScope: scope)
            guard scope.isCurrent else { return }
            await GideonModelSelectionStore.shared.reloadFromCurrentMode()
        }
    }

    private func applyFirstLoginBlankSlateIfNeeded(for userID: String) async {
        let normalizedUserID = userID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalizedUserID.isEmpty else { return }
        var seenUsers = Set(defaults.stringArray(forKey: Self.seenUsersKey) ?? [])
        let isFirstSeen = !seenUsers.contains(normalizedUserID)
        if isFirstSeen {
            for key in Self.blankSlateScopedKeys {
                ScopedDefaults.standard.removeObject(forKey: key)
            }
            let scope = SessionScope.current
            if scope.canSyncCloud {
                await purgeCloudStateForCurrentUser(scope: scope)
                guard scope.isCurrent else { return }
            }
            seenUsers.insert(normalizedUserID)
            defaults.set(Array(seenUsers).sorted(), forKey: Self.seenUsersKey)
        }
    }

    private func purgeCloudStateForCurrentUser(scope: SessionScope) async {
        guard scope.isCurrent, scope.canSyncCloud else { return }

        for table in [
            "activity_items",
            "projects",
            "accounts",
            "provider_connections",
            "chat_sessions",
            "user_model_preferences"
        ] {
            await deleteCloudRows(table: table, scope: scope)
            guard scope.isCurrent else { return }
        }

        await CloudCredentialStore.shared.purgeAll(expectedScope: scope)
    }

    private func deleteCloudRows(table: String, scope: SessionScope) async {
        guard scope.isCurrent,
              let userID = scope.userID,
              let token = currentAccessToken,
              var components = URLComponents(string: "\(Self.supabaseRESTURL)/\(table)") else {
            return
        }

        components.queryItems = [
            URLQueryItem(name: "user_id", value: "eq.\(userID)")
        ]

        guard let url = components.url else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.timeoutInterval = 30
        request.setValue(Self.supabasePublishableKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("return=minimal", forHTTPHeaderField: "Prefer")
        _ = try? await session.data(for: request)
        guard scope.isCurrent else { return }
    }

    func login(email: String, password: String) async {
        guard let attempt = beginAuthentication() else { return }
        defer { finishAuthentication(attempt) }
        let cleanEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanPassword = password.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanEmail.isEmpty, !cleanPassword.isEmpty else {
            authError = "Email and password are required."
            return
        }

        guard let url = URL(string: "\(Self.supabaseURL)/auth/v1/token?grant_type=password") else {
            authError = "Invalid Supabase URL configuration."
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue(Self.supabasePublishableKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(Self.supabasePublishableKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "email": cleanEmail,
            "password": cleanPassword
        ])

        do {
            let (data, response) = try await session.data(for: request)
            guard canComplete(attempt) else { return }
            guard let http = response as? HTTPURLResponse else {
                authError = "Invalid login response."
                return
            }
            guard (200..<300).contains(http.statusCode) else {
                authError = loginErrorMessage(statusCode: http.statusCode, data: data)
                return
            }

            guard let decoded = try? JSONDecoder().decode(SupabaseLoginResponse.self, from: data) else {
                authError = "Could not parse login response."
                return
            }

            guard let accessToken = decoded.accessToken, !accessToken.isEmpty else {
                authError = "Login response did not include an access token."
                return
            }

            try SecureKeyStore.shared.write(key: tokenKey, value: accessToken)
            if let userData = try? JSONEncoder().encode(decoded.user) {
                defaults.set(userData, forKey: userKey)
            }

            SessionIsolation.activate(userID: decoded.user.id, mode: attempt.scope.mode)
            await applyFirstLoginBlankSlateIfNeeded(for: decoded.user.id)
            guard canComplete(attempt) else { return }
            currentUser = decoded.user
            isAuthenticated = true
            notificationCenter.post(name: .gideonSessionChanged, object: nil)
            refreshScopedStores(after: .current)
        } catch {
            guard canComplete(attempt) else { return }
            authError = "Login error: \(error.localizedDescription)"
        }
    }

    func signUp(email: String, password: String) async {
        guard let attempt = beginAuthentication() else { return }
        defer { finishAuthentication(attempt) }
        let cleanEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanPassword = password.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanEmail.isEmpty, !cleanPassword.isEmpty else {
            authError = "Email and password are required."
            return
        }

        guard let url = URL(string: "\(Self.supabaseURL)/auth/v1/signup") else {
            authError = "Invalid Supabase URL configuration."
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue(Self.supabasePublishableKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(Self.supabasePublishableKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "email": cleanEmail,
            "password": cleanPassword,
            "options": [
                "redirectTo": Self.authRedirectURL.absoluteString
            ]
        ])

        do {
            let (data, response) = try await session.data(for: request)
            guard canComplete(attempt) else { return }
            guard let http = response as? HTTPURLResponse else {
                authError = "Invalid signup response."
                return
            }
            guard (200..<300).contains(http.statusCode) else {
                authError = signUpErrorMessage(statusCode: http.statusCode, data: data)
                return
            }

            // Supabase may require email confirmation based on project settings.
            if let decoded = try? JSONDecoder().decode(SupabaseLoginResponse.self, from: data),
               let accessToken = decoded.accessToken {
                try SecureKeyStore.shared.write(key: tokenKey, value: accessToken)
                if let userData = try? JSONEncoder().encode(decoded.user) {
                    defaults.set(userData, forKey: userKey)
                }
                SessionIsolation.activate(userID: decoded.user.id, mode: attempt.scope.mode)
                await applyFirstLoginBlankSlateIfNeeded(for: decoded.user.id)
                guard canComplete(attempt) else { return }
                currentUser = decoded.user
                isAuthenticated = true
                notificationCenter.post(name: .gideonSessionChanged, object: nil)
                refreshScopedStores(after: .current)
            } else {
                authNotice = "Account created. Check your email to verify your account, then log in."
            }
        } catch {
            guard canComplete(attempt) else { return }
            authError = "Sign up error: \(error.localizedDescription)"
        }
    }

    func recoverPassword(email: String) async {
        guard let attempt = beginAuthentication() else { return }
        defer { finishAuthentication(attempt) }
        let cleanEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanEmail.isEmpty else {
            authError = "Enter your email first."
            return
        }

        guard let url = URL(string: "\(Self.supabaseURL)/auth/v1/recover") else {
            authError = "Invalid Supabase URL configuration."
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue(Self.supabasePublishableKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(Self.supabasePublishableKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "email": cleanEmail,
            "redirectTo": Self.authRedirectURL.absoluteString
        ])

        do {
            let (data, response) = try await session.data(for: request)
            guard canComplete(attempt) else { return }
            guard let http = response as? HTTPURLResponse else {
                authError = "Invalid password reset response."
                return
            }
            guard (200..<300).contains(http.statusCode) else {
                let details = extractSupabaseErrorMessage(from: data)
                authError = details.map { "Password reset failed: \($0)" } ?? "Password reset failed (\(http.statusCode))."
                return
            }

            authNotice = "If an account exists for that email, check your inbox for a password reset link."
        } catch {
            guard canComplete(attempt) else { return }
            authError = "Password reset error: \(error.localizedDescription)"
        }
    }

    func logout() {
        authOperation = nil
        SessionIsolation.activate(userID: nil, mode: SessionScope.current.mode)
        isAuthenticating = false
        try? SecureKeyStore.shared.delete(key: tokenKey)
        defaults.removeObject(forKey: userKey)
        currentUser = nil
        isAuthenticated = false
        authError = ""
        authNotice = ""
        notificationCenter.post(name: .gideonSessionChanged, object: nil)
        refreshScopedStores(after: .current)
    }

    private func restoreSession() {
        guard let token = try? SecureKeyStore.shared.read(key: tokenKey),
              !token.isEmpty else {
            return
        }

        if let data = defaults.data(forKey: userKey),
           let user = try? JSONDecoder().decode(SessionUser.self, from: data) {
            SessionIsolation.activate(userID: user.id, mode: defaults.string(forKey: "gideon.data.mode.v1") ?? "cloud")
            currentUser = user
            isAuthenticated = true
            notificationCenter.post(name: .gideonSessionChanged, object: nil)
            refreshScopedStores(after: .current)
            return
        }

        // App deletion clears UserDefaults but may leave Keychain items behind.
        // Treat token-only state as stale so launch falls back to the login screen.
        try? SecureKeyStore.shared.delete(key: tokenKey)
        currentUser = nil
        isAuthenticated = false
    }

    private struct SupabaseLoginResponse: Codable {
        let accessToken: String?
        let user: SessionUser

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case user
        }
    }

    private struct SupabaseErrorResponse: Codable {
        let message: String?
    }

    private func loginErrorMessage(statusCode: Int, data: Data) -> String {
        let details = extractSupabaseErrorMessage(from: data)
        if let details, !details.isEmpty {
            if details.localizedCaseInsensitiveContains("Email not confirmed") {
                return "Login failed: Please verify your email first, then try again."
            }
            return "Login failed: \(details)"
        }
        return "Login failed (\(statusCode))."
    }

    private func signUpErrorMessage(statusCode: Int, data: Data) -> String {
        let details = extractSupabaseErrorMessage(from: data)
        if let details, !details.isEmpty {
            if details.localizedCaseInsensitiveContains("already registered") {
                return "An account with this email already exists. Use Log In instead."
            }
            return "Sign up failed: \(details)"
        }
        return "Sign up failed (\(statusCode))."
    }

    private func extractSupabaseErrorMessage(from data: Data) -> String? {
        if let decoded = try? JSONDecoder().decode(SupabaseErrorResponse.self, from: data),
           let message = decoded.message,
           !message.isEmpty {
            return message
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        let keys = ["message", "msg", "error_description", "error", "code"]
        for key in keys {
            if let value = json[key] as? String, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return value
            }
        }
        return nil
    }

    func handleIncomingURL(_ url: URL) {
        guard url.scheme?.lowercased() == Self.authRedirectURL.scheme,
              url.host == Self.authRedirectURL.host else {
            return
        }

        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let queryItems = components?.queryItems ?? []
        if let error = queryItems.first(where: { $0.name == "error_description" || $0.name == "error" })?.value,
           !error.isEmpty {
            authError = "Confirmation link error: \(error)"
            return
        }

        authNotice = "Email confirmed. You can log in now."
    }
}

struct LoginView: View {
    private enum LoginField: Hashable {
        case email
        case password
        case confirmPassword
    }

    @EnvironmentObject private var session: AppSessionStore
    @State private var email = ""
    @State private var password = ""
    @State private var confirmPassword = ""
    @State private var isCreateAccountMode = false
    @State private var orbDrift = false
    @State private var glintAngle: Double = -120
    @State private var glintOpacity: Double = 0.0
    @FocusState private var focusedField: LoginField?

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                AppTheme.background.ignoresSafeArea()

                OrbView(size: 420)
                    .opacity(1.0)
                    .brightness(0.08)
                    .saturation(1.06)
                    .offset(
                        x: orbDrift ? 18 : -18,
                        y: orbDrift ? 26 : -6
                    )
                    .scaleEffect(orbDrift ? 1.02 : 0.98)
                    .rotationEffect(.degrees(orbDrift ? 2.2 : -2.2))
                    .animation(.easeInOut(duration: 7.0).repeatForever(autoreverses: true), value: orbDrift)
                    .allowsHitTesting(false)

                Rectangle()
                    .fill(.ultraThinMaterial)
                    .ignoresSafeArea()
                    .onTapGesture {
                        focusedField = nil
                    }

                VStack(spacing: 0) {
                    PageTitle(text: "Gideon")
                        .padding(.top, max(40, proxy.safeAreaInsets.top + 24))
                        .padding(.horizontal, 22)

                    ScrollView(showsIndicators: false) {
                        VStack(spacing: 0) {
                            Spacer(minLength: max(28, proxy.size.height * 0.16))

                            loginPanel
                                .padding(.horizontal, 22)
                                .frame(maxWidth: 544)

                            Spacer(minLength: 32)
                        }
                        .frame(minHeight: proxy.size.height - 120)
                    }
                    .scrollDismissesKeyboard(.interactively)
                }
                .onAppear {
                    orbDrift = true
                    triggerGlint()
                }
                .onChange(of: isCreateAccountMode) {
                    triggerGlint()
                }
            }
        }
    }

    private var loginPanel: some View {
        VStack(spacing: 14) {
            GlassCard(corner: 18, padding: 14) {
                VStack(alignment: .leading, spacing: 10) {
                    TextField("Email", text: $email)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.system(size: 14))
                        .submitLabel(.next)
                        .focused($focusedField, equals: .email)
                        .onSubmit {
                            focusedField = .password
                        }

                    SecureField("Password", text: $password)
                        .font(.system(size: 14))
                        .submitLabel(isCreateAccountMode ? .next : .go)
                        .focused($focusedField, equals: .password)
                        .onSubmit {
                            if isCreateAccountMode {
                                focusedField = .confirmPassword
                            } else {
                                Task { await session.login(email: email, password: password) }
                            }
                        }

                    if isCreateAccountMode {
                        SecureField("Verify Password", text: $confirmPassword)
                            .font(.system(size: 14))
                            .submitLabel(.go)
                            .focused($focusedField, equals: .confirmPassword)
                            .onSubmit {
                                Task { await submit() }
                            }
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(
                        AngularGradient(
                            gradient: Gradient(stops: [
                                .init(color: .clear, location: 0.00),
                                .init(color: .clear, location: 0.37),
                                .init(color: Color.white.opacity(0.88), location: 0.50),
                                .init(color: .clear, location: 0.63),
                                .init(color: .clear, location: 1.00)
                            ]),
                            center: .center,
                            angle: .degrees(glintAngle)
                        ),
                        lineWidth: 1.3
                    )
                    .opacity(glintOpacity)
                    .blendMode(.screen)
                    .allowsHitTesting(false)
            }

            Button {
                Task { await submit() }
            } label: {
                HStack {
                    Spacer()
                    Text(isCreateAccountMode ? "Create Account" : "Log In")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                    Spacer()
                }
                .padding(.vertical, 12)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.black))
            }
            .buttonStyle(.plain)
            .disabled(session.isAuthenticating)

            if !isCreateAccountMode {
                Button {
                    Task { await session.recoverPassword(email: email) }
                } label: {
                    Text("Forgot password?")
                        .font(.system(size: 13.5, weight: .medium))
                        .foregroundStyle(Color.black.opacity(0.82))
                }
                .buttonStyle(.plain)
                .disabled(session.isAuthenticating)
            }

            Button {
                isCreateAccountMode.toggle()
                session.authError = ""
                session.authNotice = ""
                focusedField = nil
                if !isCreateAccountMode {
                    confirmPassword = ""
                }
            } label: {
                Text(isCreateAccountMode ? "Back to login" : "Create account")
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(Color.black)
            }
            .buttonStyle(.plain)

            if !session.authNotice.isEmpty {
                Text(session.authNotice)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(AppTheme.textSecondary)
                    .multilineTextAlignment(.center)
            }

            if !session.authError.isEmpty {
                Text(session.authError)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Color(red: 0.78, green: 0.24, blue: 0.21))
                    .multilineTextAlignment(.center)
            }
        }
    }

    private func triggerGlint() {
        glintAngle = -120
        glintOpacity = 0.0
        withAnimation(.easeOut(duration: 0.18)) {
            glintOpacity = 0.95
        }
        withAnimation(.easeInOut(duration: 1.85)) {
            glintAngle = 300
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.65) {
            withAnimation(.easeOut(duration: 0.40)) {
                glintOpacity = 0.0
            }
        }
    }

    private func submit() async {
        if isCreateAccountMode {
            let cleanPassword = password.trimmingCharacters(in: .whitespacesAndNewlines)
            let cleanConfirm = confirmPassword.trimmingCharacters(in: .whitespacesAndNewlines)
            guard cleanPassword == cleanConfirm else {
                session.authError = "Passwords do not match."
                return
            }
            await session.signUp(email: email, password: password)
        } else {
            await session.login(email: email, password: password)
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var session: AppSessionStore
    @State private var selection: AppTab = .messages
    @StateObject private var messagesStore = MessagesSessionStore()

    private func refreshAllStores(scope: SessionScope) async {
        guard scope.isCurrent else { return }
        await AccountStore.shared.reloadFromCurrentMode()
        guard scope.isCurrent else { return }
        await AppProjectStore.shared.reloadFromCurrentMode()
        guard scope.isCurrent else { return }
        await ProviderConnectionStore.shared.reloadFromCurrentMode()
        guard scope.isCurrent else { return }
        await GideonModelSelectionStore.shared.reloadFromCurrentMode()
        guard scope.isCurrent else { return }
        await messagesStore.reloadFromCurrentMode()
    }

    var body: some View {
        Group {
            if session.isAuthenticated {
                ZStack {
                    AppTheme.background.ignoresSafeArea()

                    // Orb floats behind every page, centered.
                    OrbView(size: 398)
                        .opacity(0.90)
                        .offset(y: 22)
                        .mask(
                            LinearGradient(
                                stops: [
                                    .init(color: .clear, location: 0.00),
                                    .init(color: .white.opacity(0.28), location: 0.26),
                                    .init(color: .white.opacity(0.78), location: 0.46),
                                    .init(color: .white, location: 0.62),
                                    .init(color: .white, location: 0.86),
                                    .init(color: .white.opacity(0.30), location: 0.95),
                                    .init(color: .clear, location: 1.00)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .allowsHitTesting(false)

                    // Page content.
                    Group {
                        switch selection {
                        case .agent:    AgentView()
                        case .messages: MessagesView(store: messagesStore)
                        case .activity: ActivityView()
                        case .projects: ProjectView()
                        case .connections: ConnectionsView()
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(.opacity)
                }
                // Place tab row in the bottom safe area so taps remain reliable across all pages.
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    TabBar(selection: $selection)
                        .padding(.top, 8)
                        .padding(.bottom, 6)
                        .background(Color.clear)
                }
            } else {
                LoginView()
            }
        }
        .onAppear {
            guard session.isAuthenticated else { return }
            let scope = SessionScope.current
            Task { await refreshAllStores(scope: scope) }
        }
        .onChange(of: session.isAuthenticated) { _, isAuthenticated in
            guard isAuthenticated else { return }
            let scope = SessionScope.current
            Task { await refreshAllStores(scope: scope) }
        }
    }
}

#Preview {
    RootView()
}
