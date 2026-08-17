import AppKit
import SwiftUI

// MARK: - Data Model

struct SidebarReorderItem {
    let id: String
    let title: String
    let systemImage: String
    let tintColor: NSColor
    /// Trailing count shown right-aligned in the row; nil hides it.
    let badge: String?
    let accessibilityIdentifier: String?
    /// 0 for a top-level row, 1 for a child. The list itself stays flat — children are ordinary
    /// rows drawn further in — so drag-to-reorder keeps working exactly as it did.
    let indentationLevel: Int
    /// Whether this row draws a disclosure triangle. Nil for rows that have nothing under them.
    let isExpanded: Bool?
    /// Rows a drag can pick up. Children are never draggable: only their parent has an order.
    let isDraggable: Bool
    /// Leaves room for a disclosure triangle whether or not this row has one.
    ///
    /// Set for every row of a list where *some* row can expand, so labels line up instead of
    /// shuffling sideways as workspaces gain and lose environments. Lists that never nest — the
    /// Library, Types, Tags — leave it off and keep their original alignment.
    let reservesDisclosureSpace: Bool
    /// Drawn dimmed, for an environment that has been switched off but still holds items.
    let isDimmed: Bool

    init(
        id: String,
        title: String,
        systemImage: String,
        tintColor: NSColor = .controlAccentColor,
        badge: String? = nil,
        accessibilityIdentifier: String? = nil,
        indentationLevel: Int = 0,
        isExpanded: Bool? = nil,
        isDraggable: Bool = true,
        isDimmed: Bool = false,
        reservesDisclosureSpace: Bool = false
    ) {
        self.id = id
        self.title = title
        self.systemImage = systemImage
        self.tintColor = tintColor
        self.badge = badge
        self.accessibilityIdentifier = accessibilityIdentifier
        self.indentationLevel = indentationLevel
        self.isExpanded = isExpanded
        self.isDraggable = isDraggable
        self.isDimmed = isDimmed
        self.reservesDisclosureSpace = reservesDisclosureSpace
    }
}

/// One entry in a sidebar row's right-click menu.
struct SidebarRowAction {
    let title: String
    let isDestructive: Bool
    let handler: () -> Void

    init(title: String, isDestructive: Bool = false, handler: @escaping () -> Void) {
        self.title = title
        self.isDestructive = isDestructive
        self.handler = handler
    }
}

// MARK: - NSViewRepresentable

/// An AppKit-backed list with native drag-to-reorder (works from anywhere on the row, like Finder).
struct ReorderableRows: NSViewRepresentable {

    /// Roughly a standard macOS sidebar row. Was 21pt, which crammed the rows together at a
    /// density no other Mac app uses.
    static let rowHeight: CGFloat = 26
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
    /// Called with the new ordered list of ids after a drag-and-drop reorder. Children are left
    /// out: only top-level rows carry an order. No-op by default.
    var onReorder: ([String]) -> Void = { _ in }
    /// Right-click menu entries for the row with the given id. Returning `[]` shows no menu.
    var contextActions: (String) -> [SidebarRowAction] = { _ in [] }
    /// Called when a disclosure triangle is clicked. Toggling never changes the selection.
    var onToggleExpansion: (String) -> Void = { _ in }

    func makeNSView(context: Context) -> NSTableView {
        let table = SidebarTableView()
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
        table.menuProvider = { [weak coordinator = context.coordinator] row in
            coordinator?.menu(forRow: row)
        }
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
        c.contextActions = contextActions
        c.onToggleExpansion = onToggleExpansion

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
                    reorderable: reorderable, onSelect: onSelect, onReorder: onReorder,
                    contextActions: contextActions, onToggleExpansion: onToggleExpansion)
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var items: [SidebarReorderItem]
        var selectedID: String?
        var allowsDeselection: Bool
        var reorderable: Bool
        var onSelect: (String?) -> Void
        var onReorder: ([String]) -> Void
        var contextActions: (String) -> [SidebarRowAction]
        var onToggleExpansion: (String) -> Void
        var isUpdating = false
        weak var tableView: NSTableView?

        /// Actions backing the menu currently on screen; `NSMenuItem.tag` indexes into this.
        private var visibleContextActions: [SidebarRowAction] = []

        init(items: [SidebarReorderItem], selectedID: String?, allowsDeselection: Bool,
             reorderable: Bool, onSelect: @escaping (String?) -> Void, onReorder: @escaping ([String]) -> Void,
             contextActions: @escaping (String) -> [SidebarRowAction],
             onToggleExpansion: @escaping (String) -> Void) {
            self.items = items
            self.selectedID = selectedID
            self.allowsDeselection = allowsDeselection
            self.reorderable = reorderable
            self.onSelect = onSelect
            self.onReorder = onReorder
            self.contextActions = contextActions
            self.onToggleExpansion = onToggleExpansion
        }

