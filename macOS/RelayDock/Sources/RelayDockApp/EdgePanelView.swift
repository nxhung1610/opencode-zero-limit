import RelayDockCore
import SwiftUI

/// The Routing tab's RelayDock Edge status: live daemon state, the upstream
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

struct EdgePanelView: View {
    @ObservedObject var model: ProxyAppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            switch model.edgePanel {
            case .unknown:
                Text("Checking…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .notConfigured:
                caption("RelayDock Edge is not installed. Run scripts/opencode-wrapper.sh install to set it up.")
            case .notRunning:
                caption("RelayDock Edge is not running. It starts on demand at the next wrapped launch.")
            case .running(let status):
                runningDetail(status)
                caption("From Edge's own tunnel accounting.")
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(color)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.callout.weight(.semibold))
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var symbol: String {
        switch model.edgePanel {
        case .unknown: "circle.dotted"
        case .notConfigured: "questionmark.circle"
        case .notRunning: "moon.zzz"
        case .running: "bolt.horizontal.circle"
        }
    }

    private var color: Color {
        switch model.edgePanel {
        case .running: .green
        case .notConfigured: .orange
        case .unknown, .notRunning: .secondary
        }
    }

    private var title: String {
        switch model.edgePanel {
        case .unknown: "RelayDock Edge"
        case .notConfigured: "RelayDock Edge is not configured"
        case .notRunning: "RelayDock Edge is not running"
        case .running(let status): "RelayDock Edge · running (pid \(status.pid))"
        }
    }

    private var subtitle: String? {
        guard case .running(let status) = model.edgePanel else { return nil }
        return "Up \(relativeTime(status.launchedAt)) · mode \(status.mode.rawValue.capitalized)"
    }

    // MARK: - Running detail

    @ViewBuilder
    private func runningDetail(_ status: EdgeStatusResponse) -> some View {
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
        LabeledContent("Traffic") {
            Text("\(status.counters.tunnelsActive) active · \(status.counters.tunnelsTotal) total tunnels")
        }
        LabeledContent("Rotation") {
            Text("\(status.counters.resolutions) resolutions · \(status.counters.switches) switches")
        }
        LabeledContent("Failures") {
            Text("\(status.counters.dialFailures) dial · \(status.counters.streamFailures) stream")
        }
        if let lastError = status.lastErrors.last {
            LabeledContent("Last error") {
                Text(lastError)
            }
        }
        attribution
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

    @ViewBuilder
    private var attribution: some View {
        let peers = model.edgeAttribution
        if !peers.isEmpty {
            DisclosureGroup("Recent tunnels") {
                ForEach(peers.prefix(8)) { peer in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(peerLine(peer))
                        Spacer(minLength: 8)
                        Text(relativeTime(peer.lastActivity))
                            .foregroundStyle(.secondary)
                    }
                    .font(.caption)
                }
            }
            .font(.caption)
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
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private func relativeTime(_ timestamp: Double) -> String {
        Date(timeIntervalSince1970: timestamp)
            .formatted(.relative(presentation: .named, unitsStyle: .abbreviated))
    }
}
