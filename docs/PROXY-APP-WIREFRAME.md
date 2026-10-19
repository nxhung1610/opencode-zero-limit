# RelayDock proxy app — wireframe variants

**Status:** implemented — config-only SwiftUI app with the P2 RelayDock Edge panel, delegated checks, a menu bar Edge line, and a shared routing-state presentation for the Routing tab and panel anchor (see "Implemented additions" below). The figures below remain the design reference; the app does not launch or control OpenCode processes.

## Reference

The attached Mos screenshot shows a compact Preferences window: centered title, a horizontal row of icon-and-label tabs, then a simple aligned settings form. **Variant A below follows that structure.** Mos's per-app screenshot also has a list/detail arrangement; that remains an alternative, not the primary direction.

- [Mos preferences screenshots](https://github.com/Caldis/Mos/tree/master/assets/readme/en-us)
- [Mos project README](https://github.com/Caldis/Mos/blob/master/README.enUS.md)

Borrow the information hierarchy and native macOS density—not Mos's colors, icons, branding, or custom appearance. RelayDock has one domain, so use only two meaningful tabs and no sidebar.

## Shared constraints

- Compact native macOS window, suggested **680 × 460 pt**, resizable; target a usable minimum near **600 × 400 pt**.
- Tabs are top-aligned icon + label controls. The Routing page owns Off/Manual/Auto; the Proxy Pool page owns import and tests.
- No account, usage, app settings, or server start/stop controls.
- A saved policy or successful endpoint check is not proof that OpenCode traffic used that route. The shipped honesty line is Edge-specific — "RelayDock verifies traffic that routes through Edge; direct traffic stays invisible." — and appears on both tabs and in the menu bar.
- Only explicit Off allows direct routing. Manual/Auto errors must never be converted into Off silently.

## Variant A — Mos-style Preferences tabs (recommended)

```text
┌──────────────────────────────────────────────────────────────────────┐
│ ● ● ●                         RelayDock                              │
│                                                                      │
│       [⇄ Routing]              ▦ Proxy Pool                           │
├──────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  ROUTING                                                             │
│                                                                      │
│  Proxy Mode       [ Off ] [ Manual ] [ Auto ]                        │
│                                                                      │
│  Manual Proxy     [ gateway-east · east.example.net:8080       ▾ ]   │
│                   Only shown/enabled when Manual is selected.        │
│                                                                      │
│  Auto Pool        2 eligible · 4 enabled                             │
│                   Unchecked proxies may be eligible.                 │
│                                                                      │
│  Policy           Saved locally                                      │
│                 Verifies Edge-routed traffic; direct stays invisible. │
│                                                                      │
└──────────────────────────────────────────────────────────────────────┘
```

**Proxy Pool tab:**

```text
┌──────────────────────────────────────────────────────────────────────┐
│ ● ● ●                         RelayDock                              │
│                                                                      │
│          ⇄ Routing          [▦ Proxy Pool]                            │
├──────────────────────────────────────────────────────────────────────┤
│  PROXY POOL · 4                              [Test All]  [ + Import ]│
│                                                                      │
│  gateway-east       east.example.net:8080       Passed · 42 ms  [On] │
│  backup-socks       socks.example.net:1080      Not tested      [On] │
│  gateway-west       west.example.net:8080       Disabled       [Off] │
│  local-debug        127.0.0.1:8888              Failed          [On] │
│                                                                      │
│  Select a row to reveal details and actions.                         │
│  Only Edge-routed traffic is verified; direct stays invisible.       │
└──────────────────────────────────────────────────────────────────────┘
```

This is closest to the screenshot you sent: icon tabs remain visible, the selected page uses straightforward form/list rows, and there is no navigation sidebar. The current MVP uses inline proxy details rather than a permanent inspector.

## Variant B — Split inspector

Best when proxy-by-proxy editing is frequent. It borrows the list/detail pattern from Mos's per-app settings screenshot, but is wider and less like the screenshot you shared.

```text
┌──────────────────────────────────────────────────────────────────────┐
│ RelayDock          [Routing] [Proxy Pool]       [Test All] [+]        │
├──────────────────────────────────────────────────────────────────────┤
│ AUTO · 2 eligible             Policy saved · live traffic unverified │
├──────────────────────┬───────────────────────────────────────────────┤
│ PROXY POOL            │ gateway-east                    [Enabled] [⋯]│
│ > gateway-east        │ east.example.net:8080                         │
│   backup-socks        │ Last test  Passed · 42 ms · 2 min ago        │
│   gateway-west        │ Protocol   HTTP                              │
│   local-debug         │ Credentials Masked                           │
│                       │ [Test]  [Use as Manual]                       │
└───────────────────────┴───────────────────────────────────────────────┘
```

Suggested size: **700 × 460 pt**. The current row selection opens details; in Auto, that selection is only an inspector focus—not the route a future caller will use.

## Variant C — Single compact list

Best for the smallest standalone window. Selecting a row expands its details inline.

```text
┌──────────────────────────────────────────────────────────────┐
│ RelayDock       [Routing] [Proxy Pool]       [Test] [+]      │
├──────────────────────────────────────────────────────────────┤
│ AUTO · 2 eligible · live traffic unverified                  │
├──────────────────────────────────────────────────────────────┤
│ ▼ gateway-east    east.example.net:8080    Passed · 42 ms    │
│   HTTP · checked 2 min ago · credentials masked               │
│   [Test this proxy]                         [Use as Manual]   │
│   backup-socks    socks.example.net:1080    Not tested        │
│   gateway-west    west.example.net:8080     Disabled          │
└──────────────────────────────────────────────────────────────┘
```

Suggested size: **590 × 390 pt**. Very compact, but expanded details increase list height.

## Variant D — Menu-bar popover

An optional Mos-like utility pattern for frequent mode changes; it is not the Preferences-window pattern in your screenshot. Use only if RelayDock should primarily live in the menu bar.

```text
             ┌────────────────────────────────────┐
             │ RelayDock                           │
             │ [ Off ] [ Manual ] [ Auto ]         │
             │ AUTO · 2 eligible                   │
             │ Live traffic not verified.          │
             ├────────────────────────────────────┤
             │ gateway-east       Passed · 42 ms   │
             │ backup-socks       Not tested       │
             │ local-debug        Failed           │
             ├────────────────────────────────────┤
             │ [Test All] [+ Import] [Manage Pool…]│
             └────────────────────────────────────┘
```

Popover width: **360–400 pt**. Detailed management opens a regular window.

## Comparison

| Variant | Footprint | Best for |
|---|---:|---|
| **A — Preferences tabs** | 680 × 460 pt | Closest match to your Mos screenshot; recommended starting point |
| **B — Split inspector** | 700 × 460 pt | Frequent detailed editing |
| **C — Inline list** | 590 × 390 pt | Smallest regular window |
| **D — Menu-bar popover** | 360–400 pt wide | Quick mode changes from the menu bar |

## Shared interaction and states

- The top tab row contains **Routing** and **Proxy Pool** only—no filler About/Updates tab.
- **Routing:** Off explicitly permits direct routing; Manual requires one enabled, valid proxy; Auto shows enabled/eligible counts and fails closed when none is usable.
- **Proxy Pool:** `Test All` checks enabled entries, `+ Import` opens a multiline import sheet, and each proxy shows text health state plus enabled state.
- Failed checks remain endpoint-check results, not proof about live OpenCode traffic; only Edge's tunnel accounting speaks to real traffic, and only to the traffic that routes through Edge. Unknown health is distinct from failed health.
- If Manual has no valid selection, keep the previous policy and prompt for a proxy. Never silently switch to Off.
- Preserve pasted import text after validation errors and show invalid line numbers; mask credentials in labels, previews, and errors.
- Use Aqua/system colors and controls in Light and Dark appearance. Pair color with a label/symbol, expose tab and control states to VoiceOver, and keep keyboard focus order visible.

## Implemented additions (P2)

- **Routing tab — RelayDock Edge section:** live daemon state (running / not running / not configured), mode, upstream with source and expiry, rotation and failure counters, provider cooldown, last error, and recent tunnels grouped by peer process (pid + name, active-first). Polled from Edge's `/__relaydock/status` roughly every 3 s while the window or the menu bar popover is visible; a miss reads as "not running", never as an error. Footnote: "From Edge's own tunnel accounting."
- **Proxy Pool — delegated `Test All`:** checks run inside Edge (`/check?scope=all`, available in every mode including Off) whenever `edge.json` exists and Edge answers; deferred results are reported, not recorded. When Edge is unreachable the check falls back in-process and the pool header says so — "RelayDock Edge was unreachable, so the last check ran in this app." — or "Last check ran through RelayDock Edge." otherwise.
- **Menu bar — Edge line:** `Edge running · <upstream label | Direct | No upstream> · <N active>`, showing Edge's own mode only when it diverges from the saved one; `Edge not running` when the daemon does not answer (tooltip: starts on demand at the next wrapped launch). Hidden entirely when Edge is not configured.
- **Honesty line (window footer + menu bar):** "RelayDock verifies traffic that routes through Edge; direct traffic stays invisible."

## Implemented refinements (menu bar panel)

- **State anchor:** the panel leads with the same symbol, tint, headline, and consequence line as the Routing tab, from one shared source (`RoutingStatePresentation`) — a warning reads identically on both surfaces. Calm captions earn their line only when they inform: Manual's fail-closed promise, and Auto's "Unchecked proxies may be eligible." while an enabled proxy is unchecked.
- **Header:** no longer repeats the saved mode; the anchor and the segmented control already say it.
- **Row freshness:** rows append a compact check age (`· 2m ago`, `1h ago`, `2d ago`) when the health timestamp is in the stored millisecond format; legacy seconds timestamps and in-progress test runs show none. Row tooltips and VoiceOver labels carry outcome, error, and age (`ProxyStatus.detail`).
- **Chrome:** "Test All" gains a refresh glyph, the error banner's Dismiss is a link, the honesty line gains an info glyph, and section padding uses the 12-point rhythm.

## Shared components (app design system)

Every surface draws its controls from one place — `Sources/RelayDockApp/AppComponents.swift` — so the menu bar panel, the window, and the sheets cannot drift apart:

- **`AppLayout`:** one set of spacing rules. Side gutters: panel 14, window 22, sheets 20; one title-to-subtitle spacing (3); one status-glyph size (13).
- **`AppActionRole` + `.appAction(_:size:)`:** the only way a button picks its look. `primary` (bordered prominent) is a surface's one forward action, `secondary` (bordered) supports it, and `link` is for inline tertiary affordances. Sizes follow the surface: `.small` in the panel, `.regular` inside forms and rows, `.large` for window headers, sheets, and empty-state calls to action. No manual padding or one-off `controlSize` on buttons; the one exception is a `ProgressView` spinner nested inside a button label (`.small`).
- **`ModeSegmentedPicker`:** the Off/Manual/Auto control, identical on the panel and the Routing tab (same size, same tags).
- **`AppTitle`:** surface titles (headline + caption subtitle) and modal titles (title2 + body subtitle) — one header shape per surface.
- **`ProxyHealthIcon` and `ProxyStatusText`:** the row glyph and the pass/fail/excluded copy with its optional "· 2m ago" age, shared by the pool window and the menu bar panel (`ProxyStatus` supplies the words and colors).
- **`HonestyFootnote`:** the honesty line's wording, glyph, and style, shared by the panel and the window footer.

Action weights in place: panel — secondary "Test All" and primary "Open RelayDock…" as equal-width halves; pool header — secondary "Test All" and primary "Import"; sheets — secondary "Cancel" and primary Add/Import/Save; empty states — one primary call to action ("Import Proxies").
