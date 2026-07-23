# Homebrew cask for Agent Babysitter. Published copy lives in the
# jaylmaao/homebrew-tap repo; this is the source of truth, stamped by
# Scripts/update-cask.sh at release time (version + sha256).
cask "agent-babysitter" do
  version "0.11.3"
  sha256 "f4923904735c113246abf70af7b39942e7ecf8e3fb7ecce20cbee92618ca7432"

  url "https://github.com/jaylmaao/agent-babysitter/releases/download/v#{version}/AgentBabysitter-#{version}.dmg"
  name "Agent Babysitter"
  desc "Menu bar monitor for AI coding agents (Claude Code, Codex, Cursor, Manus, and more)"
  homepage "https://github.com/jaylmaao/agent-babysitter"

  livecheck do
    url :url
    strategy :github_latest
  end

  app "AgentBabysitter.app"

  # This caveat exists ONLY because the DMG is not yet signed and notarized.
  # Do not reintroduce `--no-quarantine` guidance here: stripping quarantine
  # is the instruction malware distributors give, it disqualifies the cask
  # from homebrew-cask proper, and it removes the attribute macOS needs to
  # revoke a compromised binary later. The real fix is a Developer ID
  # signature + notarization ticket (see Scripts/make-dmg.sh). Once the DMG
  # is signed and notarized, delete this whole caveats block — Gatekeeper
  # verifies the stapled ticket and the first-launch prompt disappears.
  caveats <<~EOS
    Agent Babysitter is an unsigned beta, so macOS Gatekeeper blocks the
    first launch. To open it: launch it once and dismiss the warning, then
    open System Settings > Privacy & Security, scroll down, and click
    "Open Anyway" next to Agent Babysitter. You only have to do this once.
  EOS

  zap trash: [
    "~/Library/Application Support/AgentBabysitter",
    "~/Library/Preferences/app.agentbabysitter.AgentBabysitter.plist",
  ]
end
