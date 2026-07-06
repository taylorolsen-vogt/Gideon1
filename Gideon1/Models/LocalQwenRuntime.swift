import Foundation
import CoreML
import os

actor LocalQwenRuntime {
    static let shared = LocalQwenRuntime()

    private var engineBox: Any?
    private let minimumRAMBytesForThisModel: UInt64 = 4 * 1024 * 1024 * 1024

    func warmUp() async -> String? {
        #if targetEnvironment(simulator)
        return "Local Qwen inference is not supported in iOS Simulator for this model build. Run on a physical iPhone (iOS 18+) to execute locally."
        #else

        let ram = ProcessInfo.processInfo.physicalMemory
        if ram < minimumRAMBytesForThisModel {
            let gb = Double(ram) / 1_073_741_824.0
            return "This Qwen 2.5 1.5B Core ML build is too large for this device memory (\(String(format: "%.1f", gb)) GB). Use a smaller model variant for stable on-device chat."
        }

        let modelInfo = LocalModelRegistry.current
        guard modelInfo.hasModelBundle else {
            return "Local model is not bundled in the app target yet."
        }
        guard modelInfo.hasTokenizerAssets else {
            return "Tokenizer assets are missing from the app bundle."
        }

        guard #available(iOS 18.0, *) else {
            return "This local Qwen runtime requires iOS 18.0 or newer."
        }

        do {
            _ = try ensureEngine()
            return nil
        } catch {
            return "Local Qwen error: \(error.localizedDescription)"
        }
        #endif
    }

    func generateReply(prompt: String, maxNewTokens: Int = 72) async -> String {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        #if targetEnvironment(simulator)
        return "Local Qwen inference is not supported in iOS Simulator for this model build. Run on a physical iPhone (iOS 18+) to execute locally."
        #else

        let ram = ProcessInfo.processInfo.physicalMemory
        if ram < minimumRAMBytesForThisModel {
            let gb = Double(ram) / 1_073_741_824.0
            return "This Qwen 2.5 1.5B Core ML build is too large for this device memory (\(String(format: "%.1f", gb)) GB). Use a smaller model variant for stable on-device chat."
        }

        let modelInfo = LocalModelRegistry.current
        guard modelInfo.hasModelBundle else {
            return "Local model is not bundled in the app target yet."
        }
        guard modelInfo.hasTokenizerAssets else {
            return "Tokenizer assets are missing from the app bundle."
        }

        guard #available(iOS 18.0, *) else {
            return "This local Qwen runtime requires iOS 18.0 or newer."
        }

        do {
            let engine = try ensureEngine()
            return try await engine.generate(prompt: trimmed, maxNewTokens: maxNewTokens)
        } catch {
            return "Local Qwen error: \(error.localizedDescription)"
        }
        #endif
    }

    @available(iOS 18.0, *)
    private func ensureEngine() throws -> QwenCoreMLEngine {
        if engineBox == nil {
            engineBox = try QwenCoreMLEngine()
        }
        guard let engine = engineBox as? QwenCoreMLEngine else {
            throw RuntimeError("Unable to initialize local Qwen runtime.")
        }
        return engine
    }
}

@available(iOS 18.0, *)
private final class QwenCoreMLEngine: @unchecked Sendable {
    private let logger = Logger(subsystem: "com.taylorolsenvogt.Gideon1", category: "LocalQwenRuntime")
    private let model: MLModel
    private let tokenizer: QwenBPETokenizer
    private let contextLength: Int
    private let stopTokenIDs: Set<Int>
    private let debugGeneration: Bool

    init() throws {
        guard let modelURL = Bundle.main.url(forResource: "qwen25_monolithic_lut4", withExtension: "mlmodelc") else {
            throw RuntimeError("qwen25_monolithic_lut4.mlmodelc not found in bundle")
        }
        self.model = try QwenCoreMLEngine.loadBundledModel(modelURL: modelURL)

        self.tokenizer = try QwenBPETokenizer.loadFromBundle()
        self.contextLength = 2048
        self.stopTokenIDs = tokenizer.stopTokenIDs
        #if DEBUG
        self.debugGeneration = true
        #else
        self.debugGeneration = ProcessInfo.processInfo.environment["GIDEON_DEBUG_GENERATION"] == "1"
        #endif
    }