        func numberOfRows(in tableView: NSTableView) -> Int { items.count }

        // MARK: Context menu

        func menu(forRow row: Int) -> NSMenu? {
            guard row >= 0, row < items.count else { return nil }
            let actions = contextActions(items[row].id)
            guard !actions.isEmpty else { return nil }

            visibleContextActions = actions
            let menu = NSMenu()
            var didSeparateDestructive = false
            for (index, action) in actions.enumerated() {
                // macOS convention: destructive entries sit below a separator.
                if action.isDestructive, !didSeparateDestructive, index > 0 {
                    menu.addItem(.separator())
                    didSeparateDestructive = true
                }
                let menuItem = NSMenuItem(
                    title: action.title,
                    action: #selector(performContextAction(_:)),
                    keyEquivalent: ""
                )
                menuItem.target = self
                menuItem.tag = index
                menu.addItem(menuItem)
            }
            return menu
        }

        @objc private func performContextAction(_ sender: NSMenuItem) {
            guard sender.tag >= 0, sender.tag < visibleContextActions.count else { return }
            visibleContextActions[sender.tag].handler()
        }

        // MARK: Drag source — enables drag from any point on the row

        func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
            guard items[row].isDraggable else { return nil }
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
            guard let srcID = info.draggingPasteboard.string(forType: ReorderableRows.pasteType) else {
                return false
            }
            // Only top-level rows have an order. With children on screen a visible row index is
            // not an index into that order, so the drop point is counted in parents instead:
            // every parent above the drop line keeps its place, which means a drop anywhere
            // inside a workspace's expanded environments lands just after that workspace.
            var parentIDs = items.filter { $0.indentationLevel == 0 }.map(\.id)
            let parentsBeforeDrop = items.prefix(row).count { $0.indentationLevel == 0 }
            guard let fromIndex = parentIDs.firstIndex(of: srcID) else { return false }
            parentIDs.move(fromOffsets: IndexSet(integer: fromIndex), toOffset: parentsBeforeDrop)
            onReorder(parentIDs)
            return true
        }

        // MARK: Cell views

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            let item = items[row]
            let cell = tableView.makeView(withIdentifier: SidebarCell.reuseIdentifier, owner: self) as? SidebarCell
                ?? SidebarCell()
            cell.onToggleExpansion = { [weak self] in self?.onToggleExpansion(item.id) }
            cell.configure(with: item, isSelected: item.id == selectedID) { [weak self, weak tableView] in
                guard let self, let tableView else { return }
                if self.allowsDeselection, tableView.selectedRow == row {
                    tableView.deselectAll(nil)
                    self.onSelect(nil)
                    return
                }
                if tableView.selectedRow != row {
                    tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                } else {
                    self.onSelect(item.id)
                }
            }
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

// MARK: - Table View (right-click menus resolved against the clicked row)

private final class SidebarTableView: NSTableView {
    var menuProvider: ((Int) -> NSMenu?)?

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let clickedRow = row(at: point)
        guard clickedRow >= 0 else { return nil }
        return menuProvider?(clickedRow)
    }
}

// MARK: - Cell View

private final class SidebarCell: NSView {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("SidebarCell")
    /// How far one level of nesting moves a row in. Narrow on purpose: the sidebar column is
    /// 220pt at its widest and a workspace name still has to fit next to its badge.
    private static let indentationWidth: CGFloat = 13
    /// Room for the disclosure triangle to the left of the icon.
    private static let disclosureGutter: CGFloat = 13

    private let bg = NSView()
    private let disclosureButton = NSButton()
    private let imageView = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let badgeLabel = NSTextField(labelWithString: "")
    private var onPress: (() -> Void)?
    private var leadingConstraint: NSLayoutConstraint?
    var onToggleExpansion: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        identifier = Self.reuseIdentifier
        bg.wantsLayer = true
        bg.layer?.cornerRadius = 6
        bg.translatesAutoresizingMaskIntoConstraints = false
        addSubview(bg)

        disclosureButton.translatesAutoresizingMaskIntoConstraints = false
        disclosureButton.isBordered = false
        disclosureButton.bezelStyle = .inline
        disclosureButton.imagePosition = .imageOnly
        disclosureButton.target = self
        disclosureButton.action = #selector(toggleExpansion)
        disclosureButton.contentTintColor = .secondaryLabelColor
        addSubview(disclosureButton)

        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.imageScaling = .scaleProportionallyDown
        addSubview(imageView)

        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .preferredFont(forTextStyle: .body)
        label.lineBreakMode = .byTruncatingTail
        addSubview(label)

