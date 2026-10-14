---
name: RelayDock
description: Native macOS operations companion for OpenCode.
---

# Design System: RelayDock

## Direction

**Creative North Star: “The Local Signal Room.”** A calm, precise native utility that makes account, proxy, server, and quota state legible without imitating a browser dashboard.

The app should follow macOS conventions first: standard window chrome, a `NavigationSplitView`, native toolbar actions, platform typography, system accent colors, and familiar SwiftUI controls. RelayDock-specific styling should clarify real state—not replace platform affordances.

## Navigation and composition

- Use a grouped macOS sidebar for Accounts, Usage, Proxies, and Settings.
- Keep the managed OpenCode status and Start/Stop action in the native toolbar.
- Use `Form` for preferences and configuration; use `GroupBox`, row dividers, and `ContentUnavailableView` for structured content and empty/error states.
- Preserve generous native window resizing behavior instead of web breakpoints or mobile-specific layouts.
- Give each view one clear task; prioritize real account/proxy/server status over decorative metrics.

## Color and appearance

- Use semantic SwiftUI colors and the system accent color for focus, selection, and primary actions.
- Support System, Light, and Dark appearance through macOS color-scheme behavior.
- Use explicit text, icons, and shape as well as color for status. Green/orange/red may reinforce a state but must never be its only explanation.
- Keep surfaces quiet; avoid web-style gradients, glass effects, heavy shadows, and custom background layers that fight native window chrome.

## Typography and symbols

- Default to the macOS system font and dynamic text styles.
- Use monospaced styling only for paths, proxy URLs, IDs, and other technical values.
- Use SF Symbols paired with visible labels for important actions and states.
- Keep page titles, section headings, and supporting copy at native hierarchy and readable measures.

## Interaction and accessibility

- Use standard buttons, toggles, pickers, text fields, text editors, alerts, and confirmation dialogs.
- Destructive account/wrapper actions require explicit confirmation and explain exactly what is removed.
- Preserve keyboard navigation, VoiceOver labels, focus visibility, reduced-motion expectations, and adequate hit targets.
- Errors must state what failed and offer a direct recovery action when possible.
- Never invent quota remaining, account state, proxy health, or routing relationships.

## Brand assets

Keep the existing RelayDock icon as the source of truth. Do not alter the mark without explicit approval.