    private static func loadBundledModel(modelURL: URL) throws -> MLModel {
        // Single deterministic backend to prioritize compatibility and reliability.
        let config = MLModelConfiguration()
        config.computeUnits = .cpuAndGPU
        do {
            return try MLModel(contentsOf: modelURL, configuration: config)
        } catch {
            throw RuntimeError("Unable to load bundled local model (cpuAndGPU): \(error.localizedDescription)")
        }
    }

    func generate(prompt: String, maxNewTokens: Int) async throws -> String {
        var promptIDs = tokenizer.encode(prompt)
        if promptIDs.isEmpty {
            return ""
        }

        if debugGeneration {
            logger.info("prompt_chars=\(prompt.count), prompt_tokens=\(promptIDs.count), maxNewTokens=\(maxNewTokens)")
            logger.debug("prompt_ids_prefix=\(String(describing: Array(promptIDs.prefix(24))))")
        }

        if promptIDs.count >= contextLength {
            promptIDs = Array(promptIDs.suffix(contextLength - 1))
        }

        let state = model.makeState()

        var currentPos = 0
        var nextToken = 0

        // Prime KV cache one token at a time with prompt.
        for token in promptIDs {
            nextToken = try await step(
                token: token,
                position: currentPos,
                state: state,
                recentTokens: promptIDs,
                lastToken: promptIDs.last,
                avoidRepetition: false
            )
            currentPos += 1
            if currentPos >= contextLength {
                break
            }
        }

        if debugGeneration {
            logger.info("primed_tokens=\(currentPos), first_next_token=\(nextToken)")
        }

        var generated: [Int] = []
        var produced = 0
        var repeatedTokenRun = 0
        var lastGeneratedToken: Int?

        while produced < maxNewTokens && currentPos < contextLength {
            if stopTokenIDs.contains(nextToken) {
                break
            }

            if let last = lastGeneratedToken, last == nextToken {
                repeatedTokenRun += 1
            } else {
                repeatedTokenRun = 0
            }

            // Bail out if decoding collapses into a tight loop.
            if repeatedTokenRun >= 6 {
                break
            }

            generated.append(nextToken)
            lastGeneratedToken = nextToken
            produced += 1

            if debugGeneration {
                logger.debug("generated_token[\(produced)] id=\(nextToken) text=\(self.tokenizer.debugTokenString(for: nextToken))")
            }

            nextToken = try await step(
                token: nextToken,
                position: currentPos,
                state: state,
                recentTokens: generated,
                lastToken: lastGeneratedToken,
                avoidRepetition: true
            )
            currentPos += 1
        }

        let raw = tokenizer.decode(generated)
        let cleaned = sanitizeGeneratedText(raw)

        if debugGeneration {
            logger.info("raw_output=\(raw, privacy: .public)")
            logger.info("cleaned_output=\(cleaned, privacy: .public)")
            logger.info("generated_ids=\(String(describing: generated))")
        }

        if cleaned.isEmpty {
            let diag = failureSignature(reason: "empty", promptIDs: promptIDs, generatedIDs: generated)
            if debugGeneration {
                logger.error("generation_fallback=empty_output")
                return debugFailureReport(
                    reason: "empty_output",
                    promptIDs: promptIDs,
                    generatedIDs: generated,
                    raw: raw,
                    cleaned: cleaned
                )
            }
            return "I hit a local generation glitch. Please try again. \(diag)"
        }
        if isLikelyDegenerateText(cleaned) {
            let diag = failureSignature(reason: "degenerate", promptIDs: promptIDs, generatedIDs: generated)
            if debugGeneration {
                logger.error("generation_fallback=degenerate_output")
                return debugFailureReport(
                    reason: "degenerate_output",
                    promptIDs: promptIDs,
                    generatedIDs: generated,
                    raw: raw,
                    cleaned: cleaned
                )
            }
            return "I hit a local generation glitch. Please try again with a shorter prompt. \(diag)"
        }
        return cleaned
    }

