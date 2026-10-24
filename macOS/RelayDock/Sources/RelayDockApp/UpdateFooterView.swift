import AppKit
import RelayDockCore
import SwiftUI

/// The footer row on the panel and window: the running version on the left,
/// and — on the right — whatever the updater currently needs from the user.
/// Always visible in the menu bar panel; in the window it appears only when
/// there is news.
struct UpdateFooterView: View {
    @ObservedObject var updates: UpdateModel
    var showsWhenIdle = true
    var showsVersion = true
    /// The window banner already carries the phase title and detail, so its
    /// controls drop the duplicate description.
    var showsPhaseDescription = true

    var body: some View {
        if showsWhenIdle || updates.phase != .idle {
            if showsVersion {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(updates.versionDisplayText)
                        .font(.caption.monospaced())
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                    Spacer(minLength: 8)
                    controls
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                controls
            }
        }
    }

    @ViewBuilder
    private var controls: some View {
        switch updates.phase {
        case .idle:
            Button("Check for Updates") {
                Task { await updates.check(userInitiated: true) }
            }
            .appAction(.link, size: .small)

        case .checking:
            busyLabel("Checking…")

        case .upToDate:
            Text("Up to Date")
                .font(.caption)
                .foregroundStyle(.secondary)

        case .available(let release):
            HStack(spacing: 10) {
                Button("Release Notes") {
                    NSWorkspace.shared.open(release.releasePageURL)
                }
                .appAction(.link, size: .small)
                Button("Update to \(release.version)") {
                    Task { await updates.update() }
                }
                .appAction(.primary, size: .regular)
            }

        case .downloading(let release):
            if showsPhaseDescription {
                busyLabel("Downloading \(release.version)…")
            } else {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Downloading version \(release.version)")
            }

        case .ready:
            Button("Restart to Update") {
                updates.restartToUpdate()
            }
            .appAction(.primary, size: .regular)

        case .failed(let message):
            VStack(alignment: .leading, spacing: 4) {
                if showsPhaseDescription {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button("Check for Updates") {
                    Task { await updates.check(userInitiated: true) }
                }
                .appAction(.link, size: .small)
            }
        }
    }

    private func busyLabel(_ text: String) -> some View {
        HStack(spacing: 5) {
            ProgressView()
                .controlSize(.small)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
