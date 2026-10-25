import RelayDockCore
import SwiftUI

/// The Routing page's RelayDock Edge status: live daemon state, the upstream
/// Edge is serving, counters, and service attribution for recent tunnels.
/// Everything here comes from `/__relaydock/status` — Edge's own accounting
/// is the only traffic the app can honestly speak to.
enum EdgePanelState: Equatable {
    case unknown
    case notConfigured
    case notRunning
    case running(EdgeStatusResponse)
}

/// Which checker the last Test All used.
enum CheckRoute: Equatable {
    case edge
    case inApp
}

/// One peer process's Edge usage, aggregated from the status tunnels.
struct EdgeAttribution: Identifiable, Equatable {
    var id: String
    var name: String
    var pid: Int32?
    var tunnels: Int
    var activeTunnels: Int
    var bytesDown: Int
    var lastActivity: Double
}

enum OpenCodeTrafficEvidence: Equatable {
    case routingOff
    case notObserved
    case observed(lastSeen: Double)

    static func resolve(from status: EdgeStatusResponse) -> Self {
        guard status.mode != .off else { return .routingOff }

        let lastSeen = status.tunnels.compactMap { tunnel -> Double? in
            guard tunnel.peerName?.localizedCaseInsensitiveContains("opencode") == true,
                  let label = tunnel.label,
                  label != "direct (fallback)" else { return nil }
            return tunnel.endedAt ?? tunnel.startedAt
        }.max()

        guard let lastSeen else { return .notObserved }
        return .observed(lastSeen: lastSeen)
    }
}

/// Live Edge status as its own observable. The 3-second poll then invalidates
/// only the rows that show it: republishing through `ProxyAppModel` rebuilt the
/// whole window — sidebar, split view, and Routing form — on every tick, which
/// is what made expanding the sidebar hitch.
@MainActor
final class EdgePanelModel: ObservableObject {
    @Published private(set) var panel: EdgePanelState = .unknown

    /// Polls repeat an unchanged panel constantly, so an idle app stays idle by
    /// skipping the publish when nothing moved.
    func apply(_ next: EdgePanelState) {
        guard next != panel else { return }
        panel = next
    }

    /// Recent tunnels grouped by client process — the panel's "who used Edge"
    /// list. Processes with active tunnels sort first, then by last activity.
    var edgeAttribution: [EdgeAttribution] {
        guard case .running(let status) = panel else { return [] }
        var byKey: [String: EdgeAttribution] = [:]
        for tunnel in status.tunnels {
            let key = tunnel.peerPid.map(String.init) ?? "unknown"
            var summary = byKey[key] ?? EdgeAttribution(
                id: key,
                name: tunnel.peerName ?? "Unknown process",
                pid: tunnel.peerPid,
                tunnels: 0,
                activeTunnels: 0,
                bytesDown: 0,
                lastActivity: tunnel.startedAt
            )
            summary.tunnels += 1
            if tunnel.active { summary.activeTunnels += 1 }
            summary.bytesDown += tunnel.bytesDown
            summary.lastActivity = max(summary.lastActivity, tunnel.endedAt ?? tunnel.startedAt)
            byKey[key] = summary
        }
        return byKey.values.sorted { lhs, rhs in
            if (lhs.activeTunnels > 0) != (rhs.activeTunnels > 0) {
                return lhs.activeTunnels > 0
            }
            return lhs.lastActivity > rhs.lastActivity
        }
    }
}

