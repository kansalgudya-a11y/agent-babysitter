# Agent Babysitter

macOS menu bar app that monitors running Claude Code sessions: working /
waiting for you / done / stalled / ended — with native notifications and live
per-session token cost. No network calls, no telemetry.

## Layout

- `AgentBabysitterCore/` — Swift package with all logic (transcript parser,
  state engine, watchers, cost). Test with `cd AgentBabysitterCore && swift test`.
- `App/` — thin menu bar app target (coming in milestone 4).
- `docs/transcript-schema.md` — the confirmed Claude Code JSONL schema the
  parser is built against.

## Status

Milestone 1: transcript parser + sanitized fixtures + tests.
