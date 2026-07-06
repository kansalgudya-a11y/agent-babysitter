import Foundation

/// Human labels for model ids in the stats window: "claude-opus-4-8" →
/// "Opus 4.8", "gpt-5.2-codex" → "GPT-5.2 Codex". Claude and OpenAI ids
/// (the two families we price) are transformed; anything else passes
/// through untouched rather than guessed.
public enum ModelNames {

    public static func pretty(_ id: String) -> String {
        var trimmed = id
        // Date suffix: claude-haiku-4-5-20251001 → claude-haiku-4-5
        if let range = trimmed.range(of: #"-\d{8}$"#, options: .regularExpression) {
            trimmed = String(trimmed[..<range.lowerBound])
        }
        if trimmed.hasPrefix("claude-") {
            let parts = trimmed.dropFirst("claude-".count).split(separator: "-").map(String.init)
            let numbers = parts.filter { $0.allSatisfy(\.isNumber) }
            let words = parts.filter { !$0.allSatisfy(\.isNumber) }
            guard let family = words.last, !family.isEmpty else { return id }
            let version = numbers.joined(separator: ".")
            let name = family.prefix(1).uppercased() + family.dropFirst()
            return version.isEmpty ? name : "\(name) \(version)"
        }
        // OpenAI: gpt-5.2-codex → "GPT-5.2 Codex", gpt-5.1-codex-mini →
        // "GPT-5.1 Codex Mini". "GPT-<version>" keeps the hyphen; trailing
        // words (codex, mini) are title-cased and space-joined.
        if trimmed == "gpt" || trimmed.hasPrefix("gpt-") {
            let parts = trimmed.split(separator: "-").map(String.init)
            guard parts.first?.lowercased() == "gpt" else { return id }
            var out = "GPT"
            for (i, part) in parts.dropFirst().enumerated() {
                let word = part.first?.isNumber == true
                    ? part : part.prefix(1).uppercased() + part.dropFirst()
                // Version number attaches with a hyphen; words with a space.
                out += (i == 0 && part.first?.isNumber == true) ? "-\(word)" : " \(word)"
            }
            return out
        }
        return id
    }
}
