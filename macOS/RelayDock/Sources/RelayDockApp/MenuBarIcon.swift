import AppKit
import Foundation

/// The shipped app mark, cropped into a transparent macOS template. AppKit
/// supplies the menu bar's foreground color, including dark/highlighted states.
@MainActor
enum MenuBarIcon {
    static let size = NSSize(width: 18, height: 16)

    static let image: NSImage = {
        // Packaged apps carry the SwiftPM resource bundle in Contents/Resources.
        // SwiftPM command-line builds/tests use Bundle.module instead.
        let resources = Bundle.main.url(forResource: "RelayDock_RelayDockApp", withExtension: "bundle")
            .flatMap { Bundle(url: $0) } ?? Bundle.module
        let image = NSImage(size: size)
        for name in ["MenuBarIconTemplate", "MenuBarIconTemplate@2x"] {
            guard let url = resources.url(forResource: name, withExtension: "png"),
                  let data = try? Data(contentsOf: url),
                  let representation = NSBitmapImageRep(data: data) else { continue }
            representation.size = size
            image.addRepresentation(representation)
        }
        image.isTemplate = true
        image.accessibilityDescription = "RelayDock"
        return image
    }()
}
