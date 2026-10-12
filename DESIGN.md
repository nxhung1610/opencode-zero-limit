---
name: RelayDock
description: A precise local operations console for account, proxy, and service state.
colors:
  signal-blue: "#70a5ff"
  signal-blue-light: "#1d5fce"
  focus-blue: "#80b0ff"
  night-ground: "#0b0f15"
  day-ground: "#f1f3f6"
  slate-surface: "#151c28"
  paper-surface: "#ffffff"
  ice-text: "#e8edf5"
  ink-text: "#202735"
  slate-muted: "#a0acbe"
  stone-muted: "#596579"
  slate-border: "#293547"
  light-border: "#d4dbe5"
  deep-sidebar: "#080b10"
  light-sidebar: "#e8edf3"
  action-ink: "#081321"
  secondary-dark: "#202a39"
  secondary-light: "#e5e9ef"
  input-border-dark: "#39475c"
  input-border-light: "#b8c1ce"
typography:
  title:
    fontFamily: "-apple-system, BlinkMacSystemFont, 'Helvetica Neue', 'Segoe UI', sans-serif"
    fontSize: "clamp(1.4rem, 1.9vw, 1.65rem)"
    fontWeight: 650
    lineHeight: 1.1
    letterSpacing: "-0.03em"
  body:
    fontFamily: "-apple-system, BlinkMacSystemFont, 'Helvetica Neue', 'Segoe UI', sans-serif"
    fontSize: "0.875rem"
    fontWeight: 400
    lineHeight: 1.5
  description:
    fontFamily: "-apple-system, BlinkMacSystemFont, 'Helvetica Neue', 'Segoe UI', sans-serif"
    fontSize: "0.9rem"
    fontWeight: 400
    lineHeight: 1.55
  control:
    fontFamily: "-apple-system, BlinkMacSystemFont, 'Helvetica Neue', 'Segoe UI', sans-serif"
    fontSize: "0.8rem"
    fontWeight: 500
    lineHeight: 1.2
  label:
    fontFamily: "-apple-system, BlinkMacSystemFont, 'Helvetica Neue', 'Segoe UI', sans-serif"
    fontSize: "0.61rem"
    fontWeight: 700
    lineHeight: 1.2
    letterSpacing: "0.13em"
  mono:
    fontFamily: "ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, 'Liberation Mono', 'Courier New', monospace"
    fontSize: "0.75rem"
    fontWeight: 400
    lineHeight: 1.45
rounded:
  base: "0.625rem"
  input: "0.5rem"
  nav: "0.48rem"
  panel: "0.75rem"
  pill: "999px"
spacing:
  "2": "0.5rem"
  "3": "0.75rem"
  "4": "1rem"
  "6": "1.5rem"
  "8": "2rem"
components:
  button-primary:
    backgroundColor: "var(--primary)"
    textColor: "var(--primary-foreground)"
    typography: "{typography.control}"
    rounded: "{rounded.base}"
    padding: "0.25rem 0.625rem"
    height: "1.75rem"
  button-outline:
    backgroundColor: "var(--background)"
    textColor: "var(--foreground)"
    typography: "{typography.control}"
    rounded: "{rounded.base}"
    padding: "0.25rem 0.625rem"
    height: "1.75rem"
  button-secondary:
    backgroundColor: "var(--secondary)"
    textColor: "var(--secondary-foreground)"
    typography: "{typography.control}"
    rounded: "{rounded.base}"
    padding: "0.25rem 0.625rem"
    height: "1.75rem"
  button-ghost:
    backgroundColor: "transparent"
    textColor: "var(--foreground)"
    typography: "{typography.control}"
    rounded: "{rounded.base}"
    padding: "0.25rem 0.625rem"
    height: "1.75rem"
  input-field:
    backgroundColor: "var(--background)"
    textColor: "var(--foreground)"
    typography: "{typography.mono}"
    rounded: "{rounded.input}"
    padding: "0.5rem 0.75rem"
  nav-item-active:
    backgroundColor: "color-mix(in srgb, var(--primary) 14%, var(--sidebar))"
    textColor: "var(--sidebar-foreground)"
    typography: "{typography.body}"
    rounded: "{rounded.nav}"
    padding: "0.5rem 0.65rem"
    height: "2.25rem"
  status-chip:
    backgroundColor: "var(--card)"
    textColor: "var(--foreground)"
    typography: "{typography.body}"
    rounded: "{rounded.pill}"
    padding: "0.4rem 0.7rem"
    height: "2rem"
  card-panel:
    backgroundColor: "var(--card)"
    textColor: "var(--card-foreground)"
    rounded: "{rounded.panel}"
    padding: "1rem"
