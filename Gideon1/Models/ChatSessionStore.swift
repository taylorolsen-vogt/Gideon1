import Foundation

struct ChatMessage: Identifiable {
    enum Role {
        case user
        case assistant
    }

    let id = UUID()
    let role: Role
    let text: String
    let timestamp: Date = Date()
}

@MainActor
final class ChatSessionStore: ObservableObject {
    @Published var composerText: String = ""
    @Published var thread: [ChatMessage] = []
    @Published var isGenerating: Bool = false

    private var generationTask: Task<Void, Never>?

    deinit {
        generationTask?.cancel()
    }

    func sendCurrentMessage() {
        let prompt = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, !isGenerating else { return }

        composerText = ""
        thread.append(.init(role: .user, text: prompt))
        isGenerating = true

        // Exclude the current user message since `prompt` carries it separately.
        let historyTurns = thread.dropLast().map { item in
            HarnessTurn(role: item.role == .user ? .user : .assistant, text: item.text)
        }

        generationTask?.cancel()
        generationTask = Task { [weak self] in
            guard let self else { return }
            let result = await GideonAgentHarness.shared.respond(to: prompt, history: historyTurns)
            guard !Task.isCancelled else { return }
            self.thread.append(.init(role: .assistant, text: result.text))
            self.isGenerating = false
        }
    }
}
