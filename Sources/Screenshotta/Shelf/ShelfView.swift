import SwiftUI

enum ShelfLayout: String {
    case grid, list
}

struct ShelfView: View {
    @ObservedObject var shelf: Shelf
    @ObservedObject var controller: ShelfController
    @State private var isTargeted = false

    var body: some View {
        ZStack {
            WindowDragArea { shelf.selection = [] }
            if controller.isExpanded {
                ShelfBrowser(shelf: shelf, controller: controller)
                    .transition(.opacity)
            } else {
                ShelfStackView(shelf: shelf, controller: controller)
                    .transition(.opacity)
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: ShelfController.cornerRadius, style: .continuous)
                .strokeBorder(Color.accentColor, lineWidth: 3)
                .opacity(isTargeted ? 1 : 0)
                .allowsHitTesting(false)
        }
        .onDrop(of: [.fileURL, .image], isTargeted: $isTargeted) { controller.accept($0) }
        .onChange(of: shelf.isEmpty) { _, isEmpty in
            if isEmpty { controller.setExpanded(false) }
        }
        .animation(.snappy(duration: 0.2), value: isTargeted)
        .animation(.snappy(duration: 0.25), value: shelf.items.map(\.id))
    }
}

// MARK: - Collapsed: a stack of previews

private struct ShelfStackView: View {
    @ObservedObject var shelf: Shelf
    let controller: ShelfController

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Capsule()
                    .fill(.white.opacity(0.3))
                    .frame(width: 34, height: 5)
                    .allowsHitTesting(false)
                HStack {
                    GlassIconButton(symbol: "xmark", help: "Close Shelf") { controller.close() }
                    Spacer()
                    GlassIconButton(symbol: "chevron.down", help: "More") { controller.showShelfMenu() }
                }
            }
            .padding([.horizontal, .top], 10)

            Spacer(minLength: 0)
            if shelf.isEmpty {
                DropHint()
            } else {
                StackPreview(items: Array(shelf.items.suffix(3)))
                    .overlay {
                        FileDragArea(
                            items: { shelf.items },
                            onClick: { _ in controller.setExpanded(true) },
                            onDragEnded: controller.dragEnded
                        )
                    }
                    .help("Drag to move all files, click to see them")
            }
            Spacer(minLength: 0)

            if !shelf.isEmpty {
                Button { controller.setExpanded(true) } label: {
                    HStack(spacing: 5) {
                        Text(shelf.title)
                            .font(.system(size: 12, weight: .semibold))
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 13)
                    .frame(height: 28)
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .glass(in: Capsule())
                .padding(.bottom, 12)
            }
        }
    }
}

private struct StackPreview: View {
    /// Oldest first; the last one is drawn on top.
    let items: [ShelfItem]

    private let angles: [Double] = [0, -7, 6]
    private let offsets: [CGSize] = [.zero, CGSize(width: -9, height: -4), CGSize(width: 9, height: -6)]

    var body: some View {
        ZStack {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                let depth = items.count - 1 - index
                ShelfThumbnail(item: item, maxSize: CGSize(width: 112, height: 92))
                    .scaleEffect(1 - 0.06 * Double(depth))
                    .rotationEffect(.degrees(angles[depth]))
                    .offset(offsets[depth])
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
            }
        }
        .frame(width: 144, height: 112)
    }
}

private struct DropHint: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "tray.and.arrow.down")
                .font(.system(size: 26, weight: .light))
            Text("Drop files here")
                .font(.system(size: 11, weight: .medium))
        }
        .foregroundStyle(.secondary)
        .frame(width: 136, height: 104)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.white.opacity(0.22), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Expanded: every file, grid or list

private struct ShelfBrowser: View {
    @ObservedObject var shelf: Shelf
    let controller: ShelfController
    @AppStorage("shelfLayout") private var layout: ShelfLayout = .grid

