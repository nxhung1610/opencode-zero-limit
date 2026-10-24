import AppKit
import SwiftUI

/// The few semantic tokens still needed after moving the interface to native
/// macOS controls. Hierarchy and color come from the system; only status ink
/// and the one shared motion curve are app-specific.
enum AppTheme {
    /// The window and menu bar panel surface.
    static let windowBackground = Color(nsColor: .windowBackgroundColor)
    /// Full ink: failures and anything that needs a decision.
    static let ink = Color.primary
    /// Quiet ink: healthy states and supporting labels.
    static let inkMuted = Color.secondary

    enum Motion {
        /// Row status and counter changes.
        static let status = Animation.easeInOut(duration: 0.16)
    }
}
