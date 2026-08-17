import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct AppView: View {
    @Bindable var viewModel: VaultViewModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.controlActiveState) private var controlActiveState
    @State private var showOnboarding = false

    /// Bridges the split view's three-way column state onto the single "is the sidebar
    /// showing?" flag the View menu also drives. `.doubleColumn` keeps the item list; only
    /// the sidebar goes away.
    private var sidebarVisibility: Binding<NavigationSplitViewVisibility> {
        Binding(
            get: { viewModel.isSidebarVisible ? .all : .doubleColumn },
            set: { viewModel.isSidebarVisible = ($0 == .all) }
        )
    }

    var body: some View {
        ZStack {
            NavigationSplitView(columnVisibility: sidebarVisibility) {
                // The system sidebar toggle is kept: it sits where every other Mac app puts
                // it, at the head of the sidebar's own toolbar area. On a locked vault it is
                // removed on its own rather than by hiding the toolbar — hiding the whole
                // window toolbar collapses the title bar with it, and takes the close and
                // minimise buttons away on the one screen you might well want them on.
                SidebarView(viewModel: viewModel)
                    .navigationSplitViewColumnWidth(min: 196, ideal: 220, max: 260)
                    .modifier(HiddenSidebarToggle(isHidden: isVaultLocked || showOnboarding))
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
                    environmentTitlesInUse: viewModel.presentEnvironmentTitles(inWorkspace: workspaceID),
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
        .onChange(of: viewModel.container.sessionManager.lockState) { _, newValue in
            switch newValue {
            case .unlocked:
                // Defer past the unlock layout pass (overlay + toolbar) to avoid AppKit toolbar / split-view glitches.
                Task { @MainActor in
                    await Task.yield()
                    viewModel.reload()
                }
            case .locked:
                // Sensitive view-model state is cleared synchronously by the session's lock
                // callback, including when this window is closed.
                break
            case .setupRequired:
                // Reached by erasing the vault. Setting up again is the same job a new arrival
                // has, restoring a backup included, so it gets the same guided flow instead of
                // a bare "create a password" box.
                withAnimation(.easeOut(duration: 0.3)) { showOnboarding = true }
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
            MainWindowPresenter.setOpenAction { openWindow(id: PassStoreScene.mainWindowID) }
            Task { await viewModel.refreshLinkedFileStatuses() }
        }
        // Coming back from an editor is exactly when a linked `.env` is likely to have
        // changed, so that is when PassStore looks — no watcher, no background work.
        .onChange(of: controlActiveState) { _, newValue in
            guard newValue != .inactive else { return }
            Task { await viewModel.refreshLinkedFileStatuses() }
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
                        let rows = workspaceRows
                        ReorderableRows(
                            items: rows,
                            selectedID: selectedWorkspaceRowID,
                            onSelect: { rowID in
                                guard let rowID, let route = WorkspaceRowID(rowID) else { return }
                                switch route {
                                case let .workspace(id):
                                    viewModel.selectDestination(.workspace(id))
                                case let .environment(id, title):
                                    viewModel.selectDestination(.workspaceEnvironment(id, title))
                                }
                                viewModel.setSelectedType(nil)
                            },
                            onReorder: { ids in
                                viewModel.reorderWorkspaces(newIDs: ids.compactMap {
                                    if case let .workspace(id) = WorkspaceRowID($0) { return id }
                                    return nil
                                })
                            },
                            contextActions: { rowID in workspaceRowActions(for: rowID) },
                            onToggleExpansion: { rowID in
                                guard case let .workspace(id) = WorkspaceRowID(rowID) else { return }
                                if settings.expandedWorkspaceIDs.contains(id) {
                                    settings.expandedWorkspaceIDs.remove(id)
                                } else {
                                    settings.expandedWorkspaceIDs.insert(id)
                                }
                            }
                        )
                    .sidebarSectionRows(count: rows.count)
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
                                viewModel.reorderSidebarTags(ids)
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
                                viewModel.reorderSidebarEnvironments(ids)
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


    // MARK: Workspace rows

    /// Workspaces, each optionally followed by its environments.
    ///
    /// The list stays flat and the children are ordinary rows drawn one indent in, which is what
    /// keeps drag-to-reorder working: only top-level rows can be picked up, and only they have
    /// an order to change.
    private var workspaceRows: [SidebarReorderItem] {
        // Reserved for the whole section as soon as one workspace can expand, so names do not
        // shift sideways as projects gain and lose environments.
        let reservesDisclosureSpace = viewModel.workspaces.contains {
            viewModel.hasEnvironmentStructure(inWorkspace: $0.id)
        }
        return viewModel.workspaces.flatMap { workspace -> [SidebarReorderItem] in
            let count = viewModel.itemCount(inWorkspace: workspace.id)
            let slug = uiIdentifierSlug(workspace.name)
            let hasEnvironments = viewModel.hasEnvironmentStructure(inWorkspace: workspace.id)
            let isExpanded = settings.expandedWorkspaceIDs.contains(workspace.id)
            let parent = SidebarReorderItem(
                id: WorkspaceRowID.workspace(workspace.id).raw,
                title: workspace.name,
                systemImage: workspace.icon,
                tintColor: NSColor(hex: workspace.colorHex),
                badge: count > 0 ? "\(count)" : nil,
                accessibilityIdentifier: "sidebar-workspace-\(slug)",
                isExpanded: hasEnvironments ? isExpanded : nil,
                reservesDisclosureSpace: reservesDisclosureSpace
            )
            guard hasEnvironments, isExpanded else { return [parent] }

            return [parent] + viewModel.offeredEnvironments(inWorkspace: workspace.id).map { environment in
                let environmentCount = viewModel.itemCount(
                    inWorkspace: workspace.id,
                    environmentMatchKey: environment.matchKey
                )
                return SidebarReorderItem(
                    id: WorkspaceRowID.environment(workspace.id, environment.title).raw,
                    title: environment.title,
                    // Dashed rather than merely paler, so a switched-off environment reads as
                    // switched off without depending on colour.
                    systemImage: environment.isEnabled ? "circle.fill" : "circle.dashed",
                    tintColor: NSColor(hex: environment.colorHex),
                    badge: environmentCount > 0 ? "\(environmentCount)" : nil,
                    accessibilityIdentifier: "sidebar-workspace-\(slug)-environment-\(uiIdentifierSlug(environment.title))",
                    indentationLevel: 1,
                    isDraggable: false,
                    isDimmed: !environment.isEnabled,
                    reservesDisclosureSpace: reservesDisclosureSpace
                )
            }
        }
    }

    private var selectedWorkspaceRowID: String? {
        guard viewModel.selectedType == nil else { return nil }
        switch viewModel.selectedDestination {
        case let .workspace(id):
            return WorkspaceRowID.workspace(id).raw
        case let .workspaceEnvironment(id, title):
            // Resolved through the workspace's own list so a destination that names the
            // environment slightly differently still highlights its row.
            let key = WorkspaceEnvironment.matchKey(for: title)
            let resolved = viewModel.environments(inWorkspace: id).first { $0.matchKey == key }
            return WorkspaceRowID.environment(id, resolved?.title ?? title).raw
        case .library, .tag, .environment:
            return nil
        }
    }

    private func workspaceRowActions(for rowID: String) -> [SidebarRowAction] {
        switch WorkspaceRowID(rowID) {
        case let .workspace(id):
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
        case let .environment(id, title):
            let key = WorkspaceEnvironment.matchKey(for: title)
            let environment = viewModel.environments(inWorkspace: id).first { $0.matchKey == key }
            var actions = [
                SidebarRowAction(title: "New Secret Item Here…") {
                    viewModel.selectDestination(.workspaceEnvironment(id, title))
                    viewModel.setSelectedType(nil)
                    viewModel.activeSheet = .newItemFlow
                }
            ]
            if let environment {
                if environment.isDeclared {
                    actions.append(
                        SidebarRowAction(title: environment.isEnabled ? "Switch Off" : "Switch On") {
                            viewModel.setEnvironmentEnabled(!environment.isEnabled, matchKey: key, inWorkspace: id)
                        }
                    )
                } else {
                    actions.append(
                        SidebarRowAction(title: "Add to Project") {
                            viewModel.declareEnvironment(environment, inWorkspace: id)
                        }
                    )
                }
            }
            actions.append(
                SidebarRowAction(title: "Edit Workspace…") {
                    viewModel.activeSheet = .editWorkspace(id)
                }
            )
            return actions
        case nil:
            return []
        }
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

/// Identity of a row in the Workspaces section: the workspace itself, or one of its
/// environments.
///
/// Encoded as a string because the underlying list is a flat AppKit table keyed by string ids.
/// The workspace id occupies a fixed 36 characters, so an environment name is free to contain
/// anything at all — including the separator.
private enum WorkspaceRowID {
    case workspace(UUID)
    case environment(UUID, String)

    private static let environmentMarker = "|env|"

    init?(_ raw: String) {
        guard raw.count >= 36, let id = UUID(uuidString: String(raw.prefix(36))) else { return nil }
        let remainder = String(raw.dropFirst(36))
        if remainder.isEmpty {
            self = .workspace(id)
        } else if remainder.hasPrefix(Self.environmentMarker) {
            self = .environment(id, String(remainder.dropFirst(Self.environmentMarker.count)))
        } else {
            return nil
        }
    }

    var raw: String {
        switch self {
        case let .workspace(id):
            id.uuidString
        case let .environment(id, title):
            "\(id.uuidString)\(Self.environmentMarker)\(title)"
        }
    }
}

// MARK: - Item List

private struct ItemListView: View {
    @Bindable var viewModel: VaultViewModel
    private enum FocusArea: Hashable { case search, list }
    @FocusState private var focusedArea: FocusArea?

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
                    // Deliberately no `selection:` binding. AppKit draws that highlight as a
                    // solid fill of the accent colour and there is no public way to restyle
                    // it — against a yellow accent it swamped the workspace chips, and it
                    // painted straight over the row's own background. Selection is drawn and
                    // handled here instead; ⌘-click, ⇧-click ranges and ⌥↑/⌥↓ all still work.
                    List {
                        ForEach(viewModel.filteredItems, id: \.id) { item in
                            ItemRow(viewModel: viewModel, item: item) {
                                focusedArea = .list
                            }
                                .listRowBackground(rowBackground(for: item))
                        }
                    }
                    .listStyle(.inset)
                    .focusable()
                    .focused($focusedArea, equals: .list)
                    .accessibilityIdentifier("item-list")
                }

                if viewModel.isMultiSelecting {
                    MultiSelectionBar(viewModel: viewModel)
                } else if let message = viewModel.lastActionMessage {
                    StatusFooter(message: message, viewModel: viewModel)
                }
            }
            .itemListKeyboardShortcuts(
                isEnabled: {
                    viewModel.container.sessionManager.lockState == .unlocked
                        && viewModel.activeSheet == nil
                        && !viewModel.isSettingsPresented
                        && !viewModel.isCommandPalettePresented
                        // Anywhere but the search field: requiring the list to hold focus
                        // meant the arrows did nothing until a row had been clicked, which is
                        // exactly the state you are in right after unlocking.
                        && focusedArea != .search
                },
                onMove: { viewModel.moveSelection(by: $0) },
                onEscape: {
                    guard viewModel.isMultiSelecting else { return false }
                    viewModel.clearMultiSelection()
                    return true
                }
            )
            .onChange(of: viewModel.searchFocusRequests) { _, _ in
                focusedArea = .search
            }
            // No subtitle: "Favorites" does not need "Pinned secrets you reach for often"
            // under it, and the strap line only pushed the list down.
            .navigationTitle(isVaultLocked ? "" : viewModel.destinationTitle)
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
            if viewModel.isSortOrderFixedByDestination {
                // Offering "Name" here would be a lie: Recent is defined by its order.
                Text("Recent is always sorted by last used")
            }
            Picker("Sort by", selection: $viewModel.sortOrder) {
                ForEach(ItemSortOrder.allCases) { order in
                    Label(order.title, systemImage: order.systemImage).tag(order)
                }
            }
            .pickerStyle(.inline)
            .disabled(viewModel.isSortOrderFixedByDestination)
        } label: {
            Label("Sort", systemImage: "arrow.up.arrow.down")
        }
        .help(viewModel.isSortOrderFixedByDestination
              ? "Recent is always sorted by last used"
              : "Sort the list")
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
                    .buttonStyle(VaultButtonStyle(.primary))
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
                .buttonStyle(VaultButtonStyle(.primary))
            }
        }
    }

    private var listHeader: some View {
        VStack(alignment: .leading, spacing: VaultSpacing.s) {
            searchField

            if let workspaceID = viewModel.environmentBarWorkspaceID {
                EnvironmentTabBar(viewModel: viewModel, workspaceID: workspaceID)
            }

            if viewModel.hasActiveFilters {
                activeFilters
            }

            HStack(spacing: VaultSpacing.xs) {
                Text("\(viewModel.filteredItems.count) item\(viewModel.filteredItems.count == 1 ? "" : "s")")
                    .font(.vaultBadge)
                    // `.tertiary` on this size failed contrast; secondary is legible and still quiet.
                    .foregroundStyle(.secondary)

                // The order actually in effect, which is not always the one chosen: Recent
                // sorts itself.
                if viewModel.effectiveSortOrder != .title {
                    Text("· \(viewModel.effectiveSortOrder.title.lowercased())")
                        .font(.vaultBadge)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)

                if viewModel.outdatedLinkedFileCount > 0 {
                    Label("\(viewModel.outdatedLinkedFileCount)", systemImage: "arrow.down.doc")
                        .font(.vaultBadge)
                        .foregroundStyle(.orange)
                        .help("\(viewModel.outdatedLinkedFileCount) linked .env \(viewModel.outdatedLinkedFileCount == 1 ? "file needs" : "files need") attention")
                        .accessibilityIdentifier("outdated-links-badge")
                }
            }
        }
        .padding(.horizontal, VaultSpacing.m)
        .padding(.top, VaultSpacing.s)
        .padding(.bottom, VaultSpacing.s)
    }

    /// A soft wash of the item's workspace colour, so a selected row still reads as belonging
    /// to that workspace and anything drawn on top of it stays legible.
    @ViewBuilder
    private func rowBackground(for item: SecretItemEntity) -> some View {
        let isSelected = viewModel.isSelected(item)
        let tint = item.workspace.map { Color(hex: $0.colorHex) } ?? Color.accentColor

        if isSelected {
            RoundedRectangle(cornerRadius: VaultRadius.control - 1, style: .continuous)
                .fill(tint.opacity(0.16))
                .overlay(
                    RoundedRectangle(cornerRadius: VaultRadius.control - 1, style: .continuous)
                        .strokeBorder(tint.opacity(0.35), lineWidth: 1)
                )
                .padding(.horizontal, 2)
        } else {
            Color.clear
        }
    }

    /// Filters that are on but have no visible control of their own.
    ///
    /// A type picked in the sidebar stays on when you move to another workspace or section,
    /// so the list could look mysteriously short — the header named the destination and said
    /// nothing about the filter narrowing it.
    private var activeFilters: some View {
        HStack(spacing: VaultSpacing.xs) {
            if let type = viewModel.selectedType {
                filterChip(title: type.title, systemImage: type.systemImage) {
                    viewModel.setSelectedType(nil)
                }
                .accessibilityIdentifier("active-filter-type")
            }

            Spacer(minLength: 0)

            Button("Clear") { viewModel.clearFilters() }
                .buttonStyle(.plain)
                .font(.vaultBadge)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("active-filter-clear")
        }
    }

    private func filterChip(title: String, systemImage: String, onRemove: @escaping () -> Void) -> some View {
        HStack(spacing: VaultSpacing.xs) {
            Image(systemName: systemImage)
                .font(.caption2)
            Text(title)
                .font(.vaultBadge)
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
            }
            .buttonStyle(.plain)
        }
        // Primary text on a tinted capsule: the brand yellow is far too light to be readable
        // as text on a near-white background.
        .foregroundStyle(.primary)
        .padding(.horizontal, VaultSpacing.s)
        .padding(.vertical, 3)
        .background(
            Capsule(style: .continuous)
                .fill(Color.accentColor.opacity(0.22))
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Filter: \(title). Activate to remove.")
    }

    private var searchField: some View {
        HStack(spacing: VaultSpacing.xs) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.caption)
            TextField("Search", text: $viewModel.searchText)
                .textFieldStyle(.plain)
                .font(.callout)
                .focused($focusedArea, equals: .search)
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

/// The environment tabs shown above a workspace's item list.
///
/// The sidebar tree can already reach every environment; this exists because switching between
/// them is the thing you do constantly once a workspace is a project, and a row of tabs is one
/// click away wherever the sidebar happens to be scrolled — or hidden.
private struct EnvironmentTabBar: View {
    @Bindable var viewModel: VaultViewModel
    let workspaceID: UUID

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: VaultSpacing.xs) {
                tab(
                    title: "All",
                    count: viewModel.itemCount(inWorkspace: workspaceID),
                    color: .secondary,
                    isSelected: viewModel.selectedEnvironmentMatchKey == nil,
                    isDimmed: false,
                    identifier: "environment-tab-all"
                ) {
                    viewModel.selectEnvironment(matchKey: nil)
                }

                ForEach(viewModel.environmentBarItems) { environment in
                    tab(
                        title: environment.title,
                        count: viewModel.itemCount(
                            inWorkspace: workspaceID,
                            environmentMatchKey: environment.matchKey
                        ),
                        color: Color(hex: environment.colorHex),
                        isSelected: viewModel.selectedEnvironmentMatchKey == environment.matchKey,
                        isDimmed: !environment.isEnabled,
                        identifier: "environment-tab-\(uiIdentifierSlug(environment.title))"
                    ) {
                        viewModel.selectEnvironment(matchKey: environment.matchKey)
                    }
                }
            }
            .padding(.vertical, 1)
        }
        .scrollIndicators(.never)
        .accessibilityIdentifier("environment-tab-bar")
    }

    private func tab(
        title: String,
        count: Int,
        color: Color,
        isSelected: Bool,
        isDimmed: Bool,
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: VaultSpacing.xs) {
                Text(title)
                    .font(.caption)
                    .fontWeight(isSelected ? .semibold : .medium)
                if count > 0 {
                    Text("\(count)")
                        .font(.vaultBadge)
                        .foregroundStyle(isSelected ? AnyShapeStyle(color) : AnyShapeStyle(.tertiary))
                }
            }
            .foregroundStyle(isSelected ? AnyShapeStyle(color) : AnyShapeStyle(isDimmed ? .tertiary : .secondary))
            .padding(.horizontal, VaultSpacing.s)
            .padding(.vertical, VaultSpacing.xs)
            .background(
                Capsule(style: .continuous)
                    .fill(isSelected ? color.opacity(0.14) : Color.primary.opacity(0.05))
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(
                        isSelected ? color.opacity(0.35) : Color.primary.opacity(0.08),
                        // Dashed for a switched-off environment that is still shown because it
                        // holds items, so "off" does not rely on colour alone.
                        style: StrokeStyle(lineWidth: 0.6, dash: isDimmed ? [3, 2] : [])
                    )
            )
        }
        .buttonStyle(.plain)
        .help(isDimmed ? "\(title) — switched off, still holds items" : "Show \(title)")
        .accessibilityIdentifier(identifier)
    }
}