struct EdgePanelView: View {
    @ObservedObject var edgeStatus: EdgePanelModel
    /// The Routing page already explains unverified traffic above this panel,
    /// so the panel does not repeat it.
    var hasOpenCodeRoutingNotice: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            switch edgeStatus.panel {
            case .unknown:
                Text("Checking…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            case .notConfigured:
                caption("RelayDock Edge is not installed. Use the routing setup above to install it.")
            case .notRunning:
                caption("RelayDock Edge is not running. It starts on demand at the next wrapped launch.")
            case .running(let status):
                runningDetail(status)
                    .help("From Edge's own tunnel accounting.")
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(color)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                if let subtitle {
                    Text(subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var symbol: String {
        switch edgeStatus.panel {
        case .unknown: "circle.dotted"
        case .notConfigured: "questionmark.circle"
        case .notRunning: "moon.zzz"
        case .running: "bolt.horizontal.circle"
        }
    }

    private var color: Color {
        switch edgeStatus.panel {
        case .running: Color.secondary
        case .notConfigured: Color.primary
        case .unknown, .notRunning: .secondary
        }
    }

    private var title: String {
        switch edgeStatus.panel {
        case .unknown: "RelayDock Edge"
        case .notConfigured: "RelayDock Edge is not configured"
        case .notRunning: "RelayDock Edge is not running"
        case .running(let status): "RelayDock Edge · running (pid \(status.pid))"
        }
    }

    private var subtitle: String? {
        guard case .running(let status) = edgeStatus.panel else { return nil }
        return "Up \(relativeTime(status.launchedAt)) · mode \(status.mode.rawValue.capitalized)"
    }

    // MARK: - Running detail

    @ViewBuilder
    private func runningDetail(_ status: EdgeStatusResponse) -> some View {
        if !hasOpenCodeRoutingNotice { trafficVerification(status) }
        if let upstream = status.upstream {
            LabeledContent("Upstream") {
                Text(upstreamLine(upstream))
            }
        } else {
            LabeledContent("Upstream") {
                Text(status.mode == .off ? "Direct — routing is off" : "None resolved yet")
            }
        }
        if let pendingReason = status.pendingReason {
            LabeledContent("Last decision") {
                Text(pendingReason)
            }
        }
        if let retryAt = status.throttleRetryAt {
            LabeledContent("Provider cooldown") {
                Text("Retrying \(relativeTime(retryAt))")
            }
        }
        LabeledContent("Activity") {
            Text(activityLine(status.counters))
        }
        if status.counters.dialFailures + status.counters.streamFailures > 0 {
            LabeledContent("Failures") {
                Text(failureLine(status.counters))
                    .foregroundStyle(.primary)
            }
        }
        if status.counters.directFallbacks > 0 {
            LabeledContent("Direct fallbacks") {
                Text("\(status.counters.directFallbacks) tunnel\(status.counters.directFallbacks == 1 ? "" : "s") connected directly")
                    .foregroundStyle(.primary)
            }
        }
        if let lastError = status.lastErrors.last {
            LabeledContent("Last error") {
                Text(lastError)
            }
        }
        attribution
    }

    @ViewBuilder
    private func trafficVerification(_ status: EdgeStatusResponse) -> some View {
        Group {
            switch OpenCodeTrafficEvidence.resolve(from: status) {
            case .routingOff:
                Label("Routing is Off; proxying is disabled.", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.primary)
            case .notObserved:
                Label(
                    "No OpenCode traffic observed through a proxy yet. Make a fresh model request to verify.",
                    systemImage: "questionmark.circle"
                )
                .foregroundStyle(.primary)
            case .observed(let lastSeen):
                if Date().timeIntervalSince1970 - lastSeen <= 300 {
                    Label(
                        "OpenCode traffic seen through a proxy \(relativeTime(lastSeen)).",
                        systemImage: "checkmark.circle.fill"
                    )
                    .foregroundStyle(.secondary)
                } else {
                    Label(
                        "Last OpenCode proxy tunnel \(relativeTime(lastSeen)); no recent traffic to verify.",
                        systemImage: "clock"
                    )
                    .foregroundStyle(.secondary)
                }
            }
        }
        .font(.callout)
        .fixedSize(horizontal: false, vertical: true)
        .help("This reflects only tunnels Edge served. Traffic that bypasses Edge cannot be observed here.")
    }

    private func upstreamLine(_ upstream: EdgeStatusResponse.Upstream) -> String {
        var parts = [upstream.label, upstream.source]
        if let expiry = upstream.expiresAt {
            parts.append("expires \(relativeTime(expiry))")
        }
        if upstream.strikes > 0 {
            parts.append("\(upstream.strikes) strike\(upstream.strikes == 1 ? "" : "s")")
        }
        return parts.joined(separator: " · ")
    }

    private func activityLine(_ counters: EdgeStatusResponse.Counters) -> String {
        [
            "\(counters.tunnelsActive) active",
            "\(counters.tunnelsTotal) total tunnels",
            "\(counters.resolutions) resolutions",
            "\(counters.switches) switches",
        ].joined(separator: " · ")
    }

    private func failureLine(_ counters: EdgeStatusResponse.Counters) -> String {
        "\(counters.dialFailures) dial · \(counters.streamFailures) stream"
    }

    @ViewBuilder
    private var attribution: some View {
        let peers = edgeStatus.edgeAttribution
        if !peers.isEmpty {
            DisclosureGroup("Recent tunnels") {
                ForEach(peers.prefix(8)) { peer in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(peerLine(peer))
                        Spacer(minLength: 8)
                        Text(relativeTime(peer.lastActivity))
                            .foregroundStyle(.secondary)
                    }
                    .font(.callout)
                }
            }
            .font(.callout)
        }
    }

    private func peerLine(_ peer: EdgeAttribution) -> String {
        var name = peer.name
        if let pid = peer.pid {
            name += " (pid \(pid))"
        }
        var usage = ["\(peer.tunnels) tunnel\(peer.tunnels == 1 ? "" : "s")"]
        if peer.activeTunnels > 0 {
            usage.append("\(peer.activeTunnels) active")
        }
        if peer.bytesDown > 0 {
            usage.append("\(Int64(peer.bytesDown).formatted(.byteCount(style: .file))) down")
        }
        return "\(name) — \(usage.joined(separator: " · "))"
    }

    // MARK: - Helpers

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
    }

    private func relativeTime(_ timestamp: Double) -> String {
        Date(timeIntervalSince1970: timestamp)
            .formatted(.relative(presentation: .named, unitsStyle: .abbreviated))
    }
}
