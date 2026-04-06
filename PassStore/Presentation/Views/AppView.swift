import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct AppView: View {
    @Bindable var viewModel: VaultViewModel
    @Environment(\.openWindow) private var openWindow
    @State private var showOnboarding = false

    var body: some View {
        ZStack {
            NavigationSplitView {
                SidebarView(viewModel: viewModel)
                    .navigationSplitViewColumnWidth(min: 196, ideal: 220, max: 260)
            } content: {
                ItemListView(viewModel: viewModel)
                    .navigationSplitViewColumnWidth(min: 240, ideal: 300, max: 420)
            } detail: {
                ItemDetailView(viewModel: viewModel)
            }
            .navigationSplitViewStyle(.balanced)
            .disabled(isVaultLocked || showOnboarding)

            if showOnboarding {
                OnboardingView(
                    sessionManager: viewModel.container.sessionManager,
                    settings: viewModel.container.settings,
                    viewModel: viewModel,
                    onComplete: { withAnimation(.easeOut(duration: 0.3)) { showOnboarding = false } }
                )
                .transition(.opacity)
                .zIndex(1)
            } else if isVaultLocked {
                LockedVaultOverlay(viewModel: viewModel)
                    .transition(.opacity)
                    .zIndex(1)
            }

            if viewModel.isCommandPalettePresented, !isVaultLocked, !showOnboarding {
                CommandPaletteOverlay(viewModel: viewModel)
                    .transition(.opacity)
                    .zIndex(2)
            }
        }
        .frame(minWidth: 900, minHeight: 580)
        .fileExporter(
            isPresented: $viewModel.isPresentingExportFileExporter,
            document: viewModel.exportFileDocument,
            contentType: .passStoreBackup,
            defaultFilename: "PassStore-Backup"
        ) { result in
            viewModel.handleExportFileCompletion(result)
        }
        .sheet(item: $viewModel.activeSheet, onDismiss: {
            viewModel.completeExportAfterSheetDismissed()
            viewModel.onImportExportSheetDismissed()
        }) { sheet in
            switch sheet {
            case .newItemFlow:
                ItemCreationFlowSheet(viewModel: viewModel)
            case .editItem:
                ItemEditorSheet(
                    viewModel: viewModel,
                    title: "Edit Secret Item",
                    draft: viewModel.draftForSelectedItem(),
                    onSave: viewModel.saveItem
                )
            case .newWorkspace:
                WorkspaceEditorSheet(title: "New Workspace", draft: .empty, onSave: viewModel.saveWorkspace)
            case let .editWorkspace(workspaceID):
                WorkspaceEditorSheet(
                    title: "Edit Workspace",
                    draft: viewModel.draftForWorkspace(viewModel.workspace(for: workspaceID)),
                    onSave: viewModel.saveWorkspace
                )
            case .importEncryptedExport:
                ImportEncryptedExportSheet(viewModel: viewModel)
            case .export:
                ExportSheet(onExport: viewModel.exportSelectedItems)
            }
        }
        .sheet(isPresented: $viewModel.isSettingsPresented) {
            SettingsSheetView(settings: viewModel.container.settings, viewModel: viewModel)
        }
        // Keep this modifier unconditional: toggling it with lock state caused AttributeGraph crashes
        // (ApplyUpdatesToExternalTarget / value_set) on macOS when unlocking.
        .toolbar(removing: .sidebarToggle)
        .onChange(of: viewModel.container.sessionManager.lockState) { _, newValue in
            switch newValue {
            case .unlocked:
                // Defer past the unlock layout pass (overlay + toolbar) to avoid AppKit toolbar / split-view glitches.
                Task { @MainActor in
                    await Task.yield()
                    viewModel.reload()
                }
            case .locked, .setupRequired:
                viewModel.resetUnlockedSelection()
            }
        }
        .alert("PassStore", isPresented: Binding(
            get: { viewModel.alertMessage != nil },
            set: { if !$0 { viewModel.alertMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(viewModel.alertMessage ?? "")
        }
        .onAppear {
            if viewModel.container.sessionManager.lockState == .setupRequired {
                showOnboarding = true
            }
            GlobalCommandPaletteHotkey.shared.setOpenMainWindowAction {
                openWindow(id: "main")
            }
        }
    }

    private var isVaultLocked: Bool {
        viewModel.container.sessionManager.lockState != .unlocked
    }
}

// MARK: - Sidebar

private struct SidebarView: View {
    @Bindable var viewModel: VaultViewModel

    private var settings: AppSettingsStore { viewModel.container.settings }

    var body: some View {
        VStack(spacing: 0) {
            List {
                Section("Library", isExpanded: Binding(
                    get: { settings.sidebarLibraryExpanded },
                    set: { settings.sidebarLibraryExpanded = $0 }
                )) {
                    let libSelectedID: String? = {
                        guard viewModel.selectedType == nil,
                              case .library(let s) = viewModel.selectedDestination else { return nil }
                        return s.rawValue
                    }()
                        ReorderableRows(
                            items: LibrarySection.allCases.map {
                                SidebarReorderItem(
                                    id: $0.rawValue,
                                    title: $0.title,
                                    systemImage: $0.systemImage,
                                    accessibilityIdentifier: "sidebar-library-\(uiIdentifierSlug($0.title))"
                                )
                            },
                            selectedID: libSelectedID,
                            reorderable: false,
                        onSelect: { id in
                            guard let id, let section = LibrarySection(rawValue: id) else { return }
                            viewModel.selectDestination(.library(section))
                            viewModel.setSelectedType(nil)
                        }
                    )
                    .frame(height: CGFloat(LibrarySection.allCases.count) * ReorderableRows.rowHeight + 40)
                    .listRowInsets(EdgeInsets(top: -14, leading: -20, bottom: 0, trailing: -20))
                    .transformEffect(CGAffineTransform(translationX: 0, y: -10))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                }

                if !viewModel.workspaces.isEmpty {
                    Section("Workspaces", isExpanded: Binding(
                        get: { settings.sidebarWorkspacesExpanded },
                        set: { settings.sidebarWorkspacesExpanded = $0 }
                    )) {
                        let wsSelectedID: String? = {
                            if case .workspace(let id) = viewModel.selectedDestination, viewModel.selectedType == nil {
                                return id.uuidString
                            }
                            return nil
                        }()
                        ReorderableRows(
                            items: viewModel.workspaces.map {
                                SidebarReorderItem(
                                    id: $0.id.uuidString,
                                    title: $0.name,
                                    systemImage: $0.icon,
                                    tintColor: NSColor(hex: $0.colorHex),
                                    accessibilityIdentifier: "sidebar-workspace-\(uiIdentifierSlug($0.name))"
                                )
                            },
                            selectedID: wsSelectedID,
                            onSelect: { idStr in
                                guard let idStr, let id = UUID(uuidString: idStr) else { return }
                                viewModel.selectDestination(.workspace(id))
                                viewModel.setSelectedType(nil)
                            },
                            onReorder: { ids in
                                viewModel.reorderWorkspaces(newIDs: ids.compactMap(UUID.init(uuidString:)))
                            }
                        )
                        .frame(height: CGFloat(viewModel.workspaces.count) * ReorderableRows.rowHeight + 40)
                        .listRowInsets(EdgeInsets(top: -14, leading: -20, bottom: 0, trailing: -20))
                        .transformEffect(CGAffineTransform(translationX: 0, y: -10))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                    }
                }

                Section("Types", isExpanded: Binding(
                    get: { settings.sidebarTypesExpanded },
                    set: { settings.sidebarTypesExpanded = $0 }
                )) {
                    ReorderableRows(
                        items: viewModel.orderedTypes.map {
                            SidebarReorderItem(
                                id: $0.rawValue,
                                title: $0.title,
                                systemImage: $0.systemImage,
                                accessibilityIdentifier: "sidebar-type-\(uiIdentifierSlug($0.title))"
                            )
                        },
                        selectedID: viewModel.selectedType?.rawValue,
                        allowsDeselection: true,
                        onSelect: { rawValue in
                            viewModel.setSelectedType(rawValue.flatMap(SecretItemType.init(rawValue:)))
                        },
                        onReorder: { ids in
                            viewModel.container.settings.sidebarTypesOrder = ids
                        }
                    )
                    .frame(height: CGFloat(viewModel.orderedTypes.count) * ReorderableRows.rowHeight + 40)
                    .listRowInsets(EdgeInsets(top: -14, leading: -20, bottom: 0, trailing: -20))
                    .transformEffect(CGAffineTransform(translationX: 0, y: -10))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                }

                if !viewModel.orderedTags.isEmpty {
                    Section("Tags", isExpanded: Binding(
                        get: { settings.sidebarTagsExpanded },
                        set: { settings.sidebarTagsExpanded = $0 }
                    )) {
                        let tagSelectedID: String? = {
                            if case .tag(let t) = viewModel.selectedDestination, viewModel.selectedType == nil { return t }
                            return nil
                        }()
                        ReorderableRows(
                            items: viewModel.orderedTags.map {
                                SidebarReorderItem(
                                    id: $0,
                                    title: "#\($0)",
                                    systemImage: "tag",
                                    accessibilityIdentifier: "sidebar-tag-\(uiIdentifierSlug($0))"
                                )
                            },
                            selectedID: tagSelectedID,
                            onSelect: { tag in
                                guard let tag else { return }
                                viewModel.selectDestination(.tag(tag))
                                viewModel.setSelectedType(nil)
                            },
                            onReorder: { ids in
                                viewModel.container.settings.sidebarTagsOrder = ids
                            }
                        )
                        .frame(height: CGFloat(viewModel.orderedTags.count) * ReorderableRows.rowHeight + 40)
                    .listRowInsets(EdgeInsets(top: -14, leading: -20, bottom: 0, trailing: -20))
                    .transformEffect(CGAffineTransform(translationX: 0, y: -10))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                    }
                }

                if !viewModel.orderedEnvironments.isEmpty {
                    Section("Environments", isExpanded: Binding(
                        get: { settings.sidebarEnvironmentsExpanded },
                        set: { settings.sidebarEnvironmentsExpanded = $0 }
                    )) {
                        let envSelectedID: String? = {
                            if case .environment(let e) = viewModel.selectedDestination, viewModel.selectedType == nil { return e }
                            return nil
                        }()
                        ReorderableRows(
                            items: viewModel.orderedEnvironments.map {
                                SidebarReorderItem(
                                    id: $0,
                                    title: $0,
                                    systemImage: "circle.hexagongrid",
                                    accessibilityIdentifier: "sidebar-environment-\(uiIdentifierSlug($0))"
                                )
                            },
                            selectedID: envSelectedID,
                            onSelect: { env in
                                guard let env else { return }
                                viewModel.selectDestination(.environment(env))
                                viewModel.setSelectedType(nil)
                            },
                            onReorder: { ids in
                                viewModel.container.settings.sidebarEnvironmentsOrder = ids
                            }
                        )
                        .frame(height: CGFloat(viewModel.orderedEnvironments.count) * ReorderableRows.rowHeight + 40)
                    .listRowInsets(EdgeInsets(top: -14, leading: -20, bottom: 0, trailing: -20))
                    .transformEffect(CGAffineTransform(translationX: 0, y: -10))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                    }
                }

            Spacer(minLength: 20)

            }
            .listStyle(.sidebar)
            .frame(maxWidth: .infinity, maxHeight: .infinity)


            sidebarFooter
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }


    @ViewBuilder

    private var sidebarFooter: some View {
        VStack(spacing: 0) {
            Divider()
                .opacity(0.45)
            HStack {
                Button {
                    viewModel.activeSheet = .newWorkspace
                } label: {
                    Image(systemName: "folder.badge.plus")
                        .font(.system(size: 14))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("New Workspace")
                .accessibilityIdentifier("sidebar-new-workspace")
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
        }
        .frame(maxWidth: .infinity)
        .background(.bar)
    }
}

// MARK: - Item List

private struct ItemListView: View {
    @Bindable var viewModel: VaultViewModel

    private var isVaultLocked: Bool {
        viewModel.container.sessionManager.lockState != .unlocked
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                listHeader

                Divider()

                if viewModel.filteredItems.isEmpty {
                    ContentUnavailableView(
                        "No Items",
                        systemImage: "lock.slash",
                        description: Text("Adjust the search or filter, or create a new item.")
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(viewModel.filteredItems, id: \.id) { item in
                        ItemRow(viewModel: viewModel, item: item)
                    }
                    .listStyle(.plain)
                }

                if viewModel.isMultiSelecting {
                    MultiSelectionBar(viewModel: viewModel)
                }
            }
            .onKeyPress(.escape) {
                guard viewModel.isMultiSelecting else { return .ignored }
                viewModel.clearMultiSelection()
                return .handled
            }
            .navigationTitle(isVaultLocked ? "" : viewModel.destinationTitle)
            .toolbar {
                if !isVaultLocked {
                    ToolbarItem(placement: .automatic) {
                        Button {
                            viewModel.activeSheet = .newItemFlow
                        } label: {
                            Label("New Item", systemImage: "plus")
                        }
                        .accessibilityIdentifier("toolbar-new-item")
                    }
                    ToolbarItem(placement: .automatic) {
                        Button {
                            viewModel.container.sessionManager.lock()
                        } label: {
                            Label("Lock", systemImage: "lock")
                        }
                        .tint(.secondary)
                    }
                }
            }
        }
    }

    private var listHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            searchField

            Text("\(viewModel.filteredItems.count) item\(viewModel.filteredItems.count == 1 ? "" : "s")")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }

    private var searchField: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.tertiary)
                .font(.system(size: 11, weight: .medium))
            TextField("Search", text: $viewModel.searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
            if !viewModel.searchText.isEmpty {
                Button {
                    viewModel.searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }
}

// MARK: - Item Row

private struct ItemRow: View {
    @Bindable var viewModel: VaultViewModel
    let item: SecretItemEntity

    private var isSelected: Bool {
        viewModel.selectedItemID == item.id || viewModel.multiSelectedIDs.contains(item.id)
    }
    private var isMultiSelected: Bool { viewModel.multiSelectedIDs.contains(item.id) }
    private var selectionColor: Color {
        if let workspace = item.workspace {
            return Color(hex: workspace.colorHex)
        }
        return .accentColor
    }

    var body: some View {
        Button(action: handleSelection) {
            HStack(spacing: 8) {
                if viewModel.isMultiSelecting {
                    Image(systemName: isMultiSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 14))
                        .foregroundStyle(isMultiSelected ? selectionColor : .secondary)
                }

                VStack(alignment: .leading, spacing: 5) {
                    HStack(alignment: .center, spacing: 4) {
                        Text(item.title)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(isSelected ? selectionColor : .primary)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        if item.isFavorite {
                            Image(systemName: "star.fill")
                                .font(.system(size: 9))
                                .foregroundStyle(.yellow)
                        }
                    }

                    HStack(spacing: 6) {
                        Label(item.type.title, systemImage: item.type.systemImage)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)

                        if let workspace = item.workspace {
                            HStack(spacing: 3) {
                                Image(systemName: workspace.icon)
                                    .font(.system(size: 9))
                                Text(workspace.name)
                                    .font(.system(size: 10))
                            }
                            .foregroundStyle(Color(hex: workspace.colorHex))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                Capsule(style: .continuous)
                                    .fill(Color(hex: workspace.colorHex).opacity(0.12))
                            )
                        }
                    }
                }
            }
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(
            isSelected
                ? RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(selectionColor.opacity(0.12))
                : nil
        )
        .accessibilityIdentifier("item-row-\(uiIdentifierSlug(item.title))")
        .contextMenu {
            if viewModel.isMultiSelecting {
                multiSelectionContextMenu
            } else {
                singleItemContextMenu
            }
        }
    }

    private func handleSelection() {
        if NSEvent.modifierFlags.contains(.command) {
            viewModel.toggleMultiSelect(item)
        } else if viewModel.isMultiSelecting {
            viewModel.toggleMultiSelect(item)
        } else {
            viewModel.select(item)
        }
    }

    @ViewBuilder
    private var singleItemContextMenu: some View {
        Button("Edit Item", systemImage: "square.and.pencil") {
            viewModel.edit(item)
        }
        Button(
            item.isFavorite ? "Remove Favorite" : "Add to Favorites",
            systemImage: item.isFavorite ? "star.slash" : "star"
        ) {
            viewModel.toggleFavorite(for: item)
        }
        Divider()
        Button("Copy .env", systemImage: "doc.on.doc") {
            viewModel.copyEnv(for: item)
        }
        Button("Copy JSON", systemImage: "curlybraces") {
            viewModel.copyJSON(for: item)
        }
        if item.type == .database {
            Button("Copy Connection", systemImage: "externaldrive.connected.to.line.below") {
                viewModel.copyConnectionString(for: item)
            }
        }
        Divider()
        Button("Duplicate", systemImage: "plus.square.on.square") {
            viewModel.duplicate(item)
        }
        Button(
            item.isArchived ? "Restore" : "Archive",
            systemImage: item.isArchived ? "tray.and.arrow.up" : "archivebox"
        ) {
            item.isArchived ? viewModel.restore(item) : viewModel.archive(item)
        }
        Divider()
        Button("Delete", systemImage: "trash", role: .destructive) {
            viewModel.delete(item)
        }
    }

    @ViewBuilder
    private var multiSelectionContextMenu: some View {
        let count = viewModel.multiSelectedIDs.count
        Button("Add to Favorites", systemImage: "star") {
            viewModel.bulkAddFavorite()
        }
        Button("Remove from Favorites", systemImage: "star.slash") {
            viewModel.bulkRemoveFavorite()
        }
        Divider()
        Button("Copy All as .env", systemImage: "doc.on.doc") {
            viewModel.bulkCopyEnv()
        }
        Button("Copy All as JSON", systemImage: "curlybraces") {
            viewModel.bulkCopyJSON()
        }
        Divider()
        Button("Duplicate \(count) Items", systemImage: "plus.square.on.square") {
            viewModel.bulkDuplicate()
        }
        Button("Archive \(count) Items", systemImage: "archivebox") {
            viewModel.bulkArchive()
        }
        Divider()
        Button("Delete \(count) Items", systemImage: "trash", role: .destructive) {
            viewModel.bulkDelete()
        }
    }
}

// MARK: - Multi-Selection Bar

private struct MultiSelectionBar: View {
    @Bindable var viewModel: VaultViewModel

    private var allSelected: Bool {
        viewModel.multiSelectedIDs.count == viewModel.filteredItems.count
    }

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 12) {
                Text("\(viewModel.multiSelectedIDs.count) selected")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)

                Spacer()

                Button {
                    if allSelected {
                        viewModel.clearMultiSelection()
                    } else {
                        viewModel.selectAll()
                    }
                } label: {
                    Text(allSelected ? "Deselect All" : "Select All")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)

                Button {
                    viewModel.clearMultiSelection()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.bar)
        }
    }
}