---

# Design System: RelayDock

## Overview

**Creative North Star: "The Local Signal Room"**

The Local Signal Room is a precise, restrained instrument for local operations. It organizes real account, proxy, and server state in cool neutral surfaces; a single blue signal marks action, selection, focus, and a confirmed route. The interface uses a platform UI sans for working text and a monospace face for paths, IDs, and other code-like values.

The shell keeps grouped navigation and local-service status close while the work area gives real state room to breathe. Fine borders and tonal steps carry structure; one restrained route trace reveals the account-to-server relationship without turning it into spectacle. Dark is the default, light remains a deliberate alternative, and interaction remains accessible at narrow widths. This is not a literal Kubernetes dashboard, and it makes no implied remaining-quota promise.

**Key Characteristics:**
- Local and evidence-led.
- Cool-neutral surfaces; blue marks action, selection, focus, and confirmed route.
- Grouped, collapsible navigation and a compact service-status header.
- A named account → proxy/direct → server relationship.
- Tonal layers, fine borders, and motion that respects reduced-motion settings.

## Colors

The palette is “Signal blue / cool slate”: a narrow blue accent over cool near-neutrals. Dark is the default; light preserves the same semantic roles with its own contrast-safe values.

### Primary
- **Signal Blue:** Reserve for primary actions, selected navigation, keyboard focus, and confirmed route edges. The light-theme counterpart carries the same role with its theme-specific foreground.
- **Focus Blue:** A brighter edge for the keyboard ring and focused route marker; it is not a second decorative accent.

### Secondary
- **Slate Secondary:** A neutral control fill for selected modes and secondary actions, never a competing hue.

### Neutral
- **Night Ground / Day Ground:** The app canvas in dark and light themes.
- **Slate Surface / Paper Surface:** Cards, panels, and grouped work areas.
- **Deep Sidebar / Light Sidebar:** Persistent navigation background, distinct from the work canvas.
- **Ice Text / Ink Text:** Primary content text in dark and light themes.
- **Slate Muted / Stone Muted:** Supporting labels, descriptions, and code-adjacent metadata.
- **Slate Border / Light Border:** Dividers, outlines, and control boundaries.
- **Input Border:** A more legible stroke around editable fields.
- **Action Ink:** Legible text on the dark-theme primary action.
- Status and warning surfaces use neutral role tokens and explicit labels; color never carries status alone.

**The Signal Rule.** Use signal blue sparingly for actions, selection, focus, and confirmed route edges; keep status meaning in neutral tokens and explicit labels.

## Typography

**Title Font:** Platform UI sans stack.
**Body Font:** The same platform UI sans stack.
**Label/Mono Font:** A system monospace stack for paths, hostnames, IDs, and code-like values.

**Character:** Precise and restrained. Hierarchy comes from scale, weight, and compact tracking—not a separate expressive display face. Supporting copy stays readable, while code-like values are visually distinct without becoming decoration.

### Hierarchy
- **Title:** The compact, high-weight page title; it anchors each work area without reading like a marketing hero.
- **Body:** The standard interface voice for controls, descriptions, and explanatory copy.
- **Description:** Slightly more open leading and a bounded reading measure for page introductions.
- **Control:** A compact label for buttons and short actions.
- **Label:** Small uppercase text is confined to semantic navigation-group labels, not used as a page kicker.
- **Mono:** Use for paths, hostnames, IDs, and technical values only.

**The Workhorse Type Rule.** Let role, weight, and scale establish hierarchy; use the UI sans for the interface and monospace only for code-like data.

## Layout

The app uses a persistent grouped sidebar beside a flexible, scrollable work area. The expanded sidebar follows `clamp(13.75rem, 15.5vw, 19.25rem)` (220–308px), collapses accessibly to a 64px rail at widths of 820px and below, and keeps its labels and icon controls reachable. The topbar remains at least 4.15rem high with live server state, quota signal when observed, refresh, start/stop, and theme controls. The page description measure is capped at 76ch.

