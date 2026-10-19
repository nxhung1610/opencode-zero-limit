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

    var body: some View {
        if showsWhenIdle || updates.phase != .idle {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(updates.versionDisplayText)
                    .font(.footnote)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                controls
            }
            .frame(maxWidth: .infinity, alignment: .leading)
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
                .font(.footnote)
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
                .appAction(.secondary, size: .regular)
            }

        case .downloading(let release):
            busyLabel("Downloading \(release.version)…")

        case .ready:
            Button("Restart to Update") {
                updates.restartToUpdate()
            }
            .appAction(.primary, size: .regular)

        case .failed(let message):
            VStack(alignment: .trailing, spacing: 4) {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.trailing)
                    .fixedSize(horizontal: false, vertical: true)
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
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}
