# RelayDock design

## Direction

**Native Mac app.** RelayDock uses the standard macOS window model: a source-list sidebar, a real toolbar, grouped forms and inset lists, and system controls. Hierarchy comes from the platform, not from custom chrome. The one deliberate exception is status color: proxy health and routing state stay monochrome (ink weight plus SF Symbols), while interactive controls use the user's system accent. This is not a browser dashboard or an OpenCode process manager.

## Window and navigation

- Default window is **760×580 outer** (760×528 content under the unified toolbar), with a **680×500 content minimum** (680×552 outer). The sidebar is 180–240pt wide, ideally 200pt.
- `NavigationSplitView` owns the shell. The sidebar is a native `List` with one **RelayDock** section holding **Routing** and **Proxy Pool**. Its footer shows the saved Edge state and the running version.
- Actions live in the window toolbar: **Test All** (refresh glyph) and **Import Proxies** (plus, ⇧⌘O). Both are disabled when they cannot apply.
- Update news is a detail-top banner, not a sidebar footer. It appears only for actionable phases — available, downloading, ready, failed — with an icon, a short title, optional detail, and the updater's controls. The quiet daily check and its "up to date" result stay out of the way. **Check for Updates…** also lives in the app menu after About.
- The menu bar panel is **360pt wide**: title and honesty ⓘ, monochrome status summary, native segmented Off/Manual/Auto picker, up to four proxy rows, Test All / Open RelayDock, and a version plus update footer.
- Sheets stay native. Import is a 520×520 grouped form with **Add One** and **Bulk Import** modes; the manual proxy chooser and routing-mode warnings are sheets/alerts with system buttons.

## Routing

Routing is one grouped `Form`, read top to bottom:

- **Overview** — Status, Enabled, Auto eligible, and Healthy as trailing values. Footer: "How RelayDock Edge routes OpenCode traffic."
- **Policy** — native segmented **Mode** picker; a footer explaining Off, Manual, and Auto; the **Manual proxy** picker when Manual is selected; the **Direct fallback** toggle with its fail-open consequence in the footer.
- **RelayDock Edge & routing setup** — an advanced `DisclosureGroup` containing the setup rows, the copyable service hint, and live Edge telemetry. Collapsed by default; its label carries the current Edge summary.
- The Policy footer carries the honesty line: "RelayDock verifies traffic that routes through Edge; direct traffic stays invisible."

There are no custom radio rows or policy cards. The native segmented picker is the policy control, and the system accent marks the selected mode.

## Proxy Pool

- A quiet check-notes banner appears above the list only when the last check has something to report (delegated through Edge, or fell back in-process).
- The pool is a native inset `List`. The section header reads **Proxies** with a trailing count/health summary. Each row shows the status glyph, label, endpoint or "Custom script", the status text, a small enabled switch, and a disclosure chevron.
- Expanding a row reveals Protocol, Last test, **Use as Manual**, **Edit Script…**, **Copy Masked URL** / **Copy Script**, and a destructive **Remove** that stays monochrome until the system confirmation dialog.
- The section footer summarizes healthy / untested / failed / disabled counts, the Auto rule that unchecked proxies stay eligible, and the honesty line.
- An empty pool is a `ContentUnavailableView` with one **Import Proxies…** action.

## Status and color

- Interactive controls — buttons, switches, segmented pickers, links — use the **system accent**. No custom tint is applied.
- Status stays monochrome: filled check for passed, hollow question for untested, hollow circle for disabled, filled exclamation for failed. Failures take primary ink; healthy and supporting states stay secondary or tertiary. Meaning never depends on hue.
- Native red appears only in system destructive confirmation dialogs. It is not a status color.
- The app no longer defines a card, topbar, pill, or custom button palette. `AppTheme` keeps only `windowBackground`, `ink`, `inkMuted`, and the shared status animation curve.

## Typography and layout

- Use semantic system fonts: `headline` for panel titles, `body` for rows, `callout` for explanatory text, `caption` and `footnote` for supporting copy, and `monospacedDigit` for counts, timings, and versions. Reserve monospaced text for endpoints, scripts, and technical values.
- Grouped forms and inset lists provide their own surfaces, separators, and insets. Do not draw custom cards or borders around them.
- Form and list footers use footnote secondary text, left-aligned across the row width so long honesty and rule sentences do not collapse into a narrow column.
- Keep native focus rings, keyboard navigation, and control sizes. The only shared button mapping is `appAction`: prominent for a surface's forward action, bordered for support, link for inline row actions.

## Interaction and safety

- Native buttons, toggles, pickers, text editors, sheets, alerts, and confirmation dialogs remain the base. `appAction` wraps them; it does not replace their behavior.
- Motion is limited to functional changes: status glyph and counter crossfades, row detail expansion, and disclosure changes. Every animation is gated by Reduce Motion; nothing loops or auto-plays.
- Pair ink weight with a visible text label and/or symbol so proxy health and routing state survive without color. Expose selected sections, proxy health, and enabled state to VoiceOver.
- Manual/Auto errors must never silently become Off. A saved setting and a successful endpoint check do not verify live OpenCode traffic; offline or unknown state is not safe.
- Retain import text after validation errors and identify invalid lines. Mask proxy credentials in labels, previews, and copy actions.
- Custom (JS) entries use a monospaced editor, a documented Node-flavoured API surface (`fetch`/`await`, timers, `URL`, `Buffer`, `crypto`, synchronous `http.get`/`http.post`, plus a memory-only `cache` kept between runs), and Test Script and Edit Script actions. Editing keeps the entry's identity and clears stale health and cache.
- Preserve routing and probe behavior. This design changes presentation only; it never restarts or kills OpenCode or its sessions.

## Brand assets

Use the existing RelayDock icon as the source of truth. The menu bar mark is a template derived from it. Do not alter the mark without explicit approval.

## Source of truth

- `macOS/RelayDock/Sources/RelayDockApp/RootView.swift` — split shell, sidebar, toolbar, update banner.
- `RoutingView.swift` and `ProxyPoolView.swift` — the two detail pages.
- `MenuBarPanelView.swift` — the 360pt panel.
- `ProxyImportSheet.swift` — import and edit sheet.
- `AppComponents.swift` — `AppLayout`, `appAction`, and shared status views.
- `AppTheme.swift` — the remaining semantic tokens. `AppChrome.swift` has been removed; do not restore it.
