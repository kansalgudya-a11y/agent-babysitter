import Foundation

/// One redacted, display-safe summary of a single tool invocation (F11).
///
/// The `summary` is ALWAYS the output of `ToolCallRedactor.redact` — it has been
/// stripped of anything resembling a key/token/password/credential and bounded to
/// one short line. This type is the ONLY tool-call representation that may be
/// stored, displayed, or persisted; the raw `tool_input` (which carries secret-
/// bearing shell command lines and file contents) is never retained. It must never
/// be placed in a notification body, the webhook payload, or any synced/exported
/// file — see the privacy contract in F7/F11.
public struct ToolCallSummary: Equatable, Sendable, Codable {
    public let tool: String     // "Bash", "Edit", "mcp__x__y"
    public let summary: String  // redacted, ≤120 chars; "" when there was nothing salient
    public let at: Date

    public init(tool: String, summary: String, at: Date) {
        self.tool = tool
        self.summary = summary
        self.at = at
    }

    /// "Bash: npm test" — tool + summary, for one-line display.
    public var line: String { summary.isEmpty ? tool : "\(tool): \(summary)" }
}

/// Turns a raw PreToolUse `tool_input` into a redacted one-line summary.
///
/// SECURITY CONTRACT (non-negotiable): agent command lines are known to embed
/// secrets — third-party API keys, bearer tokens, passwords, credentials in URLs.
/// `redact` is the first-class, probe-tested boundary that guarantees no such shape
/// survives into anything the app stores or shows. The design bias is deliberate:
/// OVER-redaction (a benign value replaced by the placeholder) is acceptable;
/// UNDER-redaction (a real secret surviving) is a defect. Every rule below is
/// therefore written to fail safe, and a catch-all high-entropy pass backstops any
/// secret shape the structured rules miss.
public enum ToolCallRedactor {

    /// Marker substituted for every stripped secret. Contains no secret-shaped
    /// characters (10 chars, no digit) so later passes never re-match it.
    static let placeholder = "‹redacted›"

    // MARK: - Public API

    /// Strip secrets from a raw tool-input fragment and bound it to one short line.
    ///
    /// Neutralizes, in order: userinfo credentials in URLs (`scheme://user:pass@`);
    /// sensitive env-style assignments (`*KEY=`, `*TOKEN=`, `*SECRET=`, `PASSWORD=`,
    /// …); `Authorization:`/`Bearer` header values; `--password`/`--token`/
    /// `--api-key`/`--secret`/`-p<value>` flag values; branded tokens (`sk-…`,
    /// `ghp_…`, `AKIA…`, `xox…`, `AIza…`, `ya29.…`, JWTs, …); and any remaining
    /// standalone high-entropy run (mixed letters+digits ≥24, base64 ≥24, or hex
    /// ≥32). Finally collapses whitespace/newlines, trims, and truncates to ≤120
    /// with an ellipsis.
    public static func redact(_ raw: String) -> String {
        var s = raw

        // Structured passes first: these preserve surrounding context (URL host,
        // flag name, env-var name) so the summary stays legible.
        s = replace(s, urlUserinfo,   template: "$1\(placeholder)@")
        s = replace(s, sensitiveAssign, template: "$1\(placeholder)")
        s = replace(s, authHeader,    template: "Authorization: \(placeholder)")
        s = replace(s, bearerToken,   template: "Bearer \(placeholder)")
        s = replace(s, secretFlag,    template: "$1$2\(placeholder)")
        s = replace(s, attachedShortPassword, template: "-p\(placeholder)")
        s = replace(s, brandedToken,  template: placeholder)

        // Catch-all: any high-entropy run the structured rules didn't already
        // reduce to the placeholder. This is the backstop that makes an
        // un-enumerated secret shape (e.g. inside an unknown mcp__ payload) safe.
        s = stripHighEntropy(s)

        // One clean line, bounded. Redaction has already run over the FULL string,
        // so truncation can only drop trailing (already-safe) characters.
        let collapsed = s
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return collapsed.count > 120 ? String(collapsed.prefix(119)) + "…" : collapsed
    }