// MARK: - Item Detail

private struct ItemDetailView: View {
    @Bindable var viewModel: VaultViewModel
    @State private var copiedFieldID: UUID?
    @State private var showDeleteConfirmation = false

    private var isVaultLocked: Bool {
        viewModel.container.sessionManager.lockState != .unlocked
    }

    @ViewBuilder
    private var emptyDetailPlaceholder: some View {
        ContentUnavailableView {
            VStack(spacing: 12) {
                Image("icon")
                    .resizable()
                    .renderingMode(.template)
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 56, height: 56)
                    .foregroundStyle(.secondary)
                Text("Select a Secret")
                    .font(.title2)
                    .fontWeight(.semibold)
            }
        } description: {
            Text("Choose an item from the list or create a new one.")
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if let item = viewModel.selectedItem {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 20) {
                            GroupedSheetSection(title: "") {
                                detailHero(for: item)
                            }

                            if !viewModel.visibleSelectedFields.isEmpty {
                                GroupedSheetSection(title: "Fields") {
                                    fieldsSectionContent
                                }
                            }

                            if let notes = viewModel.selectedNotes {
                                GroupedSheetSection(title: "Notes") {
                                    SheetLabeledField(title: "Notes") {
                                        Text(notes)
                                            .textSelection(.enabled)
                                            .font(.body)
                                            .foregroundStyle(.primary)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .multilineTextAlignment(.leading)
                                            .padding(8)
                                            .background(
                                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                                    .fill(Color(nsColor: .controlBackgroundColor))
                                                    .overlay(
                                                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                                                            .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
                                                    )
                                            )
                                    }
                                }
                            }
                        }
                        .padding(20)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .accessibilityIdentifier("detail-item-\(uiIdentifierSlug(item.title))")
                } else {
                    emptyDetailPlaceholder
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .toolbar {
                if !isVaultLocked, let item = viewModel.selectedItem {
                    ToolbarSpacer(.flexible)
                    ToolbarItemGroup(placement: .primaryAction) {
                        Button {
                            viewModel.activeSheet = .editItem(item.id)
                        } label: {
                            Label("Edit", systemImage: "square.and.pencil")
                        }
                        .accessibilityIdentifier("toolbar-detail-edit")

                        Menu {
                            Button("Copy .env", systemImage: "doc.on.doc") {
                                viewModel.copyEnv()
                            }
                            .accessibilityIdentifier("detail-action-env")

                            Button("Copy JSON", systemImage: "curlybraces") {
                                viewModel.copyJSON()
                            }
                            .accessibilityIdentifier("detail-action-json")

                            if item.type == .database {
                                Button("Copy Connection", systemImage: "externaldrive.connected.to.line.below") {
                                    viewModel.copyConnectionString()
                                }
                                .accessibilityIdentifier("detail-action-connection")
                            }
                        } label: {
                            Label("Copy", systemImage: "doc.on.doc")
                        }
                        .accessibilityIdentifier("toolbar-detail-copy")

                        Menu {
                            Button("Duplicate", systemImage: "plus.square.on.square") {
                                viewModel.duplicateSelectedItem()
                            }
                            Button(
                                item.isArchived ? "Restore" : "Archive",
                                systemImage: item.isArchived ? "tray.and.arrow.up" : "archivebox"
                            ) {
                                if item.isArchived {
                                    viewModel.restoreSelectedItem()
                                } else {
                                    viewModel.archiveSelectedItem()
                                }
                            }
                            Divider()
                            Button("Delete", systemImage: "trash", role: .destructive) {
                                showDeleteConfirmation = true
                            }
                        } label: {
                            Label("More", systemImage: "ellipsis.circle")
                        }
                        .accessibilityIdentifier("toolbar-detail-more")
                    }
                }
            }
            .alert("Delete item?", isPresented: $showDeleteConfirmation) {
                Button("Delete", role: .destructive) {
                    viewModel.deleteSelectedItem()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This will permanently delete the item and cannot be undone.")
            }
            .onChange(of: viewModel.selectedItemID) { _, _ in
                copiedFieldID = nil
            }
        }
    }