    private var allSelected: Bool { !shelf.isEmpty && shelf.selection.count == shelf.items.count }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                Group {
                    if layout == .grid { grid } else { list }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 14)
            }
            .scrollIndicators(.never)
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            GlassIconButton(symbol: "chevron.left", help: "Back") { controller.setExpanded(false) }
            VStack(alignment: .leading, spacing: 1) {
                Text(shelf.title)
                    .font(.system(size: 14, weight: .semibold))
                Text(shelf.totalSize)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .allowsHitTesting(false)
            Spacer()
            GlassIconButton(symbol: allSelected ? "checklist.checked" : "checklist", help: allSelected ? "Deselect All" : "Select All") {
                if allSelected { shelf.selection = [] } else { shelf.selectAll() }
            }
            HStack(spacing: 0) {
                layoutButton(.grid, symbol: "square.grid.2x2")
                layoutButton(.list, symbol: "list.bullet")
            }
            .padding(2)
            .glass(in: Capsule())
        }
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }

    private func layoutButton(_ value: ShelfLayout, symbol: String) -> some View {
        Button { layout = value } label: {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 28, height: 24)
                .background(Capsule().fill(.white.opacity(layout == value ? 0.18 : 0)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(value == .grid ? "Icons" : "List")
    }

    private var grid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 104, maximum: 150), spacing: 6)], spacing: 6) {
            ForEach(shelf.items) { item in
                GridTile(item: item, isSelected: shelf.selection.contains(item.id))
                    .overlay { dragArea(for: item) }
            }
            RevealTile { controller.reveal(shelf.items) }
        }
    }

    private var list: some View {
        LazyVStack(spacing: 2) {
            ForEach(shelf.items) { item in
                ListRow(item: item, isSelected: shelf.selection.contains(item.id))
                    .overlay { dragArea(for: item) }
            }
        }
    }

    private func dragArea(for item: ShelfItem) -> FileDragArea {
        FileDragArea(
            items: { shelf.dragItems(startingAt: item) },
            onMouseDown: { shelf.mouseDown(on: item, modifiers: $0) },
            onClick: { shelf.clicked(item, modifiers: $0) },
            onDoubleClick: { controller.open([item]) },
            menu: { controller.itemMenu() },
            onDragEnded: controller.dragEnded
        )
    }
}

private struct GridTile: View {
    @ObservedObject var item: ShelfItem
    let isSelected: Bool

    var body: some View {
        VStack(spacing: 6) {
            ShelfThumbnail(item: item, maxSize: CGSize(width: 88, height: 70))
                .frame(height: 74)
            VStack(spacing: 1) {
                Text(item.name)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(item.detail)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(SelectionBackground(isSelected: isSelected))
    }
}

private struct ListRow: View {
    @ObservedObject var item: ShelfItem
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 10) {
            ShelfThumbnail(item: item, maxSize: CGSize(width: 40, height: 30))
                .frame(width: 44, height: 32)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.name)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(item.detail)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(SelectionBackground(isSelected: isSelected))
    }
}

private struct SelectionBackground: View {
    let isSelected: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Color.accentColor.opacity(isSelected ? 0.4 : 0))
    }
}

private struct RevealTile: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: "arrowshape.turn.up.right.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 52, height: 52)
                    .glass(in: Circle())
                    .frame(height: 74)
                Text("Reveal in Finder")
                    .font(.system(size: 11, weight: .medium))
                Text(" ").font(.system(size: 10))
            }
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Shared pieces

struct ShelfThumbnail: View {
    @ObservedObject var item: ShelfItem
    let maxSize: CGSize

    var body: some View {
        Group {
            if let image = item.thumbnail {
                if item.isImage {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .strokeBorder(.white.opacity(0.28), lineWidth: 0.5)
                        }
                        .shadow(color: .black.opacity(0.35), radius: 5, y: 2)
                } else {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                }
            } else {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(.white.opacity(0.08))
                    .aspectRatio(4 / 3, contentMode: .fit)
            }
        }
        .frame(maxWidth: maxSize.width, maxHeight: maxSize.height)
    }
}

private struct GlassIconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .bold))
                .frame(width: 30, height: 30)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glass(in: Circle())
        .help(help)
    }
}

private extension View {
    @ViewBuilder
    func glass(in shape: some Shape) -> some View {
        if #available(macOS 26, *) {
            glassEffect(.regular.interactive(), in: shape)
        } else {
            background(.white.opacity(0.12), in: shape)
        }
    }
}