    private func failureSignature(reason: String, promptIDs: [Int], generatedIDs: [Int]) -> String {
        let firstGen = generatedIDs.first ?? -1
        let lastGen = generatedIDs.last ?? -1
        return "[diag r=\(reason) p=\(promptIDs.count) g=\(generatedIDs.count) g0=\(firstGen) gl=\(lastGen)]"
    }

    private func debugFailureReport(
        reason: String,
        promptIDs: [Int],
        generatedIDs: [Int],
        raw: String,
        cleaned: String
    ) -> String {
        let promptPreview = promptIDs.prefix(24).map(String.init).joined(separator: ", ")
        let generatedPreview = generatedIDs.prefix(32).map(String.init).joined(separator: ", ")

        return """
        DEBUG TRACE: \(reason)
        prompt_tokens=\(promptIDs.count)
        prompt_preview=[\(promptPreview)]
        generated_tokens=\(generatedIDs.count)
        generated_preview=[\(generatedPreview)]
        raw_output=\(raw)
        cleaned_output=\(cleaned.isEmpty ? "<empty>" : cleaned)
        """
    }

    private func sanitizeGeneratedText(_ text: String) -> String {
        var output = text

        // Remove common control token artifacts if they leak through decoding.
        output = output.replacingOccurrences(of: "<|im_start|>", with: "")
        output = output.replacingOccurrences(of: "<|im_end|>", with: "")
        output = output.replacingOccurrences(of: "<|endoftext|>", with: "")

        // If control tokens leak through, trim at the first marker.
        let hardStops = ["<|im_end|>", "<|endoftext|>"]
        for marker in hardStops {
            if let range = output.range(of: marker) {
                output = String(output[..<range.lowerBound])
            }
        }

        // Stop if the model begins writing the next turn labels.
        let cutMarkers = ["\nUser:", "\nAssistant:", "\nSystem:"]
        for marker in cutMarkers {
            if let range = output.range(of: marker) {
                output = String(output[..<range.lowerBound])
            }
        }

        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func isLikelyDegenerateText(_ text: String) -> Bool {
        let normalizedTokens = text.lowercased()
            .replacingOccurrences(of: "\n", with: " ")
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)

        guard normalizedTokens.count >= 10 else {
            return false
        }

        let uniqueTokenRatio = Double(Set(normalizedTokens).count) / Double(normalizedTokens.count)
        if uniqueTokenRatio < 0.35 {
            return true
        }

        let joined = normalizedTokens.joined(separator: " ")
        let head = String(joined.prefix(min(14, joined.count)))
        guard head.count >= 8 else {
            return false
        }

        let repeats = joined.components(separatedBy: head).count - 1
        return repeats >= 4
    }

    private func step(
        token: Int,
        position: Int,
        state: MLState,
        recentTokens: [Int],
        lastToken: Int?,
        avoidRepetition: Bool
    ) async throws -> Int {
        let inputIDs = try MLMultiArray(shape: [1, 1], dataType: .int32)
        // For this stateful Qwen export, `causal_mask` acts as a length signal.
        // The model wrapper reads end_step from mask shape and builds causal mask internally.
        let endStep = min(max(position + 1, 1), contextLength)
        let causalMask = try MLMultiArray(shape: [1, 1, 1, NSNumber(value: endStep)], dataType: .float16)

        writeInt32(inputIDs, [Int32(token)])
        fillCausalMask(causalMask, position: position)

        let provider = try MLDictionaryFeatureProvider(dictionary: [
            "input_ids": MLFeatureValue(multiArray: inputIDs),
            "causal_mask": MLFeatureValue(multiArray: causalMask)
        ])

        let output = try await model.prediction(from: provider, using: state, options: MLPredictionOptions())
        let selection = argmaxTokenID(from: output)
        let chosenToken = chooseToken(
            from: selection,
            recentTokens: recentTokens,
            lastToken: lastToken,
            avoidRepetition: avoidRepetition
        )

        if debugGeneration {
            let candidateSummary = selection.topCandidates.map { "\($0.tokenID):\($0.score)" }.joined(separator: ", ")
            logger.debug("step pos=\(position) input=\(token) selected=\(selection.tokenID) chosen=\(chosenToken) chosenText=\(self.tokenizer.debugTokenString(for: chosenToken))")
            logger.debug("step_top_candidates=\(candidateSummary, privacy: .public)")
            if let logits = output.featureValue(for: "logits")?.multiArrayValue {
                logger.debug("step_logits_shape=\(String(describing: logits.shape.map { $0.intValue }))")
            }
        }

        return chosenToken
    }

