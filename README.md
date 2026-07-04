# Agent Babysitter

macOS menu bar app that monitors running coding-agent sessions (Claude Code, Codex, and Antigravity): working /
waiting for you / done / stalled / ended — with native notifications and live
per-session token cost. No network calls, no telemetry.

## Layout

- `AgentBabysitterCore/` — Swift package with all logic (transcript parser,
  state engine, watchers, cost, hooks). Test with
  `cd AgentBabysitterCore && swift test`.
- `App/` — thin SwiftUI menu bar target (`LSUIElement`, no dock icon).
- `project.yml` — XcodeGen definition; the `.xcodeproj` is generated
  (`xcodegen generate`) and gitignored.
- `docs/transcript-schema.md` — the confirmed Claude Code JSONL schema the
  parser is built against.
- `Scripts/make-dmg.sh` — Release universal build + DMG packaging.

## Building

```sh
xcodegen generate
xcodebuild -project AgentBabysitter.xcodeproj -scheme AgentBabysitter build
```

## How it works

Each agent is an `AgentAdapter` (layout + line parser + process matching)
that normalizes its transcripts into one entry model. Claude Code tails
`~/.claude/projects/` (matching processes by munged cwd); Codex tails
`~/.codex/sessions/` rollouts (matching by transcript-reported cwd);
Antigravity (desktop/IDE/`agy` CLI) is activity-based — its conversations are
SQLite+protobuf with no public schema, so it reports Working/Done/Ended from
conversation-file writes and never fakes Waiting/Stalled or cost. A
`ps`/`lsof` poll every 5s feeds all adapters from one scan. A pure state engine folds transcript
facts + process liveness + optional Precision-mode hook signals into one of
five states per session. Cost is recomputed from transcripts (deduped by
API message id, cache writes priced per TTL) — no database.

Precision mode (Preferences) merges Notification/Stop hooks into
`~/.claude/settings.json` non-destructively for exact waiting/done signals;
disabling removes only our entries.

## Known limitations

- **Pid↔session pairing is heuristic** when several sessions share a cwd (or
  for Antigravity, per surface): states stay correct, but row-click may focus
  a sibling window of the same app.
- **Antigravity is activity-based** (no public conversation schema): states
  are Working/Done/Ended only, cost shows "—", and turn notifications are
  suppressed (a >60s silent think would otherwise flap).
- **5-hour limits, per agent**: Codex shows a real % from disk (CLI + desktop,
  zero network). Antigravity shows its plan tier read from the IDE state
  ("Google AI Pro", zero network) — no % is stored anywhere locally. Claude
  Code publishes its 5h % only in live API responses, so it appears when you
  enable the opt-in "Live usage" toggle (Settings → Advanced, OFF by default);
  that is the only feature that ever makes a network call, and only to
  api.anthropic.com with your own login.
- **Costs are estimates at API list prices** — on subscription plans this is
  API-equivalent value, not spend. Sonnet 5 uses sticker pricing (intro rate
  runs through 2026-08-31).
- **Beta builds are unsigned** (Developer ID deferred for now): downloaded
  DMGs trigger Gatekeeper — open once, then System Settings → Privacy &
  Security → "Open Anyway". Instructions ship inside the DMG. The build
  script auto-upgrades to signed + notarized the moment a "Developer ID
  Application" identity exists in the keychain.
- **No auto-update yet** (Sparkle planned once signing lands); no global
  hotkey (SwiftUI provides no API to open a MenuBarExtra programmatically).

## Status

Milestones 1–8 complete + Codex/Antigravity adapters, review hardening (session pruning, dismissal, day-accurate costs, hook buffering, event-log rotation, CI) (parser, state engine, process watcher, menu bar UI,
notifications + terminal focusing, cost, Precision mode, Preferences +
launch-at-login). Remaining for 1.0: app icon, Developer ID
signing + notarization of the DMG.
