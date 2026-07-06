import Foundation

struct BundledModelInfo {
    let displayName: String
    let runtimeLabel: String
    let shortLabel: String
    let detailLabel: String
    let isAvailable: Bool
    let statusLabel: String
    let hasModelBundle: Bool
    let hasTokenizerAssets: Bool
}

enum LocalModelRegistry {
    static let current: BundledModelInfo = detectQwenModel()

    private static func detectQwenModel() -> BundledModelInfo {
        let fallback = BundledModelInfo(
            displayName: "Qwen2.5-Coder-1.5B-Instruct",
            runtimeLabel: "in-app core (not bundled)",
            shortLabel: "Qwen2.5-Coder-1.5B",
            detailLabel: "(Add qwen *.mlmodelc file to app bundle)",
            isAvailable: false,
            statusLabel: "Missing",
            hasModelBundle: false,
            hasTokenizerAssets: false
        )

        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: Bundle.main.bundleURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return fallback
        }

        var foundCoreMLPaths: Set<String> = []
        var foundGGUF = false
        var hasTokenizerJSON = false
        var hasTokenizerConfig = false
        var hasSpecialTokensMap = false
        var hasVocabJSON = false
        var hasMergesTXT = false

        for case let url as URL in enumerator {
            let filename = url.lastPathComponent.lowercased()

            if filename == "tokenizer.json" { hasTokenizerJSON = true }
            if filename == "tokenizer_config.json" { hasTokenizerConfig = true }
            if filename == "special_tokens_map.json" { hasSpecialTokensMap = true }
            if filename == "vocab.json" { hasVocabJSON = true }
            if filename == "merges.txt" { hasMergesTXT = true }

            let ext = url.pathExtension.lowercased()
            switch ext {
            case "mlmodelc":
                if isQwen25Candidate(filename: filename) {
                    foundCoreMLPaths.insert(filename)
                }
            case "mlpackage":
                if isQwen25Candidate(filename: filename) {
                    foundCoreMLPaths.insert(filename)
                }
            case "gguf":
                if isQwen25Candidate(filename: filename) {
                    foundGGUF = true
                }
            default:
                continue
            }
        }

        let hasTokenizerAssets =
            hasTokenizerJSON ||
            (hasTokenizerJSON && hasTokenizerConfig) ||
            (hasTokenizerJSON && hasVocabJSON && hasMergesTXT) ||
            (hasTokenizerConfig && hasSpecialTokensMap)
        let hasDecode = foundCoreMLPaths.contains(where: { !$0.contains("prefill") })
        let hasCoreMLModel = hasDecode

        if foundGGUF {
            return BundledModelInfo(
                displayName: "Qwen2.5-Coder-1.5B-Instruct",
                runtimeLabel: "in-app GGUF",
                shortLabel: "Qwen2.5-Coder-1.5B",
                detailLabel: hasTokenizerAssets ? "(GGUF bundled)" : "(GGUF bundled, tokenizer files missing)",
                isAvailable: hasTokenizerAssets,
                statusLabel: hasTokenizerAssets ? "Active" : "Tokenizer Missing",
                hasModelBundle: true,
                hasTokenizerAssets: hasTokenizerAssets
            )
        }

        if hasCoreMLModel {
            return BundledModelInfo(
                displayName: "Qwen2.5-Coder-1.5B-Instruct",
                runtimeLabel: "in-app Core ML",
                shortLabel: "Qwen2.5-Coder-1.5B",
                detailLabel: hasTokenizerAssets ? "(Core ML bundled)" : "(Core ML bundled, tokenizer files missing)",
                isAvailable: hasTokenizerAssets,
                statusLabel: hasTokenizerAssets ? "Active" : "Tokenizer Missing",
                hasModelBundle: true,
                hasTokenizerAssets: hasTokenizerAssets
            )
        }

        return fallback
    }

    private static func isQwen25Candidate(filename: String) -> Bool {
        let hasQwen = filename.contains("qwen")
        let has25 = filename.contains("2.5") || filename.contains("2_5") || filename.contains("25")
        return hasQwen && has25
    }
}