    private func chooseToken(
        from selection: TokenSelection,
        recentTokens: [Int],
        lastToken: Int?,
        avoidRepetition: Bool
    ) -> Int {
        guard !selection.topCandidates.isEmpty else {
            return selection.tokenID
        }

        let recentWindow = Array(recentTokens.suffix(24))
        let tailRunLength: Int = {
            guard let lastToken else { return 0 }
            var run = 0
            for token in recentWindow.reversed() {
                if token == lastToken {
                    run += 1
                } else {
                    break
                }
            }
            return run
        }()

        for candidate in selection.topCandidates {
            let id = candidate.tokenID
            if stopTokenIDs.contains(id) {
                continue
            }

            if !tokenizer.hasToken(id) {
                continue
            }

            if !avoidRepetition {
                return id
            }

            if let lastToken, id == lastToken, tailRunLength >= 2 {
                continue
            }

            return id
        }

        return selection.tokenID
    }

    private func argmaxTokenID(from provider: MLFeatureProvider) -> TokenSelection {
        if let logits = provider.featureValue(for: "logits")?.multiArrayValue {
            return argmaxLastPosition(logits)
        }

        let chunkSize = 9496
        var bestValue = -Float.greatestFiniteMagnitude
        var bestTokenID = 0
        var topCandidates: [TokenCandidate] = []

        for chunk in 1...16 {
            let name = "logits\(chunk)"
            guard let array = provider.featureValue(for: name)?.multiArrayValue else {
                continue
            }
            let allowedCount = min(chunkSize, array.count)

            let (localIndex, localValue) = argmax(array, start: 0, length: allowedCount)
            topCandidates.append(TokenCandidate(tokenID: (chunk - 1) * chunkSize + localIndex, score: localValue))
            if localValue > bestValue {
                bestValue = localValue
                bestTokenID = (chunk - 1) * chunkSize + localIndex
            }
        }

        return TokenSelection(tokenID: bestTokenID, topCandidates: topCandidates.sorted(by: { $0.score > $1.score }).prefix(5).map { $0 })
    }

    private func argmaxLastPosition(_ logits: MLMultiArray) -> TokenSelection {
        let dims = logits.shape.map { $0.intValue }
        let strides = logits.strides.map { $0.intValue }

        // Common LLM layout is [batch, sequence, vocab]. We only want the final sequence position.
        if dims.count >= 2, strides.count == dims.count {
            let vocabSize = max(1, dims[dims.count - 1])
            let sequenceLength = max(1, dims[dims.count - 2])
            let sequenceStride = strides[dims.count - 2]
            let vocabStride = strides[dims.count - 1]
            let start = (sequenceLength - 1) * sequenceStride
            let allowedVocab = vocabSize

            if allowedVocab > 0, start >= 0, vocabStride > 0 {
                let top = topK(from: logits, start: start, length: allowedVocab, stride: vocabStride, k: 20)
                return TokenSelection(tokenID: top.first?.tokenID ?? 0, topCandidates: top)
            }
        }

        let safeLength = logits.count
        if safeLength > 0 {
            let top = topK(from: logits, start: 0, length: safeLength, stride: 1, k: 20)
            return TokenSelection(tokenID: top.first?.tokenID ?? 0, topCandidates: top)
        }
        return TokenSelection(tokenID: 0, topCandidates: [])
    }

