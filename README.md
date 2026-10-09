# opencode zero limit

Desktop companion (Tauri 2 + React) that keeps the [opencode](https://opencode.ai) CLI running on
its free tier: **quota visibility, multi-account switching, proxy pools**.

> Status: active development — Phases 0–4 implemented, release packaging pending.

## What it does

- **Accounts** — lists console accounts/orgs stored by opencode, switches the active account+org
  (restarting the local `opencode serve` so the new console config is applied, exactly like the
  TUI does), logs in/out via `opencode console login|logout`.
- **Usage** — local counters (requests, tokens, cache, cost, top models) read directly from
  opencode's SQLite database. Free quota is enforced server-side and never announced ahead of
  time, so the app only claims *"quota hit"*, never *"N requests left"*.
- **Quota watcher** — subscribes to the local server's SSE stream and reacts to
  `session.status → retry` with `free_tier_limit` / `account_rate_limit`. With **auto-rotate**
  enabled it switches to the next account/org and restarts the server (cooldown 120 s).
- **Proxies** — import a pool (http/https/socks5), health-check it, and apply it on spawn via
  `HTTPS_PROXY` with `NO_PROXY=localhost,127.0.0.1`. Modes: `off`, `auto` (one sticky IP per
  account, round-robin on failure), `manual`.
- **Settings** — auto-start the local server, auto-rotate toggle, opencode binary path override
  (GUI apps inherit a stripped `PATH`), light/dark/system theme, and **in-app updates**
  (signed artifacts from GitHub Releases).
- **Tray icon** — serve + quota status at a glance, quick start/stop, show window, quit.

## How it works (opencode internals discovered in Phase 0)

| Concern | Mechanism |
| --- | --- |
| Account list / switch | `GET /experimental/console/orgs`, `POST /experimental/console/switch` on a running `opencode serve`; switch must be followed by a restart (`instance.dispose()` in the TUI) |
| Login | `opencode console login` — device-code flow, needs a TTY (opened in Terminal) |
| Quota signals | SSE `session.status` retry actions, plus persisted `message.data.error.responseBody` (`FreeUsageLimitError`) in the shared SQLite DB |
| Free limit rules | counted per **IP**, daily, resets 00:00 UTC (`Subscription.getFreeLimits`) |
| Traffic path | TUI → local instance → `https://opencode.ai/zen/v1` (key `public` when anonymous) |
| Proxy | opencode honours `HTTPS_PROXY`/`HTTP_PROXY`/`NO_PROXY` (`util/proxy-env.ts`) |

## Development

```bash
npm install
npm run tauri dev     # requires Rust (rustup) + opencode CLI on PATH
npm run build         # tsc + vite build
cd src-tauri && cargo check
bash scripts/contract-test.sh   # requires opencode-ai CLI; pins the API surface we rely on
```

Requires opencode ≥ 1.18 (tested against 1.18.35). CI runs on every push to `main`:
frontend build, `cargo check`, and the contract test (`.github/workflows/ci.yml`).

## Release

```bash
# 1. bump version in package.json AND src-tauri/tauri.conf.json
# 2. commit, then:
git tag v0.1.0 && git push origin v0.1.0
```

The `release` workflow (`.github/workflows/release.yml`) builds macOS (arm64 + x64),
Linux and Windows, signs the updater bundles, and creates a **draft** GitHub release with
`latest.json` for auto-update.

Required repository secrets (Settings → Secrets → Actions):

| Secret | Content |
| --- | --- |
| `TAURI_SIGNING_PRIVATE_KEY` | contents of the private key file (kept at `~/.tauri/…) |
| `TAURI_SIGNING_PRIVATE_KEY_PASSWORD` | its password |

> Note: no Developer ID / notarization yet — macOS users will need right-click → Open on
> first launch, and Windows SmartScreen will warn. Both disappear once proper code signing
> is set up (see PLAN.md Phase 5).

## Layout

```
src/                    React app
  features/             accounts · usage · proxy · settings pages
  services/             typed wrappers over Tauri invoke
  components/           layout + shadcn/ui
src-tauri/src/
  services/opencode.rs  spawn/stop/health of `opencode serve`
  services/console.rs   account org list/switch/login/logout
  services/watcher.rs   SSE quota watcher + auto-rotate
  services/usage.rs     SQLite usage summaries (read-only)
  services/proxy.rs     proxy pool, health checks, sticky bindings
  commands.rs           Tauri command surface
PLAN.md                 phase plan, risks, milestones
```

## Roadmap

- DB polling as a second quota signal (SSE only sees sessions that run on *this* app's server).
- Per-account quick switch from the tray menu.
- macOS Developer ID signing + notarization, Windows signtool.
- Screenshots for the store page.

## License

MIT — see [LICENSE](LICENSE).
