# Privacy Policy — Agent Babysitter

> **DRAFT.** This is a starting template that describes the app's actual data
> behavior as built. Replace every `<PLACEHOLDER>`, confirm the details against
> the shipping build, and have it reviewed before you publish. It is not legal
> advice.

**Last updated: <DATE>**
**Applies to: the Agent Babysitter macOS application ("the app").**
**Provided by: `<YOUR_LEGAL_NAME>` ("we", "us").**

## The short version

**Your transcripts and prompts never leave your Mac.** The app watches the
files your coding agents already write on this Mac and turns them into status,
cost estimates, and usage-limit readings — all computed locally. It runs no
analytics, no telemetry, and no advertising, and it never phones home about how
you use it.

A few clearly labeled features do reach the network, each on its own trigger and
each only its own vendor. They are listed in full below. Except for those, the
app is fully offline.

## 1. What the app reads on your Mac

To do its job the app reads, locally and read-only, the files your installed
agents produce, for example:

- Claude Code transcripts under `~/.claude/projects/`
- Codex session rollouts under `~/.codex/sessions/`
- Antigravity conversation files (activity signals only; their format has no
  public schema)
- Cursor and Manus local state (for example, the plan tier stored on this Mac)
- Running-process information from a periodic `ps`/`lsof` scan, used to tell
  which agent sessions are alive and to focus the right terminal window

From these it derives session state (working / waiting / done / stalled /
ended), cost estimates at API list prices, token counts, and usage-limit
percentages. This processing happens entirely on your Mac. The contents of your
prompts and agent transcripts are used only in memory to compute these figures
and are **not** copied off the device.

## 2. What the app stores on your Mac

- **Preferences** (thresholds, toggles, display choices) — in the standard macOS
  preferences store (`UserDefaults`) for the app.
- **Your local stats ledger** (aggregate activity: active time, sessions
  watched, cost per agent/model) — on this Mac.
- **Your license key** — in the macOS Keychain.

You can remove all of this by quitting the app and deleting its preferences,
its stats file, and its Keychain item.

## 3. When the app writes to other local files

- **Precision mode** (opt-in) merges Notification/Stop hook entries into
  `~/.claude/settings.json` so Claude Code can signal exact waiting/done events.
  The merge is non-destructive, and turning Precision mode off removes only the
  app's own entries.
- **The Claude usage meter** (opt-in, Settings → Advanced) installs a small
  status-line helper that records Claude's 5-hour / weekly percentage locally.
  This is **zero network** — it reads a number Claude already computes on your
  Mac. Turning it off restores your previous status line.

## 4. Optional iCloud stats sync (off by default)

If you turn on stats sync, each of your Macs writes its **own** aggregate stats
ledger to a file in **your** iCloud Drive (an `AgentBabysitter` folder), so
"all-time" totals can span your Macs. This uses Apple's iCloud — your own
account — not any server we operate.

**Honesty note:** that ledger is keyed by agent id, model id, **and the name of
the project folder** you worked in. So turning this on copies your *project
folder names* (not just numbers) into your iCloud Drive. It never includes your
prompts or transcripts. Turning sync off deletes this Mac's file again.

## 5. Network connections (the complete list)

Every outbound connection the app can make is below. There are no others. None
of them send your prompts or transcripts.

| Feature | Host contacted | When | What is sent | Default |
|---|---|---|---|---|
| Currency conversion | `open.er-api.com` | While your display currency is not USD | Nothing about you — a request for current USD exchange rates, then cached | Triggered only by a non-USD currency choice |
| Update check | `api.github.com` | About once a day (toggle in License & Updates) | Nothing about you — a request for the latest release of `jaylmaao/agent-babysitter` | On; can be turned off |
| Live usage — Claude | `api.anthropic.com` | Only while **Live usage** is on (about every 5 min) | A tiny 1-token request using the Claude login already on this Mac; returns your 5-hour + weekly usage % | **Off** |
| Live usage — Cursor | `cursor.com` | Only while **Live usage** is on (about every 5 min) | A read-only usage request using the Cursor session already on this Mac; returns your included-usage % | **Off** |
| Live usage — Manus | `api.manus.im` | Only while **Live usage** is on (about every 5 min) | A read-only request using the Manus login already on this Mac; returns your credit balance | **Off** |
| License activation | `api.lemonsqueezy.com` | Only when you press **Activate** | Your license key and a machine/instance identifier, to activate and validate the license | Triggered only by activation |

Notes:

- **Live usage** is a single toggle, **off by default**. When off, none of
  `api.anthropic.com`, `cursor.com`, or `api.manus.im` is contacted. When on,
  the app uses the logins those vendors already have on your Mac to read *your
  own* usage back; it creates no new accounts and sends no transcripts. Each
  request goes only to that one vendor.
- Codex and Antigravity usage is read from local files with **no network call**.
- We operate **no server that receives your usage data.** The hosts above are
  third parties (Apple/iCloud, the currency-rate provider, GitHub, Anthropic,
  Cursor, Manus, and Lemon Squeezy). Data you send to them is also subject to
  their own privacy policies.

## 6. What we do NOT do

- No analytics or telemetry SDKs, no crash-reporting upload, no advertising or
  tracking, no device fingerprinting for us.
- We do not sell or share your personal information.
- We never transmit your prompts, agent transcripts, code, or file contents.

## 7. Third-party services and their policies

When an opt-in feature contacts a third party, that party processes the request
under its own terms. See:

- Apple iCloud — `<APPLE_PRIVACY_URL>`
- GitHub — `<GITHUB_PRIVACY_URL>`
- Anthropic — `<ANTHROPIC_PRIVACY_URL>`
- Cursor — `<CURSOR_PRIVACY_URL>`
- Manus — `<MANUS_PRIVACY_URL>`
- Lemon Squeezy — `<LEMONSQUEEZY_PRIVACY_URL>`
- open.er-api.com (exchange-rate provider) — `<ERAPI_PRIVACY_URL>`

<CONFIRM_BEFORE_RELEASE: verify each link and that this host list still matches
the shipping build.>

## 8. Data retention and your control

Because your data stays on your Mac, you control it directly:

- Preferences, stats, and license key live on your device; delete them to remove
  them.
- Turn off any opt-in feature to stop its network activity immediately; turning
  off iCloud stats sync also deletes this Mac's synced file.
- We hold no server-side copy of your usage to delete, because we never receive
  one.

## 9. Children

The app is not directed to children and does not knowingly collect information
from children under `<AGE, e.g. 13/16 per your jurisdiction>`.

## 10. Changes to this policy

If a future version changes what the app reads, stores, or sends, we will update
this policy and its "Last updated" date, and the in-app privacy text will match.

## 11. Contact

Questions about privacy: `<YOUR_SUPPORT_EMAIL>`
`<YOUR_LEGAL_NAME>`
`<YOUR_MAILING_ADDRESS — required in some jurisdictions>`
