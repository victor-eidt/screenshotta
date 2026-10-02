import SwiftUI

/// Live mock of a window capture with the current style settings.
struct WindowStylePreview: View {
    @ObservedObject var prefs: Preferences
    @State private var wallpaper: NSImage? = WindowStylePreview.loadWallpaper()

    /// Preview points per real point.
    private let k: CGFloat = 0.42

    var body: some View {
        mockWindow
            .padding(prefs.windowPadding * k)
            .frame(maxWidth: .infinity)
            .frame(height: 230)
            .background { background }
            .clipped()
        .animation(.snappy(duration: 0.2), value: prefs.windowPadding)
        .animation(.snappy(duration: 0.2), value: prefs.windowCornerRadius)
    }

    @ViewBuilder
    private var background: some View {
        if prefs.windowBackground == .wallpaper {
            if let wallpaper {
                Image(nsImage: wallpaper)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                LinearGradient(colors: [.indigo, .blue, .teal], startPoint: .topLeading, endPoint: .bottomTrailing)
            }
        } else {
            Checkerboard()
        }
    }

    private var mockWindow: some View {
        let shape = RoundedRectangle(cornerRadius: max(prefs.windowCornerRadius, 4) * k * 1.6, style: .continuous)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 5) {
                Circle().fill(Color(red: 1, green: 0.37, blue: 0.34))
                Circle().fill(Color(red: 1, green: 0.74, blue: 0.18))
                Circle().fill(Color(red: 0.16, green: 0.79, blue: 0.25))
            }
            .frame(height: 8)
            .padding(.horizontal, 10)
            .padding(.vertical, 9)

            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(0..<5) { i in
                        RoundedRectangle(cornerRadius: 2).fill(.primary.opacity(0.12)).frame(width: i == 0 ? 50 : 40, height: 6)
                    }
                }
                VStack(alignment: .leading, spacing: 7) {
                    RoundedRectangle(cornerRadius: 3).fill(.primary.opacity(0.18)).frame(width: 120, height: 9)
                    RoundedRectangle(cornerRadius: 6).fill(Brand.accent.opacity(0.25)).frame(height: 50)
                    RoundedRectangle(cornerRadius: 2).fill(.primary.opacity(0.1)).frame(height: 6)
                    RoundedRectangle(cornerRadius: 2).fill(.primary.opacity(0.1)).frame(width: 160, height: 6)
                }
            }
            .padding(.horizontal, 12)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor), in: shape)
        .overlay(shape.strokeBorder(.primary.opacity(0.12), lineWidth: 0.5))
        .shadow(color: .black.opacity(prefs.windowShadow ? 0.22 : 0), radius: 22 * k, y: 6 * k)
        .shadow(color: .black.opacity(prefs.windowShadow ? 0.18 : 0), radius: 1, y: 0.5)
    }

    private static func loadWallpaper() -> NSImage? {
        guard let screen = NSScreen.main, let url = NSWorkspace.shared.desktopImageURL(for: screen) else { return nil }
        return NSImage(contentsOf: url)
    }
}

private struct Checkerboard: View {
    var body: some View {
        Canvas { context, size in
            let cell: CGFloat = 10
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(white: 0.92)))
            for row in 0..<Int(size.height / cell) + 1 {
                for column in 0..<Int(size.width / cell) + 1 where (row + column).isMultiple(of: 2) {
                    let rect = CGRect(x: CGFloat(column) * cell, y: CGFloat(row) * cell, width: cell, height: cell)
                    context.fill(Path(rect), with: .color(Color(white: 0.8)))
                }
            }
        }
    }
}
