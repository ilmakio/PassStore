import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct AppView: View {
    @Bindable var viewModel: VaultViewModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.controlActiveState) private var controlActiveState
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
            // Attached here rather than on the enclosing ZStack: that already owns a
            // confirmationDialog for workspace deletion and two on one view conflict.
            .confirmationDialog(
                viewModel.itemDeletionTitle,
                isPresented: Binding(
                    get: { !viewModel.itemsPendingDeletion.isEmpty },
                    set: { if !$0 { viewModel.cancelItemDeletion() } }
                ),
                titleVisibility: .visible
            ) {
                Button(viewModel.itemDeletionConfirmLabel, role: .destructive) {
                    viewModel.confirmItemDeletion()
                }
                .accessibilityIdentifier("confirm-delete-items")
                Button("Cancel", role: .cancel) {
                    viewModel.cancelItemDeletion()
                }
            } message: {
                Text(viewModel.itemDeletionMessage)
            }

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
            case let .editItem(itemID):
                // The id in the case is what is edited. It used to be ignored in favour of
                // whatever happened to be selected, which is the same thing right up until
                // it isn't.
                ItemEditorSheet(
                    viewModel: viewModel,
                    title: "Edit Secret Item",
                    draft: viewModel.draft(forItemID: itemID),
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
                ExportSheet(viewModel: viewModel)
            case .importPreview:
                ImportPreviewSheet(viewModel: viewModel)
            case .passwordGenerator:
                PasswordGeneratorSheet(viewModel: viewModel)
            case .vaultHealth:
                VaultHealthSheet(viewModel: viewModel)
            case .bulkEdit:
                BulkEditSheet(viewModel: viewModel)
            case let .itemHistory(itemID):
                ItemHistorySheet(viewModel: viewModel, itemID: itemID)
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
        .confirmationDialog(
            viewModel.workspacePendingDeletion.map { "Delete “\($0.name)”?" } ?? "Delete workspace?",
            isPresented: Binding(
                get: { viewModel.workspacePendingDeletion != nil },
                set: { if !$0 { viewModel.workspacePendingDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete Workspace", role: .destructive) {
                viewModel.confirmWorkspaceDeletion()
            }
            Button("Cancel", role: .cancel) {
                viewModel.workspacePendingDeletion = nil
            }
        } message: {
            Text(workspaceDeletionMessage)
        }
        .onAppear {
            if viewModel.container.sessionManager.lockState == .setupRequired {
                showOnboarding = true
            }
            GlobalCommandPaletteHotkey.shared.setOpenMainWindowAction {
                openWindow(id: "main")
            }
            viewModel.refreshLinkedFileStatuses()
        }
        // Coming back from an editor is exactly when a linked `.env` is likely to have
        // changed, so that is when PassStore looks — no watcher, no background work.
        .onChange(of: controlActiveState) { _, newValue in
            guard newValue != .inactive else { return }
            viewModel.refreshLinkedFileStatuses()
        }
    }

    private var isVaultLocked: Bool {
        viewModel.container.sessionManager.lockState != .unlocked
    }

    private var workspaceDeletionMessage: String {
        guard let workspace = viewModel.workspacePendingDeletion else { return "" }
        let count = viewModel.itemCount(inWorkspace: workspace.id)
        guard count > 0 else {
            return "This workspace is empty. Deleting it cannot be undone."
        }
        let noun = count == 1 ? "item" : "items"
        return "\(count) \(noun) will stay in your vault but lose this workspace. Deleting the workspace cannot be undone."
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
                            items: LibrarySection.allCases.map { section in
                                let count = viewModel.itemCount(in: section)
                                return SidebarReorderItem(
                                    id: section.rawValue,
                                    title: section.title,
                                    systemImage: section.systemImage,
                                    badge: count > 0 ? "\(count)" : nil,
                                    accessibilityIdentifier: "sidebar-library-\(uiIdentifierSlug(section.title))"
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
                    .sidebarSectionRows(count: LibrarySection.allCases.count)
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
                            items: viewModel.workspaces.map { workspace in
                                let count = viewModel.itemCount(inWorkspace: workspace.id)
                                return SidebarReorderItem(
                                    id: workspace.id.uuidString,
                                    title: workspace.name,
                                    systemImage: workspace.icon,
                                    tintColor: NSColor(hex: workspace.colorHex),
                                    badge: count > 0 ? "\(count)" : nil,
                                    accessibilityIdentifier: "sidebar-workspace-\(uiIdentifierSlug(workspace.name))"
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
                            },
                            contextActions: { idStr in
                                guard let id = UUID(uuidString: idStr) else { return [] }
                                return [
                                    SidebarRowAction(title: "Edit Workspace…") {
                                        viewModel.activeSheet = .editWorkspace(id)
                                    },
                                    SidebarRowAction(title: "New Secret Item Here…") {
                                        viewModel.selectDestination(.workspace(id))
                                        viewModel.setSelectedType(nil)
                                        viewModel.activeSheet = .newItemFlow
                                    },
                                    SidebarRowAction(title: "Delete Workspace…", isDestructive: true) {
                                        viewModel.requestWorkspaceDeletion(id: id)
                                    }
                                ]
                            }
                        )
                    .sidebarSectionRows(count: viewModel.workspaces.count)
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
                    .sidebarSectionRows(count: viewModel.orderedTypes.count)
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
                    .sidebarSectionRows(count: viewModel.orderedTags.count)
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
                    .sidebarSectionRows(count: viewModel.orderedEnvironments.count)
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
    @FocusState private var isSearchFocused: Bool

    private var isVaultLocked: Bool {
        viewModel.container.sessionManager.lockState != .unlocked
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                listHeader

                Divider()

                if viewModel.filteredItems.isEmpty {
                    emptyListPlaceholder
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    // A real `List` selection rather than a stack of buttons: this is what
                    // gives arrow-key navigation, ⇧-click ranges, ⌘-click toggling and a
                    // focus ring, none of which the hand-rolled version had.
                    List(viewModel.filteredItems, id: \.id, selection: $viewModel.listSelection) { item in
                        ItemRow(viewModel: viewModel, item: item)
                            .tag(item.id)
                    }
                    .listStyle(.inset)
                    .accessibilityIdentifier("item-list")
                }

                if viewModel.isMultiSelecting {
                    MultiSelectionBar(viewModel: viewModel)
                } else if let message = viewModel.lastActionMessage {
                    StatusFooter(message: message, viewModel: viewModel)
                }
            }
            .onKeyPress(.escape) {
                guard viewModel.isMultiSelecting else { return .ignored }
                viewModel.clearMultiSelection()
                return .handled
            }
            .onChange(of: viewModel.searchFocusRequests) { _, _ in
                isSearchFocused = true
            }
            .navigationTitle(isVaultLocked ? "" : viewModel.destinationTitle)
            .navigationSubtitle(isVaultLocked ? "" : viewModel.destinationSubtitle)
            .toolbar {
                if !isVaultLocked {
                    ToolbarItem(placement: .automatic) {
                        sortMenu
                    }
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

    /// Sorting was hard-coded to A-Z everywhere except "Recent", so there was no way to ask
    /// what you touched last from any other destination.
    private var sortMenu: some View {
        Menu {
            Picker("Sort by", selection: $viewModel.sortOrder) {
                ForEach(ItemSortOrder.allCases) { order in
                    Label(order.title, systemImage: order.systemImage).tag(order)
                }
            }
            .pickerStyle(.inline)
        } label: {
            Label("Sort", systemImage: "arrow.up.arrow.down")
        }
        .help("Sort the list")
        .accessibilityIdentifier("toolbar-sort")
    }

    /// A brand-new vault has nothing to "adjust", so the empty state has to say something different
    /// from the one you get after filtering everything out.
    @ViewBuilder
    private var emptyListPlaceholder: some View {
        if viewModel.items.isEmpty {
            ContentUnavailableView {
                Label("Your Vault Is Empty", systemImage: "lock.open")
            } description: {
                Text("Add your first API key, database credential, or .env file to get started.")
            } actions: {
                VStack(spacing: VaultSpacing.s) {
                    Button("New Secret Item…") {
                        viewModel.activeSheet = .newItemFlow
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("empty-vault-new-item")

                    Button("Import a .env File…") {
                        viewModel.importEnvFileCreatingItem()
                    }
                    .accessibilityIdentifier("empty-vault-import-env")
                }
            }
        } else if viewModel.hasActiveFilters {
            ContentUnavailableView {
                Label("No Matches", systemImage: "magnifyingglass")
            } description: {
                Text("No items match the current search and filters.")
            } actions: {
                Button("Clear Filters") {
                    viewModel.clearFilters()
                }
                .accessibilityIdentifier("empty-list-clear-filters")
            }
        } else {
            ContentUnavailableView {
                Label("Nothing Here Yet", systemImage: "tray")
            } description: {
                Text(viewModel.emptyDestinationHint)
            } actions: {
                Button("New Secret Item…") {
                    viewModel.activeSheet = .newItemFlow
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private var listHeader: some View {
        VStack(alignment: .leading, spacing: VaultSpacing.s) {
            searchField

            HStack(spacing: VaultSpacing.xs) {
                Text("\(viewModel.filteredItems.count) item\(viewModel.filteredItems.count == 1 ? "" : "s")")
                    .font(.vaultBadge)
                    // `.tertiary` on this size failed contrast; secondary is legible and still quiet.
                    .foregroundStyle(.secondary)

                if viewModel.sortOrder != .title {
                    Text("· \(viewModel.sortOrder.title.lowercased())")
                        .font(.vaultBadge)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)

                if viewModel.outdatedLinkedFileCount > 0 {
                    Label("\(viewModel.outdatedLinkedFileCount)", systemImage: "arrow.down.doc")
                        .font(.vaultBadge)
                        .foregroundStyle(.orange)
                        .help("\(viewModel.outdatedLinkedFileCount) linked .env \(viewModel.outdatedLinkedFileCount == 1 ? "file has" : "files have") changed on disk")
                        .accessibilityIdentifier("outdated-links-badge")
                }
            }
        }
        .padding(.horizontal, VaultSpacing.m)
        .padding(.top, VaultSpacing.s)
        .padding(.bottom, VaultSpacing.s)
    }

    private var searchField: some View {
        HStack(spacing: VaultSpacing.xs) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.caption)
            TextField("Search", text: $viewModel.searchText)
                .textFieldStyle(.plain)
                .font(.callout)
                .focused($isSearchFocused)
                .accessibilityIdentifier("item-list-search")
            if !viewModel.searchText.isEmpty {
                Button {
                    viewModel.searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, VaultSpacing.s)
        .padding(.vertical, VaultSpacing.xs + 1)
        .background(
            RoundedRectangle(cornerRadius: VaultRadius.control, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }
}

// MARK: - Item Row

private struct ItemRow: View {
    @Bindable var viewModel: VaultViewModel
    let item: SecretItemEntity

    @State private var isHovering = false
    @State private var didCopy = false

    /// The field a quick-copy should reach for: the password, or failing that the first
    /// sensitive value.
    private var quickCopyField: FieldResolvedValue? {
        viewModel.primaryCopyField(for: item)
    }

    var body: some View {
        HStack(spacing: VaultSpacing.s) {
            VStack(alignment: .leading, spacing: VaultSpacing.xs) {
                HStack(alignment: .center, spacing: VaultSpacing.xs) {
                    Text(item.title)
                        .font(.vaultRowTitle)
                        .lineLimit(1)

                    if item.isFavorite {
                        Image(systemName: "star.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(.yellow)
                            .accessibilityLabel("Favourite")
                    }

                    if item.linkedFile != nil {
                        Image(systemName: viewModel.itemsWithOutdatedLinks.contains(item.id)
                              ? "arrow.down.doc.fill"
                              : "link")
                            .font(.system(size: 9))
                            .foregroundStyle(viewModel.itemsWithOutdatedLinks.contains(item.id) ? .orange : .secondary)
                            .accessibilityLabel(viewModel.itemsWithOutdatedLinks.contains(item.id)
                                                ? "Linked file changed"
                                                : "Linked to a file")
                    }

                    Spacer(minLength: VaultSpacing.xs)
                }

                HStack(spacing: VaultSpacing.xs) {
                    Label(item.type.title, systemImage: item.type.systemImage)
                        .font(.vaultRowSubtitle)
                        .foregroundStyle(.secondary)
                        .labelStyle(.titleAndIcon)

                    if let workspace = item.workspace {
                        VaultChip(title: workspace.name, systemImage: workspace.icon, color: Color(hex: workspace.colorHex))
                    }
                }
            }

            // Quick copy without leaving the list. Copying the password used to mean
            // select → move to the detail pane → hover → click.
            if let quickCopyField, isHovering || didCopy {
                Button {
                    viewModel.copyField(quickCopyField)
                    flashCopied()
                } label: {
                    Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(VaultIconButtonStyle(isActive: didCopy))
                .help("Copy \(quickCopyField.label)")
                .accessibilityLabel("Copy \(quickCopyField.label) of \(item.title)")
                .accessibilityIdentifier("item-row-quickcopy-\(uiIdentifierSlug(item.title))")
            }
        }
        .padding(.vertical, VaultSpacing.xs)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("item-row-\(uiIdentifierSlug(item.title))")
        .contextMenu {
            if viewModel.isMultiSelecting {
                multiSelectionContextMenu
            } else {
                singleItemContextMenu
            }
        }
    }

    private func flashCopied() {
        didCopy = true
        Task {
            try? await Task.sleep(for: .seconds(1.4))
            didCopy = false
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
        Button("Delete…", systemImage: "trash", role: .destructive) {
            viewModel.requestDeletion(of: item)
        }
    }

    @ViewBuilder
    private var multiSelectionContextMenu: some View {
        let count = viewModel.multiSelectedIDs.count
        Button("Edit \(count) Items…", systemImage: "slider.horizontal.3") {
            viewModel.activeSheet = .bulkEdit
        }
        Divider()
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
        Button("Delete \(count) Items…", systemImage: "trash", role: .destructive) {
            viewModel.requestDeletionOfMultiSelection()
        }
    }
}

// MARK: - Status footer

/// Transient confirmation strip under the list.
///
/// Several actions move their result out of view — archiving from inside a workspace,
/// restoring a backup, merging — and without this they looked like they had done nothing.
private struct StatusFooter: View {
    let message: String
    @Bindable var viewModel: VaultViewModel

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: VaultSpacing.s) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
                    .accessibilityHidden(true)

                Text(message)
                    .font(.vaultRowSubtitle)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)

                Spacer(minLength: VaultSpacing.s)

                if let undoLabel = viewModel.undoActionLabel {
                    Button("Undo") { viewModel.undoLastDestructiveAction() }
                        .buttonStyle(.link)
                        .font(.vaultRowSubtitle)
                        .help("Undo \(undoLabel.lowercased()) (⌘Z)")
                        .accessibilityIdentifier("status-undo")
                }
            }
            .padding(.horizontal, VaultSpacing.m)
            .padding(.vertical, VaultSpacing.s)
            .background(.bar)
        }
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Multi-Selection Bar

private struct MultiSelectionBar: View {
    @Bindable var viewModel: VaultViewModel

    /// Compares against the items actually on screen — `multiSelectedIDs` can still hold ids that
    /// dropped out of `filteredItems` after a search or filter change.
    private var allSelected: Bool {
        let visible = viewModel.filteredItems
        guard !visible.isEmpty else { return false }
        return visible.allSatisfy { viewModel.multiSelectedIDs.contains($0.id) }
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
                    viewModel.activeSheet = .bulkEdit
                } label: {
                    Text("Edit…")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .help("Edit tags, workspace, environment and status for every selected item")
                .accessibilityIdentifier("multi-selection-edit")

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
                        VStack(alignment: .leading, spacing: VaultSpacing.xl) {
                            VaultCard { detailHero(for: item) }

                            LinkedFileSection(viewModel: viewModel, item: item)

                            if !viewModel.visibleSelectedFields.isEmpty {
                                VaultSection("Fields", systemImage: "list.bullet") {
                                    fieldsSectionContent(for: item)
                                }
                            }

                            VaultSection("Details", systemImage: "info.circle") {
                                metadataRows(for: item)
                            }

                            if !item.changeHistory.isEmpty {
                                VaultSection("History", systemImage: "clock.arrow.circlepath") {
                                    Button("Show full history…") {
                                        viewModel.activeSheet = .itemHistory(item.id)
                                    }
                                    .buttonStyle(.link)
                                    .font(.vaultFootnote)
                                    .accessibilityIdentifier("detail-show-history")
                                } content: {
                                    historyRows(for: item)
                                }
                            }

                            if let notes = viewModel.selectedNotes {
                                VaultSection("Notes", systemImage: "note.text") {
                                    VaultValueBox {
                                        Text(notes)
                                            .textSelection(.enabled)
                                            .font(.body)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .multilineTextAlignment(.leading)
                                    }
                                }
                            }
                        }
                        .padding(VaultSpacing.xl)
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
                            Button("Delete…", systemImage: "trash", role: .destructive) {
                                viewModel.requestDeletionOfSelectedItem()
                            }
                        } label: {
                            Label("More", systemImage: "ellipsis.circle")
                        }
                        .accessibilityIdentifier("toolbar-detail-more")
                    }
                }
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

    // MARK: Metadata

    /// createdAt / updatedAt / lastAccessedAt were tracked from the start but never shown.
    @ViewBuilder
    private func metadataRows(for item: SecretItemEntity) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            metadataRow("Created", value: Self.absoluteFormatter.string(from: item.createdAt))
            metadataRow("Last modified", value: Self.relative(item.updatedAt))
            metadataRow(
                "Last used",
                value: item.lastAccessedAt.map(Self.relative) ?? "Never"
            )
            if item.isArchived {
                metadataRow("Status", value: "Archived")
            }
        }
    }

    // MARK: History

    /// Audit trail for the item. Entries name the kind of change and, at most, a field
    /// label — a secret value never reaches this view.
    @ViewBuilder
    private func historyRows(for item: SecretItemEntity) -> some View {
        let entries = item.orderedChangeHistory
        let visible = entries.prefix(Self.historyPreviewLimit)

        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(visible)) { entry in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: entry.kind.systemImage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 14)
                    Text(entry.kind.title)
                        .font(.caption)
                        .foregroundStyle(.primary)
                    if let detail = entry.detail, !detail.isEmpty {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    Text(Self.relative(entry.changedAt))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .accessibilityElement(children: .combine)
            }

            if entries.count > visible.count {
                Text("+\(entries.count - visible.count) older \(entries.count - visible.count == 1 ? "change" : "changes")")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .accessibilityIdentifier("detail-history")
    }

    /// Enough to see recent activity without turning the detail pane into a log viewer.
    private static let historyPreviewLimit = 8

    private func metadataRow(_ label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 96, alignment: .leading)
            Text(value)
                .font(.caption)
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label): \(value)")
    }

    private static let absoluteFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter
    }()

    private static func relative(_ date: Date) -> String {
        // Within a minute "in 0 seconds" reads oddly; say it plainly.
        guard Date().timeIntervalSince(date) >= 60 else { return "Just now" }
        return relativeFormatter.localizedString(for: date, relativeTo: Date())
    }

    // MARK: Fields

    private func fieldsSectionContent(for item: SecretItemEntity) -> some View {
        VStack(alignment: .leading, spacing: VaultSpacing.l) {
            ForEach(viewModel.visibleSelectedFields) { field in
                FieldRow(
                    field: field,
                    canRevealSecrets: viewModel.container.sessionManager.lockState == .unlocked,
                    isCopied: copiedFieldID == field.id,
                    onCopy: {
                        viewModel.copyField(field)
                        flashCopiedField(field.id)
                    },
                    onOpenURL: { viewModel.openFieldURL(field) },
                    onShowHistory: { viewModel.activeSheet = .itemHistory(item.id) }
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

// MARK: - Linked file

/// The `.env` an item mirrors, and the one-click sync in both directions.
///
/// The workflow this replaces was: open Finder, find the file, open it, select all, copy,
/// come back, edit the item, paste, save — every time the file changed. Nothing polls and
/// nothing writes on its own; the item just knows where it came from.
private struct LinkedFileSection: View {
    @Bindable var viewModel: VaultViewModel
    let item: SecretItemEntity

    @State private var status: LinkedFileStatus = .unlinked
    @State private var isConfirmingWrite = false

    private var supportsLinking: Bool {
        item.type == .envGroup
    }

    var body: some View {
        Group {
            if let link = item.linkedFile {
                linkedContent(link)
            } else if supportsLinking {
                unlinkedPrompt
            }
        }
        .onAppear { refresh() }
        .onChange(of: item.id) { _, _ in refresh() }
        .onChange(of: viewModel.itemsWithOutdatedLinks) { _, _ in refresh() }
    }

    // MARK: Linked

    private func linkedContent(_ link: LinkedFileReference) -> some View {
        VaultSection("Linked file", systemImage: "link", tint: tint) {
            Menu {
                Button("Choose a different file…") {
                    viewModel.chooseLinkedFile(for: item, parsedIntoFields: link.parsedIntoFields)
                    refresh()
                }
                Button("Reveal in Finder") {
                    NSWorkspace.shared.selectFile(link.displayPath, inFileViewerRootedAtPath: "")
                }
                Divider()
                Button("Remove link", role: .destructive) {
                    viewModel.unlinkFile(from: item)
                    refresh()
                }
            } label: {
                Label(link.abbreviatedPath, systemImage: "doc.text")
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            .menuStyle(.borderlessButton)
            .accessibilityIdentifier("linked-file-menu")

            statusRow(link)

            HStack(spacing: VaultSpacing.s) {
                Button {
                    viewModel.updateItemFromLinkedFile(item)
                    refresh()
                } label: {
                    Label("Update from file", systemImage: "arrow.down.doc")
                }
                .disabled(status == .unavailable || status == .upToDate)
                .accessibilityIdentifier("linked-file-pull")

                Button {
                    if status == .diverged || status == .fileChanged {
                        isConfirmingWrite = true
                    } else {
                        write()
                    }
                } label: {
                    Label("Write to file", systemImage: "arrow.up.doc")
                }
                .disabled(status == .unavailable || status == .upToDate)
                .accessibilityIdentifier("linked-file-push")

                Spacer(minLength: 0)
            }
        }
        .confirmationDialog(
            "Overwrite \(link.fileName)?",
            isPresented: $isConfirmingWrite,
            titleVisibility: .visible
        ) {
            Button("Overwrite File", role: .destructive) { write() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("That file has changed since the last sync. Writing replaces its contents with what this item holds.")
        }
    }

    @ViewBuilder
    private func statusRow(_ link: LinkedFileReference) -> some View {
        switch status {
        case .unlinked:
            EmptyView()
        case .upToDate:
            VaultNote(
                text: link.syncedAt.map { "In sync as of \(Self.relative($0))." } ?? "In sync.",
                tone: .success
            )
        case .fileChanged:
            VaultNote(text: "The file on disk has changed. Update to pull the new contents in.", tone: .warning)
        case .vaultChanged:
            VaultNote(text: "This item has changed since the last sync. Write to push it back to the file.", tone: .warning)
        case .diverged:
            VaultNote(text: "Both the file and this item changed since the last sync. Choose which side wins.", tone: .warning)
        case .unavailable:
            VaultNote(
                text: "The file can't be reached — it may have been moved, renamed or deleted. Choose it again from the menu above.",
                tone: .danger
            )
        }
    }

    private var tint: Color {
        switch status {
        case .upToDate: .green
        case .unavailable: .red
        case .fileChanged, .vaultChanged, .diverged: .orange
        case .unlinked: .accentColor
        }
    }

    // MARK: Unlinked

    private var unlinkedPrompt: some View {
        VaultSection("Linked file", systemImage: "link") {
            VaultNote(text: "Link this item to the .env it mirrors, and you can pull in changes with one click instead of copying and pasting.")
            Button {
                viewModel.chooseLinkedFile(for: item, parsedIntoFields: true)
                refresh()
            } label: {
                Label("Link a .env file…", systemImage: "link.badge.plus")
            }
            .accessibilityIdentifier("linked-file-attach")
        }
    }

    // MARK: Helpers

    private func write() {
        viewModel.writeLinkedFile(from: item)
        refresh()
    }

    private func refresh() {
        status = viewModel.linkedFileStatus(for: item)
    }

    private static func relative(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

// MARK: - Field Row

private struct FieldRow: View {
    let field: FieldResolvedValue
    let canRevealSecrets: Bool
    let isCopied: Bool
    let onCopy: () -> Void
    let onOpenURL: () -> Void
    var onShowHistory: (() -> Void)?

    /// Pinned reveal: stays shown after the pointer leaves.
    ///
    /// Hovering reveals on its own — that is the quick, mouse-driven way and it is what the
    /// app has always done. The button exists because hover was the *only* way, which left
    /// keyboard and VoiceOver users unable to read a stored secret at all.
    @State private var isRevealPinned = false
    @State private var isHoveringValue = false

    private var isOpenableURL: Bool {
        field.kind == .url && !field.isSensitive && FieldURLSupport.url(from: field.value) != nil
    }

    private var showsPlaintext: Bool {
        guard field.isSensitive else { return true }
        guard canRevealSecrets else { return false }
        return isRevealPinned || isHoveringValue
    }

    var body: some View {
        VStack(alignment: .leading, spacing: VaultSpacing.s) {
            header

            valueBox

            if isOpenableURL {
                Button(action: onOpenURL) {
                    Label("Open in browser", systemImage: "arrow.up.right.square")
                        .font(.vaultFootnote)
                }
                .buttonStyle(.link)
                .accessibilityIdentifier("detail-field-open-\(field.key)")
            }
        }
        .accessibilityIdentifier("detail-field-\(field.key)")
        // A pinned reveal must not carry over to a value the owner has not asked to see.
        .onChange(of: field.value) { _, _ in isRevealPinned = false }
        .onChange(of: field.id) { _, _ in
            isRevealPinned = false
            isHoveringValue = false
        }
    }

    private var helpText: String {
        switch (field.isCopyable, field.isSensitive && canRevealSecrets) {
        case (true, true): "Hover to show, click to copy"
        case (true, false): "Click to copy"
        case (false, true): "Hover to show"
        case (false, false): ""
        }
    }

    private var header: some View {
        HStack(spacing: VaultSpacing.xs) {
            Text(field.label)
                .font(.vaultFieldLabel)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("field-label-\(field.key)")

            if field.isSensitive {
                Image(systemName: "lock.fill")
                    .font(.system(size: 8))
                    .foregroundStyle(.tertiary)
                    .accessibilityLabel("Sensitive")
            }

            Spacer(minLength: VaultSpacing.s)

            if field.isSensitive, canRevealSecrets {
                Button {
                    isRevealPinned.toggle()
                } label: {
                    Image(systemName: isRevealPinned ? "eye.slash" : "eye")
                }
                .buttonStyle(VaultIconButtonStyle(isActive: isRevealPinned))
                .help(isRevealPinned ? "Hide value" : "Keep value shown")
                .accessibilityLabel(isRevealPinned ? "Hide \(field.label)" : "Show \(field.label)")
                .accessibilityIdentifier("detail-field-reveal-\(field.key)")
            }

            if let onShowHistory, !field.previousValues.isEmpty {
                Button(action: onShowHistory) {
                    Image(systemName: "clock.arrow.circlepath")
                }
                .buttonStyle(VaultIconButtonStyle())
                .help("\(field.previousValues.count) previous \(field.previousValues.count == 1 ? "value" : "values")")
                .accessibilityLabel("Previous values for \(field.label)")
                .accessibilityIdentifier("detail-field-history-\(field.key)")
            }

            if field.isCopyable {
                Button(action: onCopy) {
                    Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(VaultIconButtonStyle(isActive: isCopied))
                .help("Copy \(field.label)")
                .accessibilityLabel("Copy \(field.label)")
                .accessibilityIdentifier("detail-field-copy-\(field.key)")
            }
        }
    }

    private var valueBox: some View {
        VaultValueBox(isHighlighted: isCopied) {
            valueText
                .font(.vaultValue)
                .foregroundStyle(showsPlaintext ? .primary : .secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .multilineTextAlignment(.leading)
                .lineLimit(valueLineLimit)
                .fixedSize(horizontal: false, vertical: true)
        }
        .contentShape(Rectangle())
        .onTapGesture { if field.isCopyable { onCopy() } }
        .onHover { hovering in
            if field.isSensitive, canRevealSecrets {
                isHoveringValue = hovering
            }
            guard field.isCopyable else { return }
            if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
        .help(helpText)
        .accessibilityIdentifier("detail-field-value-\(field.key)")
        .accessibilityLabel("\(field.label): \(showsPlaintext ? "shown" : "hidden")")
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: isCopied)
    }

    @ViewBuilder
    private var valueText: some View {
        if showsPlaintext {
            Text(displayText)
                .textSelection(.enabled)
        } else {
            Text(displayText)
        }
    }

    private var valueLineLimit: Int {
        switch field.kind {
        case .json, .multiline: 8
        default: 4
        }
    }

    private var displayText: String {
        guard showsPlaintext else { return SecretMasking.mask }
        let raw = TemplatePickerFieldDisplay.presentationValue(fieldKey: field.key, stored: field.value)
        guard needsSoftWrap(raw) else { return raw }
        return Self.insertSoftBreakOpportunities(raw)
    }

    /// Only long unbroken runs need help wrapping.
    ///
    /// The previous version inserted a zero-width space between *every* character of *every*
    /// sensitive value on every render — quadratic-ish work on long private keys, and VoiceOver
    /// read the result one letter at a time.
    private func needsSoftWrap(_ value: String) -> Bool {
        guard value.count > 40 else { return false }
        return !value.contains(where: { $0 == " " || $0.isNewline })
    }

    /// Breaks every 24 characters rather than every 1.
    private static func insertSoftBreakOpportunities(_ string: String) -> String {
        var result = ""
        result.reserveCapacity(string.count + string.count / 24)
        for (index, character) in string.enumerated() {
            if index > 0, index % 24 == 0 { result.append("\u{200B}") }
            result.append(character)
        }
        return result
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
                settings: viewModel.container.settings
            )
                .frame(maxWidth: 400)
                .padding(VaultSpacing.xxl)
        }
    }
}

private struct LockedVaultView: View {
    @Bindable var sessionManager: VaultSessionManager
    @Bindable var settings: AppSettingsStore

    @State private var password = ""
    @State private var isConfirmingReset = false
    /// Set once per locked session so the automatic prompt does not re-fire in a loop when
    /// the Touch ID sheet itself hands focus back to the window.
    @State private var didAttemptAutomaticUnlock = false
    @FocusState private var isPasswordFocused: Bool

    @Environment(\.controlActiveState) private var controlActiveState

    private var isSetup: Bool { sessionManager.lockState == .setupRequired }

    private var showTouchIDBadge: Bool {
        sessionManager.lockState == .locked
            && sessionManager.isBiometricAvailable
            && settings.biometricsEnabled
    }

    var body: some View {
        VStack(spacing: VaultSpacing.xl) {
            icon

            VStack(spacing: VaultSpacing.xs) {
                Text(isSetup ? "Create Your Password" : "PassStore is Locked")
                    .font(.title2.weight(.semibold))
                Text(isSetup
                     ? "Set a master password to protect your secrets."
                     : "Unlock with Touch ID, or enter your master password.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: VaultSpacing.m) {
                SecureField(isSetup ? "New master password" : "Master password", text: $password)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.large)
                    .frame(width: 300)
                    .focused($isPasswordFocused)
                    .disabled(sessionManager.isBusy)
                    .onSubmit { submit() }
                    .accessibilityIdentifier("lock-password-field")

                statusLine

                actions
            }

            if !isSetup {
                Button("Forgot your master password?") { isConfirmingReset = true }
                    .buttonStyle(.link)
                    .font(.vaultFootnote)
                    .accessibilityIdentifier("lock-forgot-password")
            }
        }
        .padding(VaultSpacing.xxl)
        .onAppear {
            focusOrAuthenticate()
        }
        // Coming back to PassStore from another app should raise the prompt again, which is
        // the whole point of not having to reach for the mouse. Leaving is what re-arms it
        // after a manual lock.
        .onChange(of: controlActiveState) { _, newValue in
            guard newValue != .inactive else {
                sessionManager.allowAutomaticUnlockOnNextActivation()
                didAttemptAutomaticUnlock = false
                return
            }
            focusOrAuthenticate()
        }
        // Locking deliberately does *not* authenticate: it just puts the caret where the
        // owner would type if they change their mind.
        .onChange(of: sessionManager.lockState) { _, newValue in
            guard newValue != .unlocked else { return }
            isPasswordFocused = true
        }
        .confirmationDialog(
            "Erase this vault and start over?",
            isPresented: $isConfirmingReset,
            titleVisibility: .visible
        ) {
            Button("Erase Vault", role: .destructive) {
                sessionManager.resetVaultDestroyingAllData()
                password = ""
            }
            .accessibilityIdentifier("lock-confirm-reset")
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("There is no way to recover a forgotten master password — your secrets are encrypted with it. Erasing deletes every stored item on this Mac and lets you set up a new vault. If you have a .pstore backup you can restore it afterwards.")
        }
    }

    // MARK: Pieces

    private var icon: some View {
        appLockHeaderImage
            .frame(width: 96, height: 96)
            .clipShape(RoundedRectangle(cornerRadius: VaultRadius.hero, style: .continuous))
            .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
            .overlay(alignment: .bottomTrailing) {
                if showTouchIDBadge {
                    Image("touch_id")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 28, height: 28)
                        .padding(5)
                        .background(Circle().fill(Color.white))
                        .overlay(Circle().strokeBorder(Color.black.opacity(0.08), lineWidth: 0.5))
                        .offset(x: 4, y: 4)
                        .accessibilityHidden(true)
                }
            }
    }

    @ViewBuilder
    private var statusLine: some View {
        if sessionManager.isBusy {
            HStack(spacing: VaultSpacing.s) {
                ProgressView()
                    .controlSize(.small)
                Text(isSetup ? "Creating your vault…" : "Unlocking…")
                    .font(.vaultFootnote)
                    .foregroundStyle(.secondary)
            }
            .accessibilityIdentifier("lock-busy")
        } else if let message = sessionManager.lastErrorMessage, !message.isEmpty {
            Text(message)
                .foregroundStyle(.red)
                .font(.vaultFootnote)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("lock-error")
        } else if isSetup {
            PasswordStrengthBar(password: password)
                .frame(width: 300)
        }
    }

    private var actions: some View {
        HStack(spacing: VaultSpacing.m) {
            // The default action and the visually prominent button are the same button now.
            // They used to be different ones, so Return did not do what the UI implied.
            Button(isSetup ? "Create Password" : "Unlock") { submit() }
                .buttonStyle(VaultButtonStyle(.primary))
                .keyboardShortcut(.defaultAction)
                .disabled(password.isEmpty || sessionManager.isBusy)
                .accessibilityIdentifier("lock-submit")

            if sessionManager.lockState == .locked, sessionManager.isBiometricAvailable {
                Button("Use Touch ID") {
                    Task { await sessionManager.unlockWithBiometrics() }
                }
                .buttonStyle(VaultButtonStyle(.secondary))
                .disabled(sessionManager.isBusy)
                .accessibilityIdentifier("lock-biometrics")
            }
        }
    }

    // MARK: Behaviour

    /// Raises Touch ID by itself when it can succeed, and otherwise puts the caret where the
    /// owner is about to type. Previously the field never took focus, so every single unlock
    /// started with a mouse click.
    ///
    /// `shouldOfferAutomaticUnlock` is false right after a lock the owner asked for, so
    /// locking does not immediately offer to unlock again.
    private func focusOrAuthenticate() {
        guard sessionManager.lockState != .unlocked else { return }

        if settings.unlocksWithBiometricsAutomatically,
           !didAttemptAutomaticUnlock,
           sessionManager.shouldOfferAutomaticUnlock {
            didAttemptAutomaticUnlock = true
            Task {
                let unlocked = await sessionManager.unlockWithBiometrics()
                if !unlocked { isPasswordFocused = true }
            }
            return
        }

        isPasswordFocused = true
    }

    private func submit() {
        guard !password.isEmpty, !sessionManager.isBusy else { return }
        let entered = password
        password = ""
        Task {
            if sessionManager.lockState == .setupRequired {
                await sessionManager.createVault(password: entered)
            } else {
                await sessionManager.unlockWithPassword(entered)
            }
            if sessionManager.lockState != .unlocked {
                isPasswordFocused = true
            }
        }
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

// MARK: - Preview

#Preview("App") {
    AppView(viewModel: VaultViewModel(container: .preview()))
}

// MARK: - Utilities

private extension View {
    /// Layout for an AppKit-backed reorderable table hosted inside a SwiftUI sidebar `List`.
    ///
    /// This stack of insets and offsets used to be copy-pasted into all five sidebar
    /// sections, drifting slightly in each. One place now owns the geometry.
    func sidebarSectionRows(count: Int) -> some View {
        frame(height: CGFloat(count) * ReorderableRows.rowHeight + 40)
            .listRowInsets(EdgeInsets(top: -14, leading: -20, bottom: 0, trailing: -20))
            .transformEffect(CGAffineTransform(translationX: 0, y: -10))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
    }
}

private func uiIdentifierSlug(_ value: String) -> String {
    value
        .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        .replacingOccurrences(of: "[^a-zA-Z0-9]+", with: "-", options: .regularExpression)
        .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        .lowercased()
}
