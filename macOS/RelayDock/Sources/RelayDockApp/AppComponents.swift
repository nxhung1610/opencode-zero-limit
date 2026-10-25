import RelayDockCore
import SwiftUI

// MARK: - Layout

/// One set of spacing rules so every surface keeps the same rhythm: the menu
/// bar panel is the compact surface, window content the comfortable one, and
/// sheets sit in between.
enum AppLayout {
    /// Side gutter inside the menu bar panel.
    static let panelGutter: CGFloat = 12
    /// Side gutter inside modal sheets.
    static let sheetGutter: CGFloat = 20
    /// Point size for the small status glyphs shared by rows on all surfaces.
    static let statusGlyphSize: CGFloat = 13
}

// MARK: - Actions

/// The three action weights the app uses. Every button picks one of these so
/// the same weight reads the same on every surface: `primary` is a surface's
/// one forward action, `secondary` supports it, and `link` is for inline
/// tertiary affordances inside rows and banners.
enum AppActionRole {
    case primary
    case secondary
    case link
}

extension View {
    /// Native macOS button treatment. The system accent drives interactive
    /// controls; only status text and glyphs stay monochrome.
    @ViewBuilder
    func appAction(_ role: AppActionRole, size: ControlSize = .regular) -> some View {
        switch role {
        case .primary:
            buttonStyle(.borderedProminent).controlSize(size)
        case .secondary:
            buttonStyle(.bordered).controlSize(size)
        case .link:
            buttonStyle(.link).controlSize(size)
        }
    }
}

// MARK: - Copy

/// Copy that must say the same thing on every surface.
enum AppCopy {
    static let verificationHonesty = "RelayDock verifies traffic that routes through Edge; direct traffic stays invisible."
}

// MARK: - Shared views

/// The one status glyph for a proxy row: failed / untested / disabled /
/// passed. Shared by the menu bar panel and the pool window so the two can
/// never drift apart.
struct ProxyHealthIcon: View {
    var proxy: ProxyEntry
    var now: Date? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @ViewBuilder
    var body: some View {
        if let now {
            icon(now: now)
        } else if proxy.isFreeUsageLimited() {
            TimelineView(.periodic(from: .now, by: 1)) { timeline in
                icon(now: timeline.date)
            }
        } else {
            icon(now: Date())
        }
    }

    @ViewBuilder
    private func icon(now: Date) -> some View {
        Group {
            if !proxy.enabled {
                Image(systemName: "circle")
                    .foregroundStyle(.tertiary)
                    .accessibilityLabel("Disabled")
            } else if let limitedUntil = proxy.freeUsageLimitedUntil,
                      let remaining = ProxyStatus.remainingTime(until: limitedUntil, now: now) {
                Image(systemName: "clock.fill")
                    .foregroundStyle(Color.primary)
                    .accessibilityLabel("OpenCode free-usage limit active, \(remaining) remaining")
            } else if let health = proxy.health {
                Image(systemName: health.ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .foregroundStyle(health.ok ? Color.secondary : Color.primary)
                    .accessibilityLabel(health.ok ? "Last test passed" : "Last test failed")
            } else {
                Image(systemName: "questionmark.circle")
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Not tested")
            }
        }
        .font(.system(size: AppLayout.statusGlyphSize, weight: .semibold))
        .contentTransition(.opacity)
        .animation(reduceMotion ? nil : AppTheme.Motion.status, value: proxy.enabled)
        .animation(reduceMotion ? nil : AppTheme.Motion.status, value: proxy.health?.ok)
        .animation(reduceMotion ? nil : AppTheme.Motion.status, value: proxy.freeUsageLimitedUntil)
    }
}

/// The pass/fail/excluded line for a proxy row, with the optional
/// "· 2m ago" suffix. The menu bar panel and the pool window both use it so
/// the copy, ink weight, and age formatting cannot diverge.
struct ProxyStatusText: View {
    var proxy: ProxyEntry
    var mode: ProxyMode
    var isTesting: Bool
    var probeStatus: FreeUsageProbeStatus?
    /// A parent can supply its own timeline date to keep the whole row's
    /// visible, tooltip, and accessibility copy in sync.
    var now: Date? = nil
    var showsAge = true
    var font: Font = .footnote
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @ViewBuilder
    var body: some View {
        if let now {
            status(now: now)
        } else if proxy.isFreeUsageLimited() {
            TimelineView(.periodic(from: .now, by: 1)) { timeline in
                status(now: timeline.date)
            }
        } else {
            status(now: Date())
        }
    }

    private func status(now: Date) -> some View {
        let rowIsTesting = isTesting && probeStatus == nil
        let text = ProxyStatus.text(
            for: proxy,
            mode: mode,
            isTesting: rowIsTesting,
            probeStatus: probeStatus,
            now: now
        )

        return HStack(spacing: 4) {
            if probeStatus == .checking {
                ProgressView().controlSize(.mini)
            }
            Text(text)
                .monospacedDigit()
                .foregroundStyle(ProxyStatus.color(
                    for: proxy,
                    isTesting: rowIsTesting,
                    probeStatus: probeStatus,
                    now: now
                ))
                .contentTransition(.opacity)
                .animation(reduceMotion ? nil : AppTheme.Motion.status, value: text)
            if showsAge, let age = ageSuffix(now: now) {
                Text("· \(age)")
                    .foregroundStyle(.tertiary)
            }
        }
        .font(font)
        .lineLimit(1)
    }

    /// Row age suffix; hidden while a test run is rewriting results.
    private func ageSuffix(now: Date) -> String? {
        guard (!isTesting || probeStatus != nil), probeStatus != .checking, proxy.enabled else { return nil }
        return ProxyStatus.checkedAgo(for: proxy, now: now)
    }
}

/// The honesty line, reduced to one control so it stays available without
/// repeating a full sentence on every surface.
struct VerificationInfoButton: View {
    var text: String
    @State private var showsText = false

    var body: some View {
        Button {
            showsText.toggle()
        } label: {
            Image(systemName: "info.circle")
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showsText, arrowEdge: .bottom) {
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(14)
                .frame(width: 300)
        }
        .accessibilityLabel("About verification")
    }
}
