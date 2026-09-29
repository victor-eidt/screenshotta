import AppKit
import ImageIO
import UniformTypeIdentifiers

/// A file on a shelf. Shelves only reference files: they never move or copy them.
final class ShelfItem: ObservableObject, Identifiable {
    let id = UUID()
    let url: URL
    let isImage: Bool
    let byteCount: Int64?
    @Published private(set) var thumbnail: NSImage?
    @Published private(set) var pixelSize: CGSize?

    init(url: URL) {
        self.url = url
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentTypeKey])
        isImage = values?.contentType?.conforms(to: .image) ?? false
        byteCount = values?.fileSize.map(Int64.init)
        thumbnail = isImage ? nil : NSWorkspace.shared.icon(forFile: url.path)
        if isImage { loadImagePreview() }
    }

    var name: String { url.lastPathComponent }

    var exists: Bool { FileManager.default.fileExists(atPath: url.path) }

    /// "1.7 MB · 3548×2274"
    var detail: String {
        var parts: [String] = []
        if let byteCount { parts.append(ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file)) }
        if let pixelSize { parts.append("\(Int(pixelSize.width))×\(Int(pixelSize.height))") }
        return parts.joined(separator: " · ")
    }

    private func loadImagePreview() {
        let url = url
        Task {
            let preview = await Self.imagePreview(url)
            pixelSize = preview.pixelSize
            thumbnail = preview.image.map { NSImage(cgImage: $0, size: .zero) }
                ?? NSWorkspace.shared.icon(forFile: url.path)
        }
    }

    @concurrent
    private nonisolated static func imagePreview(_ url: URL) async -> (image: CGImage?, pixelSize: CGSize?) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return (nil, nil) }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        var pixelSize: CGSize?
        if let width = properties?[kCGImagePropertyPixelWidth] as? Int, let height = properties?[kCGImagePropertyPixelHeight] as? Int {
            pixelSize = CGSize(width: width, height: height)
        }
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 480,
        ] as CFDictionary
        return (CGImageSourceCreateThumbnailAtIndex(source, 0, options), pixelSize)
    }
}

/// A temporary holding place for files, shown in a floating panel.
final class Shelf: ObservableObject, Identifiable {
    let id: UUID
    let createdAt: Date
    @Published private(set) var items: [ShelfItem] = []
    @Published var selection: Set<ShelfItem.ID> = []

    /// Called after every change to the list of files, so the history stays current.
    var onChange: (() -> Void)?

    init(id: UUID = UUID(), createdAt: Date = Date(), urls: [URL] = []) {
        self.id = id
        self.createdAt = createdAt
        items = Self.unique(urls, excluding: []).map(ShelfItem.init)
    }

    var isEmpty: Bool { items.isEmpty }

    var title: String { Self.title(count: items.count, allImages: items.allSatisfy(\.isImage)) }

    var totalSize: String {
        let total = items.compactMap(\.byteCount).reduce(0, +)
        return ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
    }

    var selectedItems: [ShelfItem] { items.filter { selection.contains($0.id) } }

    func add(_ urls: [URL]) {
        let fresh = Self.unique(urls, excluding: Set(items.map(\.url.standardizedFileURL)))
        guard !fresh.isEmpty else { return }
        items.append(contentsOf: fresh.map(ShelfItem.init))
        onChange?()
    }

    func remove(_ ids: Set<ShelfItem.ID>) {
        guard !ids.isEmpty else { return }
        items.removeAll { ids.contains($0.id) }
        selection.subtract(ids)
        onChange?()
    }

    /// Drops files that were moved or deleted elsewhere (or dragged to the Trash).
    func removeMissing() {
        remove(Set(items.filter { !$0.exists }.map(\.id)))
    }

    // MARK: - Selection (Finder icon view rules; Shift and Command both toggle)

    func mouseDown(on item: ShelfItem, modifiers: NSEvent.ModifierFlags) {
        if modifiers.contains(.shift) || modifiers.contains(.command) {
            if selection.contains(item.id) { selection.remove(item.id) } else { selection.insert(item.id) }
        } else if !selection.contains(item.id) {
            selection = [item.id]
        }
    }

    /// A plain click that didn't turn into a drag narrows a multiple selection to that item.
    func clicked(_ item: ShelfItem, modifiers: NSEvent.ModifierFlags) {
        guard !modifiers.contains(.shift), !modifiers.contains(.command) else { return }
        selection = [item.id]
    }

    /// What a drag starting on `item` carries: the selection if the item is part of it.
    func dragItems(startingAt item: ShelfItem) -> [ShelfItem] {
        selection.contains(item.id) ? selectedItems : [item]
    }

    func selectAll() {
        selection = Set(items.map(\.id))
    }

    // MARK: - Helpers

    static func title(count: Int, allImages: Bool) -> String {
        let noun = allImages ? (count == 1 ? "Image" : "Images") : (count == 1 ? "File" : "Files")
        return "\(count) \(noun)"
    }

    private static func unique(_ urls: [URL], excluding existing: Set<URL>) -> [URL] {
        var seen = existing
        return urls.filter { seen.insert($0.standardizedFileURL).inserted }
    }
}

/// A shelf as stored in the history.
struct ShelfRecord: Codable, Identifiable {
    let id: UUID
    let createdAt: Date
    var updatedAt: Date
    var paths: [String]

    var urls: [URL] { paths.map { URL(fileURLWithPath: $0) } }

    var title: String {
        Shelf.title(count: paths.count, allImages: urls.allSatisfy { UTType(filenameExtension: $0.pathExtension)?.conforms(to: .image) ?? false })
    }
}