private struct ItemRow: View {
    @Bindable var viewModel: VaultViewModel
    let item: SecretItemEntity
    let onActivateList: () -> Void

    @State private var isHovering = false
    @State private var didCopy = false

    /// The field a quick-copy should reach for: the password, or failing that the first
    /// sensitive value.
    private var quickCopyField: FieldResolvedValue? {
        viewModel.primaryCopyField(for: item)
    }

    var body: some View {
        Button(action: handleClick) {
            rowContent
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("item-row-\(uiIdentifierSlug(item.title))")
        .contextMenu {
            if viewModel.multiSelectedIDs.count > 1 && viewModel.multiSelectedIDs.contains(item.id) {
                multiSelectionContextMenu
            } else {
                singleItemContextMenu
            }
        }
    }

    /// Plain click selects, ⌘ toggles, ⇧ extends — the modifiers a Mac list is expected to
    /// honour, handled here because the row owns its own selection.
    private func handleClick() {
        onActivateList()
        let flags = NSEvent.modifierFlags
        if flags.contains(.shift) {
            viewModel.extendSelection(to: item)
        } else if flags.contains(.command) {
            viewModel.toggleMultiSelect(item)
        } else {
            viewModel.select(item)
        }
    }

    private var rowContent: some View {
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
        Button("View History…", systemImage: "clock.arrow.circlepath") {
            viewModel.select(item)
            viewModel.activeSheet = .itemHistory(item.id)
        }
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

// MARK: - List keyboard handling

/// Bare ↑ / ↓ / Escape for the item list.
///
/// SwiftUI's `onKeyPress` only fires for a focused view, and the list deliberately no longer
/// owns an AppKit selection — that is what was painting a solid accent block over every
/// selected row. A local monitor gives the keys back without that, and without the menu-level
/// key equivalents that would steal arrows and Escape from every text field in the app.
private struct ItemListKeyboardShortcuts: ViewModifier {
    /// Read at event time rather than captured, so the monitor can be installed once and
    /// still respect state that changes while it is running.
    let isEnabled: () -> Bool
    let onMove: (Int) -> Void
    let onEscape: () -> Bool

    @State private var monitor: Any?

    private enum Key {
        static let upArrow: UInt16 = 126
        static let downArrow: UInt16 = 125
        static let escape: UInt16 = 53
    }

    func body(content: Content) -> some View {
        content
            .onAppear { install() }
            .onDisappear { remove() }
    }

    private func install() {
        remove()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard isEnabled(), Self.isAddressedToTheList(event) else { return event }
            switch event.keyCode {
            case Key.upArrow:
                onMove(-1)
                return nil
            case Key.downArrow:
                onMove(1)
                return nil
            case Key.escape:
                return onEscape() ? nil : event
            default:
                return event
            }
        }
    }

    private func remove() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    /// True only for a key press nothing else is entitled to.
    private static func isAddressedToTheList(_ event: NSEvent) -> Bool {
        // Only the chord modifiers disqualify an event. Testing the whole
        // `deviceIndependentFlagsMask` looked equivalent but was not: macOS sets `.function`
        // and `.numericPad` on every arrow key, so that check rejected all of them and the
        // arrows never reached the list.
        let chordModifiers: NSEvent.ModifierFlags = [.command, .option, .control, .shift]
        guard event.modifierFlags.intersection(chordModifiers).isEmpty else { return false }
        guard let window = event.window, window.attachedSheet == nil else { return false }
        // Typing anywhere keeps its own arrow and Escape behaviour. A focused `TextField`
        // reports its field editor, which is an `NSTextView`.
        if window.firstResponder is NSTextView { return false }
        return true
    }
}

private extension View {
    func itemListKeyboardShortcuts(
        isEnabled: @escaping () -> Bool,
        onMove: @escaping (Int) -> Void,
        onEscape: @escaping () -> Bool
    ) -> some View {
        modifier(ItemListKeyboardShortcuts(isEnabled: isEnabled, onMove: onMove, onEscape: onEscape))
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

// MARK: - Workspace overview

/// What the detail pane shows when you are standing in a workspace with nothing selected.
///
/// That pane used to spend its whole width asking for a click. Once a workspace is a project it
/// is the natural place to describe one: which environments it has and how much is in each, what
/// mirrors a file on disk, and the two or three things you are most likely to do next.
private struct WorkspaceOverviewView: View {
    @Bindable var viewModel: VaultViewModel
    let workspace: WorkspaceEntity

    private var accent: Color { Color(hex: workspace.colorHex) }

    private var environments: [ResolvedWorkspaceEnvironment] {
        viewModel.environments(inWorkspace: workspace.id)
    }

    private var itemCount: Int { viewModel.itemCount(inWorkspace: workspace.id) }

    var body: some View {
        VStack(spacing: 0) {
            header

            ScrollView {
                VStack(alignment: .leading, spacing: VaultSpacing.xl) {
                    environmentsSection
                    linkedFilesSection
                    actionsSection

                    if !workspace.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        VaultSection("Notes", systemImage: "note.text") {
                            Text(workspace.notes)
                                .font(.body)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .multilineTextAlignment(.leading)
                        }
                    }
                }
                .padding(VaultSpacing.xl)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityIdentifier("workspace-overview-\(uiIdentifierSlug(workspace.name))")
    }

    // MARK: Header

    private var header: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: VaultSpacing.l) {
                icon

                VStack(alignment: .leading, spacing: VaultSpacing.xs) {
                    Text("Workspace")
                        .font(.vaultBadge)
                        .foregroundStyle(.secondary)

                    Text(workspace.name)
                        .font(.title3.weight(.semibold))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .multilineTextAlignment(.leading)
                        .accessibilityIdentifier("workspace-overview-title")

                    Text(summary)
                        .font(.vaultFootnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .multilineTextAlignment(.leading)
                }
            }
            .padding(.horizontal, VaultSpacing.xl)
            .padding(.vertical, VaultSpacing.l)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(banner)

            Rectangle()
                .fill(VaultChrome.hairline)
                .frame(height: 1)
        }
    }

    private var summary: String {
        var parts = ["\(itemCount) \(itemCount == 1 ? "secret" : "secrets")"]
        if environments.count > 1 {
            parts.append("\(environments.count) environments")
        }
        if let updated = viewModel.lastUpdatedAt(inWorkspace: workspace.id) {
            parts.append("updated \(Self.relative(updated))")
        }
        return parts.joined(separator: " · ")
    }

    private var banner: some View {
        ZStack {
            LinearGradient(
                colors: [accent.opacity(0.20), accent.opacity(0.04)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            VaultPixelGrid(
                tint: accent,
                spacing: 11,
                dot: 1.5,
                maxAlpha: 0.30,
                baseAlpha: 0.03,
                focus: UnitPoint(x: 0.12, y: 0.35),
                framesPerSecond: 8
            )
        }
        .accessibilityHidden(true)
    }

    private var icon: some View {
        let shape = RoundedRectangle(cornerRadius: VaultRadius.hero, style: .continuous)
        return shape
            .fill(accent)
            .overlay(
                LinearGradient(
                    colors: [.white.opacity(0.32), .white.opacity(0.04), .black.opacity(0.14)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .clipShape(shape)
            )
            .overlay(shape.strokeBorder(.white.opacity(0.22), lineWidth: 0.5))
            .frame(width: 50, height: 50)
            .shadow(color: accent.opacity(0.40), radius: 9, y: 4)
            .overlay(
                Image(systemName: workspace.icon)
                    .font(.system(size: 21, weight: .semibold))
                    .foregroundStyle(accent.vaultContrastingGlyph)
            )
            .accessibilityHidden(true)
    }

    // MARK: Environments

    @ViewBuilder
    private var environmentsSection: some View {
        VaultSection("Environments", systemImage: "circle.hexagongrid", tint: accent) {
            Button("Manage…") { viewModel.activeSheet = .editWorkspace(workspace.id) }
                .buttonStyle(.link)
                .font(.vaultFootnote)
                .accessibilityIdentifier("workspace-overview-manage-environments")
        } content: {
            VStack(alignment: .leading, spacing: VaultSpacing.m) {
                if environments.isEmpty {
                    VaultNote(
                        text: "Nothing in this workspace yet. Declare the environments the project has and each one gets its own tab."
                    )
                } else {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 150), spacing: VaultSpacing.s)],
                        alignment: .leading,
                        spacing: VaultSpacing.s
                    ) {
                        ForEach(environments) { environment in
                            environmentCard(environment)
                        }
                    }
                }

                let undeclared = viewModel.undeclaredEnvironments(inWorkspace: workspace.id)
                if !undeclared.isEmpty {
                    VaultNote(
                        text: undeclared.count == 1
                            ? "\(undeclared[0].title) is in use here but is not part of the project yet."
                            : "In use here but not part of the project yet: \(undeclared.map(\.title).joined(separator: ", "))."
                    )
                    Button(undeclared.count == 1 ? "Add It to the Project" : "Add Them to the Project") {
                        viewModel.declareEnvironmentsInUse(inWorkspace: workspace.id)
                    }
                    .buttonStyle(VaultButtonStyle(.secondary))
                    .accessibilityIdentifier("workspace-overview-adopt-environments")
                }
            }
        }
    }

    private func environmentCard(_ environment: ResolvedWorkspaceEnvironment) -> some View {
        let color = Color(hex: environment.colorHex)
        let count = viewModel.itemCount(inWorkspace: workspace.id, environmentMatchKey: environment.matchKey)
        let isCurrent = viewModel.selectedEnvironmentMatchKey == environment.matchKey

        return Button {
            viewModel.selectEnvironment(matchKey: environment.matchKey)
        } label: {
            VStack(alignment: .leading, spacing: VaultSpacing.xs) {
                HStack(spacing: VaultSpacing.s) {
                    Circle()
                        .fill(color)
                        .frame(width: 9, height: 9)
                        .opacity(environment.isEnabled ? 1 : 0.35)
                    Text(environment.title)
                        .font(.vaultRowTitle)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Text("\(count)")
                        .font(.vaultBadge)
                        .foregroundStyle(.secondary)
                }

                // Deliberately not "not in the project" on every card: when a workspace has
                // declared nothing that is every card, and the note under the grid already says
                // it once, by name.
                Text(environmentSubtitle(environment, count: count))
                    .font(.vaultBadge)
                    .foregroundStyle(.tertiary)
            }
            .padding(VaultSpacing.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: VaultRadius.value, style: .continuous)
                    .fill(isCurrent ? color.opacity(0.12) : VaultChrome.mutedFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: VaultRadius.value, style: .continuous)
                    .strokeBorder(
                        isCurrent ? color.opacity(0.45) : VaultChrome.hairline,
                        lineWidth: isCurrent ? 1 : 0.5
                    )
            )
        }
        .buttonStyle(.plain)
        .contextMenu {
            if environment.isDeclared {
                Button(environment.isEnabled ? "Switch Off" : "Switch On") {
                    viewModel.setEnvironmentEnabled(
                        !environment.isEnabled,
                        matchKey: environment.matchKey,
                        inWorkspace: workspace.id
                    )
                }
                Button("Remove from Project") {
                    viewModel.undeclareEnvironment(matchKey: environment.matchKey, inWorkspace: workspace.id)
                }
            } else {
                Button("Add to Project") {
                    viewModel.declareEnvironment(environment, inWorkspace: workspace.id)
                }
            }
        }
        .accessibilityIdentifier("workspace-overview-environment-\(uiIdentifierSlug(environment.title))")
    }

    private func environmentSubtitle(_ environment: ResolvedWorkspaceEnvironment, count: Int) -> String {
        if !environment.isEnabled {
            return count > 0 ? "Switched off · \(count) still here" : "Switched off"
        }
        return count == 0 ? "Empty" : "\(count) \(count == 1 ? "secret" : "secrets")"
    }

    // MARK: Linked files

    @ViewBuilder
    private var linkedFilesSection: some View {
        let linked = viewModel.linkedFileCount(inWorkspace: workspace.id)
        if linked > 0 {
            let outdated = viewModel.outdatedLinkedFileCount(inWorkspace: workspace.id)
            VaultSection("Linked Files", systemImage: "doc.text.magnifyingglass", tint: accent) {
                VStack(alignment: .leading, spacing: VaultSpacing.s) {
                    Text("\(linked) of \(itemCount) \(itemCount == 1 ? "secret" : "secrets") here mirrors a file on disk.")
                        .font(.vaultFootnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    if outdated > 0 {
                        VaultNote(
                            text: "\(outdated) \(outdated == 1 ? "file has" : "files have") changed on one side since the last sync. Open the secret to pull the file in or push the vault out.",
                            tone: .warning
                        )
                    } else {
                        VaultNote(text: "Everything matched at the last check.", tone: .success)
                    }

                    Button("Check Again") {
                        Task { await viewModel.refreshLinkedFileStatuses() }
                    }
                    .buttonStyle(VaultButtonStyle(.secondary))
                    .accessibilityIdentifier("workspace-overview-check-links")
                }
            }
        }
    }

    // MARK: Actions

    private var actionsSection: some View {
        VaultSection("Add to This Project", systemImage: "plus.circle", tint: accent) {
            VaultFlowLayout(spacing: VaultSpacing.s, lineSpacing: VaultSpacing.s) {
                Button("New Secret…") {
                    viewModel.activeSheet = .newItemFlow
                }
                .buttonStyle(VaultButtonStyle(.primary))
                .accessibilityIdentifier("workspace-overview-new-item")

                Button("Import a .env File…") {
                    viewModel.importEnvFileCreatingItem()
                }
                .buttonStyle(VaultButtonStyle(.secondary))
                .accessibilityIdentifier("workspace-overview-import-env")

                Button("Edit Workspace…") {
                    viewModel.activeSheet = .editWorkspace(workspace.id)
                }
                .buttonStyle(VaultButtonStyle(.secondary))
                .accessibilityIdentifier("workspace-overview-edit")
            }
        }
    }

    private static func relative(_ date: Date) -> String {
        // Same rule the item detail uses: inside a minute, "in 0 sec." is not an answer.
        guard Date().timeIntervalSince(date) >= 60 else { return "just now" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
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
                    VStack(spacing: 0) {
                        // Edge to edge and pinned above the scroll view, rather than a card
                        // floating inside it: it is the identity of what you are looking at,
                        // not the first row of its contents.
                        ItemDetailHeader(viewModel: viewModel, item: item)

                        ScrollView {
                        VStack(alignment: .leading, spacing: VaultSpacing.xl) {
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
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .accessibilityIdentifier("detail-item-\(uiIdentifierSlug(item.title))")
                } else if let workspaceID = viewModel.selectedDestination.workspaceID,
                          let workspace = viewModel.workspace(for: workspaceID) {
                    // Standing in a workspace with nothing selected used to say "Select a
                    // Secret" — a whole pane spent asking for a click. It is the one place with
                    // room to describe the project instead.
                    WorkspaceOverviewView(viewModel: viewModel, workspace: workspace)
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
                            Button("View History…", systemImage: "clock.arrow.circlepath") {
                                viewModel.activeSheet = .itemHistory(item.id)
                            }
                            .keyboardShortcut("y", modifiers: [.command])
                            .accessibilityIdentifier("detail-action-history")

                            Divider()

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

    // MARK: Metadata

    /// createdAt / updatedAt / lastAccessedAt were tracked from the start but never shown.
    @ViewBuilder
    private func metadataRows(for item: SecretItemEntity) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            metadataRow("Created", value: Self.absoluteFormatter.string(from: item.createdAt))
            metadataRow("Last modified", value: Self.relative(item.updatedAt))
            if let lastAccessedAt = item.lastAccessedAt {
                metadataRow("Last used", value: Self.relative(lastAccessedAt))
            } else {
                metadataRow("Last used", value: "Never")
            }
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
        .task(id: item.id) { await refresh() }
        .onChange(of: viewModel.itemsWithOutdatedLinks) { _, _ in Task { await refresh() } }
        .onChange(of: viewModel.linkedFileStatuses[item.id]) { _, newValue in
            if let newValue { status = newValue }
        }
    }

    // MARK: Linked

    private func linkedContent(_ link: LinkedFileReference) -> some View {
        VaultSection("Linked file", systemImage: "link", tint: tint) {
            Menu {
                Button("Choose a different file…") {
                    viewModel.chooseLinkedFile(for: item, parsedIntoFields: link.parsedIntoFields)
                }
                Button("Reveal in Finder") {
                    NSWorkspace.shared.selectFile(link.displayPath, inFileViewerRootedAtPath: "")
                }
                Divider()
                Button("Remove link", role: .destructive) {
                    viewModel.unlinkFile(from: item)
                    Task { await refresh() }
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
                    Task {
                        _ = await viewModel.updateItemFromLinkedFile(item)
                        await refresh()
                    }
                } label: {
                    Label("Update from file", systemImage: "arrow.down.doc")
                }
                .disabled(status == .unavailable || status == .upToDate)
                .accessibilityIdentifier("linked-file-pull")

                Button {
                    if status == .diverged || status == .fileChanged || status == .needsInitialSync {
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
            Button("Overwrite File", role: .destructive) { write(allowingFileChanges: true) }
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
        case .needsInitialSync:
            VaultNote(text: "The file and this item differ. Choose Update to keep the file, or Write to replace it.", tone: .warning)
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
        case .needsInitialSync, .fileChanged, .vaultChanged, .diverged: .orange
        // Sits next to green / orange / red as a status glyph, so it needs the readable
        // shade rather than the bright fill yellow.
        case .unlinked: .vaultAccentStrong
        }
    }

    // MARK: Unlinked

    private var unlinkedPrompt: some View {
        VaultSection("Linked file", systemImage: "link") {
            VaultNote(text: "Link this item to the .env it mirrors, and you can pull in changes with one click instead of copying and pasting.")
            Button {
                viewModel.chooseLinkedFile(for: item, parsedIntoFields: true)
            } label: {
                Label("Link a .env file…", systemImage: "link.badge.plus")
            }
            .accessibilityIdentifier("linked-file-attach")
        }
    }

    // MARK: Helpers

    private func write(allowingFileChanges: Bool = false) {
        Task {
            _ = await viewModel.writeLinkedFile(from: item, allowingFileChanges: allowingFileChanges)
            await refresh()
        }
    }

    private func refresh() async {
        status = await viewModel.linkedFileStatus(for: item)
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
    @State private var didPushCursor = false

    /// `isSensitive` governs history/search policy; `isMasked` is the explicit presentation
    /// preference. Treat either as concealed so a malformed or legacy record cannot expose a
    /// secret merely because those two flags drifted apart.
    private var isConcealed: Bool { field.isSensitive || field.isMasked }

    private var isOpenableURL: Bool {
        field.kind == .url && !isConcealed && FieldURLSupport.url(from: field.value) != nil
    }

    private var showsPlaintext: Bool {
        guard isConcealed else { return true }
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
        .onDisappear {
            // Scrolling a hovered row out of view would otherwise leave the pushed cursor
            // behind, and the pointing hand would stick for the whole app.
            if didPushCursor {
                NSCursor.pop()
                didPushCursor = false
            }
        }
    }

    private var helpText: String {
        switch (field.isCopyable, isConcealed && canRevealSecrets) {
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

            if isConcealed {
                Image(systemName: "lock.fill")
                    .font(.system(size: 8))
                    .foregroundStyle(.tertiary)
                    .accessibilityLabel("Sensitive")
            }

            Spacer(minLength: VaultSpacing.s)

            if isConcealed, canRevealSecrets {
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

    /// The value, as a button when it can be copied.
    ///
    /// It has to be a real `Button`, not a tap gesture on the box: a tap gesture layered over
    /// selectable `Text` never fires, because the text view claims the click for selection.
    /// That is exactly what broke click-to-copy — and selection is not wanted here anyway,
    /// since clicking already copies.
    @ViewBuilder
    private var valueBox: some View {
        if field.isCopyable {
            Button(action: onCopy) {
                valueSurface
            }
            .buttonStyle(.plain)
            .onHover(perform: handleHover)
            .help(helpText)
            .accessibilityIdentifier("detail-field-value-\(field.key)")
            .accessibilityLabel(field.label)
            .accessibilityHint(accessibilityCopyHint)
        } else {
            valueSurface
                .textSelection(.enabled)
                .onHover(perform: handleHover)
                .help(helpText)
                .accessibilityIdentifier("detail-field-value-\(field.key)")
        }
    }

    private var valueSurface: some View {
        VaultValueBox(isHighlighted: isCopied) {
            Text(displayText)
                .font(.vaultValue)
                .foregroundStyle(showsPlaintext ? .primary : .secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .multilineTextAlignment(.leading)
                .lineLimit(valueLineLimit)
                .fixedSize(horizontal: false, vertical: true)
        }
        .contentShape(Rectangle())
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
        HStack(spacing: VaultSpacing.xs) {
            Image(systemName: "checkmark.circle.fill")
                .font(.body.weight(.semibold))
                .symbolRenderingMode(.hierarchical)
            Text("Copied")
                .font(.subheadline.weight(.semibold))
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, VaultSpacing.m)
        .padding(.vertical, VaultSpacing.s - 1)
        .background {
            RoundedRectangle(cornerRadius: VaultRadius.value, style: .continuous)
                .fill(.thickMaterial)
                .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
        }
        .accessibilityHidden(true)
    }

    /// Reveals on hover, and shows the pointing hand only while the value is actually
    /// copyable. The pushed cursor is tracked so an unbalanced `pop` cannot leave the whole
    /// app stuck with a pointing hand.
    private func handleHover(_ hovering: Bool) {
        if isConcealed, canRevealSecrets {
            isHoveringValue = hovering
        }
        guard field.isCopyable else { return }
        if hovering, !didPushCursor {
            NSCursor.pointingHand.push()
            didPushCursor = true
        } else if !hovering, didPushCursor {
            NSCursor.pop()
            didPushCursor = false
        }
    }

    private var accessibilityCopyHint: String {
        isConcealed && canRevealSecrets
            ? "Hover to show the value, then activate to copy it"
            : "Activate to copy to the clipboard"
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

// MARK: - Item detail header

/// The banner at the top of the detail pane: where this item lives, what it is, and how to get
/// back to everything like it.
///
/// Takes its colour from the workspace, so moving between items reads as moving between
/// projects rather than between identical grey cards. The pixel grid is the same one the
/// welcome and lock screens use, turned right down — enough to give the band a texture, not
/// enough to compete with the title sitting on it.
private struct ItemDetailHeader: View {
    @Bindable var viewModel: VaultViewModel
    let item: SecretItemEntity

    private var accent: Color {
        item.workspace.map { Color(hex: $0.colorHex) } ?? .vaultAccent
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: VaultSpacing.l) {
                icon

                VStack(alignment: .leading, spacing: VaultSpacing.xs) {
                    breadcrumb

                    Text(item.title)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("detail-item-title")

                    if !item.tags.isEmpty {
                        tags
                            .padding(.top, VaultSpacing.hair)
                    }
                }

                favouriteButton
            }
            .padding(.horizontal, VaultSpacing.xl)
            .padding(.vertical, VaultSpacing.l)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(banner)

            Rectangle()
                .fill(VaultChrome.hairline)
                .frame(height: 1)
        }
    }

    // MARK: Bands

    private var banner: some View {
        ZStack {
            LinearGradient(
                colors: [accent.opacity(0.20), accent.opacity(0.04)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            VaultPixelGrid(
                tint: accent,
                spacing: 11,
                dot: 1.5,
                maxAlpha: 0.30,
                baseAlpha: 0.03,
                focus: UnitPoint(x: 0.12, y: 0.35),
                framesPerSecond: 8
            )
        }
        .accessibilityHidden(true)
    }

    /// Solid workspace colour with a lit top edge, not a 20% wash of it.
    ///
    /// The washed version read as a disabled control on a tinted band — the one element that
    /// should carry the workspace's colour was the palest thing on screen. The glyph picks
    /// black or white from the colour's own luminance so it stays legible whichever colour the
    /// workspace was given.
    private var icon: some View {
        let shape = RoundedRectangle(cornerRadius: VaultRadius.hero, style: .continuous)

        return shape
            .fill(accent)
            .overlay(
                LinearGradient(
                    colors: [.white.opacity(0.32), .white.opacity(0.04), .black.opacity(0.14)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .clipShape(shape)
            )
            .overlay(shape.strokeBorder(.white.opacity(0.22), lineWidth: 0.5))
            .frame(width: 50, height: 50)
            .shadow(color: accent.opacity(0.40), radius: 9, y: 4)
            .overlay(
                Image(systemName: item.type.systemImage)
                    .font(.system(size: 21, weight: .semibold))
                    .foregroundStyle(accent.vaultContrastingGlyph)
                    .shadow(color: .black.opacity(0.18), radius: 1, y: 0.5)
            )
            .accessibilityHidden(true)
    }

    // MARK: Rows

    /// Where the item sits, above its name — workspace, then type, then environment.
    ///
    /// Every part is a link back to the list it came from, so the header doubles as a way of
    /// asking "what else is in here?". Wraps rather than scrolls: a long workspace name used
    /// to leave the next chip sliced in half at the edge of the pane.
    private var breadcrumb: some View {
        VaultFlowLayout(spacing: VaultSpacing.s, lineSpacing: VaultSpacing.xs) {
            if let workspace = item.workspace {
                DetailHeaderLink(
                    title: workspace.name,
                    systemImage: workspace.icon,
                    color: Color(hex: workspace.colorHex),
                    hint: "Show everything in \(workspace.name)"
                ) {
                    viewModel.selectDestination(.workspace(workspace.id))
                    viewModel.setSelectedType(nil)
                }
            }

            DetailHeaderLink(
                title: item.type.title,
                systemImage: item.type.systemImage,
                hint: "Show every \(item.type.title)"
            ) {
                viewModel.selectDestination(.library(.allItems))
                viewModel.setSelectedType(item.type)
            }

            // Inside a workspace the environment link stays inside it: from a secret in
            // "Acme API › Prod", the useful neighbours are the rest of that project's
            // production secrets, not every production secret you own. The vault-wide list is
            // still one click away in the sidebar's Environments section.
            if let workspace = item.workspace {
                DetailHeaderLink(
                    title: item.environmentValue.title,
                    systemImage: "circle.hexagongrid",
                    hint: "Show \(workspace.name) › \(item.environmentValue.title)"
                ) {
                    viewModel.selectDestination(
                        .workspaceEnvironment(workspace.id, item.environmentValue.title)
                    )
                    viewModel.setSelectedType(nil)
                }
            } else {
                DetailHeaderLink(
                    title: item.environmentValue.title,
                    systemImage: "circle.hexagongrid",
                    hint: "Show everything in \(item.environmentValue.title)"
                ) {
                    viewModel.selectDestination(.environment(item.environmentValue.title))
                    viewModel.setSelectedType(nil)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Plain `#tag` text under the name, not chips: they are the least important line here and
    /// a row of capsules gave them the same weight as the workspace.
    private var tags: some View {
        VaultFlowLayout(spacing: VaultSpacing.m, lineSpacing: VaultSpacing.xs) {
            ForEach(item.tags, id: \.self) { tag in
                DetailHeaderTagLink(tag: tag) {
                    viewModel.selectDestination(.tag(tag))
                    viewModel.setSelectedType(nil)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var favouriteButton: some View {
        Button { viewModel.toggleFavoriteForSelectedItem() } label: {
            Image(systemName: item.isFavorite ? "star.fill" : "star")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(item.isFavorite ? AnyShapeStyle(Color.vaultAccentStrong) : AnyShapeStyle(.secondary))
        }
        .buttonStyle(.plain)
        .help(item.isFavorite ? "Remove from Favorites" : "Add to Favorites")
        .accessibilityIdentifier("detail-favorite-toggle")
    }
}

/// One clickable part of the breadcrumb.
private struct DetailHeaderLink: View {
    let title: String
    let systemImage: String
    var color: Color = .secondary
    let hint: String
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: VaultSpacing.xs) {
                Image(systemName: systemImage)
                    .font(.caption2)
                    .accessibilityHidden(true)
                Text(title)
                    .font(.caption.weight(.medium))
            }
            .foregroundStyle(color == .secondary ? Color.secondary : color)
            .opacity(isHovering ? 1 : 0.85)
            .underline(isHovering)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(hint)
        .accessibilityLabel("\(title). \(hint)")
    }
}

private struct DetailHeaderTagLink: View {
    let tag: String
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Text("#\(tag)")
                .font(.caption)
                .foregroundStyle(isHovering ? AnyShapeStyle(Color.primary) : AnyShapeStyle(.tertiary))
                .underline(isHovering)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help("Show everything tagged #\(tag)")
        .accessibilityLabel("Tag \(tag). Show everything tagged \(tag)")
    }
}

// MARK: - Toolbar

/// Takes the split view's automatic sidebar toggle out of the toolbar while the vault is
/// locked, leaving the title bar — and so the window buttons — in place.
///
/// A toolbar with nothing in it collapses to a short title bar, which moves the traffic lights
/// up and in by about ten points; the empty item holds the toolbar at its normal height so the
/// buttons stay exactly where they are in the rest of the app.
private struct HiddenSidebarToggle: ViewModifier {
    let isHidden: Bool

    private static let toolbarControlHeight: CGFloat = 28

    func body(content: Content) -> some View {
        if isHidden {
            content
                .toolbar(removing: .sidebarToggle)
                .toolbar {
                    ToolbarItem(placement: .navigation) {
                        Color.clear
                            .frame(width: 1, height: Self.toolbarControlHeight)
                            .accessibilityHidden(true)
                    }
                }
        } else {
            content
        }
    }
}

// MARK: - Locked Vault

private struct LockedVaultOverlay: View {
    @Bindable var viewModel: VaultViewModel

    var body: some View {
        ZStack {
            // Opaque, not a blur: a locked vault should not show a frosted outline of the
            // items behind it, and it is the screen the app is most often looked at on.
            VaultHeroBackground()
                .ignoresSafeArea()

            LockedVaultView(
                sessionManager: viewModel.container.sessionManager,
                settings: viewModel.container.settings
            )
            .vaultHeroContent()
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
        VStack(spacing: 0) {
            Spacer(minLength: VaultSpacing.xxl)

            VStack(spacing: VaultSpacing.xl) {
                icon

                VaultHeroWordmark(
                    tagline: isSetup
                        ? "Set a master password to protect your secrets."
                        : "Unlock with Touch ID, or enter your master password."
                )

                VStack(spacing: VaultSpacing.m) {
                    SecureField(
                        "",
                        text: $password,
                        prompt: Text(isSetup ? "New master password" : "Master password")
                    )
                    .vaultHeroField(isFocused: isPasswordFocused)
                    .frame(width: 300)
                    .focused($isPasswordFocused)
                    .disabled(sessionManager.isBusy)
                    .onSubmit { submit() }
                    .accessibilityLabel(isSetup ? "New master password" : "Master password")
                    .accessibilityIdentifier("lock-password-field")

                    actions

                    // Fixed height so the spinner, an error and the strength bar all occupy
                    // the same space. Swapping between them used to shove the buttons up and
                    // down the screen mid-unlock.
                    statusLine
                        .frame(width: 300, height: Self.statusLineHeight, alignment: .top)
                }
            }
            .frame(maxWidth: 400)

            Spacer(minLength: VaultSpacing.xxl)

            // Pinned to the bottom of the window, not tucked under the buttons: it is the
            // escape hatch for a lost password, not a step in unlocking.
            if !isSetup {
                Button("Forgot your master password?") { isConfirmingReset = true }
                    .buttonStyle(.plain)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.35))
                    .padding(.bottom, VaultSpacing.l)
                    .accessibilityIdentifier("lock-forgot-password")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, VaultSpacing.xxl)
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
        .sheet(isPresented: $isConfirmingReset) {
            EraseVaultSheet(sessionManager: sessionManager) {
                try sessionManager.resetVaultDestroyingAllData()
                password = ""
            }
        }
    }

    // MARK: Pieces

    private var icon: some View {
        VaultHeroLogo(size: 96, badge: showTouchIDBadge ? AnyView(touchIDBadge) : nil)
    }

    private var touchIDBadge: some View {
        Image("touch_id")
            .resizable()
            .scaledToFit()
            .frame(width: 28, height: 28)
            .padding(5)
            .background(Circle().fill(Color.white))
            .overlay(Circle().strokeBorder(Color.black.opacity(0.08), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.35), radius: 5, y: 2)
            .offset(x: 4, y: 4)
            .accessibilityHidden(true)
    }

    /// Reserved space under the buttons, tall enough for the tallest of the three states.
    private static let statusLineHeight: CGFloat = 34

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
            .frame(maxWidth: .infinity)
            .accessibilityIdentifier("lock-busy")
        } else if let message = sessionManager.lastErrorMessage, !message.isEmpty {
            Text(message)
                .foregroundStyle(.red)
                .font(.vaultFootnote)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("lock-error")
        } else if isSetup {
            PasswordStrengthBar(password: password)
        } else {
            Color.clear
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
