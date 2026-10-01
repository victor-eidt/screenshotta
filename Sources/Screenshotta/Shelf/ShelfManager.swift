import AppKit
import UniformTypeIdentifiers

/// Owns the open shelves and the history of recent ones.
final class ShelfManager {
    static let shared = ShelfManager()

    private(set) var openShelves: [ShelfController] = []
    /// Newest first.
    private(set) var history: [ShelfRecord] = []

    private let historyLimit = 20

    private static let supportFolder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Screenshotta", isDirectory: true)
    private let historyURL = ShelfManager.supportFolder.appendingPathComponent("Shelves.json")
    /// Where images dropped as raw data (not files) are written.
    static let droppedFilesFolder = supportFolder.appendingPathComponent("Dropped Files", isDirectory: true)

    private init() {
        loadHistory()
    }

    // MARK: - Shelves

    /// Opens an empty shelf, centered on `point` (the pointer, after a shake) or at the right edge of the screen.
    @discardableResult
    func newShelf(with urls: [URL] = [], centeredAt point: NSPoint? = nil) -> ShelfController {
        present(Shelf(urls: urls), centeredAt: point)
    }

    /// Adds files to the frontmost shelf, opening one if there is none.
    func add(_ urls: [URL]) {
        if let shelf = openShelves.last {
            shelf.shelf.add(urls)
            shelf.bringToFront()
        } else {
            newShelf(with: urls)
        }
    }

    func reopen(_ record: ShelfRecord) {
        if let open = openShelves.first(where: { $0.shelf.id == record.id }) {
            open.bringToFront()
            return
        }
        let urls = record.urls.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !urls.isEmpty else {
            forget(record.id)
            return
        }
        present(Shelf(id: record.id, createdAt: record.createdAt, urls: urls), centeredAt: nil)
    }

    func shelf(at point: NSPoint) -> ShelfController? {
        openShelves.last { $0.frame.contains(point) }
    }

    func closed(_ controller: ShelfController) {
        openShelves.removeAll { $0 === controller }
    }

    @discardableResult
    private func present(_ shelf: Shelf, centeredAt point: NSPoint?) -> ShelfController {
        let controller = ShelfController(shelf: shelf)
        shelf.onChange = { [weak self, weak shelf] in
            guard let self, let shelf else { return }
            self.record(shelf)
        }
        controller.show(centeredAt: point, cascadeIndex: openShelves.count)
        openShelves.append(controller)
        record(shelf)
        return controller
    }

    // MARK: - History

    private func record(_ shelf: Shelf) {
        guard !shelf.isEmpty else {
            forget(shelf.id)
            return
        }
        let paths = shelf.items.map(\.url.path)
        if let index = history.firstIndex(where: { $0.id == shelf.id }) {
            guard history[index].paths != paths else { return }
            var record = history.remove(at: index)
            record.paths = paths
            record.updatedAt = Date()
            history.insert(record, at: 0)
        } else {
            history.insert(ShelfRecord(id: shelf.id, createdAt: shelf.createdAt, updatedAt: Date(), paths: paths), at: 0)
        }
        history = Array(history.prefix(historyLimit))
        saveHistory()
    }

    private func forget(_ id: UUID) {
        guard history.contains(where: { $0.id == id }) else { return }
        history.removeAll { $0.id == id }
        saveHistory()
    }

    func clearHistory() {
        let openIDs = Set(openShelves.map(\.shelf.id))
        history.removeAll { !openIDs.contains($0.id) }
        saveHistory()
        // Dropped image data is only reachable through a shelf, so it goes with the history.
        let inUse = Set(openShelves.flatMap { $0.shelf.items.map(\.url.standardizedFileURL) })
        let files = (try? FileManager.default.contentsOfDirectory(at: Self.droppedFilesFolder, includingPropertiesForKeys: nil)) ?? []
        for file in files where !inUse.contains(file.standardizedFileURL) {
            try? FileManager.default.removeItem(at: file)
        }
    }

    private func loadHistory() {
        guard let data = try? Data(contentsOf: historyURL),
              let records = try? JSONDecoder().decode([ShelfRecord].self, from: data)
        else { return }
        // Files moved or deleted since then are dropped, and so are shelves left empty.
        history = records.compactMap { record in
            var record = record
            record.paths = record.paths.filter { FileManager.default.fileExists(atPath: $0) }
            return record.paths.isEmpty ? nil : record
        }
    }

    private func saveHistory() {
        do {
            try FileManager.default.createDirectory(at: historyURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(history).write(to: historyURL, options: .atomic)
        } catch {
            NSLog("Screenshotta: could not save shelf history: \(error)")
        }
    }

    // MARK: - Dropped data

    /// Keeps image data that arrived without a file (for example, an image dragged out of a browser).
    static func storeDroppedImage(_ data: Data) -> URL? {
        guard let image = NSBitmapImageRep(data: data),
              let png = image.representation(using: .png, properties: [:])
        else { return nil }
        let fm = FileManager.default
        try? fm.createDirectory(at: droppedFilesFolder, withIntermediateDirectories: true)
        var url = droppedFilesFolder.appendingPathComponent("Image").appendingPathExtension("png")
        var counter = 2
        while fm.fileExists(atPath: url.path) {
            url = droppedFilesFolder.appendingPathComponent("Image \(counter)").appendingPathExtension("png")
            counter += 1
        }
        return (try? png.write(to: url)) != nil ? url : nil
    }
}