    // MARK: Hero

    private func detailHero(for item: SecretItemEntity) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 14) {
                let accent = item.workspace.map { Color(hex: $0.colorHex) } ?? Color.accentColor
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(accent.opacity(0.15))
                    .frame(width: 46, height: 46)
                    .overlay(
                        Image(systemName: item.type.systemImage)
                            .font(.system(size: 20, weight: .medium))
                            .foregroundStyle(accent)
                    )
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("detail-item-title")
                    Text(item.type.title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                Button {
                    viewModel.toggleFavoriteForSelectedItem()
                } label: {
                    Image(systemName: item.isFavorite ? "star.fill" : "star")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(item.isFavorite ? .yellow : .secondary)
                }
                .buttonStyle(.plain)
                .help(item.isFavorite ? "Remove from Favorites" : "Add to Favorites")
                .accessibilityIdentifier("detail-favorite-toggle")
            }
            .padding(.vertical, 2)

            heroPills(for: item)
        }
    }

    private func heroPills(for item: SecretItemEntity) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                if let workspace = item.workspace {
                    pillChip(workspace.name, systemImage: workspace.icon, color: Color(hex: workspace.colorHex))
                }
                pillChip(item.environmentValue.title, systemImage: "circle.hexagongrid")
                ForEach(item.tags, id: \.self) { tag in
                    pillChip("#\(tag)", systemImage: "tag")
                }
            }
            .padding(.vertical, 1)
        }
    }

    private func pillChip(_ title: String, systemImage: String, color: Color = .secondary) -> some View {
        Label(title, systemImage: systemImage)
            .font(.caption.weight(.medium))
            .labelStyle(.titleAndIcon)
            .foregroundStyle(color)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(
                Capsule(style: .continuous)
                    .fill(color.opacity(0.12))
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(color.opacity(0.18), lineWidth: 0.5)
            )
    }

    // MARK: Fields

    private var fieldsSectionContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(viewModel.visibleSelectedFields) { field in
                FieldRow(
                    field: field,
                    canRevealSecrets: viewModel.container.sessionManager.lockState == .unlocked,
                    isCopied: copiedFieldID == field.id,
                    onCopy: {
                        viewModel.copyField(field)
                        flashCopiedField(field.id)
                    }
                )

                if field.id != viewModel.visibleSelectedFields.last?.id {
                    Divider()
                }
            }
        }
    }

    // MARK: Helpers

    private func flashCopiedField(_ fieldID: UUID) {
        copiedFieldID = fieldID
        Task {
            try? await Task.sleep(for: .seconds(1.4))
            if copiedFieldID == fieldID { copiedFieldID = nil }
        }
    }
}