        badgeLabel.translatesAutoresizingMaskIntoConstraints = false
        badgeLabel.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
        badgeLabel.textColor = .secondaryLabelColor
        badgeLabel.alignment = .right
        badgeLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        addSubview(badgeLabel)

        let leading = imageView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 7)
        leadingConstraint = leading

        NSLayoutConstraint.activate([
            bg.leadingAnchor.constraint(equalTo: leadingAnchor),
            bg.trailingAnchor.constraint(equalTo: trailingAnchor),
            bg.topAnchor.constraint(equalTo: topAnchor, constant: 1),
            bg.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1),

            disclosureButton.trailingAnchor.constraint(equalTo: imageView.leadingAnchor, constant: -1),
            disclosureButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            disclosureButton.widthAnchor.constraint(equalToConstant: 12),
            disclosureButton.heightAnchor.constraint(equalToConstant: 14),

            leading,
            imageView.centerYAnchor.constraint(equalTo: centerYAnchor),
            imageView.widthAnchor.constraint(equalToConstant: 17),
            imageView.heightAnchor.constraint(equalToConstant: 17),

            label.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 7),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),

            badgeLabel.leadingAnchor.constraint(greaterThanOrEqualTo: label.trailingAnchor, constant: 6),
            badgeLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -7),
            badgeLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func toggleExpansion() {
        onToggleExpansion?()
    }

    func configure(with item: SidebarReorderItem, isSelected: Bool, onPress: @escaping () -> Void) {
        self.onPress = onPress
        // The triangle lives in the gutter that `reservesDisclosureSpace` opens up to the left
        // of the icon; indentation moves the whole row in from there.
        leadingConstraint?.constant = 7
            + (item.reservesDisclosureSpace ? Self.disclosureGutter : 0)
            + CGFloat(item.indentationLevel) * Self.indentationWidth

        if let isExpanded = item.isExpanded {
            disclosureButton.isHidden = false
            disclosureButton.image = NSImage(
                systemSymbolName: isExpanded ? "chevron.down" : "chevron.right",
                accessibilityDescription: isExpanded ? "Collapse" : "Expand"
            )
            disclosureButton.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold)
            disclosureButton.setAccessibilityElement(true)
            disclosureButton.setAccessibilityRole(.button)
            disclosureButton.setAccessibilityLabel(
                isExpanded ? "Collapse \(item.title)" : "Expand \(item.title)"
            )
            disclosureButton.setAccessibilityIdentifier(
                item.accessibilityIdentifier.map { "\($0)-disclosure" }
            )
        } else {
            disclosureButton.isHidden = true
            disclosureButton.image = nil
        }

        label.stringValue = item.title
        // Matches a real macOS sidebar: full label colour at the standard sidebar size.
        // 11pt in `secondaryLabelColor` made every row look disabled next to Finder or Mail,
        // and it ignored the system text-size setting entirely.
        label.textColor = isSelected ? item.tintColor : (item.isDimmed ? .tertiaryLabelColor : .labelColor)
        // Children sit at the smaller sidebar size, the way Finder draws a nested folder.
        label.font = .preferredFont(forTextStyle: item.indentationLevel > 0 ? .subheadline : .body)
        imageView.symbolConfiguration = NSImage.SymbolConfiguration(
            textStyle: item.indentationLevel > 0 ? .subheadline : .body,
            scale: .medium
        )
        imageView.image = NSImage(systemSymbolName: item.systemImage, accessibilityDescription: item.title)
        imageView.contentTintColor = isSelected
            ? item.tintColor
            : (item.isDimmed ? .tertiaryLabelColor : .secondaryLabelColor)
        badgeLabel.stringValue = item.badge ?? ""
        badgeLabel.isHidden = item.badge == nil
        bg.layer?.backgroundColor = isSelected
            ? item.tintColor.withAlphaComponent(0.18).cgColor
            : .clear
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(item.badge.map { "\(item.title), \($0)" } ?? item.title)
        setAccessibilityIdentifier(item.accessibilityIdentifier)
        // The cell is its own accessibility element, which by default makes it a leaf and hides
        // everything inside it. The triangle has to stay reachable: it is the only way to open a
        // workspace's environments, and with it hidden there is no keyboard or VoiceOver route in
        // at all.
        setAccessibilityChildren(item.isExpanded == nil ? [] : [disclosureButton])
    }

    override func accessibilityPerformPress() -> Bool {
        onPress?()
        return true
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
