import Foundation

/// F7 — Remote push. A second notification sink beside `UNUserNotificationCenter`
/// that POSTs a *metadata* update to a webhook the user turns on and points at
/// themselves.
///
/// Privacy contract (load-bearing — see the app's "no transcripts leave your Mac"
/// promise): this is opt-in, and the URL is always supplied by the USER, never
/// taken from anything the app observed. The default payload carries only
/// `{agent, project, state, timestamp}` — no prompt, question, transcript, or
/// tool text. The pending question is a SEPARATE opt-in (`question` is nil unless
/// the caller's include-question toggle is on), and even then it is the ONLY
/// prompt-derived field that may ride the wire. Tool command lines are never sent
/// from here: this type has no field that could carry one, and callers are
/// forbidden (per contract §4) from reading `recentToolCalls` when building a
/// payload. So the redaction burden lives at the source; this sink can only send
/// the four metadata fields plus the opted-in question.
///
/// Honesty note: `send` performs a real outbound network request, so any UI copy
/// claiming the app makes "no network connections" is false while a webhook is
/// enabled — that copy (in PreferencesView) names this user-defined endpoint
/// alongside the other opt-in calls. The POST itself is TYPE-ONLY here: it
/// type-checks now and is confirmed against a live endpoint when Xcode returns.
/// Payload construction is trivially type-checkable now.
struct WebhookPayload: Encodable, Equatable {
    let agent: String      // display name, e.g. "Claude Code"
    let project: String    // row.projectName
    let state: String      // SessionState.label, e.g. "Waiting for you"
    let timestamp: String  // ISO8601 (built by the caller: Date().ISO8601Format())
    /// Present ONLY when the caller's include-question toggle is on; otherwise
    /// nil, and the synthesized `Encodable` conformance omits the key entirely
    /// (it uses `encodeIfPresent` for optionals) — so a default-config endpoint
    /// never even sees a `"question": null` placeholder.
    let question: String?
}

/// Posts `WebhookPayload`s to a user-supplied URL. Isolated as an `actor` so the
/// model can fire sends from the main actor without blocking its 2s tick and
/// without sharing mutable state across threads. The failure string it returns
/// is the ONLY thing surfaced to the user; response bodies are never read back
/// into the app.
actor WebhookSink {

    private let session: URLSession

    /// `.shared` by default so the common case needs no configuration. A caller
    /// may inject an ephemeral, cookie-less session; the per-request 5s timeout
    /// below is set on each `URLRequest` so it holds even on the shared session.
    init(session: URLSession = .shared) {
        self.session = session
    }

    /// POST the payload to `url`.
    ///
    /// ntfy topics (host contains "ntfy") get a `text/plain` body — the one line
    /// "<agent> · <project> — <state>" — because ntfy renders the raw body as the
    /// push notification text; a JSON blob would show up verbatim on the phone.
    /// Everything else gets `application/json` (the full encoded payload). The
    /// opted-in `question`, when present, is appended to the ntfy line too, so the
    /// include-question toggle behaves the same on both transports; when it's nil
    /// (the default) nothing prompt-derived is ever in the body.
    ///
    /// Returns nil on success (a 2xx response) and a short, human-readable failure
    /// string otherwise. Never throws to the caller: a broken webhook must not
    /// take down notification delivery, so every error path is converted to a
    /// returned string the UI can show and move on.
    func send(_ payload: WebhookPayload, to url: URL) async -> String? {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        // Per contract: a bounded 5s timeout so a hung endpoint can't wedge the
        // fire-and-forget task the model spawns for each event.
        request.timeoutInterval = 5

        let isNtfy = (url.host?.lowercased().contains("ntfy")) ?? false
        if isNtfy {
            request.setValue("text/plain; charset=utf-8", forHTTPHeaderField: "Content-Type")
            var line = "\(payload.agent) · \(payload.project) — \(payload.state)"
            // Only reached when the caller opted in (question != nil). Keeps the
            // toggle meaningful for ntfy users without ever adding prompt text to
            // the default payload.
            if let question = payload.question, !question.isEmpty {
                line += "\n\(question)"
            }
            request.httpBody = Data(line.utf8)
        } else {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            do {
                request.httpBody = try JSONEncoder().encode(payload)
            } catch {
                // Encoding a fixed-shape struct of Strings shouldn't fail, but we
                // never want an unhandled throw to escape into the caller's task.
                return "Couldn't encode webhook payload."
            }
        }

        do {
            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                // A non-HTTP response (e.g. a file: URL slipping through) — treat
                // as a misconfiguration rather than a silent success.
                return "Webhook: no HTTP response."
            }
            guard (200..<300).contains(http.statusCode) else {
                return "Webhook returned HTTP \(http.statusCode)."
            }
            return nil
        } catch {
            // Timeouts, DNS failures, TLS errors, offline — all land here. Surface
            // a compact reason; the full response body is deliberately not read.
            return "Webhook failed: \(error.localizedDescription)"
        }
    }
}
