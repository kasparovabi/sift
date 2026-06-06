# Claude OS

Native macOS control center for Claude Code: find/search/resume any session, run
several sessions at once, menubar + global quick-open, and a durable launchd
scheduler. Full plan lives in the session plan file.

## Module map
- `ClaudeOSCore` — shared contracts with no UI and no DB: the `SessionLauncher`
  seam, models (`Project`, `SessionSummary`), the environment/PATH resolver, and
  `claude` binary resolution. Both halves of the app depend only on this.
- `claudeos-spike` — M0 proof: a SwiftUI window that embeds the real `claude`
  CLI in a SwiftTerm PTY. Verifies embedded TUI fidelity, `--resume`, and the
  environment/PATH fix.

## M0 commands
```sh
swift build                 # compiles Core + spike (pulls SwiftTerm)
swift test                  # headless logic tests (PATH fix, path codec)
swift run claudeos-spike    # opens the embedded-claude window
```

In the spike window: leave the id field empty to start a fresh session, or paste
a real session id to prove `--resume`.