// MARK: - Field Row

private struct FieldRow: View {
    let field: FieldResolvedValue
    let canRevealSecrets: Bool
    let isCopied: Bool
    let onCopy: () -> Void

    @State private var isHoveringSecret = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SheetLabeledField(title: field.label, titleAccessibilityIdentifier: "field-label-\(field.key)") {
                Group {
                    if field.isCopyable {
                        Button(action: onCopy) {
                            valueStack(showPlaintext: showsPlaintext)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("detail-field-value-\(field.key)")
                        .accessibilityLabel(field.label)
                        .accessibilityHint(accessibilityCopyHint)
                    } else {
                        valueStack(showPlaintext: showsPlaintext)
                            .textSelection(.enabled)
                    }
                }
                .onHover { hovering in
                    if field.isSensitive, canRevealSecrets {
                        isHoveringSecret = hovering
                    }
                    if field.isCopyable {
                        if hovering {
                            NSCursor.pointingHand.push()
                        } else {
                            NSCursor.pop()
                        }
                    }
                }
                .help(helpText)
            }
        }
        .accessibilityIdentifier("detail-field-\(field.key)")
    }

    private var showsPlaintext: Bool {
        if !field.isSensitive { return true }
        guard canRevealSecrets else { return false }
        return isHoveringSecret
    }

    private var helpText: String {
        if field.isCopyable, field.isSensitive, canRevealSecrets {
            return "Hover to show, click to copy"
        }
        if field.isCopyable {
            return "Click to copy"
        }
        if field.isSensitive, canRevealSecrets {
            return "Hover to show"
        }
        return ""
    }

    private var accessibilityCopyHint: String {
        if field.isSensitive, canRevealSecrets {
            return "Hover to show the value, then activate to copy to the clipboard"
        }
        return "Activate to copy to the clipboard"
    }

    @ViewBuilder
    private func valueStack(showPlaintext: Bool) -> some View {
        Text(displayText(showPlaintext: showPlaintext))
            .font(.system(.body, design: .monospaced))
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .multilineTextAlignment(.leading)
            .lineLimit(valueLineLimit)
            .fixedSize(horizontal: false, vertical: true)
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(valueBorderColor, lineWidth: isCopied ? 2 : 0.5)
                    )
            )
            .overlay {
                if isCopied {
                    copiedFeedbackBadge
                        .allowsHitTesting(false)
                        .transition(.scale(scale: 0.92).combined(with: .opacity))
                }
            }
            .animation(.spring(response: 0.32, dampingFraction: 0.82), value: isCopied)
    }

    private var copiedFeedbackBadge: some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.circle.fill")
                .font(.body.weight(.semibold))
                .symbolRenderingMode(.hierarchical)
            Text("Copied")
                .font(.subheadline.weight(.semibold))
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.thickMaterial)
                .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
        }
    }

    private var valueBorderColor: Color {
        if isCopied {
            return Color.accentColor.opacity(0.9)
        }
        return Color.primary.opacity(0.06)
    }

    private var valueLineLimit: Int {
        switch field.kind {
        case .json, .multiline: 8
        default: 4
        }
    }

    /// Inserts zero-width spaces so long secrets / API keys wrap instead of overflowing when there are no real spaces.
    private var needsSoftCharacterWrap: Bool {
        field.kind == .secret || field.isSensitive
    }

    private func displayText(showPlaintext: Bool) -> String {
        let raw = displayValue(showPlaintext: showPlaintext)
        guard needsSoftCharacterWrap else { return raw }
        return Self.insertSoftBreakOpportunities(raw)
    }

    private func displayValue(showPlaintext: Bool) -> String {
        guard field.isSensitive, !showPlaintext else {
            return TemplatePickerFieldDisplay.presentationValue(fieldKey: field.key, stored: field.value)
        }
        return String(repeating: "•", count: max(field.value.count, 8))
    }

    private static func insertSoftBreakOpportunities(_ string: String) -> String {
        guard !string.isEmpty else { return string }
        return string.map { String($0) }.joined(separator: "\u{200B}")
    }
}

