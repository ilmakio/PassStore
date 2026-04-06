import AppKit
import SwiftUI

// MARK: - Data Model

struct SidebarReorderItem {
    let id: String
    let title: String
    let systemImage: String
    let tintColor: NSColor

    init(id: String, title: String, systemImage: String, tintColor: NSColor = .controlAccentColor) {
        self.id = id
        self.title = title
        self.systemImage = systemImage
        self.tintColor = tintColor
    }
}

// MARK: - NSViewRepresentable

/// An AppKit-backed list with native drag-to-reorder (works from anywhere on the row, like Finder).
struct ReorderableRows: NSViewRepresentable {

    static let rowHeight: CGFloat = 21
    private static let pasteType = NSPasteboard.PasteboardType("app.passstore.sidebar-reorder")

    let items: [SidebarReorderItem]
    /// The id of the currently selected item, or nil for no selection.
    let selectedID: String?
    /// When true, clicking a selected row deselects it (used for Types toggle).
    var allowsDeselection: Bool = false
    /// When false, drag-to-reorder is disabled (used for non-reorderable sections).
    var reorderable: Bool = true
    /// Called with the selected item id, or nil when deselected.
    let onSelect: (String?) -> Void
    /// Called with the new ordered list of ids after a drag-and-drop reorder. No-op by default.
    var onReorder: ([String]) -> Void = { _ in }

    func makeNSView(context: Context) -> NSTableView {
        let table = NSTableView()
        table.headerView = nil
        table.backgroundColor = .clear
        table.gridStyleMask = []
        table.selectionHighlightStyle = .none
        table.focusRingType = .none
        table.rowHeight = Self.rowHeight
        table.intercellSpacing = .zero
        table.usesAlternatingRowBackgroundColors = false
        table.allowsEmptySelection = true
        table.allowsMultipleSelection = false

        let col = NSTableColumn(identifier: .init("col"))
        col.isEditable = false
        col.resizingMask = .autoresizingMask
        table.addTableColumn(col)
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle

        if context.coordinator.reorderable {
            table.registerForDraggedTypes([Self.pasteType])
            table.setDraggingSourceOperationMask(.move, forLocal: true)
        }

        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        context.coordinator.tableView = table

        return table
    }

    func updateNSView(_ table: NSTableView, context: Context) {
        let c = context.coordinator
        c.items = items
        c.selectedID = selectedID
        c.allowsDeselection = allowsDeselection
        c.onSelect = onSelect
        c.onReorder = onReorder

        table.reloadData()

        // Sync selection from SwiftUI state without triggering the callback.
        c.isUpdating = true
        defer { c.isUpdating = false }
        if let sid = selectedID, let idx = items.firstIndex(where: { $0.id == sid }) {
            if table.selectedRow != idx {
                table.selectRowIndexes(IndexSet(integer: idx), byExtendingSelection: false)
            }
        } else if table.selectedRow >= 0 {
            table.deselectAll(nil)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(items: items, selectedID: selectedID, allowsDeselection: allowsDeselection,
                    reorderable: reorderable, onSelect: onSelect, onReorder: onReorder)
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var items: [SidebarReorderItem]
        var selectedID: String?
        var allowsDeselection: Bool
        var reorderable: Bool
        var onSelect: (String?) -> Void
        var onReorder: ([String]) -> Void
        var isUpdating = false
        weak var tableView: NSTableView?

        init(items: [SidebarReorderItem], selectedID: String?, allowsDeselection: Bool,
             reorderable: Bool, onSelect: @escaping (String?) -> Void, onReorder: @escaping ([String]) -> Void) {
            self.items = items
            self.selectedID = selectedID
            self.allowsDeselection = allowsDeselection
            self.reorderable = reorderable
            self.onSelect = onSelect
            self.onReorder = onReorder
        }

        func numberOfRows(in tableView: NSTableView) -> Int { items.count }

        // MARK: Drag source — enables drag from any point on the row

        func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
            let pb = NSPasteboardItem()
            pb.setString(items[row].id, forType: ReorderableRows.pasteType)
            return pb
        }

        // MARK: Drag destination

        func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo,
                       proposedRow row: Int, proposedDropOperation op: NSTableView.DropOperation) -> NSDragOperation {
            tableView.setDropRow(row, dropOperation: .above)
            return .move
        }

        func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo,
                       row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
            guard let srcID = info.draggingPasteboard.string(forType: ReorderableRows.pasteType),
                  let fromIndex = items.firstIndex(where: { $0.id == srcID }) else { return false }
            var ids = items.map(\.id)
            ids.move(fromOffsets: IndexSet(integer: fromIndex), toOffset: row)
            onReorder(ids)
            return true
        }

        // MARK: Cell views

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            let item = items[row]
            let cell = SidebarCell()
            cell.configure(with: item, isSelected: item.id == selectedID)
            return cell
        }

        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            ClearRowView()
        }

        // MARK: Selection

        func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
            if allowsDeselection && tableView.selectedRow == row {
                DispatchQueue.main.async { [weak self, weak tableView] in
                    tableView?.deselectAll(nil)
                    self?.onSelect(nil)
                }
                return false
            }
            return true
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !isUpdating, let tv = notification.object as? NSTableView else { return }
            let row = tv.selectedRow
            if row >= 0 && row < items.count {
                onSelect(items[row].id)
            }
        }
    }
}

// MARK: - Cell View

private final class SidebarCell: NSView {
    private let bg = NSView()
    private let imageView = NSImageView()
    private let label = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        bg.wantsLayer = true
        bg.layer?.cornerRadius = 6
        bg.translatesAutoresizingMaskIntoConstraints = false
        addSubview(bg)

        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.imageScaling = .scaleProportionallyDown
        addSubview(imageView)

        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 13)
        label.lineBreakMode = .byTruncatingTail
        addSubview(label)

        NSLayoutConstraint.activate([
            bg.leadingAnchor.constraint(equalTo: leadingAnchor),
            bg.trailingAnchor.constraint(equalTo: trailingAnchor),
            bg.topAnchor.constraint(equalTo: topAnchor, constant: 1),
            bg.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1),

            imageView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            imageView.centerYAnchor.constraint(equalTo: centerYAnchor),
            imageView.widthAnchor.constraint(equalToConstant: 15),
            imageView.heightAnchor.constraint(equalToConstant: 15),

            label.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(with item: SidebarReorderItem, isSelected: Bool) {
        label.stringValue = item.title
        label.textColor = isSelected ? item.tintColor : .secondaryLabelColor
        label.font = .systemFont(ofSize: 11)
        imageView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular, scale: .small)
        imageView.image = NSImage(systemSymbolName: item.systemImage, accessibilityDescription: item.title)
        imageView.contentTintColor = isSelected ? item.tintColor : .tertiaryLabelColor
        bg.layer?.backgroundColor = isSelected
            ? item.tintColor.withAlphaComponent(0.15).cgColor
            : .clear
    }
}

// MARK: - Row View (no default selection highlight)

private final class ClearRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {}
}

// MARK: - NSColor hex helper

extension NSColor {
    convenience init(hex: String) {
        let s = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var v: UInt64 = 0
        Scanner(string: s).scanHexInt64(&v)
        let r, g, b: CGFloat
        if s.count == 6 {
            r = CGFloat((v >> 16) & 0xFF) / 255
            g = CGFloat((v >> 8)  & 0xFF) / 255
            b = CGFloat(v         & 0xFF) / 255
        } else {
            r = 74/255; g = 122/255; b = 1
        }
        self.init(srgbRed: r, green: g, blue: b, alpha: 1)
    }
}