    /// The salient scalar of a PreToolUse `tool_input`, per tool. Redaction is NOT
    /// applied here — callers pass the result through `redact` (or use `summarize`).
    ///   Bash → command; Edit/Write/Read/MultiEdit/NotebookEdit → file path basename;
    ///   Grep/Glob → pattern; WebFetch → url; WebSearch → query;
    ///   default (unknown / mcp__…) → first meaningful String value found.
    public static func salientField(tool: String, toolInput: [String: Any]) -> String? {
        switch tool {
        case "Bash":
            return string(toolInput["command"])
        case "Read", "Edit", "Write", "MultiEdit", "NotebookEdit":
            return (string(toolInput["file_path"]) ?? string(toolInput["notebook_path"]))
                .map(basename)
        case "Grep", "Glob":
            return string(toolInput["pattern"]) ?? string(toolInput["path"])
        case "WebFetch":
            return string(toolInput["url"])
        case "WebSearch":
            return string(toolInput["query"])
        default:
            // Unknown or mcp__ tools: pick a short, meaningful identifier if one is
            // present, else fall back to the first string value (deterministically,
            // by sorted key). Large free-text fields (prompt/content/new_string) are
            // deprioritized to avoid surfacing bulk user text; whatever is chosen is
            // still redacted + truncated downstream.
            let preferred = ["command", "query", "url", "pattern", "file_path", "path",
                             "name", "title", "description", "prompt", "text", "content"]
            for key in preferred {
                if let value = string(toolInput[key]) { return value }
            }
            for key in toolInput.keys.sorted() {
                if let value = string(toolInput[key]) { return value }
            }
            return nil
        }
    }

    /// Convenience: `salientField` → `redact` → `ToolCallSummary`. `toolInput` may
    /// be the real payload dict or `nil` (summary is then empty — just the tool).
    public static func summarize(tool: String, toolInput: [String: Any]?, at: Date) -> ToolCallSummary {
        let field = toolInput.flatMap { salientField(tool: tool, toolInput: $0) }
        let summary = field.map(redact) ?? ""
        return ToolCallSummary(tool: tool, summary: summary, at: at)
    }

    // MARK: - Compiled patterns
    //
    // Compiled once and reused. NSRegularExpression is immutable and Sendable, so a
    // shared instance is safe to match against concurrently. Patterns are literal
    // constants validated against the real events.jsonl, so `try!` cannot trap.