// MARK: - Locked Vault

private struct LockedVaultOverlay: View {
    @Bindable var viewModel: VaultViewModel

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)
                .ignoresSafeArea()

            LockedVaultView(
                sessionManager: viewModel.container.sessionManager,
                biometricsEnabled: viewModel.container.settings.biometricsEnabled
            )
                .frame(maxWidth: 380)
                .padding(32)
        }
    }
}

private struct LockedVaultView: View {
    @Bindable var sessionManager: VaultSessionManager
    var biometricsEnabled: Bool
    @State private var password = ""

    private var showTouchIDBadge: Bool {
        sessionManager.lockState == .locked
            && sessionManager.isBiometricAvailable
            && biometricsEnabled
    }

    var body: some View {
        VStack(spacing: 20) {
            appLockHeaderImage
                .frame(width: 100, height: 100)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
                .overlay(alignment: .bottomTrailing) {
                    if showTouchIDBadge {
                        Image("touch_id")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 30, height: 30)
                            .padding(5)
                            .background(
                                Circle()
                                    .fill(Color.white)
                            )
                            .overlay(
                                Circle()
                                    .strokeBorder(Color.black.opacity(0.08), lineWidth: 0.5)
                            )
                            .offset(x: 4, y: 4)
                    }
                }

            VStack(spacing: 6) {
                Text(sessionManager.lockState == .setupRequired ? "Create Your Password" : "PassStore is Locked")
                    .font(.title3.weight(.semibold))
                Text(sessionManager.lockState == .setupRequired
                     ? "Set a master password to protect your secrets."
                     : "Enter your master password to unlock.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            VStack(spacing: 10) {
                SecureField("Master Password", text: $password)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 280)
                    .onSubmit(submit)

                if let message = sessionManager.lastErrorMessage {
                    Text(message)
                        .foregroundStyle(.red)
                        .font(.caption)
                }

                HStack(spacing: 10) {
                    if sessionManager.lockState == .setupRequired {
                        Button("Create Password", action: submit)
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                            .keyboardShortcut(.defaultAction)
                            .disabled(password.isEmpty)
                    } else {
                        Button("Unlock", action: submit)
                            .buttonStyle(.bordered)
                            .tint(.secondary)
                            .controlSize(.large)
                            .keyboardShortcut(.defaultAction)
                            .disabled(password.isEmpty)
                    }

                    if sessionManager.lockState == .locked, sessionManager.isBiometricAvailable {
                        Button("Use Biometrics") {
                            Task { _ = await sessionManager.unlockWithBiometrics() }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                    }
                }
            }
        }
        .padding(32)
    }