    private func topK(from array: MLMultiArray, start: Int, length: Int, stride: Int, k: Int) -> [TokenCandidate] {
        guard start >= 0, length > 0, stride > 0, k > 0 else { return [] }

        var candidates: [TokenCandidate] = []
        candidates.reserveCapacity(min(k, length))

        func insert(_ candidate: TokenCandidate) {
            candidates.append(candidate)
            candidates.sort { $0.score > $1.score }
            if candidates.count > k {
                candidates.removeLast(candidates.count - k)
            }
        }

        switch array.dataType {
        case .float16:
            let ptr = array.dataPointer.bindMemory(to: UInt16.self, capacity: array.count)
            for i in 0..<length {
                let idx = start + i * stride
                if idx < 0 || idx >= array.count { break }
                let candidate = TokenCandidate(tokenID: i, score: Float(Float16(bitPattern: ptr[idx])))
                insert(candidate)
            }
        case .float32:
            let ptr = array.dataPointer.bindMemory(to: Float.self, capacity: array.count)
            for i in 0..<length {
                let idx = start + i * stride
                if idx < 0 || idx >= array.count { break }
                insert(TokenCandidate(tokenID: i, score: ptr[idx]))
            }
        case .double:
            let ptr = array.dataPointer.bindMemory(to: Double.self, capacity: array.count)
            for i in 0..<length {
                let idx = start + i * stride
                if idx < 0 || idx >= array.count { break }
                insert(TokenCandidate(tokenID: i, score: Float(ptr[idx])))
            }
        default:
            for i in 0..<length {
                let idx = start + i * stride
                if idx < 0 || idx >= array.count { break }
                insert(TokenCandidate(tokenID: i, score: array[idx].floatValue))
            }
        }

        return candidates
    }

    private func argmax(_ array: MLMultiArray) -> (Int, Float) {
        argmax(array, start: 0, length: array.count)
    }

    private func argmax(_ array: MLMultiArray, start: Int, length: Int) -> (Int, Float) {
        var bestIndex = 0
        var bestValue = -Float.greatestFiniteMagnitude
        let count = max(0, min(length, array.count - start))

        guard count > 0 else { return (0, bestValue) }

        switch array.dataType {
        case .float16:
            let ptr = array.dataPointer.bindMemory(to: UInt16.self, capacity: array.count)
            for i in 0..<count {
                let value = Float(Float16(bitPattern: ptr[start + i]))
                if value > bestValue {
                    bestValue = value
                    bestIndex = i
                }
            }
        case .float32:
            let ptr = array.dataPointer.bindMemory(to: Float.self, capacity: array.count)
            for i in 0..<count {
                let value = ptr[start + i]
                if value > bestValue {
                    bestValue = value
                    bestIndex = i
                }
            }
        case .double:
            let ptr = array.dataPointer.bindMemory(to: Double.self, capacity: array.count)
            for i in 0..<count {
                let value = Float(ptr[start + i])
                if value > bestValue {
                    bestValue = value
                    bestIndex = i
                }
            }
        default:
            for i in 0..<count {
                let value = array[start + i].floatValue
                if value > bestValue {
                    bestValue = value
                    bestIndex = i
                }
            }
        }

        return (bestIndex, bestValue)
    }


    private func writeInt32(_ array: MLMultiArray, _ values: [Int32]) {
        let ptr = array.dataPointer.bindMemory(to: Int32.self, capacity: values.count)
        for i in values.indices {
            ptr[i] = values[i]
        }
    }

    private func fillCausalMask(_ mask: MLMultiArray, position: Int) {
        // Stateful wrapper expects an all-zero tensor with shape [1,1,1,end_step].
        // It computes the true lower-triangular causal mask internally.
        let cap = mask.count
        switch mask.dataType {
        case .float16:
            let ptr = mask.dataPointer.bindMemory(to: UInt16.self, capacity: cap)
            let zero = Float16(0).bitPattern
            for i in 0..<cap {
                ptr[i] = zero
            }
        case .float32:
            let ptr = mask.dataPointer.bindMemory(to: Float.self, capacity: cap)
            for i in 0..<cap {
                ptr[i] = 0
            }
        default:
            for i in 0..<cap {
                mask[i] = NSNumber(value: 0.0)
            }
        }
    }
}

