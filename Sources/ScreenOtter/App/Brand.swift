import AppKit
import SwiftUI

/// ScreenOtter's identity: a sea otter keeps a favorite stone tucked under its arm, and this app keeps
/// the things you capture.
enum Brand {
    static let name = "ScreenOtter"
    static let tagline = "Keeps the things you capture, the way a sea otter keeps its favorite stone."

    /// The blue of the icon's sky.
    static let accent = Color(red: 0.31, green: 0.42, blue: 0.97)

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }

    /// The simplified otter head, as a template so it follows the menu bar's color.
    static let menuBarIcon: NSImage? = {
        guard let image = Bundle.main.image(forResource: "MenuBarIcon") else { return nil }
        image.isTemplate = true
        image.accessibilityDescription = name
        return image
    }()

    /// The full illustration: the otter floating with its captures.
    static let illustration: NSImage? = Bundle.main.url(forResource: "OtterHero", withExtension: "jpg").flatMap(NSImage.init(contentsOf:))
}

/// The app icon at any size.
struct AppIconImage: View {
    var size: CGFloat

    var body: some View {
        Image(nsImage: NSApp.applicationIconImage)
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}
