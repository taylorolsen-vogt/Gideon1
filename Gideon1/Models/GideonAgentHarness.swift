import Foundation

struct HarnessTurn {
    enum Role {
        case user
        case assistant
    }

    let role: Role
    let text: String
}

struct HarnessResult {
    let text: String
    let usedTool: Bool
}

protocol GideonTool {
    var name: String { get }
    var description: String { get }
    func run(input: String) -> String
}

struct DeviceTimeTool: GideonTool {
    let name = "device_time"
    let description = "Returns current local date and time on device."

    func run(input: String) -> String {
        let f = DateFormatter()
        f.dateFormat = "EEEE, MMM d, h:mm a"
        return "Current local time: \(f.string(from: Date()))"
    }
}

actor GideonAgentHarness {
    static let shared = GideonAgentHarness()

    private let runtime = LocalQwenRuntime.shared
    private let remoteRuntime = RemoteGideonRuntime.shared
    private let tools: [any GideonTool] = [DeviceTimeTool()]

    func respond(to userInput: String, history: [HarnessTurn]) async -> HarnessResult {
        let settings = await MainActor.run {
            let store = GideonModelSelectionStore.shared
            return (
                selectedModelID: store.selectedModelID,
                backend: store.selectedOption.backend,
                routeLabel: "\(store.selectedOption.title) (\(store.selectedOption.subtitle))",
                mode: store.reasoningMode,
                tokens: Self.tunedTokenLimit(base: store.maxNewTokens, mode: store.reasoningMode),
                modeInstruction: store.reasoningMode.promptInstruction,
                apiConfig: store.resolveAPIModelConfig(for: store.selectedModelID)
            )
        }

        let toolContext = maybeRunTool(for: userInput)
        let prompt = buildPrompt(
            userInput: userInput,
            history: history,
            toolContext: toolContext,
            reasoningInstruction: settings.modeInstruction,
            routeContext: settings.routeLabel,
            mode: settings.mode
        )

        let text: String
        switch settings.backend {
        case .localQwen:
            text = await runtime.generateReply(prompt: prompt, maxNewTokens: settings.tokens)
        case .gideonServer:
            text = "Server Gideon is planned and not connected yet. Use Local or an API model for now."
        case .apiModel:
            guard let apiConfig = settings.apiConfig else {
                text = "This API model is not configured. Add a valid endpoint and API key in Agent Profile."
                break
            }
            text = await remoteRuntime.generateReply(
                context: RemoteGideonRequestContext(
                    endpoint: apiConfig.endpoint,
                    apiKey: apiConfig.apiKey,
                    modelIdentifier: apiConfig.modelID,
                    provider: apiConfig.provider,
                    maxNewTokens: settings.tokens,
                    userMessage: userInput,
                    history: history
                )
            )
        }

        return HarnessResult(
            text: normalizeFinalAnswer(text, mode: settings.mode),
            usedTool: toolContext != nil
        )
    }

    private static func tunedTokenLimit(base: Int, mode: GideonReasoningMode) -> Int {
        switch mode {
        case .quick:
            return min(base, 16)
        case .balanced:
            return min(base, 32)
        case .deep:
            return base
        }
    }

    private func maybeRunTool(for input: String) -> String? {
        let lower = input.lowercased()
        if lower.contains("time") || lower.contains("date") {
            guard let tool = tools.first(where: { $0.name == "device_time" }) else {
                return nil
            }
            let output = tool.run(input: input)
            return "TOOL_RESULT[\(tool.name)]: \(output)"
        }
        return nil
    }

    private func buildPrompt(
        userInput: String,
        history: [HarnessTurn],
        toolContext: String?,
        reasoningInstruction: String,
        routeContext: String,
        mode: GideonReasoningMode
    ) -> String {
        let modeStyle: String
        switch mode {
        case .quick:
            modeStyle = "Reply in exactly one short sentence unless the user asks for detail. Do not ask follow-up questions."
        case .balanced:
            modeStyle = "Reply in one or two short sentences by default."
        case .deep:
            modeStyle = "You may give a longer answer when it helps, but stay focused."
        }

        let system = """
        You are Gideon, an assistant in the Gideon app.
        Be concise, helpful, and clear.
        Default to 1-2 short sentences unless the user asks for detail.
        Current response route: \(routeContext).
        \(reasoningInstruction)
        \(modeStyle)
        Respond in English unless the user explicitly asks for another language.
        If a tool result is provided, use it directly and do not invent values.
        Reply as plain text for end users.
        """

        var parts: [String] = []
        parts.append("<|im_start|>system\n\(system)<|im_end|>")

        let historyCount: Int
        let perTurnCharLimit: Int
        switch mode {
        case .quick:
            historyCount = 1
            perTurnCharLimit = 120
        case .balanced:
            historyCount = 3
            perTurnCharLimit = 240
        case .deep:
            historyCount = 4
            perTurnCharLimit = 320
        }

        for turn in history.suffix(historyCount) {
            let clipped = String(turn.text.prefix(perTurnCharLimit))
            switch turn.role {
            case .user:
                parts.append("<|im_start|>user\n\(clipped)<|im_end|>")
            case .assistant:
                parts.append("<|im_start|>assistant\n\(clipped)<|im_end|>")
            }
        }

        if let toolContext {
            parts.append("<|im_start|>system\n\(toolContext)<|im_end|>")
        }

        parts.append("<|im_start|>user\n\(userInput)<|im_end|>")
        parts.append("<|im_start|>assistant\n")

        return parts.joined(separator: "\n")
    }

    private func normalizeFinalAnswer(_ text: String, mode: GideonReasoningMode) -> String {
        let cleaned = text
            .replacingOccurrences(of: "Assistant:", with: "")
            .replacingOccurrences(of: "User:", with: "")
            .replacingOccurrences(of: "<|im_start|>", with: "")
            .replacingOccurrences(of: "<|im_end|>", with: "")
            .replacingOccurrences(of: "assistant\n", with: "")
            .replacingOccurrences(of: "user\n", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let maxSentences: Int
        switch mode {
        case .quick:
            maxSentences = 1
        case .balanced:
            maxSentences = 2
        case .deep:
            maxSentences = 3
        }

        let deduped = collapseRepeatedSentences(cleaned, maxSentences: maxSentences)

        if deduped.isEmpty {
            return "I’m here. Could you rephrase that?"
        }
        return deduped
    }

    private func collapseRepeatedSentences(_ text: String, maxSentences: Int) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"[^.!?]+[.!?]?"#) else {
            return text
        }

        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        let parts = matches
            .map { ns.substring(with: $0.range).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard parts.count > 1 else { return text }

        var output: [String] = []
        var seen = Set<String>()
        for part in parts {
            let normalized = part.lowercased()
            if seen.contains(normalized) {
                continue
            }
            seen.insert(normalized)
            output.append(part)
            if output.count >= maxSentences {
                break
            }
        }

        guard !output.isEmpty else { return text }
        return output.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
