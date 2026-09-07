import SwiftUI

struct MessagesView: View {
    @ObservedObject var store: MessagesSessionStore
    @EnvironmentObject private var modelSelection: GideonModelSelectionStore
    @FocusState private var isComposerFocused: Bool
    @State private var autoFollowLatest = true
    @State private var isAtBottom = true

    private let bottomAnchorID = "chat-bottom-anchor"

    var body: some View {
        VStack(spacing: 0) {
            // Pull-down bar: history in center, new chat on the right.
            ZStack {
                Menu {
                    Section("Chats") {
                        ForEach(store.chats) { chat in
                            Button {
                                store.selectChat(id: chat.id)
                            } label: {
                                Label(
                                    chat.title,
                                    systemImage: store.selectedChatID == chat.id ? "checkmark" : "bubble.left"
                                )
                            }
                        }
                    }
                } label: {
                    VStack(spacing: 4) {
                        Capsule()
                            .fill(AppTheme.textMuted)
                            .frame(width: 42, height: 4)

                        Text("HISTORY")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(AppTheme.textTertiary)
                            .tracking(1.2)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                HStack {
                    HeaderMenuButton()

                    Spacer(minLength: 0)

                    Button {
                        store.createNewChat()
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 18, weight: .regular))
                            .foregroundStyle(AppTheme.textPrimary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.trailing, 2)
            }
            .padding(.horizontal, 22)
            .padding(.top, 4)
            .onTapGesture {
                isComposerFocused = false
            }

            ScrollViewReader { proxy in
                ZStack(alignment: .bottomTrailing) {
                    ScrollView(showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(store.thread) { item in
                                VStack(alignment: item.role == .user ? .trailing : .leading, spacing: 4) {
                                    Text(item.text)
                                        .font(.system(size: 14.5, weight: .regular))
                                        .foregroundStyle(AppTheme.textPrimary)
                                        .padding(.horizontal, 14)
                                        .padding(.vertical, 10)
                                        .background(
                                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                                .fill(item.role == .user ? Color.white.opacity(0.92) : AppTheme.textPrimary.opacity(0.06))
                                        )

                                    Text(messageMetaText(for: item))
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundStyle(AppTheme.textTertiary)
                                        .padding(.horizontal, 2)
                                }
                                .frame(maxWidth: .infinity, alignment: item.role == .user ? .trailing : .leading)
                            }

                            if store.isGeneratingSelectedChat {
                                Text(generationStatusText)
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(AppTheme.textSecondary)
                                    .padding(.horizontal, 2)
                            }

                            if let email = store.pendingEmailForSelectedChat {
                                VStack(alignment: .leading, spacing: 8) {
                                    Label("Email awaiting approval", systemImage: "envelope.badge")
                                        .font(.headline)
                                    Text("From: \(email.sender)")
                                    Text("To: \(email.recipients.joined(separator: ", "))")
                                    Text("Subject: \(email.subject)")
                                    Button("Review email") { store.reviewingEmail = email }
                                        .buttonStyle(.borderedProminent)
                                        .accessibilityIdentifier("email.review")
                                }
                                .font(.subheadline)
                                .foregroundStyle(AppTheme.textPrimary)
                                .padding(16)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color.white, in: RoundedRectangle(cornerRadius: 16))
                            }

                            // Keeps newest content visible above composer controls.
                            Color.clear
                                .frame(height: 18)

                            Color.clear
                                .frame(height: 1)
                                .id(bottomAnchorID)
                                .onAppear {
                                    if !isAtBottom {
                                        isAtBottom = true
                                    }
                                    if !autoFollowLatest {
                                        autoFollowLatest = true
                                    }
                                }
                                .onDisappear {
                                    if isAtBottom {
                                        isAtBottom = false
                                    }
                                }
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 12)
                    }
                    .scrollDismissesKeyboard(.interactively)
                    .simultaneousGesture(
                        DragGesture(minimumDistance: 8)
                            .onChanged { drag in
                                // User intentionally pulled down to inspect older messages.
                                if drag.translation.height > 6, autoFollowLatest, !isAtBottom {
                                    autoFollowLatest = false
                                }
                            }
                    )
                    .onTapGesture {
                        isComposerFocused = false
                    }
                    .onAppear {
                        scrollToBottom(proxy: proxy, animated: false)
                    }
                    .onChange(of: store.thread.count) { _, _ in
                        scrollToBottom(proxy: proxy, animated: true)
                    }
                    .onChange(of: store.generatingChatID) { _, _ in
                        scrollToBottom(proxy: proxy, animated: true)
                    }
                    .onChange(of: store.selectedChatID) { _, _ in
                        autoFollowLatest = true
                        scrollToBottom(proxy: proxy, animated: false)
                    }
                    .onChange(of: isAtBottom) { _, atBottom in
                        if atBottom && !autoFollowLatest {
                            autoFollowLatest = true
                        }
                    }

                    if !autoFollowLatest && !isAtBottom {
                        Button {
                            autoFollowLatest = true
                            scrollToBottom(proxy: proxy, animated: true)
                        } label: {
                            Label("Latest", systemImage: "arrow.down")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(
                                    Capsule(style: .continuous)
                                        .fill(AppTheme.darkBlock)
                                )
                        }
                        .buttonStyle(.plain)
                        .padding(.trailing, 18)
                        .padding(.bottom, 10)
                    }
                }
            }

            chatControlRow
                .padding(.bottom, 14)
                .onTapGesture {
                    isComposerFocused = false
                }

            // Composer.
            composer
                .padding(.horizontal, 16)
                .padding(.bottom, 18)
        }
        .sheet(item: $store.reviewingEmail) { email in
            NavigationStack {
                Form {
                    Section("Sender") { Text(email.sender).textSelection(.enabled) }
                    Section("Recipients") {
                        ForEach(email.recipients, id: \.self) { Text($0).textSelection(.enabled) }
                    }
                    Section("Subject") { Text(email.subject).textSelection(.enabled) }
                    Section("Message") { Text(email.body).textSelection(.enabled) }
                    Section {
                        Text("Confirm sends this exact email through Gmail. Approval expires after 15 minutes. To change it, discard and ask Gideon for a revised email.")
                            .font(.footnote)
                        Button("Confirm & Send") { store.confirmEmail(email) }
                            .accessibilityIdentifier("email.confirmSend")
                        Button("Discard email", role: .destructive) { store.discardEmail(email) }
                            .accessibilityIdentifier("email.discard")
                    }
                }
                .navigationTitle("Review email")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close") { store.reviewingEmail = nil }
                    }
                }
            }
        }
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField("Message Gideon…", text: $store.message, axis: .vertical)
                .font(.system(size: 15))
                .foregroundStyle(AppTheme.textPrimary)
                .lineLimit(1...6)
                .padding(.leading, 18)
                .padding(.vertical, 10)
                .focused($isComposerFocused)

            Button {
                sendFromComposer()
            } label: {
                ZStack {
                    Circle()
                        .fill(AppTheme.darkBlock)
                        .frame(width: 38, height: 38)
                    Image(systemName: "arrow.up")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }
            .buttonStyle(.plain)
            .padding(.trailing, 6)
            .disabled(store.isGeneratingSelectedChat)
        }
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color.white)
                .shadow(color: Color.black.opacity(0.06), radius: 10, x: 0, y: 4)
        )
    }

    private var chatControlRow: some View {
        HStack(spacing: 10) {
            modelDropdownHalf
            reasoningDropdownHalf
        }
        .padding(.horizontal, 16)
    }

    private var modelDropdownHalf: some View {
        Menu {
            Section("Provider") {
                ForEach(modelSelection.providerOptions) { option in
                    Button {
                        modelSelection.selectProvider(option)
                    } label: {
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(option.title)
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(AppTheme.textPrimary)
                                Text(option.subtitle)
                                    .font(.system(size: 11.5, weight: .regular))
                                    .foregroundStyle(AppTheme.textSecondary)
                            }
                            Spacer(minLength: 8)
                                    if modelSelection.selectedProviderOption.id == option.id {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(AppTheme.textPrimary)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    .disabled(!option.isAvailable)
                }
            }
        } label: {
            dropdownChip(text: condensedProviderLabel)
        }
        .frame(maxWidth: .infinity)
        .buttonStyle(.plain)
        .disabled(modelSelection.providerOptions.isEmpty)
    }

    private var reasoningDropdownHalf: some View {
        Menu {
            Section("Model") {
                ForEach(modelSelection.modelVariantsForSelectedProvider) { option in
                    Button {
                        modelSelection.selectModelVariant(option)
                    } label: {
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(option.title)
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(AppTheme.textPrimary)
                                Text(option.detail)
                                    .font(.system(size: 11.5, weight: .regular))
                                    .foregroundStyle(AppTheme.textSecondary)
                            }
                            Spacer(minLength: 8)
                            if modelSelection.selectedModelVariant.id == option.id {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(AppTheme.textPrimary)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    .disabled(!option.isAvailable)
                }
            }
        } label: {
            dropdownChip(text: condensedVariantLabel)
        }
        .frame(maxWidth: .infinity)
        .buttonStyle(.plain)
    }

    private func dropdownChip(text: String) -> some View {
        HStack(spacing: 8) {
            Text(text)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(AppTheme.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .truncationMode(.tail)

            Image(systemName: "chevron.down")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(AppTheme.textTertiary)
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private var condensedProviderLabel: String {
        let title = modelSelection.selectedProviderOption.title
        if title.count <= 24 {
            return title
        }
        return "Provider: \(String(title.prefix(14)))"
    }

    private var condensedVariantLabel: String {
        let title = modelSelection.selectedModelVariant.title
        if title.count <= 24 {
            return title
        }
        return "Model: \(String(title.prefix(16)))"
    }

    private func sendFromComposer() {
        isComposerFocused = false
        store.sendCurrentMessage()
    }

    private func scrollToBottom(proxy: ScrollViewProxy, animated: Bool) {
        guard autoFollowLatest else { return }
        if animated {
            withAnimation(.easeOut(duration: 0.2)) {
                proxy.scrollTo(bottomAnchorID, anchor: .bottom)
            }
        } else {
            proxy.scrollTo(bottomAnchorID, anchor: .bottom)
        }
    }

    private func messageMetaText(for item: ChatItem) -> String {
        let time = Self.timestampFormatter.string(from: item.timestamp)
        guard item.role == .assistant,
              let modelLabel = item.modelLabel,
              !modelLabel.isEmpty else {
            return time
        }
        return "\(time) • \(modelLabel)"
    }

    private var generationStatusText: String {
        switch modelSelection.selectedOption.backend {
        case .localQwen:
            return "Thinking locally…"
        case .gideonServer:
            return "Thinking via server…"
        case .apiModel:
            return "Thinking via \(modelSelection.selectedOption.subtitle)…"
        }
    }

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        return formatter
    }()
}

struct ChatItem: Identifiable, Codable {
    enum Role: String, Codable {
        case user
        case assistant
    }

    let id: UUID
    let role: Role
    let text: String
    let modelLabel: String?
    let timestamp: Date

    init(id: UUID = UUID(), role: Role, text: String, modelLabel: String? = nil, timestamp: Date = Date()) {
        self.id = id
        self.role = role
        self.text = text
        self.modelLabel = modelLabel
        self.timestamp = timestamp
    }
}

struct ChatSession: Identifiable, Codable {
    var id: UUID
    var title: String
    var messages: [ChatItem]
}

@MainActor
final class MessagesSessionStore: ObservableObject {
    @Published var message: String = ""
    @Published private(set) var chats: [ChatSession] = []
    @Published private(set) var selectedChatID: UUID?
    @Published var isGenerating = false
    @Published private(set) var generatingChatID: UUID?
    @Published var isPreparingModel = false
    @Published var reviewingEmail: PendingGmailSend?
    @Published private var emailApprovals: [UUID: EmailApproval] = [:]
    @Published private var sendingEmailChats: Set<UUID> = []

    private struct EmailApproval {
        let email: PendingGmailSend
        let session: GideonAgentToolSession
        let scope: SessionScope
    }

    var pendingEmailForSelectedChat: PendingGmailSend? {
        selectedChatID.flatMap { emailApprovals[$0]?.email }
    }

    func discardEmail(_ email: PendingGmailSend) {
        guard loadedScope.isCurrent else { return }
        guard let entry = emailApprovals.first(where: { $0.value.email.id == email.id }) else { return }
        emailApprovals.removeValue(forKey: entry.key)
        reviewingEmail = nil
        Task { await entry.value.session.discardPendingSend(id: email.id) }
        append(.init(role: .assistant, text: "Email discarded. Nothing was sent.", modelLabel: "Gmail"), to: entry.key)
    }

    func confirmEmail(_ email: PendingGmailSend) {
        let scope = SessionScope.current
        guard scope.isCurrent, loadedScope == scope else { return }
        guard let chatID = selectedChatID, let approval = emailApprovals[chatID],
              approval.scope == scope, approval.email == email, !sendingEmailChats.contains(chatID) else { return }
        // Consume UI approval synchronously; model output and repeated taps cannot authorize sending.
        emailApprovals.removeValue(forKey: chatID)
        reviewingEmail = nil
        sendingEmailChats.insert(chatID)
        append(.init(role: .assistant,
                     text: "Email send approved. Awaiting Gmail's response. If this run is interrupted, check Sent before attempting another send.",
                     modelLabel: "Gmail"), to: chatID)
        Task {
            guard scope.isCurrent else { return }
            let outcome = await approval.session.confirmSend(id: email.id)
            guard scope.isCurrent else { return }
            sendingEmailChats.remove(chatID)
            append(.init(role: .assistant, text: outcome.text, modelLabel: "Gmail"), to: chatID)
        }
    }

    private var generationTask: Task<Void, Never>?
    private var observerTokens: [NSObjectProtocol] = []
    private var coldLaunchChatID: UUID?
    private var loadedScope = SessionScope.current
    private static let storageKey = "gideon.chatSessions.v2"
    private static let selectedChatStorageKey = "gideon.chatSessions.selected.v1"
    private let coldStartTimeoutNanoseconds: UInt64 = 180_000_000_000
    private var generationTimeoutNanoseconds: UInt64 {
        let selection = GideonModelSelectionStore.shared
        let tokenCap = selection.maxNewTokens
        let seconds: Int
        switch selection.selectedOption.backend {
        case .apiModel:
            // Remote turns may contain multiple bounded model/tool round trips.
            seconds = 300
        case .gideonServer:
            seconds = max(25, tokenCap)
        default:
            switch selection.reasoningMode {
            case .quick:
                seconds = 25
            case .balanced:
                seconds = max(40, tokenCap)
            case .deep:
                seconds = max(60, tokenCap * 2)
            }
        }
        return UInt64(seconds) * 1_000_000_000
    }

    init() {
        loadLocal()
        registerObservers()
        let scope = SessionScope.current
        if scope.canSyncCloud {
            Task {
                guard scope.isCurrent else { return }
                await loadCloud(scope: scope)
                guard scope.isCurrent else { return }
                selectFreshChatForColdLaunch()
            }
        } else {
            selectFreshChatForColdLaunch()
        }
        warmModelIfNeeded()
    }

    deinit {
        generationTask?.cancel()
    }

    func sendCurrentMessage() {
        let scope = SessionScope.current
        guard scope.isCurrent, loadedScope == scope else { return }
        let prompt = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return }
        guard let selectedChatID else { return }
        guard generatingChatID != selectedChatID else { return }
        guard !sendingEmailChats.contains(selectedChatID) else { return }
        if let previous = emailApprovals[selectedChatID] { discardEmail(previous.email) }
        let responseModelLabel = GideonModelSelectionStore.shared.selectedOption.title
        let isRemote = GideonModelSelectionStore.shared.selectedOption.backend == .apiModel

        generationTask?.cancel()

        append(.init(role: .user, text: prompt), to: selectedChatID)
        message = ""
        isGenerating = true
        generatingChatID = selectedChatID

        // Exclude the just-appended user message because it is provided separately
        // as `prompt` to the harness.
        let historyTurns = activeThread.dropLast().map { item in
            HarnessTurn(role: item.role == .user ? .user : .assistant, text: item.text)
        }

        generationTask = Task {
            guard scope.isCurrent else { return }
            let timeout = !isRemote && self.activeThread.count <= 1 ? self.coldStartTimeoutNanoseconds : self.generationTimeoutNanoseconds
            let result = await respondWithTimeout(prompt: prompt, history: historyTurns, timeoutNanoseconds: timeout, scope: scope)
            guard scope.isCurrent else { return }

            guard self.generatingChatID == selectedChatID else { return }
            if let result {
                self.append(.init(role: .assistant, text: result.text, modelLabel: responseModelLabel), to: selectedChatID)
                if let email = result.pendingEmail, let session = result.emailSession {
                    self.emailApprovals[selectedChatID] = EmailApproval(email: email, session: session, scope: scope)
                }
            } else {
                self.append(
                    .init(
                        role: .assistant,
                        text: isRemote
                            ? "The provider/tool run timed out and was cancelled. Completed actions were not undone. Check Activity before retrying."
                            : "The local model timed out on this turn. Please try again with a shorter prompt.",
                        modelLabel: responseModelLabel
                    ),
                    to: selectedChatID
                )
            }
            self.generatingChatID = nil
            self.isGenerating = false
        }
    }

    var isGeneratingSelectedChat: Bool {
        guard let selectedChatID else { return false }
        return generatingChatID == selectedChatID || sendingEmailChats.contains(selectedChatID)
    }

    func createNewChat() {
        guard loadedScope.isCurrent else { return }
        let chat = ChatSession(
            id: UUID(),
            title: "New Chat",
            messages: []
        )
        chats.insert(chat, at: 0)
        selectedChatID = chat.id
        message = ""
        persist()
    }

    private func selectFreshChatForColdLaunch() {
        if let existing = chats.first(where: { $0.messages.isEmpty }) {
            coldLaunchChatID = existing.id
            selectedChatID = existing.id
            message = ""
            persist()
            return
        }
        createNewChat()
        coldLaunchChatID = selectedChatID
    }

    func selectChat(id: UUID) {
        guard loadedScope.isCurrent, chats.contains(where: { $0.id == id }) else { return }
        reviewingEmail = nil
        if id != coldLaunchChatID {
            coldLaunchChatID = nil
        }
        selectedChatID = id
        message = ""
        persistLocal()
    }

    var thread: [ChatItem] {
        activeThread
    }

    var selectedChatTitle: String {
        chats.first(where: { $0.id == selectedChatID })?.title ?? "Chats"
    }

    func warmModelIfNeeded() {
        let scope = SessionScope.current
        guard scope.isCurrent, loadedScope == scope else { return }
        guard !isPreparingModel else { return }
        isPreparingModel = true

        Task {
            guard scope.isCurrent else { return }
            _ = await LocalQwenRuntime.shared.warmUp()
            guard scope.isCurrent else { return }
            self.isPreparingModel = false
        }
    }

    private func respondWithTimeout(prompt: String, history: [HarnessTurn], timeoutNanoseconds: UInt64, scope: SessionScope) async -> HarnessResult? {
        guard scope.isCurrent else { return nil }
        let result = await withTaskGroup(of: HarnessResult?.self, returning: HarnessResult?.self) { group in
            group.addTask {
                guard await MainActor.run(body: { scope.isCurrent }) else { return nil }
                let result = await GideonAgentHarness.shared.respond(to: prompt, history: history)
                guard await MainActor.run(body: { scope.isCurrent }) else { return nil }
                return result
            }

            group.addTask {
                try? await Task.sleep(nanoseconds: timeoutNanoseconds)
                return nil
            }

            let firstFinished = await group.next() ?? nil
            group.cancelAll()
            guard scope.isCurrent else { return nil }
            return firstFinished
        }
        guard scope.isCurrent else { return nil }
        return result
    }

    private var activeThread: [ChatItem] {
        guard let selectedChatID,
              let index = chats.firstIndex(where: { $0.id == selectedChatID }) else {
            return []
        }
        return chats[index].messages
    }

    private func append(_ item: ChatItem, to chatID: UUID) {
        guard loadedScope.isCurrent else { return }
        guard let index = chats.firstIndex(where: { $0.id == chatID }) else {
            return
        }

        chats[index].messages.append(item)
        if chats[index].title == "New Chat", item.role == .user {
            let trimmed = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
            chats[index].title = String(trimmed.prefix(28)).isEmpty ? "New Chat" : String(trimmed.prefix(28))
        }

        persist()
    }

    private func persist() {
        let scope = SessionScope.current
        guard scope.isCurrent, loadedScope == scope else { return }
        persistLocal()
        guard scope.canSyncCloud else { return }
        Task { [snapshot = chats, selected = selectedChatID] in
            guard scope.isCurrent else { return }
            await persistCloud(snapshot: snapshot, selectedID: selected, scope: scope)
        }
    }

    private func persistLocal() {
        guard loadedScope.isCurrent else { return }
        if let selectedChatID {
            ScopedDefaults.standard.set(selectedChatID.uuidString, forKey: Self.selectedChatStorageKey)
        } else {
            ScopedDefaults.standard.removeObject(forKey: Self.selectedChatStorageKey)
        }

        guard let data = try? JSONEncoder().encode(chats) else { return }
        ScopedDefaults.standard.set(data, forKey: Self.storageKey)
    }

    private func loadLocal() {
        guard let data = ScopedDefaults.standard.data(forKey: Self.storageKey),
              let decoded = try? JSONDecoder().decode([ChatSession].self, from: data) else {
            chats = []
            selectedChatID = nil
            return
        }

        chats = decoded

        if let savedSelected = ScopedDefaults.standard.string(forKey: Self.selectedChatStorageKey),
           let uuid = UUID(uuidString: savedSelected),
           chats.contains(where: { $0.id == uuid }) {
            selectedChatID = uuid
        } else {
            selectedChatID = chats.first?.id
        }
    }

    private func registerObservers() {
        for name in [Notification.Name.gideonSessionChanged, .gideonDataModeChanged] {
            observerTokens.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let scope = SessionScope.current
                    self.resetForCurrentScope(scope)
                    Task { [weak self] in
                        guard scope.isCurrent else { return }
                        await self?.reload(scope: scope)
                    }
                }
            })
        }
    }

    private func resetForCurrentScope(_ scope: SessionScope) {
        // Only an uninterrupted same-owner transition may preserve a launch chat.
        let launchChat = loadedScope.userID == scope.userID && selectedChatID == coldLaunchChatID
            ? coldLaunchChatID.flatMap { id in chats.first(where: { $0.id == id }) }
            : nil
        generationTask?.cancel()
        generationTask = nil
        generatingChatID = nil
        isGenerating = false
        isPreparingModel = false
        message = ""
        reviewingEmail = nil
        let discarded = Array(emailApprovals.values)
        emailApprovals.removeAll()
        sendingEmailChats.removeAll()
        chats = []
        selectedChatID = nil
        coldLaunchChatID = nil
        loadedScope = scope
        loadLocal()
        if let launchChat {
            if !chats.contains(where: { $0.id == launchChat.id }) {
                chats.insert(launchChat, at: 0)
            }
            coldLaunchChatID = launchChat.id
            selectedChatID = launchChat.id
        }
        // Cleanup deliberately targets the captured old actors even after a scope
        // change. It cannot send mail or write any new-session UI/cache state.
        for approval in discarded {
            Task { await approval.session.discardPendingSend(id: approval.email.id) }
        }
    }

    func reloadFromCurrentMode() async {
        let scope = SessionScope.current
        guard scope.isCurrent else { return }
        resetForCurrentScope(scope)
        await reload(scope: scope)
    }

    private func reload(scope: SessionScope) async {
        guard scope.isCurrent else { return }
        let launchChat = selectedChatID == coldLaunchChatID
            ? coldLaunchChatID.flatMap { id in chats.first(where: { $0.id == id }) }
            : nil
        if scope.canSyncCloud {
            await loadCloud(scope: scope)
            guard scope.isCurrent else { return }
        }
        if let launchChat {
            if !chats.contains(where: { $0.id == launchChat.id }) {
                chats.insert(launchChat, at: 0)
            }
            selectedChatID = launchChat.id
            persist()
        } else if chats.isEmpty {
            createNewChat()
        }
    }

    private func loadCloud(scope: SessionScope) async {
        guard scope.isCurrent, scope.canSyncCloud,
              let userID = scope.userID,
              let token = AppSessionStore.shared.currentAccessToken,
              let url = URL(string: "\(AppSessionStore.supabaseRESTURL)/chat_sessions?user_id=eq.\(userID)&select=*&order=created_at.desc") else {
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        request.setValue(AppSessionStore.supabasePublishableKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard scope.isCurrent else { return }
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return
            }

            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let rows = try decoder.decode([SupabaseChatSessionDTO].self, from: data)
            guard rows.allSatisfy({ $0.userID.lowercased() == userID }) else { return }
            if rows.isEmpty {
                chats = []
                selectedChatID = nil
                persistLocal()
                return
            }

            let cloudChats = rows.map { $0.toRecord() }
            chats = cloudChats
            if let selected = rows.first(where: { $0.isSelected == true })?.id,
               chats.contains(where: { $0.id == selected }) {
                selectedChatID = selected
            } else {
                selectedChatID = chats.first?.id
            }
            persistLocal()
        } catch {
            // Keep local cache when cloud read fails.
        }
    }

    private func persistCloud(snapshot: [ChatSession], selectedID: UUID?, scope: SessionScope) async {
        guard scope.isCurrent, scope.canSyncCloud,
              let userID = scope.userID,
              let token = AppSessionStore.shared.currentAccessToken,
              !snapshot.isEmpty,
              let insertURL = URL(string: "\(AppSessionStore.supabaseRESTURL)/chat_sessions?on_conflict=user_id,id") else {
            return
        }

        do {
            let payload = snapshot.map {
                SupabaseChatSessionDTO(record: $0, userID: userID, isSelected: $0.id == selectedID)
            }
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601

            var insertRequest = URLRequest(url: insertURL)
            insertRequest.httpMethod = "POST"
            insertRequest.timeoutInterval = 30
            insertRequest.setValue(AppSessionStore.supabasePublishableKey, forHTTPHeaderField: "apikey")
            insertRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            insertRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
            insertRequest.setValue("return=minimal, resolution=merge-duplicates", forHTTPHeaderField: "Prefer")
            insertRequest.httpBody = try encoder.encode(payload)

            let (_, response) = try await URLSession.shared.data(for: insertRequest)
            guard scope.isCurrent else { return }
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else {
                print("[Gideon] chat cloud insert failed for user \(userID)")
                return
            }
        } catch {
            guard scope.isCurrent else { return }
            print("[Gideon] chat cloud sync error: \(error.localizedDescription)")
        }
    }

    private func totalMessageCount(_ sessions: [ChatSession]) -> Int {
        sessions.reduce(0) { partial, session in
            partial + session.messages.count
        }
    }
}

private struct SupabaseChatSessionDTO: Codable {
    let id: UUID
    let userID: String
    let title: String
    let messagesJSON: [ChatItem]
    let isSelected: Bool?
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case userID = "user_id"
        case title
        case messagesJSON = "messages_json"
        case isSelected = "is_selected"
        case createdAt = "created_at"
    }

    init(record: ChatSession, userID: String, isSelected: Bool) {
        self.id = record.id
        self.userID = userID
        self.title = record.title
        self.messagesJSON = record.messages
        self.isSelected = isSelected
        self.createdAt = record.messages.first?.timestamp ?? Date()
    }

    func toRecord() -> ChatSession {
        ChatSession(id: id, title: title, messages: messagesJSON)
    }
}

#Preview { RootView() }
