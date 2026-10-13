# Udha for iOS

The iPhone and iPad client for **Udha**, a supervisor for long-running AI coding sessions (Claude Code, Codex,
Qwen Code, any shell command) on your own machines. From the phone you see every session on every machine,
read its live terminal, answer the prompts waiting on you, start new sessions, get a push when something needs
a human, record meetings on-device and talk to an agent by voice.

The phone runs no sessions itself. It reaches the hosts that do (the Udha macOS app, or `udha-agent` on a
Linux box) through a small relay you run yourself, signed in with your own Auth0 tenant. Nothing in this
repository points at anybody else's server, and no credential ships in the binary.

## Quick start

```bash
open Udha.xcodeproj
```

Add the launch argument `--udha-mock` to the scheme and run it on a simulator. A built-in fake host gives you a
working app with no relay, no account and no Mac.

To connect real machines, copy `Local.xcconfig.example` to `Local.xcconfig` and fill in your relay and Auth0
values. **[CLAUDE.md](CLAUDE.md) is the full setup guide**: requirements, configuration, the self-hosted relay,
optional features, tests and the code layout.

## Requirements

Xcode 26.1+, iOS 26.1+. No third-party dependencies.

## License

MIT. See [LICENSE](LICENSE).
