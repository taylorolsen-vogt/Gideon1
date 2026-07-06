import SwiftUI

struct MessagesView: View {
    @ObservedObject var store: MessagesSessionStore
    @EnvironmentObject private var modelSelection: GideonModelSelectionStore
    @FocusState private var isComposerFocused: Bool

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
                    HStack(spacing: 8) {
                        Capsule()
                            .fill(AppTheme.textMuted)
                            .frame(width: 42, height: 4)

                        Image(systemName: "chevron.down")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(AppTheme.textTertiary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                HStack {
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

                            Text(Self.timestampFormatter.string(from: item.timestamp))
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(AppTheme.textTertiary)
                                .padding(.horizontal, 2)
                        }
                        .frame(maxWidth: .infinity, alignment: item.role == .user ? .trailing : .leading)
                    }

                    if store.isGenerating {
                        Text(generationStatusText)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(AppTheme.textSecondary)
                            .padding(.horizontal, 2)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
            }
            .scrollDismissesKeyboard(.interactively)

            Spacer()

            chatControlRow
                .padding(.bottom, 14)

            // Composer.
            composer
                .padding(.horizontal, 16)
                .padding(.bottom, 18)
        }
        .contentShape(Rectangle())
        .simultaneousGesture(
            TapGesture().onEnded {
                isComposerFocused = false
            }
        )
    }

    private var composer: some View {
        HStack(spacing: 10) {
            TextField("Message Gideon…", text: $store.message)
                .font(.system(size: 15))
                .foregroundStyle(AppTheme.textPrimary)
                .padding(.leading, 18)
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
            .disabled(store.isGenerating)
        }
        .padding(.vertical, 6)
        .background(
            Capsule(style: .continuous)
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
            Section("Model") {
                ForEach(modelSelection.options) { option in
                    Button {
                        modelSelection.select(option)
                    } label: {
                        Label(
                            option.title,
                            systemImage: modelSelection.selectedOption.id == option.id ? "checkmark" : "circle"
                        )
                    }
                    .disabled(!option.isAvailable)
                }
            }
        } label: {
            dropdownChip(text: condensedModelLabel)
        }
        .frame(maxWidth: .infinity)
        .buttonStyle(.plain)
        .disabled(modelSelection.options.isEmpty)
    }

    private var reasoningDropdownHalf: some View {
        Menu {
            Section("Reasoning") {
                ForEach(GideonReasoningMode.allCases, id: \.rawValue) { mode in
                    Button {
                        modelSelection.reasoningMode = mode
                    } label: {
                        Label(
                            mode.displayName,
                            systemImage: modelSelection.reasoningMode == mode ? "checkmark" : "circle"
                        )
                    }
                }
            }

            Section("Max Tokens") {
                ForEach([24, 32, 40, 56, 72, 96], id: \.self) { tokenCap in
                    Button {
                        modelSelection.maxNewTokens = tokenCap
                    } label: {
                        Label(
                            "\(tokenCap) tokens",
                            systemImage: modelSelection.maxNewTokens == tokenCap ? "checkmark" : "circle"
                        )
                    }
                }
            }
        } label: {
            dropdownChip(text: "Reasoning: \(modelSelection.reasoningMode.displayName)")
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

    private var condensedModelLabel: String {
        let title = modelSelection.selectedOption.title
        if title.count <= 24 {
            return title
        }
        return "Model: \(String(title.prefix(16)))"
    }

    private func sendFromComposer() {
        isComposerFocused = false
        store.sendCurrentMessage()
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

struct ChatItem: Identifiable {
    enum Role {
        case user
        case assistant
    }

    let id = UUID()
    let role: Role
    let text: String
    let timestamp: Date = Date()
}

struct ChatSession: Identifiable {
    let id: UUID
    var title: String
    var messages: [ChatItem]
}

@MainActor
final class MessagesSessionStore: ObservableObject {
    @Published var message: String = ""
    @Published private(set) var chats: [ChatSession] = []
    @Published private(set) var selectedChatID: UUID?
    @Published var isGenerating = false
    @Published var isPreparingModel = false

    private var generationTask: Task<Void, Never>?
    private let coldStartTimeoutNanoseconds: UInt64 = 180_000_000_000
    private var generationTimeoutNanoseconds: UInt64 {
        let selection = GideonModelSelectionStore.shared
        let tokenCap = selection.maxNewTokens
        let seconds: Int
        switch selection.selectedOption.backend {
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
        createNewChat()
        warmModelIfNeeded()
    }

    deinit {
        generationTask?.cancel()
    }

    func sendCurrentMessage() {
        let prompt = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, !isGenerating else { return }
        guard let selectedChatID else { return }

        generationTask?.cancel()

        append(.init(role: .user, text: prompt), to: selectedChatID)
        message = ""
        isGenerating = true

        // Exclude the just-appended user message because it is provided separately
        // as `prompt` to the harness.
        let historyTurns = activeThread.dropLast().map { item in
            HarnessTurn(role: item.role == .user ? .user : .assistant, text: item.text)
        }

        generationTask = Task {
            let timeout = self.activeThread.count <= 1 ? self.coldStartTimeoutNanoseconds : self.generationTimeoutNanoseconds
            let result = await respondWithTimeout(prompt: prompt, history: historyTurns, timeoutNanoseconds: timeout)
            if Task.isCancelled { return }

            await MainActor.run {
                if let result {
                    self.append(.init(role: .assistant, text: result.text), to: selectedChatID)
                } else {
                    self.append(
                        .init(
                            role: .assistant,
                            text: "I’m still loading the local model and timed out on this turn. Please try again with a shorter prompt."
                        ),
                        to: selectedChatID
                    )
                }
                self.isGenerating = false
            }
        }
    }

    func createNewChat() {
        let chat = ChatSession(
            id: UUID(),
            title: "New Chat",
            messages: []
        )
        chats.insert(chat, at: 0)
        selectedChatID = chat.id
        message = ""
    }

    func selectChat(id: UUID) {
        selectedChatID = id
        message = ""
    }

    var thread: [ChatItem] {
        activeThread
    }

    var selectedChatTitle: String {
        chats.first(where: { $0.id == selectedChatID })?.title ?? "Chats"
    }

    func warmModelIfNeeded() {
        guard !isPreparingModel else { return }
        isPreparingModel = true

        Task {
            _ = await LocalQwenRuntime.shared.warmUp()
            await MainActor.run {
                self.isPreparingModel = false
            }
        }
    }

    private func respondWithTimeout(prompt: String, history: [HarnessTurn], timeoutNanoseconds: UInt64) async -> HarnessResult? {
        await withTaskGroup(of: HarnessResult?.self) { group in
            group.addTask {
                await GideonAgentHarness.shared.respond(to: prompt, history: history)
            }

            group.addTask {
                try? await Task.sleep(nanoseconds: timeoutNanoseconds)
                return nil
            }

            let firstFinished = await group.next() ?? nil
            group.cancelAll()
            return firstFinished
        }
    }

    private var activeThread: [ChatItem] {
        guard let selectedChatID,
              let index = chats.firstIndex(where: { $0.id == selectedChatID }) else {
            return []
        }
        return chats[index].messages
    }

    private func append(_ item: ChatItem, to chatID: UUID) {
        guard let index = chats.firstIndex(where: { $0.id == chatID }) else {
            return
        }

        chats[index].messages.append(item)
        if chats[index].title == "New Chat", item.role == .user {
            let trimmed = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
            chats[index].title = String(trimmed.prefix(28)).isEmpty ? "New Chat" : String(trimmed.prefix(28))
        }
    }
}

#Preview { RootView() }
