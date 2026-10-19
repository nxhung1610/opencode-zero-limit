# Contributing to RelayDock

Thanks for taking the time to improve RelayDock. This is a small, focused project; the notes below keep changes predictable.

## Ground rules

- **Keep routing fail-closed.** Manual and Auto must never silently fall back to direct. The opt-in Direct fallback stays labeled and counted, and pinned listeners never fall back.
- **The app does not manage OpenCode.** It must not launch, restart, or kill OpenCode processes, and it must never edit `~/.zshrc`, `~/.zprofile`, or other shell profiles.
- **No new runtime dependencies.** `RelayDockCore` is a plain Swift package built on Foundation and system frameworks.
- **macOS 14+ and Swift 6.** Release builds are Apple Silicon (arm64); keep the code buildable from a clean checkout.
- **English copy.** UI strings, documentation, code comments, and commits are written in English.
- **Never commit credentials.** Use example hosts such as `gateway.example`; redact proxy URLs and tokens in logs and screenshots.

## Development

```sh
swift test --package-path macOS/RelayDock
scripts/build-macos-app.sh
scripts/launcher-sandbox-test.sh
```

`scripts/launcher-sandbox-test.sh` is the end-to-end check for the wrapper, Edge, and installer: it uses a stub command, a fake `launchctl`, and local fake providers, so it needs no real OpenCode account or network.

UI fixture images used in the README are rendered offscreen by `UIFixturesTests`:

```sh
RELAYDOCK_FIXTURE_DIR="$PWD/build/ui-captures/fixtures" \
  swift test --package-path macOS/RelayDock --filter UIFixturesTests
```

## Pull requests

- Keep a pull request to one concern; split unrelated refactors.
- Add or update tests when behavior changes. Run the full Swift suite and the sandbox script before opening the PR.
- Update the README or the relevant document in `docs/` when user-visible behavior, policy, or the update path changes.
- CI must be green. The release workflow only publishes from `v*` tags; do not tag from a pull request.

Security issues should follow [SECURITY.md](SECURITY.md) instead of a public issue or pull request.
