# opencode-zero-limit — Plan v1

Desktop app (macOS / Windows / Linux) giữ **opencode CLI** luôn chạy được trên free tier:
**quota visibility + multi-account switching + proxy pool**.

## Quyết định đã chốt

| Hạng mục | Quyết định |
| --- | --- |
| Scope | Chỉ **opencode CLI** (provider `opencode` / zen / go), không mở rộng provider khác |
| Stack | Tauri 2 · React + TypeScript · Tailwind + shadcn/ui · Rust backend |
| Phát hành | Public release: code signing + updater + GitHub Releases |
| Quota cạn | **Tự động switch** account (kèm proxy nếu bật) + cho phép **manual switch** trong UI |

## Kiến trúc

```
┌─ opencode-zero-limit (Tauri 2) ─────────────────────────┐
│ React UI                                                 │
│   Accounts · Usage · Proxy · Settings                    │
│ Rust services (src-tauri/src/services/)                  │
│   opencode.rs  spawn/manage `opencode serve`             │
│                REST + SSE (GET /doc, /event, /provider)  │
│   accounts.rs  N account, key trong OS keychain          │
│                switch qua PUT /auth/:id                  │
│   usage.rs     đọc SQLite của opencode (read-only)       │
│                bắt lỗi quota từ SSE                      │
│   proxy.rs     pool proxy, health check, rotation        │
│                set HTTPS_PROXY khi spawn                 │
└──────────────────────────────────────────────────────────┘
```

## Nguồn dữ liệu (đã tra cứu)

- **API**: `opencode serve` expose OpenAPI 3.1 tại `/doc` — các endpoint dùng tới:
  `GET /global/health`, `GET /event` (SSE), `GET /provider`, `GET /config`,
  `PUT /auth/:id` (đặt credentials), `GET /session`, `GET /event`.
- **Proxy**: opencode tôn trọng `HTTPS_PROXY` / `HTTP_PROXY` / `NO_PROXY`
  (docs `/docs/network`) — **bắt buộc** `NO_PROXY=localhost,127.0.0.1` tránh routing loop.
- **Usage**: SQLite cục bộ của opencode (xem `opencode debug paths`), bảng
  `session` / `message` / `part` (tokens, reasoning tokens, cost).
- **Quota**: opencode **không có API quota**. Free limit là *dynamic* theo capacity
  (issue anomalyco/opencode#28055). Nên app hiển thị:
  1. usage cục bộ (tokens / requests / per model / per ngày),
  2. **phát hiện** error `Free usage exceeded` / 429 từ SSE → đánh dấu account cạn + cooldown.
  Không hứa "còn X lượt".
- **Credential**: `PUT /auth/:id` trên server, hoặc file credential của opencode.
  Cơ chế switch chính xác xác nhận ở **Phase 0**.

## Phase 0 — Spike (1–2 ngày) ⚠️ chặn tiến độ

1. Switch account: test `PUT /auth/:id` với 2 API key thật — switch được không,
   có cần restart server không.
2. Nguồn quota: xác nhận bắt được error `Free usage exceeded` từ stream event.
3. Proxy: xác nhận `HTTPS_PROXY` khi spawn hoạt động + `NO_PROXY` cho local.

## Phase 1 — Scaffold + plumbing

- `create-tauri-app` (react-ts) + Tailwind + shadcn/ui + ESLint/Prettier + CI.
- Rust: spawn `opencode serve --port <random>`, health check `/global/health`,
  subscribe SSE `/event`, cache `/config` + `/provider`.
- UI shell: sidebar **Accounts · Usage · Proxy · Settings**.

## Phase 2 — Account manager

- CRUD account: label, provider (`opencode` / `opencode-go`), API key.
- Key lưu **OS keychain** (crate `keyring`: macOS Keychain / Windows Credential
  Manager / libsecret).
- Manual switch → `PUT /auth/:id` → verify `GET /provider` (`connected`).
- Trạng thái mỗi account: `active` / `exhausted` / `error`.

## Phase 3 — Quota & usage

- Dashboard: tokens, reasoning tokens, requests, cost — theo ngày / model / account
  (đọc SQLite **read-only**).
- Event `Free usage exceeded` / 429 → toast + **auto-switch** account (nếu bật
  auto-rotate) + cooldown timer.

## Phase 4 — Proxy pool

- Import bulk (http / https / socks5), health check (latency + reachability).
- Rotation: **sticky theo account** (mỗi account 1 IP, tránh bị link),
  fallback round-robin khi proxy chết.
- Áp dụng khi spawn: `HTTPS_PROXY=<selected>` + `NO_PROXY=localhost,127.0.0.1`.
- Manual: user chọn proxy cụ thể cho lần chạy tiếp theo.

## Phase 5 — Public release

- Tray icon: switch account nhanh, pause proxy, trạng thái quota.
- Onboarding, dark mode, empty states.
- Signing: macOS Developer ID + notarization, Windows signtool, Linux AppImage/deb/rpm.
- `tauri-plugin-updater` + GitHub Releases (auto-update channel).
- CI: `tauri-action` build 3 OS on tag; contract test `/doc` với opencode pinned.
- README, screenshots, LICENSE.

## Rủi ro

| Rủi ro | Mitigation |
| --- | --- |
| opencode API không ổn định giữa version | Pin version opencode, contract test `/doc` trong CI |
| Quota dynamic, không có API | Chỉ claim "phát hiện cạn", không claim "còn bao nhiêu" |
| Switch cần restart server (Phase 0 lệch) | Fallback: ghi credential + restart `opencode serve` |
| Keychain lần đầu hiện prompt | Document trong onboarding |
| Linux tray yếu trên GNOME | Ghi nhận trong README (cần AppIndicator extension) |

## Mốc ước tính

| Milestone | Nội dung | Ước |
| --- | --- | --- |
| M0 | Phase 0 spike | 1–2 ngày |
| M1 | Scaffold + serve manager | 2–3 ngày |
| M2 | Account manager | 2–3 ngày |
| M3 | Usage + quota events | 2–3 ngày |
| M4 | Proxy pool | 2 ngày |
| M5 | Release | 2–3 ngày |
