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
  (GUI apps inherit a stripped `PATH`).

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
```

Requires opencode ≥ 1.18 (tested against 1.18.35).

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

- Phase 5: tray icon, dark mode, custom icons, updater + GitHub Releases, CI (3-OS build),
  macOS/Windows signing, onboarding.
- DB polling as a second quota signal (SSE only sees sessions that run on *this* app's server).

## License

MIT (pending release).
