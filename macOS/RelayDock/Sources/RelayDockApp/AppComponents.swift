import RelayDockCore
import SwiftUI

// MARK: - Layout

/// One set of spacing rules so every surface keeps the same rhythm: the menu
/// bar panel is the compact surface, window content the comfortable one, and
/// sheets sit in between.
enum AppLayout {
    /// Side gutter inside the menu bar panel.
    static let panelGutter: CGFloat = 14
    /// Side gutter for window content (RootView footer, pool header and rows).
    static let windowGutter: CGFloat = 22
    /// Side gutter inside modal sheets.
    static let sheetGutter: CGFloat = 20
    /// Title-to-subtitle spacing on every surface header.
    static let titleSpacing: CGFloat = 3
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
    /// App-standard button treatment. `size` follows the surface: `.large` for
    /// surface actions, headers, sheets, and calls to action; `.regular` inside
    /// forms and rows; `.small` for inline links.
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

// MARK: - Shared views

/// A surface's leading title and optional subtitle/count line. `surface`
/// heads a panel or window section; `modal` heads a sheet.
struct AppTitle: View {
    enum Style {
        case surface
        case modal
    }

    var title: String
    var subtitle: String?
    var style: Style = .surface

    var body: some View {
        VStack(alignment: .leading, spacing: AppLayout.titleSpacing) {
            Text(title)
                .font(style == .surface ? .headline : .title2.weight(.semibold))
            if let subtitle {
                Text(subtitle)
                    .font(style == .surface ? .caption : .body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// The Off/Manual/Auto control, identical on both surfaces.
struct ModeSegmentedPicker: View {
    @Binding var mode: ProxyMode
    var size: ControlSize = .large

    var body: some View {
        Picker("Proxy Mode", selection: $mode) {
            Text("Off").tag(ProxyMode.off)
            Text("Manual").tag(ProxyMode.manual)
            Text("Auto").tag(ProxyMode.auto)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(size)
    }
}

/// The honesty line — one wording, one icon, one style, on every surface.
struct HonestyFootnote: View {
    var body: some View {
        Label(
            "RelayDock verifies traffic that routes through Edge; direct traffic stays invisible.",
            systemImage: "info.circle"
        )
        .font(.footnote)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// The one status glyph for a proxy row: failed / untested / disabled /
/// passed. Shared by the menu bar panel and the pool window so the two can
/// never drift apart.
struct ProxyHealthIcon: View {
    var proxy: ProxyEntry

    var body: some View {
        Group {
            if !proxy.enabled {
                Image(systemName: "circle")
                    .foregroundStyle(.tertiary)
                    .accessibilityLabel("Disabled")
            } else if let health = proxy.health {
                Image(systemName: health.ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .foregroundStyle(health.ok ? Color.green : Color.orange)
                    .accessibilityLabel(health.ok ? "Last test passed" : "Last test failed")
            } else {
                Image(systemName: "questionmark.circle")
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Not tested")
            }
        }
        .font(.system(size: AppLayout.statusGlyphSize, weight: .semibold))
    }
}

/// The pass/fail/excluded line for a proxy row, with the optional
/// "· 2m ago" suffix. The menu bar panel and the pool window both use it so
/// the copy, color, and age formatting cannot diverge.
struct ProxyStatusText: View {
    var proxy: ProxyEntry
    var mode: ProxyMode
    var isTesting: Bool
    var showsAge = true
    var font: Font = .footnote

    var body: some View {
        HStack(spacing: 4) {
            Text(ProxyStatus.text(for: proxy, mode: mode, isTesting: isTesting))
                .monospacedDigit()
                .foregroundStyle(ProxyStatus.color(for: proxy, isTesting: isTesting))
            if showsAge, let age = ageSuffix {
                Text("· \(age)")
                    .foregroundStyle(.tertiary)
            }
        }
        .font(font)
        .lineLimit(1)
    }

    /// Row age suffix; hidden while a test run is rewriting results.
    private var ageSuffix: String? {
        guard !isTesting, proxy.enabled else { return nil }
        return ProxyStatus.checkedAgo(for: proxy)
    }
}
