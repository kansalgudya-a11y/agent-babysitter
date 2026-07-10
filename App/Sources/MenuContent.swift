import SwiftUI
import AgentBabysitterCore

struct MenuContent: View {
    @ObservedObject var model: AppModel
    /// Snapshot harness only — forces the expanded limits list.
    var forceShowAllLimits = false
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow
    @State private var showLegend = false
    @State private var showCostInfo = false
    @AppStorage("showAllLimits") private var storedShowAllLimits = false
    private var showAllLimits: Bool { storedShowAllLimits || forceShowAllLimits }
    /// Which session rows are expanded into their drill-in. Owned here (not
    /// per-row) so the list height can grow to fit the expanded content.
    @State private var expandedRows: Set<String> = []

    private func toggleExpanded(_ id: String) {
        withAnimation(.easeInOut(duration: 0.15)) {
            if expandedRows.contains(id) { expandedRows.remove(id) }
            else { expandedRows.insert(id) }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if showLegend { LegendView() }

            if model.newFeatureCount > 0, model.welcomeDismissed {
                Button {
                    NSApp.activate(ignoringOtherApps: true)
                    openWindow(id: "welcome")
                } label: {
                    Label("✨ \(model.newFeatureCount) new since your last look — see what's new",
                          systemImage: "sparkles")
                        .font(.caption)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.borderless)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(Color.accentColor.opacity(0.1))
            }
            if model.noAgentsDetected {
                OnboardingView(model: model)
            } else {
                if !model.welcomeDismissed {
                    WelcomeCard(model: model)
                }
                if model.rows.isEmpty {
                    emptyState
                } else {
                    sessionList
                }
            }

            if model.processDetectionDegraded {
                Label("Having trouble checking which sessions are still running — statuses may lag for a moment.",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
            }
            ForEach(model.unreadableAgents) { agent in
                Label("\(agent.name) is running but its data format looks new — try updating Agent Babysitter.",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
            }

            Divider()
            if !model.installedAgents.isEmpty {
                limitsSection
                Divider()
            }
            footer
        }
        .frame(width: 330)
        .onAppear { model.popoverOpened() }
    }

    // MARK: - Pieces

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text("Agent Babysitter")
                    .font(.headline)
                Text(statusPhrase)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                withAnimation(.easeOut(duration: 0.15)) { showLegend.toggle() }
            } label: {
                Image(systemName: showLegend ? "questionmark.circle.fill" : "questionmark.circle")
            }
            .buttonStyle(.borderless)
            .help("What do the colors mean?")
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 6)
    }

    /// Plain-language one-liner for the top of the dropdown.
    private var statusPhrase: String {
        let rows = model.rows
        let waiting = rows.filter { $0.state == .waitingForInput }.count
        let stalled = rows.filter { $0.state == .stalled }.count
        let working = rows.filter { $0.state == .working }.count
        if waiting > 0 { return waiting == 1 ? "1 agent needs you" : "\(waiting) agents need you" }
        if stalled > 0 { return stalled == 1 ? "1 agent may be stuck" : "\(stalled) agents may be stuck" }
        if working > 0 { return working == 1 ? "1 agent working" : "\(working) agents working" }
        if rows.contains(where: { $0.state == .done }) { return "All caught up" }
        return "Watching for agent sessions"
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Text("All quiet right now.")
                .foregroundStyle(.secondary)
            Text("Start a Claude Code, Codex, or Antigravity session and it will appear here automatically.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding()
    }

    /// Sessions grouped per agent app, in a fixed friendly order; rows keep
    /// their needs-attention-first ordering within each group.
    private var groupedRows: [(agentID: String, agentName: String, rows: [SessionRow])] {
        let order = ["claude-code": 0, "codex": 1, "manus": 2, "cursor": 3,
                     "antigravity": 4, "antigravity-ide": 5, "antigravity-cli": 6,
                     "gemini": 7, "gemini-cli": 8]
        // Never show activity for an app that isn't installed (a running
        // session is always counted as installed, so this can't hide a live
        // one — only stale rows from an uninstalled app).
        let installed = Set(model.installedAgents.map(\.id))
        return Dictionary(grouping: model.rows.filter { installed.contains($0.agentID) },
                          by: \.agentID)
            .sorted { (order[$0.key] ?? 99, $0.key) < (order[$1.key] ?? 99, $1.key) }
            .map { (agentID: $0.key,
                    agentName: $0.value.first?.agentName ?? $0.key,
                    rows: $0.value) }
    }

    private var sessionList: some View {
        // Snapshot harness: ScrollView content doesn't reach ImageRenderer,
        // so QA renders use the plain stack. In the app the ScrollView gets
        // an EXPLICIT height: with maxHeight it collapsed to zero on the
        // popover's first layout (MenuBarExtra sizing quirk - the list only
        // appeared after any control forced a re-layout).
        Group {
            if AppModel.isSnapshotMode {
                sessionListContent
            } else {
                ScrollView { sessionListContent }
                    .frame(height: estimatedListHeight)
            }
        }
    }

    /// Two-line session rows ≈44pt, group headers ≈26pt, list padding 12pt.
    /// An expanded drill-in adds ≈150pt, and the cap lifts so it isn't
    /// clipped — seeing it is the whole point of expanding.
    private var estimatedListHeight: CGFloat {
        let rows = CGFloat(model.rows.count) * 44
        let headers = CGFloat(groupedRows.count) * 26
        let expanded = CGFloat(expandedRows.count) * 150
        return min(expandedRows.isEmpty ? 380 : 540, rows + headers + expanded + 12)
    }

    private var sessionListContent: some View {
        VStack(alignment: .leading, spacing: 2) {
                ForEach(groupedRows, id: \.agentID) { group in
                    HStack(spacing: 6) {
                        Text(group.agentName)
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundStyle(.secondary)
                        Text("\(group.rows.count)")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        VStack { Divider() }
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 6)
                    ForEach(group.rows) { row in
                        SessionRowView(row: row, money: { model.money($0) },
                                       onDismiss: { model.dismiss($0) },
                                       onJump: { TerminalFocuser.focusSession(row) },
                                       isExpanded: expandedRows.contains(row.id),
                                       onToggleExpand: { toggleExpanded(row.id) })
                    }
                }
            }
        .padding(.vertical, 6)
    }

    /// Open apps by default; expanding shows every installed agent. An agent
    /// gets its 5h reading when one is known, an honest fallback otherwise.
    private var limitEntries: [(id: String, name: String, limit: UsageLimitSnapshot?, running: Bool)] {
        let order = ["claude-code": 0, "codex": 1, "manus": 2, "cursor": 3,
                     "antigravity": 4, "antigravity-ide": 5, "antigravity-cli": 6,
                     "gemini": 7, "gemini-cli": 8]
        let now = Date()
        // An agent whose window has rolled over shows a "reset" bar with
        // nothing to act on — sink those below agents with a live reading,
        // keeping the fixed order within each group.
        func resetTier(_ limit: UsageLimitSnapshot?) -> Int {
            (limit?.isExpired(at: now) ?? false) ? 1 : 0
        }
        // Gemini keeps its usage on Google's servers (link-only, no local
        // reading), so it sits at the very bottom, below even reset windows.
        func bottomTier(_ id: String) -> Int { id.hasPrefix("gemini") ? 1 : 0 }
        return model.installedAgents
            .filter { showAllLimits || model.runningAgentIDs.contains($0.id) }
            .map { (id: $0.id, name: $0.name,
                    limit: model.usageLimits[$0.id],
                    running: model.runningAgentIDs.contains($0.id)) }
            .sorted { a, b in
                (bottomTier(a.id), resetTier(a.limit), order[a.id] ?? 99, a.id)
                    < (bottomTier(b.id), resetTier(b.limit), order[b.id] ?? 99, b.id)
            }
    }

    /// Whether expanding would reveal anything beyond the open apps.
    private var hasClosedAgents: Bool {
        model.installedAgents.contains { !model.runningAgentIDs.contains($0.id) }
    }

    private var limitsSection: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                // Not all agents use a 5-hour window: Cursor is a monthly
                // billing cycle, Manus a daily refresh. Each row shows its
                // own reset, so the header stays window-agnostic.
                Text("Usage limits")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                Spacer()
                if hasClosedAgents {
                    Button {
                        withAnimation(.easeOut(duration: 0.15)) { storedShowAllLimits.toggle() }
                    } label: {
                        HStack(spacing: 2) {
                            Text(showAllLimits ? "Open apps only" : "Show all")
                            Image(systemName: showAllLimits ? "chevron.up" : "chevron.down")
                        }
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help(showAllLimits ? "Hide agents that aren't running"
                                        : "Also show installed agents that aren't running right now")
                }
            }
            if limitEntries.isEmpty {
                Text("No agent apps are open right now.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            ForEach(limitEntries, id: \.id) { entry in
                limitRow(entry)
                    .opacity(limitRowOpacity(entry))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// Non-running apps and rolled-over windows recede below live readings.
    private func limitRowOpacity(_ entry: (id: String, name: String,
                                           limit: UsageLimitSnapshot?, running: Bool)) -> Double {
        if !entry.running { return 0.55 }
        if entry.limit?.isExpired() == true { return 0.6 }
        return 1
    }

    @ViewBuilder
    private func limitRow(_ entry: (id: String, name: String,
                                    limit: UsageLimitSnapshot?, running: Bool)) -> some View {
        VStack(spacing: 1) {
            HStack(spacing: 8) {
                Text(entry.name)
                    .font(.caption)
                    .frame(width: 92, alignment: .leading)
                    .lineLimit(1)
                if let limit = entry.limit {
                    if limit.usedPercent == nil, let plan = limit.plan {
                        Text(plan)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("plan")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .frame(width: 44, alignment: .trailing)
                            .help(entry.id.hasPrefix("gemini") ? "Gemini keeps its usage limits on Google's servers only — nothing is stored on your Mac. The plan tier comes from your Google account."
                                  : entry.id == "cursor" ? "Cursor stores only your plan tier on this Mac. Turn on Live usage in Settings → Advanced to fetch your real numbers from cursor.com with your own login."
                                  : "Only the plan tier is available offline right now — the % appears once the agent syncs its quota to disk.")
                    } else if limit.isExpired() {
                        ProgressView(value: 0)
                            .tint(.secondary)
                        Text("reset")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 44, alignment: .trailing)
                            .help("The 5-hour window rolled over; fresh numbers arrive with the next agent activity.")
                    } else {
                        // Readings age between turns; show the pace-corrected
                        // estimate ("≈9%") once one applies.
                        let estimate = UsageForecast.estimatedCurrentPercent(limit)
                        let shown = estimate ?? limit.usedPercent ?? 0
                        ProgressView(value: min(shown, 100) / 100)
                            .tint(shown >= 90 ? .red : shown >= 70 ? .orange : .green)
                        Text("\(estimate != nil ? "≈" : "")\(Int(shown))%")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 44, alignment: .trailing)
                            .help(limitHelp(limit, estimate: estimate))
                    }
                } else if entry.id == "claude-code", !model.claudeUsageMeterEnabled {
                    // The flagship number shouldn't require a Settings trip:
                    // one click enables the meter right where the gap is.
                    Text("no data yet")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Spacer()
                    Button("Show my %") { model.claudeUsageMeterEnabled = true }
                        .buttonStyle(.link)
                        .font(.caption)
                        .help("Records the usage numbers Claude Code already computes on your Mac (adds a small status-line helper to Claude's settings; fully reversible in Settings). Works offline. Desktop-only users can use Live usage in Settings instead.")
                } else if entry.id.hasPrefix("gemini") {
                    // Gemini's real % lives only behind Google's web login and
                    // is never written to disk (verified) — so link straight
                    // to the page that has it rather than show a plan tier.
                    Text("on Google's servers")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Spacer()
                    Button("Check usage ↗") {
                        NSWorkspace.shared.open(URL(string: "https://gemini.google.com/usage")!)
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                    .help("Gemini keeps your usage limits on Google's servers, behind your Google login — they're never stored on your Mac, so they can't be shown here without your full Google session. This opens your live usage page in the browser.")
                } else {
                    Text(entry.running ? "not shared by this app" : "no recent reading")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .help(entry.id.hasPrefix("antigravity")
                              ? "Antigravity syncs its quota through the Antigravity IDE's account state. Open the IDE once (any window) and the reading appears here."
                              : entry.id == "manus"
                              ? "Manus keeps your credits on its servers. Turn on Live usage in Settings → Advanced to fetch your credit balance using your existing Manus login."
                              : entry.running
                              ? "This agent doesn't record its limit usage on your Mac, and Agent Babysitter never guesses or phones home."
                              : "Open this app and the reading appears once it records usage.")
                    Spacer()
                }
            }
            if let limit = entry.limit, limit.usedPercent != nil,
               let caption = limitCaption(limit) {
                caption
                    .font(.caption2)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            // Same floors as the pace notification (user-set in Preferences)
            // — the menu must not paint red for a state the notification
            // path classifies as noise. Closed apps aren't burning anything,
            // so their pace is history, not a prediction: running only.
            if entry.running, let limit = entry.limit {
                paceCaption(limit, floor: model.paceFiveHourFloor, prefix: "")
                if let weekly = limit.weeklyWindow {
                    paceCaption(weekly, floor: model.paceWeeklyFloor, prefix: "week: ")
                }
            }
            // Cursor/Manus keep their real numbers behind a login the user
            // already has — one click turns the fetch on, right where the
            // gap is (same pattern as Claude's "Show my %").
            if !model.liveUsageEnabled, entry.limit?.usedPercent == nil,
               entry.id == "cursor" || entry.id == "manus" {
                HStack {
                    Spacer()
                    Button("Show my real numbers") { model.liveUsageEnabled = true }
                        .buttonStyle(.link)
                        .font(.caption2)
                        .help("Fetches your usage from \(entry.id == "cursor" ? "cursor.com" : "manus.im") with the login this Mac already has — nothing to type, fully reversible in Settings → Advanced.")
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(limitAccessibilityLabel(entry))
    }

    /// One reading of the pace, shared by the visible caption and its
    /// VoiceOver mirror so the two can never drift. `.exhausting` fires the
    /// warning line, `.landing` the reassuring one, `.none` shows nothing —
    /// below the user's floor, or no measurable/fresh pace (UsageForecast
    /// applies the same staleness ceiling the notification path uses).
    private enum PaceForecast {
        case exhausting(early: TimeInterval, at: Date)
        case landing(percent: Int)
        case none
    }

    private func paceForecast(_ window: UsageLimitSnapshot, floor: Double) -> PaceForecast {
        // Freshness lives in UsageForecast itself (maximumStaleness), so the
        // menu and the banner path can't drift on what counts as too old.
        guard (window.usedPercent ?? 0) >= floor, let resets = window.resetsAt
        else { return .none }
        if let exhaustion = UsageForecast.projectedExhaustion(window) {
            return .exhausting(early: resets.timeIntervalSince(exhaustion), at: exhaustion)
        }
        if let projected = UsageForecast.projectedPercentAtReset(window), projected <= 100 {
            return .landing(percent: Int(projected.rounded()))
        }
        return .none
    }

    /// The pace line, always on from the user's floor up — reassuring when
    /// the window outlasts its reset ("on pace for ~62% at reset"), a
    /// warning when it doesn't ("on pace to hit the limit at 2:14 PM").
    /// Works for the 5h snapshot and its weeklyWindow.
    @ViewBuilder
    private func paceCaption(_ window: UsageLimitSnapshot, floor: Double,
                             prefix: String) -> some View {
        switch paceForecast(window, floor: floor) {
        case .exhausting(let early, let at):
            // Snapshot renders pin the wall-clock text: absolute times
            // change every run and flip format at midnight.
            let clock = AppModel.isSnapshotMode ? "2:14 PM"
                : NotificationManager.clockTime(at)
            Text("\(prefix)on pace to hit the limit at \(clock) (~\(Self.humanDuration(early)) early)")
                .font(.caption2)
                .foregroundStyle(early >= 3600 ? .red : .orange)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .help("At the current pace this window runs out ~\(Self.humanDuration(early)) before it resets. Ease off or switch agents to stretch it. You can choose when this line appears in Settings → Notifications.")
        case .landing(let percent):
            Text("\(prefix)on pace for ~\(percent)% at reset")
                .font(.caption2)
                .foregroundStyle(.green)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .help("At the current pace this window lands around \(percent)% when it resets — no limit trouble ahead. You can choose when this line appears in Settings → Notifications.")
        case .none:
            EmptyView()
        }
    }

    private func limitAccessibilityLabel(
        _ entry: (id: String, name: String, limit: UsageLimitSnapshot?, running: Bool)
    ) -> String {
        guard let limit = entry.limit else {
            if entry.id.hasPrefix("gemini") {
                return "\(entry.name), usage kept on Google's servers, button to open the usage page"
            }
            return "\(entry.name), no usage data"
        }
        if let used = UsageForecast.estimatedCurrentPercent(limit) ?? limit.usedPercent {
            var text = "\(entry.name), \(Int(used)) percent of the \(windowName(limit.windowMinutes)) used"
            if let resets = limit.resetsAt, resets > Date() {
                text += ", resets in \(Self.humanDuration(resets.timeIntervalSinceNow))"
            }
            // The pace captions are drawn inside this ignored-children
            // element, so VoiceOver only hears them if they're spoken here.
            // Running apps only — mirrors the visible captions.
            if entry.running {
                text += paceSentence(limit, floor: model.paceFiveHourFloor, name: "")
                if let weekly = limit.weeklyWindow {
                    text += paceSentence(weekly, floor: model.paceWeeklyFloor,
                                         name: "weekly window ")
                }
            }
            return text
        }
        return "\(entry.name), \(limit.plan ?? "plan") plan"
    }

    /// Spoken mirror of paceCaption for VoiceOver — reads from the same
    /// paceForecast so the sentence can't drift from the visible line.
    private func paceSentence(_ window: UsageLimitSnapshot, floor: Double,
                              name: String) -> String {
        switch paceForecast(window, floor: floor) {
        case .exhausting(let early, _):
            return ", \(name)on pace to hit the limit \(Self.humanDuration(early)) before it resets"
        case .landing(let percent):
            return ", \(name)on pace for \(percent) percent at reset"
        case .none:
            return ""
        }
    }

    /// Human name for a usage window, from its length.
    private func windowName(_ minutes: Int) -> String {
        switch minutes {
        case ..<361: return "five hour window"
        case ..<(2 * 24 * 60): return "daily quota"
        case ..<(8 * 24 * 60): return "weekly window"
        default: return "billing cycle"
        }
    }

    /// "resets in 2h 22m · week 23%" — whatever parts are known. Only the
    /// weekly part escalates to orange/red, by its own severity (the 5h bar
    /// already carries the 5h color).
    private func limitCaption(_ limit: UsageLimitSnapshot) -> Text? {
        var pieces: [Text] = []
        // Credit-based agents (Manus) carry the balance in the plan label —
        // keep it visible even when the bar shows the daily quota.
        if let plan = limit.plan, plan.localizedCaseInsensitiveContains("credit") {
            pieces.append(Text(plan).foregroundColor(.secondary.opacity(0.7)))
        }
        if let phrase = resetPhrase(limit.resetsAt) {
            pieces.append(Text(phrase).foregroundColor(.secondary.opacity(0.7)))
        }
        if let weekly = limit.weeklyUsedPercent {
            let color: Color = weekly >= 90 ? .red : weekly >= 70 ? .orange
                : .secondary.opacity(0.7)
            pieces.append(Text("week \(Int(weekly))%").foregroundColor(color))
        }
        guard var caption = pieces.first else { return nil }
        for piece in pieces.dropFirst() {
            caption = caption + Text(" · ").foregroundColor(.secondary.opacity(0.7)) + piece
        }
        return caption
    }

    /// "resets in 2h 22m" when the reset time is known and ahead of us.
    private func resetPhrase(_ resets: Date?) -> String? {
        guard let resets, resets > Date() else { return nil }
        return "resets in " + Self.humanDuration(resets.timeIntervalSinceNow)
    }

    /// Compact duration that scales past a day, so monthly (Cursor) and daily
    /// (Manus) windows don't render as "resets in 720h 0m".
    static func humanDuration(_ seconds: TimeInterval) -> String {
        let total = max(Int(seconds), 60)
        let days = total / 86_400
        let hours = (total % 86_400) / 3600
        let minutes = (total % 3600) / 60
        if days >= 1 { return hours > 0 ? "\(days)d \(hours)h" : "\(days)d" }
        if hours >= 1 { return "\(hours)h \(minutes)m" }
        return "\(max(minutes, 1))m"
    }

    private func limitHelp(_ limit: UsageLimitSnapshot, estimate: Double? = nil) -> String {
        var parts: [String] = []
        if let estimate, let raw = limit.usedPercent {
            parts.append("≈\(Int(estimate))% estimated from pace — last real reading \(Int(raw))%")
        }
        if let plan = limit.plan {
            // Capitalize single lowercase words ("plus" -> "Plus") but leave
            // already-styled names ("Google AI Pro") untouched.
            parts.append("\(plan == plan.lowercased() ? plan.capitalized : plan) plan")
        }
        if let resets = limit.resetsAt, resets > Date() {
            parts.append("resets in " + Self.humanDuration(resets.timeIntervalSinceNow))
        }
        if let weekly = limit.weeklyUsedPercent {
            var text = "weekly window \(Int(weekly))% used"
            if let resets = limit.weeklyResetsAt, resets > Date() {
                text += ", resets in \(Int(resets.timeIntervalSinceNow / 86_400))d"
            }
            parts.append(text)
        }
        let age = Int(Date().timeIntervalSince(limit.capturedAt) / 60)
        parts.append(age < 1 ? "just updated" : "as of \(age)m ago")
        return parts.joined(separator: " · ")
    }

    private var footer: some View {
        HStack(spacing: 8) {
            // A brand-new install has no cost to report; skip the noise.
            if !model.noAgentsDetected {
            Text("Today: \(model.todayCost.display(money: { model.money($0) }))\(model.costsArePlanValue ? " value" : "")")
                .font(.caption)
                .foregroundStyle(.secondary)
                .onTapGesture { showCostInfo.toggle() }
                .help(model.costsArePlanValue
                      ? "Estimated value of today's usage at API list prices — a subscription doesn't bill per token. Click for the 7-day trend."
                      : "Click for the 7-day trend")
            Button {
                showCostInfo.toggle()
            } label: {
                Image(systemName: "info.circle")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .popover(isPresented: $showCostInfo, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Estimated from token usage at API list prices.\nOn a subscription plan (Pro/Max) this is not an extra charge — it shows the value of today's usage.\nToken counts are new work (input + output + newly cached); cached-context re-reads are priced in but not counted.")
                        .font(.caption)
                    if model.costHistory.count > 1 {
                        Divider()
                        Text("Last 7 days")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        CostTrendView(history: model.costHistory, money: { model.money($0) })
                    }
                }
                .padding(10)
                .frame(width: 240)
            }
            }
            Spacer()
            Button {
                // Menu bar apps don't activate on their own — without this
                // the stats window opens behind whatever app is frontmost.
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: "stats")
            } label: {
                Image(systemName: "chart.bar")
            }
            .buttonStyle(.borderless)
            .help("This week's stats")
            .accessibilityLabel("Statistics")
            Button {
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: "history")
            } label: {
                Image(systemName: "clock.arrow.circlepath")
            }
            .buttonStyle(.borderless)
            .help("Session history")
            .accessibilityLabel("Session history")
            Button {
                model.notificationsMuted.toggle()
            } label: {
                Image(systemName: model.notificationsMuted ? "bell.slash" : "bell")
            }
            .accessibilityLabel(model.notificationsMuted ? "Alerts paused, click to resume"
                                                         : "Pause alerts")
            .buttonStyle(.borderless)
            .help(model.notificationsMuted ? "Alerts are off — click to turn back on"
                                           : "Pause all alerts")
            Button {
                openSettings()
                NSApp.activate()
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.borderless)
            .help("Settings")
            Button("Quit") { NSApp.terminate(nil) }
                .buttonStyle(.borderless)
                .font(.caption)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

/// Explains the status colors in plain words.
struct LegendView: View {
    private let items: [(String, String, String)] = [
        ("🟢", "Working", "the agent is actively doing things"),
        ("🟡", "Needs you", "waiting for your answer or a permission"),
        ("🔵", "Done", "finished — ready for your next prompt"),
        ("🔴", "Maybe stuck", "mid-task but silent for a while"),
        ("⚫", "Ended", "the session has exited"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(items, id: \.0) { dot, name, meaning in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(dot).font(.caption)
                    Text(name).font(.caption).fontWeight(.medium)
                    Text("— \(meaning)").font(.caption).foregroundStyle(.secondary)
                }
            }
            Text("Click a session to jump to it · right-click for more options")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.top, 2)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.05))
    }
}

/// One-time intro shown until dismissed.
struct WelcomeCard: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("👋 Welcome!")
                .font(.subheadline).fontWeight(.semibold)
            Text("Agent Babysitter keeps an eye on your AI coding agents so you don't have to keep switching windows. The dot in your menu bar shows the session that most needs you, and you'll get a notification when an agent wants input or finishes.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("See everything it can do") {
                    NSApp.activate(ignoringOtherApps: true)
                    openWindow(id: "welcome")
                }
                .controlSize(.small)
                Spacer()
                Button("Got it") { model.dismissWelcome() }
                    .controlSize(.small)
            }
        }
        .padding(10)
        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 10)
        .padding(.bottom, 4)
    }
}