private struct QwenBPETokenizer {
    private let vocab: [String: Int]
    private let inverseVocab: [Int: String]
    private let mergesRank: [String: Int]
    private let byteToUnicode: [UInt8: Character]
    private let unicodeToByte: [Character: UInt8]
    private let unkID: Int
    private let specialTokens: [(token: String, id: Int)]
    let maxTokenID: Int
    let stopTokenIDs: Set<Int>

    static func loadFromBundle() throws -> QwenBPETokenizer {
        let tokenizerJSONURL = Bundle.main.url(forResource: "tokenizer", withExtension: "json")
        let tokenizerConfigURL = Bundle.main.url(forResource: "tokenizer_config", withExtension: "json")

        if let tokenizerJSONURL {
            return try QwenBPETokenizer(tokenizerJSONURL: tokenizerJSONURL, tokenizerConfigURL: tokenizerConfigURL)
        }

        guard let vocabURL = Bundle.main.url(forResource: "vocab", withExtension: "json"),
              let mergesURL = Bundle.main.url(forResource: "merges", withExtension: "txt") else {
            throw RuntimeError("Tokenizer assets not found in bundle")
        }

        return try QwenBPETokenizer(vocabURL: vocabURL, mergesURL: mergesURL, tokenizerConfigURL: tokenizerConfigURL)
    }

    init(tokenizerJSONURL: URL, tokenizerConfigURL: URL?) throws {
        let data = try Data(contentsOf: tokenizerJSONURL)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let model = json["model"] as? [String: Any],
              let rawVocab = model["vocab"] as? [String: Int] else {
            throw RuntimeError("Invalid tokenizer.json format")
        }

        var mergedVocab = rawVocab
        if let addedTokens = json["added_tokens"] as? [[String: Any]] {
            for token in addedTokens {
                if let content = token["content"] as? String,
                   let id = token["id"] as? Int {
                    mergedVocab[content] = id
                }
            }
        }
        self.vocab = mergedVocab

        var inv: [Int: String] = [:]
        inv.reserveCapacity(mergedVocab.count)
        for (token, id) in mergedVocab {
            inv[id] = token
        }
        self.inverseVocab = inv
        self.maxTokenID = inv.keys.max() ?? 0

        var ranks: [String: Int] = [:]
        var rank = 0
        if let merges = model["merges"] as? [String] {
            for pair in merges {
                let trimmed = pair.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty { continue }
                ranks[trimmed] = rank
                rank += 1
            }
        } else if let merges = model["merges"] as? [[String]] {
            for pair in merges where pair.count == 2 {
                ranks["\(pair[0]) \(pair[1])"] = rank
                rank += 1
            }
        }
        self.mergesRank = ranks

        let maps = QwenBPETokenizer.makeByteUnicodeMaps()
        self.byteToUnicode = maps.byteToUnicode
        self.unicodeToByte = maps.unicodeToByte

        if let unkToken = model["unk_token"] as? String,
           let unkID = mergedVocab[unkToken] {
            self.unkID = unkID
        } else {
            self.unkID = mergedVocab["<|unk|>"] ?? 0
        }

        self.specialTokens = mergedVocab
            .filter { key, _ in key.hasPrefix("<") && key.hasSuffix(">") }
            .map { ($0.key, $0.value) }
            .sorted { $0.token.count > $1.token.count }

        var stops = Set<Int>()
          if let configURL = tokenizerConfigURL,
              let stopSet = try? QwenBPETokenizer.loadStopIDs(configURL: configURL, vocab: mergedVocab) {
            stops.formUnion(stopSet)
        }
        if let eos = mergedVocab["<|endoftext|>"] {
            stops.insert(eos)
        }
        self.stopTokenIDs = stops
    }