Responsive cut points are 820px, 760px, 560px, and 520px. The sidebar becomes an icon rail at the first cut; the route and setup content reflow at 760px; at 560px route/setup become single-column, usage uses a two-column grid, and proxy rows stack. At smaller widths, topbar controls wrap rather than overflow. Keep real primary actions and states first; do not fill sparse data with generic metrics.

**The Route Truth Rule.** Show only observed account, proxy/direct, and local server relationships; never infer a route or remaining quota.

## Elevation & Depth

Depth is tonal and border-led. A panel separates from the canvas through surface color and a fine boundary, not a resting shadow. Blue focus rings and the single route trace are state signals, not decoration. The route line draws once over 560ms and is disabled by reduced-motion preference; ordinary control transitions stay brief.

**The Tonal Depth Rule.** Use tonal surfaces and borders at rest; reserve halos for focus and avoid decorative shadow.

## Shapes

The shape vocabulary uses the base control radius for buttons, a slightly tighter radius for text fields and navigation, a broader corner on panels, and a full pill for compact status/mode chips. Route markers are circular. Keep borders fine and consistent; do not add clipped, glassy, or ornamental silhouettes. Focus remains explicit: a 2px outline with a 2px offset, supported by a 3px ring on interactive controls.

## Components

### Buttons
- **Primary:** A blue-filled, compact action; keep the label direct and pair it with a familiar Lucide icon only when it improves recognition.
- **Outline:** A neutral canvas with a visible boundary for secondary operations such as reload, test, or navigation.
- **Secondary:** A neutral raised fill for a selected mode or confirmed choice.
- **Ghost:** No resting fill; use for low-emphasis toolbar actions and collapsible utilities.
- **States:** Hover shifts the neutral/blue surface rather than adding a shadow. Focus uses the visible ring; active presses translate down by 1px. Disabled state reduces emphasis and blocks interaction.

### Chips
- **Style:** Compact pill with a neutral card fill, thin border, and explicit state text.
- **State:** Server health and quota signals appear only when observed; warning/positive meanings are not conveyed by hue alone.

### Cards / Containers
- **Style:** A single-pixel border, panel surface, and the panel corner token; content padding follows the spacing rhythm.
- **Depth:** No resting shadow. Use tonal separation and neighboring boundaries.

### Inputs / Fields
- **Style:** Native controls with a neutral border and canvas fill; path-like values use monospace.
- **Focus:** Keep the ring visible and preserve the native text-entry affordance.
- **Error / Disabled:** Pair a neutral error surface with explicit text and retry action; never rely on color alone.

### Navigation
- **Style:** Grouped Operations, Insights, and System sections; Lucide line icons; active page has a blue icon and restrained blue-tinted fill.
- **Mobile:** Collapse to an accessible icon rail while preserving `aria-current`, names, and keyboard focus.

### Switches
- **Style:** A pill track with a circular thumb; checked is blue, unchecked is neutral. Preserve the enlarged hit target and visible focus state.

### Route Topology
- **Style:** Three named nodes—account, usable proxy or direct path, and `opencode serve`—connected by a restrained route line.
- **Truth:** Health and binding copy comes only from current mode and observed health; untested, unavailable, and healthy remain distinct.
- **Motion:** One route-line draw on entry; honor reduced motion.

## Do's and Don'ts

### Do:
- Do reserve blue for actions, active navigation, focus, and confirmed route edges; keep status surfaces neutral.
- Do preserve explicit state text and use shape/icons as supporting cues, not color as the sole signal.
- Do keep paths, hostnames, IDs, and code-like values monospace.
- Do keep navigation, status, and primary actions usable at narrow widths and with keyboard focus.
- Do show only real account, proxy/direct, server, and quota state.

### Don't:
- Don't use green, yellow, or red hues for status, or rely on color alone.
- Don't invent remaining quota, proxy health, account state, or route topology.
- Don't make the app shell mimic macOS Settings or a native titlebar; keep the Settings route within the operations console.
- Don't add decorative hard shadows, glass, blur, gradients, or showy motion.
- Don't fill sparse local data with generic metric cards or literal Kubernetes concepts.