    private func submit() {
        guard !password.isEmpty else { return }
        if sessionManager.lockState == .setupRequired {
            sessionManager.createVault(password: password)
        } else {
            _ = sessionManager.unlockWithPassword(password)
        }
        password = ""
    }

    @ViewBuilder
    private var appLockHeaderImage: some View {
        if let appIcon = NSImage(named: NSImage.applicationIconName) {
            Image(nsImage: appIcon)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
        } else {
            Image("icon")
                .resizable()
                .scaledToFit()
        }
    }
}

// MARK: - Shared Pills

private struct VaultPillValue: Hashable {
    let title: String
    let systemImage: String
    var accentHex: String?
    var isEmphasized: Bool = false

    init(title: String, systemImage: String, accentHex: String? = nil, isEmphasized: Bool = false) {
        self.title = title
        self.systemImage = systemImage
        self.accentHex = accentHex
        self.isEmphasized = isEmphasized
    }

    static func workspace(_ workspace: WorkspaceEntity) -> VaultPillValue {
        .init(title: workspace.name, systemImage: workspace.icon, accentHex: workspace.colorHex, isEmphasized: true)
    }
}

// MARK: - Preview

#Preview("App") {
    AppView(viewModel: VaultViewModel(container: .preview()))
}

// MARK: - Utilities

private func uiIdentifierSlug(_ value: String) -> String {
    value
        .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        .replacingOccurrences(of: "[^a-zA-Z0-9]+", with: "-", options: .regularExpression)
        .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        .lowercased()
}
