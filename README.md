# Agent Babysitter

macOS menu bar app that monitors running coding-agent sessions (Claude Code and Codex): working /
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
`~/.codex/sessions/` rollouts (matching by transcript-reported cwd). A
`ps`/`lsof` poll every 5s feeds all adapters from one scan. A pure state engine folds transcript
facts + process liveness + optional Precision-mode hook signals into one of
five states per session. Cost is recomputed from transcripts (deduped by
API message id, cache writes priced per TTL) — no database.

Precision mode (Preferences) merges Notification/Stop hooks into
`~/.claude/settings.json` non-destructively for exact waiting/done signals;
disabling removes only our entries.

## Status

Milestones 1–8 complete (parser, state engine, process watcher, menu bar UI,
notifications + terminal focusing, cost, Precision mode, Preferences +
launch-at-login). Remaining for 1.0: app icon, Developer ID
signing + notarization of the DMG.
