# Homebrew cask for Agent Babysitter. Published copy lives in the
# jaylmaao/homebrew-tap repo; this is the source of truth, stamped by
# Scripts/update-cask.sh at release time (version + sha256).
cask "agent-babysitter" do
  version "0.11.1"
  sha256 "75adb72a6eb96f5c93289efdf31068795dd9333fdeac1bde9654d3cf33d9accc"

  url "https://github.com/jaylmaao/agent-babysitter/releases/download/v#{version}/AgentBabysitter-#{version}.dmg"
  name "Agent Babysitter"
  desc "Menu bar monitor for AI coding agents (Claude Code, Codex, Cursor, Manus, and more)"
  homepage "https://github.com/jaylmaao/agent-babysitter"

  livecheck do
    url :url
    strategy :github_latest
  end

  app "AgentBabysitter.app"

  caveats <<~EOS
    Agent Babysitter is an unsigned beta. To skip the one-time Gatekeeper
    prompt, install with:
      brew install --cask --no-quarantine jaylmaao/tap/agent-babysitter
    Otherwise, allow it once under System Settings > Privacy & Security.
  EOS

  zap trash: [
    "~/Library/Application Support/AgentBabysitter",
    "~/Library/Preferences/app.agentbabysitter.AgentBabysitter.plist",
  ]
end