    /// `scheme://user:pass@host` → keep the scheme, drop the credentials.
    private static let urlUserinfo =
        regex(#"([A-Za-z][A-Za-z0-9+.\-]*://)[^\s/:@]+:[^\s/@]+@"#)

    /// `NAME=value` where NAME has a full underscore-delimited segment that is a
    /// sensitive word (so `API_KEY=`/`DB_PASSWORD=` match but `MONKEY=`/`KEYBOARD=`
    /// do not). The name+`=` is preserved; only the value is stripped. Quoted values
    /// are handled so `KEY="a b"` redacts the whole quoted string.
    // Unquoted values stop at shell delimiters (`"'`;&|` and whitespace) so a
    // trailing quote or command separator survives the summary intact; quoted
    // values are captured whole. Either way the value is replaced wholesale.
    private static let sensitiveAssign = regex(
        #"((?<![A-Za-z0-9_])(?:[A-Za-z0-9]+_)*(?i:KEY|TOKEN|SECRET|SECRETS|PASSWORD|PASSWD|PASSPHRASE|CREDENTIAL|CREDENTIALS|APIKEY|ACCESSKEY|AUTH|PAT)(?:_[A-Za-z0-9]+)*\s*=\s*)(?:"[^"]*"|'[^']*'|[^\s"';&|]+)"#)

    /// `Authorization: <anything>` (optionally `Bearer`/`Basic`/`Token`). Value ends
    /// at whitespace or a closing quote, so `-H "Authorization: Bearer x"` keeps its
    /// quote.
    private static let authHeader =
        regex(#"(?i)authorization\s*:\s*(?:bearer\s+|basic\s+|token\s+)?[^\s"']+"#)

    /// A bare `Bearer <token>` not already caught by the header rule.
    private static let bearerToken =
        regex(#"(?i)\bbearer\s+[A-Za-z0-9._~+/=\-]+"#)

    /// `--password`/`--token`/`--api-key`/`--secret`/… with a `=` or space value —
    /// including COMPOUND flag names where the sensitive word is a hyphen/underscore
    /// segment, not the whole name: `--secret-access-key`, `--aws-secret-access-key`,
    /// `--client-secret`. The earlier `(?:secret|access-key)` form matched neither of
    /// those (a probe leaked `--secret-access-key <awsKey>`), because each alternative
    /// had to consume the entire name up to the separator. Now optional leading and
    /// trailing `[a-z0-9]+[-_]` segments wrap the sensitive word. `key`/`keys`/`auth`
    /// match only as full segments (`--keyboard`/`--author` don't, since the next char
    /// must be a separator or the value delimiter). Flag name + separator preserved.
    private static let secretFlag = regex(
        #"(?i)(--(?:[a-z0-9]+[-_])*(?:password|passwd|passphrase|secret|secrets|token|tokens|credential|credentials|apikey|api[-_]?key|access[-_]?key|auth[-_]?token|client[-_]?secret|bearer|keys?|auth|pat)(?:[-_][a-z0-9]+)*)([ =])(?:"[^"]*"|'[^']*'|[^\s"';&|]+)"#)

    /// Attached short-form password (`mysql -pSECRET`). Deliberately narrow: only the
    /// no-space `-p<value>` idiom, since a genuinely secret value here can be short
    /// enough to slip past the high-entropy backstop. This can over-redact attached
    /// short-flag values like `-pr`/ports; that cosmetic cost is accepted to avoid a
    /// leaked DB password. The spaced `-p <value>` form is left alone (it collides
    /// with `mkdir -p`, `ps -p`, …); a secret-shaped value there is still caught by
    /// the backstop.
    private static let attachedShortPassword =
        regex(#"(?<![A-Za-z0-9_\-])-p(?=[^\s\-])[^\s"']+"#)

    /// Well-known secret token prefixes. Case-sensitive (the prefixes are).
    private static let brandedToken = regex(
        #"(sk-[A-Za-z0-9_\-]{10,}|sk_(?:live|test)_[A-Za-z0-9]{10,}|rk_(?:live|test)_[A-Za-z0-9]{10,}|gh[pousr]_[A-Za-z0-9]{16,}|github_pat_[A-Za-z0-9_]{20,}|glpat-[A-Za-z0-9_\-]{16,}|AKIA[0-9A-Z]{12,}|ASIA[0-9A-Z]{12,}|xox[baprse]-[A-Za-z0-9-]{10,}|AIza[0-9A-Za-z_\-]{20,}|ya29\.[A-Za-z0-9_\-]{10,}|npm_[A-Za-z0-9]{30,}|eyJ[A-Za-z0-9_\-]{6,}\.[A-Za-z0-9_\-]{4,}\.[A-Za-z0-9_\-]{4,})"#)

    /// Candidate runs for the high-entropy backstop. `/` and `.` are excluded so file
    /// paths and dotted hostnames split into short, benign segments rather than being
    /// swallowed whole; `looksSecret` then decides each run.
    private static let entropyCandidate =
        regex(#"[A-Za-z0-9+=_\-]{24,}"#)

    // MARK: - Helpers

    private static func regex(_ pattern: String) -> NSRegularExpression {
        // Force-try: every pattern is a validated compile-time constant.
        try! NSRegularExpression(pattern: pattern)
    }

    private static func replace(_ s: String, _ re: NSRegularExpression, template: String) -> String {
        let range = NSRange(s.startIndex..., in: s)
        return re.stringByReplacingMatches(in: s, range: range, withTemplate: template)
    }

    /// Replace every high-entropy candidate run that `looksSecret`. Replacing in
    /// reverse keeps the NSRanges (computed against the original) valid as the
    /// mutable copy shrinks/grows behind each edit.
    private static func stripHighEntropy(_ s: String) -> String {
        let ns = s as NSString
        let matches = entropyCandidate.matches(in: s, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return s }
        let mutable = NSMutableString(string: s)
        for match in matches.reversed() where looksSecret(ns.substring(with: match.range)) {
            mutable.replaceCharacters(in: match.range, with: placeholder)
        }
        return mutable as String
    }

    /// A run (already stripped of `/` and `.`) reads as a secret when it is long and
    /// high-entropy: mixed letters+digits ≥24 (random keys / mixed hex), base64 with
    /// `+`/`=` ≥24, or pure hex ≥32 (all-hex hashes and long numeric strings). Plain
    /// long lowercase words and short numbers (timestamps, PIDs) are left intact.
    private static func looksSecret(_ token: String) -> Bool {
        let length = token.count
        guard length >= 24 else { return false }
        let hasLetter = token.contains { $0.isLetter }
        let hasDigit = token.contains { $0.isNumber }
        if hasLetter && hasDigit { return true }
        if token.contains(where: { $0 == "+" || $0 == "=" }) { return true }
        if length >= 32 && token.allSatisfy({ $0.isHexDigit }) { return true }
        return false
    }

    /// Non-empty String value, or nil.
    private static func string(_ value: Any?) -> String? {
        guard let text = value as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : text
    }

    /// Last path component, so `/Users/me/project/SessionStore.swift` shows as
    /// `SessionStore.swift` (less home-directory structure, cleaner rows).
    private static func basename(_ path: String) -> String {
        let name = (path as NSString).lastPathComponent
        return name.isEmpty ? path : name
    }
}
