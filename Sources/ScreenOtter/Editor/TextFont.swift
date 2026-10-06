import AppKit
import CoreText

/// The typefaces the text tool offers: three modern, open-licensed (SIL OFL) faces that each look
/// clearly different (neutral, friendly geometric, technical), bundled in `Resources/Fonts`, one weight
/// each. Semibold reads well on busy screenshots without shouting.
nonisolated enum TextFont: String, CaseIterable, Identifiable, Codable, Sendable {
    case geist, jakarta, geistMono

    var id: Self { self }

    var title: String {
        switch self {
        case .geist: "Geist"
        case .jakarta: "Jakarta"
        case .geistMono: "Mono"
        }
    }

    var postScriptName: String {
        switch self {
        case .geist: "Geist-SemiBold"
        case .jakarta: "PlusJakartaSans-SemiBold"
        case .geistMono: "GeistMono-SemiBold"
        }
    }

    /// The face at `size`. If the bundled file is missing (a test host, a broken bundle) this falls
    /// back to the system font at the same weight rather than CoreText's default Helvetica.
    func ctFont(size: CGFloat) -> CTFont {
        let font = CTFontCreateWithName(postScriptName as CFString, size, nil)
        if CTFontCopyPostScriptName(font) as String == postScriptName { return font }
        let fallback = self == .geistMono
            ? NSFont.monospacedSystemFont(ofSize: size, weight: .semibold)
            : NSFont.systemFont(ofSize: size, weight: .semibold)
        return fallback as CTFont
    }

    /// Registers every font file in `directory` for this process only, so the faces are usable by name
    /// without being installed system wide. Returns how many files were registered.
    @discardableResult
    static func registerFonts(in directory: URL) -> Int {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        var count = 0
        for url in files where ["ttf", "otf"].contains(url.pathExtension.lowercased()) {
            var error: Unmanaged<CFError>?
            if CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) {
                count += 1
            } else if let error = error?.takeRetainedValue(),
                      CFErrorGetCode(error) == CTFontManagerError.alreadyRegistered.rawValue {
                count += 1
            }
        }
        return count
    }

    /// Called once at launch: the fonts ship in `Contents/Resources/Fonts`.
    static func registerBundledFonts(in bundle: Bundle = .main) {
        guard let directory = bundle.resourceURL?.appendingPathComponent("Fonts") else { return }
        registerFonts(in: directory)
    }
}

/// How a text annotation sits on the screenshot.
nonisolated enum TextLabelStyle: String, CaseIterable, Identifiable, Codable, Sendable {
    /// Just the text, with a soft shadow so it stays legible on busy backgrounds.
    case plain
    /// Text on a solid plate of the color, in black or white, whichever contrasts.
    case filled
    /// A plate outlined in the color, with the text in the color on a neutral fill.
    case outlined

    var id: Self { self }

    var title: String {
        switch self {
        case .plain: "Plain"
        case .filled: "Label"
        case .outlined: "Outline"
        }
    }
}
