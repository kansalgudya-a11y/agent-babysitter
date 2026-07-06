import Foundation

/// Turns a GitHub release body (markdown) into a short plain-text "what's
/// new" digest for the update notification: the first few bullet points,
/// markdown stripped, each capped to one banner-friendly line.
public enum ReleaseNotesDigest {

    /// Up to `maxItems` lines, each "• …", or nil when the body has nothing
    /// usable. Bullets that lead with a bold span (our release-note style:
    /// "- **Headline.** Details…") are cut down to just the headline.
    public static func digest(markdown: String, maxItems: Int = 3,
                              maxItemLength: Int = 100) -> String? {
        var items: [String] = []
        // Bodies edited in GitHub's web UI use \r\n — and Swift treats
        // "\r\n" as ONE Character, so split(separator: "\n") would never
        // match it. Normalize before splitting.
        let normalized = markdown.replacingOccurrences(of: "\r\n", with: "\n")
        for rawLine in normalized.split(separator: "\n", omittingEmptySubsequences: true) {
            guard items.count < maxItems else { break }
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.hasPrefix("- ") || line.hasPrefix("* ") else { continue }
            var text = String(line.dropFirst(2))
            if let headline = boldLead(of: text) { text = headline }
            text = strippedMarkdown(text).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            if text.count > maxItemLength {
                text = String(text.prefix(maxItemLength - 1)) + "…"
            }
            items.append("• " + text)
        }
        return items.isEmpty ? nil : items.joined(separator: "\n")
    }

    /// "**Headline.** rest" → "Headline." — the bold span is the summary,
    /// the rest is detail the banner doesn't have room for.
    private static func boldLead(of text: String) -> String? {
        guard text.hasPrefix("**"),
              let close = text.dropFirst(2).range(of: "**") else { return nil }
        let headline = String(text.dropFirst(2)[..<close.lowerBound])
        return headline.isEmpty ? nil : headline
    }

    /// Strips inline markdown: `[text](url)` → text, then `**`, `*`, and
    /// backtick markers. Good enough for release-note bullets; anything it
    /// misses just shows as harmless punctuation.
    private static func strippedMarkdown(_ text: String) -> String {
        var result = text
        while let open = result.range(of: "["),
              let mid = result.range(of: "](", range: open.upperBound..<result.endIndex),
              let close = result.range(of: ")", range: mid.upperBound..<result.endIndex) {
            let label = result[open.upperBound..<mid.lowerBound]
            result.replaceSubrange(open.lowerBound..<close.upperBound, with: label)
        }
        for marker in ["**", "*", "`"] {
            result = result.replacingOccurrences(of: marker, with: "")
        }
        return result
    }
}