struct SessionRowView: View {
    let row: SessionRow
    var money: (Double) -> String = { String(format: "~$%.2f", $0) }
    var onDismiss: (SessionRow) -> Void = { _ in }
    var onJump: () -> Void = {}
    /// Expansion is owned by the parent list (so it can size to fit); the
    /// fixture passes a constant true to render the drill-in for snapshots.
    var isExpanded = false
    var onToggleExpand: () -> Void = {}
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if isExpanded { detailPanel }
        }
        .background(rowBackground, in: RoundedRectangle(cornerRadius: 6))
        .onHover { hovering = $0 }
        .contextMenu {
            if let url = row.transcriptURL {
                Button("Reveal Session Log in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            }
            Button("Copy Session ID") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(row.id, forType: .string)
            }
            Divider()
            Button("Hide Until Next Activity") { onDismiss(row) }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(row.state.dotEmoji)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.projectName)
                    .fontWeight(.medium)
                    .lineLimit(1)
                // What it's working on: the user's last real prompt. Skipped
                // when it would just repeat the row label (Cursor composers
                // already surface their name as projectName).
                if let title = row.title, title != row.projectName {
                    Text("“\(title)”")
                        .font(.caption)
                        .italic()
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                HStack(spacing: 4) {
                    Text(row.state.label)
                    if row.isDesktopApp {
                        Text("· Desktop")
                    }
                    if let elapsed = elapsedText {
                        Text("· \(elapsed)")
                    }
                    if row.isUnreadable {
                        Text("· can't read this session's log")
                            .foregroundStyle(.orange)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            // Price and tokens together, for every app — the price answers
            // "what did this cost", the tokens answer "how much work was it".
            VStack(alignment: .trailing, spacing: 1) {
                Text(row.cost.dollars > 0
                     ? money(row.cost.dollars).replacingOccurrences(
                           of: "~", with: CostConfidence.amountPrefix(CostConfidence.level(for: row.cost)))
                     : row.cost.totalTokens > 0 ? "\(row.cost.formattedTokens) tok" : "—")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                if row.cost.dollars > 0, row.cost.totalTokens > 0 {
                    Text("\(row.cost.formattedTokens) tok")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
            .help(costHelp)
            Button {
                onToggleExpand()
            } label: {
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .opacity(hovering || isExpanded ? 0.8 : 0)
            // opacity(0) still hit-tests; keep the hidden chevron from eating
            // taps meant for the row.
            .allowsHitTesting(hovering || isExpanded)
            .help(isExpanded ? "Hide details" : "Session details")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .onTapGesture { onJump() }
        .help("Click to jump to this session")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(row.projectName), \(row.state.label)"
            + (row.title.map { $0 == row.projectName ? "" : ", working on \($0)" } ?? "")
            + (row.cost.dollars > 0 ? ", about \(Int(row.cost.dollars)) dollars" : "")
            + (row.cost.totalTokens > 0 ? ", \(row.cost.formattedTokens) tokens" : ""))
        .accessibilityHint("Jumps to this session")
        // The chevron is swallowed by children:.ignore, so expose the drill-in
        // toggle as an action on the combined element instead.
        .accessibilityAction(named: isExpanded ? "Hide details" : "Show details",
                             onToggleExpand)
    }

    /// The drill-in: everything the row knows, untruncated — the question
    /// it's stuck on, the last reply, timings, the working directory — plus
    /// the actions that otherwise hide in the context menu.
    private var detailPanel: some View {
        VStack(alignment: .leading, spacing: 5) {
            Divider().padding(.vertical, 2)
            // The full prompt, untruncated. Skipped when it's just the
            // project name (Cursor composers) — the header already shows it.
            if let title = row.title, title != row.projectName {
                Text("“\(title)”")
                    .font(.caption)
                    .italic()
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let hook = row.hookDetail, let text = hook.detail, !text.isEmpty {
                Label {
                    Text(text)
                        .lineLimit(4)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: hookIcon(hook.kind))
                }
                .font(.caption)
                .foregroundStyle(hook.kind == .waitingForInput ? .orange : .secondary)
                .help(hookLabel(hook.kind))
            }
            HStack(spacing: 4) {
                if let started = row.turnStartedAt {
                    Text("turn started \(Self.humanAgo(started))")
                }
                if let grown = row.lastGrowthAt {
                    Text("· last activity \(Self.humanAgo(grown))")
                }
                if let entrypoint = row.entrypoint {
                    Text("· \(entrypoint)")
                }
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
            if let cwd = row.cwd {
                Text(cwd)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(cwd)
            }
            HStack(spacing: 14) {
                Button("Jump to session") { onJump() }
                if let url = row.transcriptURL {
                    Button("Reveal log") {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                }
                Button("Copy ID") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(row.id, forType: .string)
                }
            }
            .buttonStyle(.link)
            .font(.caption)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
    }

    private func hookIcon(_ kind: HookSignal.Kind) -> String {
        switch kind {
        case .waitingForInput: "questionmark.bubble"
        case .turnCompleted: "text.bubble"
        case .toolStarted: "gearshape.2"
        }
    }

    private func hookLabel(_ kind: HookSignal.Kind) -> String {
        switch kind {
        case .waitingForInput: "What it's asking you"
        case .turnCompleted: "How the last reply started"
        case .toolStarted: "The tool it's running"
        }
    }

    /// "3m ago" / "just now" — coarse on purpose so the popover's 2s tick
    /// doesn't animate a counter.
    static func humanAgo(_ date: Date) -> String {
        let seconds = max(0, Date().timeIntervalSince(date))
        if seconds < 60 { return "just now" }
        if seconds < 3600 { return "\(Int(seconds / 60))m ago" }
        if seconds < 86_400 { return "\(Int(seconds / 3600))h \(Int(seconds.truncatingRemainder(dividingBy: 3600) / 60))m ago" }
        return "\(Int(seconds / 86_400))d ago"
    }

    /// Plain-language cost explanation for the row's trailing numbers.
    private var costHelp: String {
        if row.cost.hasUnknownPricing && row.cost.dollars == 0 {
            return "Tokens used this session. No price is shown because this model isn't in the price list — dollars are never guessed."
        }
        if row.cost.hasUnknownPricing && row.cost.dollars > 0 {
            return "At least this much, from the priced models in this session at API list prices — one or more models aren't in the price list, so the real total is higher."
        }
        if row.cost.dollars > 0 {
            return "Estimated from this session's tokens at API list prices. On a subscription plan this isn't an extra charge — it's the value of the usage."
        }
        return "No readable usage for this session yet."
    }

    /// Waiting rows carry a soft amber wash so the one row that needs a
    /// human reads before the dots do; hover still darkens any row.
    private var rowBackground: Color {
        if row.state == .waitingForInput {
            return Color.yellow.opacity(hovering ? 0.22 : 0.13)
        }
        return hovering ? Color.primary.opacity(0.07) : .clear
    }

    private var elapsedText: String? {
        guard let start = row.turnStartedAt else { return nil }
        // Finished turns show their frozen duration; anything else counts up.
        let end: Date
        switch row.state {
        case .working, .waitingForInput, .stalled: end = Date()
        case .done: end = row.lastGrowthAt ?? Date()
        case .ended: return nil
        }
        let seconds = Int(end.timeIntervalSince(start))
        guard seconds > 0 else { return nil }
        // Whole minutes past the first one: "6m 0s"/"6m 32s" flickered a new
        // value every refresh, which reads as motion where nothing happened.
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        return "\(seconds / 3600)h \((seconds % 3600) / 60)m"
    }
}

extension SessionCost {
    /// "~$1.22" (in the user's currency), or token counts when pricing is
    /// unknown — never guessed dollars. `money` converts a USD amount.
    func display(money: (Double) -> String) -> String {
        if dollars == 0 && totalTokens == 0 && !hasUnknownPricing {
            return "—"  // no readable usage at all (e.g. Antigravity)
        }
        if hasUnknownPricing {
            return dollars > 0
                ? "\(money(dollars)) + \(formattedTokens) tokens"
                : "\(formattedTokens) tokens"
        }
        return money(dollars)
    }
}

struct OnboardingView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "binoculars")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("No coding agents yet")
                .fontWeight(.semibold)
            Text("Agent Babysitter works with:")
                .font(.caption)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Label("Claude Code — terminal or desktop app", systemImage: "checkmark.circle")
                Label("Codex — CLI or desktop app", systemImage: "checkmark.circle")
                Label("Antigravity — app, IDE, or agy CLI", systemImage: "checkmark.circle")
                Label("Gemini — desktop app or CLI", systemImage: "checkmark.circle")
                Label("Cursor — agent (composer) sessions", systemImage: "checkmark.circle")
                Label("Manus — desktop app", systemImage: "checkmark.circle")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            Text("Run any of them once and this list fills in by itself — no setup needed.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Check Again") { model.retryDetection() }
        }
        .padding()
    }
}