    init(vocabURL: URL, mergesURL: URL, tokenizerConfigURL: URL?) throws {
        let vocabData = try Data(contentsOf: vocabURL)
        guard let raw = try JSONSerialization.jsonObject(with: vocabData) as? [String: Int] else {
            throw RuntimeError("Invalid vocab.json format")
        }
        self.vocab = raw

        var inv: [Int: String] = [:]
        inv.reserveCapacity(raw.count)
        for (token, id) in raw {
            inv[id] = token
        }
        self.inverseVocab = inv
        self.maxTokenID = inv.keys.max() ?? 0

        let mergesText = try String(contentsOf: mergesURL, encoding: .utf8)
        var ranks: [String: Int] = [:]
        var rank = 0
        for line in mergesText.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                continue
            }
            ranks[trimmed] = rank
            rank += 1
        }
        self.mergesRank = ranks

        let maps = QwenBPETokenizer.makeByteUnicodeMaps()
        self.byteToUnicode = maps.byteToUnicode
        self.unicodeToByte = maps.unicodeToByte

        self.unkID = raw["<|unk|>"] ?? 0
        self.specialTokens = raw
            .filter { key, _ in key.hasPrefix("<") && key.hasSuffix(">") }
            .map { ($0.key, $0.value) }
            .sorted { $0.token.count > $1.token.count }

        var stops = Set<Int>()
          if let configURL = tokenizerConfigURL,
              let stopSet = try? QwenBPETokenizer.loadStopIDs(configURL: configURL, vocab: raw) {
            stops.formUnion(stopSet)
        }
        if let eos = raw["<|endoftext|>"] {
            stops.insert(eos)
        }
        self.stopTokenIDs = stops
    }

    func encode(_ text: String) -> [Int] {
        var output: [Int] = []
        var cursor = text.startIndex

        while cursor < text.endIndex {
            if let special = matchSpecialToken(in: text, at: cursor) {
                output.append(special.id)
                cursor = text.index(cursor, offsetBy: special.token.count)
                continue
            }

            let nextSpecial = nextSpecialTokenIndex(in: text, from: cursor)
            let end = nextSpecial ?? text.endIndex
            let chunk = String(text[cursor..<end])
            let subChunks = preTokenize(chunk)

            for subChunk in subChunks {
                let transformed = String(subChunk.utf8.map { byteToUnicode[$0] ?? " " })
                let pieces = bpe(transformed)
                for piece in pieces {
                    if let id = vocab[piece] {
                        output.append(id)
                    } else if piece.count > 1 {
                        // If a merged token is missing, fall back to smaller units
                        // rather than collapsing to a single unknown token.
                        for ch in piece {
                            output.append(vocab[String(ch)] ?? unkID)
                        }
                    } else {
                        output.append(unkID)
                    }
                }
            }

            cursor = end
        }

        return output
    }

    func decode(_ tokenIDs: [Int]) -> String {
        let joined = tokenIDs.compactMap { inverseVocab[$0] }.joined()
        var bytes: [UInt8] = []
        bytes.reserveCapacity(joined.utf8.count)

        for ch in joined {
            if let b = unicodeToByte[ch] {
                bytes.append(b)
            } else {
                let s = String(ch)
                bytes.append(contentsOf: s.utf8)
            }
        }

        return String(decoding: bytes, as: UTF8.self)
    }

    func debugTokenString(for tokenID: Int) -> String {
        guard let token = inverseVocab[tokenID] else {
            return "<missing:\(tokenID)>"
        }

        return token
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
    }

    func hasToken(_ tokenID: Int) -> Bool {
        inverseVocab[tokenID] != nil
    }

    private func preTokenize(_ text: String) -> [String] {
        guard !text.isEmpty else { return [] }

        let pattern = #"(?i:'s|'t|'re|'ve|'m|'ll|'d)|[^\r\n\p{L}\p{N}]?\p{L}+|\p{N}| ?[^\s\p{L}\p{N}]+[\r\n]*|\s*[\r\n]+|\s+(?!\S)|\s+"#
        if let regex = try? NSRegularExpression(pattern: pattern, options: []) {
            let nsText = text as NSString
            let range = NSRange(location: 0, length: nsText.length)
            let matches = regex.matches(in: text, options: [], range: range)
            if !matches.isEmpty {
                return matches.map { nsText.substring(with: $0.range) }
            }
        }

        var out: [String] = []
        var current = ""
        var currentIsWS: Bool?

        for ch in text {
            let ws = ch.isWhitespace
            if let flag = currentIsWS {
                if flag == ws {
                    current.append(ch)
                } else {
                    out.append(current)
                    current = String(ch)
                    currentIsWS = ws
                }
            } else {
                current.append(ch)
                currentIsWS = ws
            }
        }

        if !current.isEmpty {
            out.append(current)
        }
        return out
    }

    private func matchSpecialToken(in text: String, at index: String.Index) -> (token: String, id: Int)? {
        for entry in specialTokens {
            guard let end = text.index(index, offsetBy: entry.token.count, limitedBy: text.endIndex) else {
                continue
            }
            if text[index..<end] == entry.token {
                return entry
            }
        }
        return nil
    }

    private func nextSpecialTokenIndex(in text: String, from index: String.Index) -> String.Index? {
        var best: String.Index?
        for entry in specialTokens {
            if let found = text.range(of: entry.token, range: index..<text.endIndex)?.lowerBound {
                if best == nil || found < best! {
                    best = found
                }
            }
        }
        return best
    }

    private func bpe(_ token: String) -> [String] {
        if token.count <= 1 {
            return [token]
        }

        var word = token.map { String($0) }

        while word.count > 1 {
            var bestRank = Int.max
            var bestIndex: Int?

            for i in 0..<(word.count - 1) {
                let pair = "\(word[i]) \(word[i + 1])"
                if let rank = mergesRank[pair], rank < bestRank {
                    bestRank = rank
                    bestIndex = i
                }
            }

            guard let idx = bestIndex else {
                break
            }

            word[idx] = word[idx] + word[idx + 1]
            word.remove(at: idx + 1)
        }

        return word
    }

    private static func loadStopIDs(configURL: URL, vocab: [String: Int]) throws -> Set<Int> {
        let data = try Data(contentsOf: configURL)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }

        var ids = Set<Int>()

        if let eos = json["eos_token_id"] as? Int {
            ids.insert(eos)
        } else if let eosList = json["eos_token_id"] as? [Int] {
            ids.formUnion(eosList)
        }

        if let eosToken = json["eos_token"] as? String,
           let eosTokenID = vocab[eosToken] {
            ids.insert(eosTokenID)
        } else if let eosTokenList = json["eos_token"] as? [String] {
            for token in eosTokenList {
                if let id = vocab[token] {
                    ids.insert(id)
                }
            }
        }

        if let modelMax = json["model_max_length"] as? Int, modelMax > 0 {
            _ = modelMax
        }

        return ids
    }

    private static func makeByteUnicodeMaps() -> (byteToUnicode: [UInt8: Character], unicodeToByte: [Character: UInt8]) {
        var bs: [UInt8] = []
        bs.append(contentsOf: Array(33...126))
        bs.append(contentsOf: Array(161...172))
        bs.append(contentsOf: Array(174...255))

        var cs = bs.map { Int($0) }
        var n = 0

        for b in 0...255 {
            let ub = UInt8(b)
            if !bs.contains(ub) {
                bs.append(ub)
                cs.append(256 + n)
                n += 1
            }
        }

        var b2u: [UInt8: Character] = [:]
        var u2b: [Character: UInt8] = [:]
        b2u.reserveCapacity(256)
        u2b.reserveCapacity(256)

        for (b, c) in zip(bs, cs) {
            if let scalar = UnicodeScalar(c) {
                let ch = Character(scalar)
                b2u[b] = ch
                u2b[ch] = b
            }
        }

        return (b2u, u2b)
    }
}

private struct TokenCandidate {
    let tokenID: Int
    let score: Float
}

private struct TokenSelection {
    let tokenID: Int
    let topCandidates: [TokenCandidate]
}

private struct RuntimeError: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? { message }
}
