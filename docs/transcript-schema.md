# Claude Code transcript JSONL schema

Confirmed against real transcripts in `~/.claude/projects/` on 2026-07-04
(Claude Code `version: "2.1.197"`). Fixtures in
`AgentBabysitterCore/Tests/AgentBabysitterCoreTests/Fixtures/` are sanitized
slices of these files (content redacted, structure untouched).

## Layout

`~/.claude/projects/<munged-cwd>/<session-uuid>.jsonl` — one JSON object per
line. The directory name is the session's cwd with `/` and `.` replaced by `-`
(e.g. `/Users/jay` → `-Users-jay`).

## Entry types (observed counts across ~14k lines)

| type | meaning |
|---|---|
| `assistant` | one **content block** of an API assistant message (see below) |
| `user` | real user prompt OR tool result delivered back to the model |
| `system` | hook execution / system notices (`subtype`, `level`, `toolUseID`) |
| `queue-operation` | prompt queue enqueue/dequeue (`operation`, `content`) |
| `attachment` | attachment metadata injected into context |
| `ai-title` / `custom-title` | session title (no timestamp, no uuid) |
| `last-prompt` | last user prompt snapshot (no timestamp) |
| `mode` | permission-mode change (no timestamp) |

Only `user` and `assistant` matter for state/cost; everything else is "meta"
but still counts as file growth.

## Common envelope (user/assistant/system/attachment)

`uuid`, `parentUuid`, `timestamp` (ISO8601 with ms, `Z`), `sessionId`, `cwd`,
`version`, `gitBranch`, `isSidechain` (true = subagent sidechain),
`userType: "external"`, `entrypoint` (`claude-desktop`, `cli`, ...).
Title/prompt/mode entries have **only** `sessionId` + their payload field.

## Assistant entries — ⚠️ one line per content block

A single API message is written as **multiple consecutive lines**, one per
content block (`thinking`, `text`, `tool_use`), each repeating the **same**
`message.id` and the **full identical `usage`**. Cost code MUST dedupe usage
by `message.id` or it will double/triple-count.

```json
{
  "type": "assistant",
  "message": {
    "id": "msg_01ELo2YuPr98Sxdj6GH5MftS",
    "model": "claude-fable-5",          // or "<synthetic>" for injected notices
    "role": "assistant",
    "content": [ { "type": "tool_use", "id": "toolu_…", "name": "Read", "input": {…} } ],
    "stop_reason": "tool_use",           // tool_use | end_turn | stop_sequence | null
    "usage": {
      "input_tokens": 26870,
      "output_tokens": 156,
      "cache_creation_input_tokens": 4207,
      "cache_read_input_tokens": 15148,
      "cache_creation": { "ephemeral_1h_input_tokens": 4207, "ephemeral_5m_input_tokens": 0 },
      "service_tier": "standard", "iterations": […], …
    }
  },
  "requestId": "req_…", …envelope…
}
```

- `stop_reason` is repeated on every block-line of the message.
- Parallel tool calls → several `tool_use` lines sharing one `message.id`.
- `model: "<synthetic>"` = injected notice ("No response requested.",
  API error text). Usage is all zeros, `stop_reason: "stop_sequence"`.

## User entries

Two shapes of `message.content`:

- **Real prompt**: plain string, or array of `{type:"text",text:…}` blocks.
- **Tool result**: array of `{type:"tool_result", tool_use_id, is_error, content}`;
  the envelope also carries `toolUseResult` (string or object) and
  `sourceToolAssistantUUID`.

A user turn interrupted mid-tool shows up as a user entry whose text block is
`[Request interrupted by user for tool use]` (or `[Request interrupted by user]`).

## Waiting-for-permission signature

Transcript ends with an assistant `tool_use` line and **no** subsequent user
`tool_result` for that `tool_use_id` — while the process is still alive and
the file stops growing.
