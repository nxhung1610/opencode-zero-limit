import AppKit
import Foundation
import SwiftUI
import Testing
@testable import RelayDockApp

@MainActor
struct MenuBarIconTests {
    @Test func appMarkIsATemplateWithStandardAndRetinaRepresentations() {
        let image = MenuBarIcon.image
        #expect(image.isTemplate)
        #expect(image.size == NSSize(width: 18, height: 16))
        #expect(image.accessibilityDescription == "RelayDock")
        let bitmaps = image.representations.compactMap { $0 as? NSBitmapImageRep }
        #expect(bitmaps.contains { $0.pixelsWide == 18 && $0.pixelsHigh == 16 })
        #expect(bitmaps.contains { $0.pixelsWide == 36 && $0.pixelsHigh == 32 })
        for bitmap in bitmaps {
            #expect(bitmap.hasAlpha)
            #expect(bitmap.colorAt(x: 0, y: 0)?.alphaComponent == 0)
            let opaquePixels = (0..<bitmap.pixelsHigh).reduce(0) { count, y in
                count + (0..<bitmap.pixelsWide).filter { (bitmap.colorAt(x: $0, y: y)?.alphaComponent ?? 0) > 0.5 }.count
            }
            #expect(opaquePixels > 0)
            #expect(opaquePixels < bitmap.pixelsWide * bitmap.pixelsHigh / 2)
        }
    }

    @Test func rendersTheMarkOnLightAndDarkMenuSurfaces() throws {
        _ = NSApplication.shared
        let output = ProcessInfo.processInfo.environment["RELAYDOCK_FIXTURE_DIR"].map { URL(fileURLWithPath: $0) }
        if let output { try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true) }
        for (scheme, appearance, slug) in [
            (ColorScheme.light, NSAppearance.Name.aqua, "light"),
            (ColorScheme.dark, NSAppearance.Name.darkAqua, "dark"),
        ] {
            let view = Image(nsImage: MenuBarIcon.image)
                .foregroundStyle(.primary)
                .padding(12)
                .background(.background)
                .environment(\.colorScheme, scheme)
            let host = NSHostingView(rootView: view)
            host.appearance = try #require(NSAppearance(named: appearance))
            host.frame = CGRect(origin: .zero, size: host.fittingSize)
            host.layoutSubtreeIfNeeded()
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            if let output {
                let png = try #require(bitmap.representation(using: .png, properties: [:]))
                try png.write(to: output.appending(path: "menu-bar-icon-\(slug).png"))
            }
        }
    }
}
