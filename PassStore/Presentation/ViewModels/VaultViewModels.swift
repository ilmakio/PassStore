import AppKit
import CryptoKit
import Foundation
import Observation

@MainActor
@Observable
final class VaultViewModel {
    let container: AppContainer

    /// Encrypted payload produced by the export sheet; consumed when the sheet dismisses, then drives `.fileExporter`.
    @ObservationIgnored private var pendingExportData: Data?

    var exportFileDocument: JSONExportDocument?
    var isPresentingExportFileExporter = false

    var importExportSelectedFileName: String?
    @ObservationIgnored private var pendingImportFileData: Data?

    var workspaces: [WorkspaceEntity] = []
    var items: [SecretItemEntity] = []
    var templates: [SecretFieldTemplateEntity] = []

    var selectedDestination: VaultDestination = .library(.allItems)
    var selectedItemID: UUID?
    var multiSelectedIDs: Set<UUID> = []
    var searchText = ""
    var selectedType: SecretItemType?
    var activeSheet: VaultSheet?
    var alertMessage: String?
    var isSettingsPresented = false

    /// Set by the sidebar's Delete Workspace action; drives the confirmation alert in `AppView`.
    var workspacePendingDeletion: WorkspaceEntity?
    /// Items awaiting delete confirmation. Deleting a secret is irreversible, so every entry
    /// point (context menu, multi-selection, detail toolbar, palette) funnels through here.
    var itemsPendingDeletion: [SecretItemEntity] = []
    /// Incremented by the Find command; `ItemListView` moves focus to the search field on change.
    var searchFocusRequests = 0

    var isCommandPalettePresented = false
    var commandPaletteQuery = ""

    init(container: AppContainer) {
        self.container = container
        reload()
        applyUITestLaunchOverrides()
    }

    var selectedItem: SecretItemEntity? {
        items.first(where: { $0.id == selectedItemID })
    }

    var selectedFields: [FieldResolvedValue] {
        guard let selectedItem else { return [] }
        return resolvedFields(for: selectedItem)
    }

    var visibleSelectedFields: [FieldResolvedValue] {
        Self.visibleFields(in: selectedFields)
    }

    var selectedNotes: String? {
        guard let notes = selectedItem?.notes.trimmingCharacters(in: .whitespacesAndNewlines), !notes.isEmpty else {
            return nil
        }
        return notes
    }

    var availableTags: [String] {
        Array(Set(items.flatMap(\.tags))).sorted()
    }

    var availableEnvironments: [String] {
        Array(Set(items.map { $0.environmentValue.title })).sorted()
    }

    var orderedTypes: [SecretItemType] {
        let customOrder = container.settings.sidebarTypesOrder
        if customOrder.isEmpty { return SecretItemType.allCases }
        let mapped = customOrder.compactMap { SecretItemType(rawValue: $0) }
        let remaining = SecretItemType.allCases.filter { !mapped.contains($0) }
        return mapped + remaining
    }

    var orderedTags: [String] {
        let customOrder = container.settings.sidebarTagsOrder
        let current = availableTags
        if customOrder.isEmpty { return current }
        let ordered = customOrder.filter { current.contains($0) }
        let newTags = current.filter { !customOrder.contains($0) }.sorted()
        return ordered + newTags
    }

    var orderedEnvironments: [String] {
        let customOrder = container.settings.sidebarEnvironmentsOrder
        let current = availableEnvironments
        if customOrder.isEmpty { return current }
        let ordered = customOrder.filter { current.contains($0) }
        let newEnvs = current.filter { !customOrder.contains($0) }.sorted()
        return ordered + newEnvs
    }

    func reorderWorkspaces(newIDs: [UUID]) {
        do {
            try container.workspaceRepository.reorderWorkspaces(newIDs)
            reload()
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    func requestWorkspaceDeletion(id: UUID) {
        workspacePendingDeletion = workspace(for: id)
    }

    /// Deletes the workspace and un-assigns (never deletes) the items that belonged to it.
    func confirmWorkspaceDeletion() {
        guard let workspace = workspacePendingDeletion else { return }
        workspacePendingDeletion = nil
        let wasSelected: Bool = {
            if case let .workspace(id) = selectedDestination { return id == workspace.id }
            return false
        }()
        do {
            try container.workspaceRepository.deleteWorkspace(workspace)
            if wasSelected {
                selectedDestination = .library(.allItems)
            }
            reload()
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    func itemCount(in section: LibrarySection) -> Int {
        items.count { Self.matches(section: section, item: $0) }
    }

    func itemCount(inWorkspace id: UUID) -> Int {
        items.filter { $0.workspace?.id == id && !$0.isArchived }.count
    }

    func requestSearchFocus() {
        searchFocusRequests += 1
    }

    /// Moves the list selection by `offset` within the currently filtered items (keyboard navigation).
    func moveSelection(by offset: Int) {
        let visible = filteredItems
        guard !visible.isEmpty else { return }
        guard let current = selectedItemID, let index = visible.firstIndex(where: { $0.id == current }) else {
            select(visible.first)
            return
        }
        let next = min(max(index + offset, 0), visible.count - 1)
        guard next != index else { return }
        select(visible[next])
    }

    var builtInTemplates: [SecretFieldTemplateEntity] {
        templates
            .filter(\.isBuiltIn)
            .sorted(by: templateSortComparator)
    }

    var customTemplates: [SecretFieldTemplateEntity] {
        templates
            .filter { !$0.isBuiltIn }
            .sorted(by: templateSortComparator)
    }

    var featuredTemplates: [SecretFieldTemplateEntity] {
        builtInTemplates.filter { [.generic, .websiteService].contains($0.itemType) }
    }

    var standardBuiltInTemplates: [SecretFieldTemplateEntity] {
        builtInTemplates.filter { ![.generic, .websiteService].contains($0.itemType) }
    }

    // MARK: - Filtered list (memoised)

    /// Identity of one filtered-list result. When this is unchanged, so is the list.
    private struct FilterFingerprint: Equatable {
        let destination: VaultDestination
        let type: SecretItemType?
        let query: String
        let sortOrder: ItemSortOrder
        let generation: Int
    }

    /// Bumped by `reload()`; every mutation path funnels through it.
    @ObservationIgnored private var vaultGeneration = 0
    @ObservationIgnored private var filteredCache: (key: FilterFingerprint, value: [SecretItemEntity])?

    /// The list the middle column shows.
    ///
    /// Memoised because it is read many times per render — the list body, the selection bar,
    /// selection syncing and keyboard navigation all ask for it — and each miss was two
    /// passes plus a sort over the whole vault.
    var filteredItems: [SecretItemEntity] {
        // Touch `items` so SwiftUI still registers the dependency on a cache hit.
        let all = items
        let key = FilterFingerprint(
            destination: selectedDestination,
            type: selectedType,
            query: searchText.trimmingCharacters(in: .whitespacesAndNewlines),
            sortOrder: sortOrder,
            generation: vaultGeneration
        )
        if let cached = filteredCache, cached.key == key {
            return cached.value
        }
        let result = all
            .filter(matchesDestination)
            .filter(matchesSearchAndType)
            .sorted(by: sortComparator)
        filteredCache = (key, result)
        return result
    }

    var sortOrder: ItemSortOrder {
        get { container.settings.itemSortOrder }
        set { container.settings.itemSortOrder = newValue }
    }

    var destinationTitle: String {
        switch selectedDestination {
        case let .library(section):
            section.title
        case let .workspace(id):
            workspace(for: id)?.name ?? "Workspace"
        case let .tag(tag):
            "#\(tag)"
        case let .environment(environment):
            environment
        }
    }

    var destinationSubtitle: String {
        switch selectedDestination {
        case .library(.allItems):
            "Everything in your vault"
        case .library(.favorites):
            "Pinned secrets you reach for often"
        case .library(.recent):
            "Sorted by last modified, newest first"
        case .library(.archived):
            "Archived items you can still restore"
        case .workspace:
            "Scoped to a workspace"
        case .tag:
            "Items carrying this tag"
        case .environment:
            "Items for this environment"
        }
    }

    var hasActiveFilters: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || selectedType != nil
    }

    func clearFilters() {
        searchText = ""
        setSelectedType(nil)
    }

    /// Shown when the vault has items but this particular destination is empty.
    var emptyDestinationHint: String {
        switch selectedDestination {
        case .library(.allItems):
            "Every item in your vault is archived."
        case .library(.favorites):
            "Star an item to pin it here for quick access."
        case .library(.recent):
            "Items you create or edit will show up here."
        case .library(.archived):
            "Nothing is archived. Archived items stay recoverable."
        case .workspace:
            "This workspace has no items yet."
        case .tag:
            "No items carry this tag anymore."
        case .environment:
            "No items target this environment anymore."
        }
    }

    var destinationSystemImage: String {
        switch selectedDestination {
        case let .library(section):
            section.systemImage
        case let .workspace(id):
            workspace(for: id)?.icon ?? "folder"
        case .tag:
            "tag"
        case .environment:
            "circle.hexagongrid"
        }
    }

    func reload() {
        do {
            vaultGeneration &+= 1
            filteredCache = nil
            workspaces = try container.workspaceRepository.fetchAll(includeArchived: false)
            items = try container.itemRepository.fetchAll(includeArchived: true)
            templates = try container.templateRepository.fetchAll()
            normalizeSelection()
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    /// Invalidates the filtered-list cache without re-reading the store.
    ///
    /// Used by mutations that change an entity in place (favourite, last-used) where a full
    /// `reload()` would be pure waste.
    private func invalidateFilteredCache() {
        vaultGeneration &+= 1
        filteredCache = nil
    }

    func resetUnlockedSelection() {
        workspaces = []
        items = []
        templates = []
        selectedItemID = nil
        isCommandPalettePresented = false
        commandPaletteQuery = ""
    }

    func dismissCommandPalette() {
        isCommandPalettePresented = false
        commandPaletteQuery = ""
    }

    func presentCommandPalette() {
        guard container.sessionManager.lockState == .unlocked else { return }
        commandPaletteQuery = ""
        isCommandPalettePresented = true
    }

    /// Switches destination so the item appears in the list, then selects it (palette / quick open).
    func revealAndSelectItemFromPalette(_ item: SecretItemEntity) {
        searchText = ""
        selectedType = nil
        if item.isArchived {
            selectDestination(.library(.archived))
        } else if let workspaceID = item.workspace?.id {
            selectDestination(.workspace(workspaceID))
        } else {
            selectDestination(.library(.allItems))
        }
        if !filteredItems.contains(where: { $0.id == item.id }) {
            selectDestination(.library(item.isArchived ? .archived : .allItems))
        }
        select(item)
    }

    func selectDestination(_ destination: VaultDestination) {
        selectedDestination = destination
        multiSelectedIDs.removeAll()
        syncSelectedItem()
    }

    /// Updates the sidebar type filter and keeps the list selection consistent with `filteredItems`.
    func setSelectedType(_ type: SecretItemType?) {
        selectedType = type
        syncSelectedItem()
    }

    /// Selects a row and stamps "last used".
    ///
    /// The stamp used to trigger a synchronous full-vault re-encrypt plus a complete
    /// `reload()` — every entity in the vault rebuilt — on every click. The repository now
    /// coalesces the write, and the entity is observable, so nothing has to be reloaded.
    func select(_ item: SecretItemEntity?) {
        multiSelectedIDs.removeAll()
        selectedItemID = item?.id
        guard let item else { return }
        try? container.itemRepository.recordItemAccess(item)
        // Deliberately no cache invalidation: under a last-used sort, re-ordering the list
        // under the pointer on every click would make it impossible to work down a list.
        // The new order lands on the next natural refresh.
    }

    // MARK: - Multi-selection

    /// Bridge between SwiftUI's `List(selection:)` and the existing single/multi split.
    ///
    /// Handing the list a real selection set is what buys arrow keys, ⇧-click ranges and
    /// ⌘-click toggling; the rest of the app still thinks in terms of "the selected item"
    /// plus "a multi-selection", so this keeps both in step.
    var listSelection: Set<UUID> {
        get {
            if !multiSelectedIDs.isEmpty { return multiSelectedIDs }
            return selectedItemID.map { [$0] } ?? []
        }
        set {
            guard newValue != listSelection else { return }
            if newValue.count > 1 {
                multiSelectedIDs = newValue
                if let current = selectedItemID, newValue.contains(current) { return }
                selectedItemID = filteredItems.first(where: { newValue.contains($0.id) })?.id
            } else {
                multiSelectedIDs = []
                select(items.first(where: { $0.id == newValue.first }))
            }
        }
    }

    /// The field a one-click copy should reach for.
    ///
    /// Prefers a password, then any other secret, then the first copyable value — which is
    /// what "copy this item" means for the .env and connection-string types that have no
    /// password at all.
    func primaryCopyField(for item: SecretItemEntity) -> FieldResolvedValue? {
        let fields = Self.visibleFields(in: resolvedFields(for: item)).filter(\.isCopyable)
        if let password = fields.first(where: {
            SecretFieldClassification.isPasswordLike(key: $0.key, label: $0.label)
        }) {
            return password
        }
        return fields.first(where: \.isSensitive) ?? fields.first
    }

    var isMultiSelecting: Bool { !multiSelectedIDs.isEmpty }

    var multiSelectedItems: [SecretItemEntity] {
        filteredItems.filter { multiSelectedIDs.contains($0.id) }
    }

    func toggleMultiSelect(_ item: SecretItemEntity) {
        if multiSelectedIDs.contains(item.id) {
            multiSelectedIDs.remove(item.id)
        } else {
            multiSelectedIDs.insert(item.id)
        }
        // Keep selectedItemID pointing to the last toggled item for detail view
        if multiSelectedIDs.isEmpty {
            selectedItemID = nil
        } else {
            selectedItemID = item.id
        }
    }

    func selectAll() {
        multiSelectedIDs = Set(filteredItems.map(\.id))
        selectedItemID = filteredItems.first?.id
    }

    func clearMultiSelection() {
        multiSelectedIDs.removeAll()
    }

    func bulkAddFavorite() {
        for item in multiSelectedItems where !item.isFavorite {
            var draft = makeDraft(from: item)
            draft.isFavorite = true
            do {
                try container.itemRepository.saveItem(draft)
            } catch {
                alertMessage = error.localizedDescription
                return
            }
        }
        reload()
    }

    func bulkRemoveFavorite() {
        for item in multiSelectedItems where item.isFavorite {
            var draft = makeDraft(from: item)
            draft.isFavorite = false
            do {
                try container.itemRepository.saveItem(draft)
            } catch {
                alertMessage = error.localizedDescription
                return
            }
        }
        reload()
    }

    func bulkCopyEnv() {
        let selected = multiSelectedItems
        guard !selected.isEmpty else { return }
        let parts = selected.map { item in
            let fields = Self.visibleFields(in: resolvedFields(for: item))
            return CopyFormatter.envString(for: item, fields: fields)
        }
        let combined = parts.joined(separator: "\n\n")
        let hasSensitive = selected.contains { item in
            Self.visibleFields(in: resolvedFields(for: item)).contains(where: \.isSensitive)
        }
        maybeWarnForSensitiveCopy(isSensitive: hasSensitive)
        container.clipboard.copy(combined, label: ".env")
    }

    func bulkCopyJSON() {
        let selected = multiSelectedItems
        guard !selected.isEmpty else { return }
        var allPayloads: [String: Any] = [:]
        var hasSensitive = false
        for item in selected {
            let fields = Self.visibleFields(in: resolvedFields(for: item))
            if fields.contains(where: \.isSensitive) { hasSensitive = true }
            // Two items can share a title, so disambiguate instead of letting the last one win.
            var key = item.title
            var suffix = 2
            while allPayloads[key] != nil {
                key = "\(item.title) (\(suffix))"
                suffix += 1
            }
            allPayloads[key] = CopyFormatter.keyedValues(fields)
        }
        guard let data = try? JSONSerialization.data(withJSONObject: allPayloads, options: [.prettyPrinted, .sortedKeys]) else { return }
        let json = String(decoding: data, as: UTF8.self)
        maybeWarnForSensitiveCopy(isSensitive: hasSensitive)
        container.clipboard.copy(json, label: "JSON")
    }

    func bulkDuplicate() {
        for item in multiSelectedItems {
            _ = try? container.itemRepository.duplicateItem(item)
        }
        reload()
        multiSelectedIDs.removeAll()
    }

    /// Archives every selected item with a single reload; the per-item path would otherwise
    /// re-fetch the vault and retarget the sidebar destination once per item.
    func bulkArchive() {
        let selected = multiSelectedItems
        guard !selected.isEmpty else { return }
        for item in selected {
            var draft = makeDraft(from: item)
            draft.id = item.id
            draft.isArchived = true
            do {
                try container.itemRepository.saveItem(draft)
            } catch {
                alertMessage = error.localizedDescription
                break
            }
        }
        multiSelectedIDs.removeAll()
        selectedItemID = nil
        selectedDestination = .library(.archived)
        reload()
    }

    // MARK: - Bulk edit

    /// Applies one set of edits across the whole multi-selection.
    ///
    /// Every item goes through the normal `saveItem` path, so each one gets its own audit
    /// entries and the same normalization a single-item edit would get.
    func applyBulkEdit(_ draft: BulkEditDraft) {
        let targets = multiSelectedItems
        guard !targets.isEmpty, draft.hasChanges else { return }

        let removals = Set(draft.tagsToRemove.map { $0.lowercased() })
        var didArchive = false

        for item in targets {
            var itemDraft = makeDraft(from: item)
            itemDraft.id = item.id

            var tags = itemDraft.tags.filter { !removals.contains($0.lowercased()) }
            tags.append(contentsOf: draft.tagsToAdd)
            itemDraft.tags = tags

            switch draft.workspaceAction {
            case .keep: break
            case .clear: itemDraft.workspaceID = nil
            case let .move(id): itemDraft.workspaceID = id
            }

            if case let .set(environment) = draft.environmentAction {
                itemDraft.environment = environment
            }

            switch draft.favoriteAction {
            case .keep: break
            case .enable: itemDraft.isFavorite = true
            case .disable: itemDraft.isFavorite = false
            }

            switch draft.archiveAction {
            case .keep: break
            case .enable:
                itemDraft.isArchived = true
                didArchive = true
            case .disable:
                itemDraft.isArchived = false
            }

            do {
                try container.itemRepository.saveItem(itemDraft)
            } catch {
                alertMessage = error.localizedDescription
                break
            }
        }

        // Edited items can drop out of the current destination (archived, moved, retagged),
        // so the stale selection is cleared rather than left pointing at rows that vanished.
        multiSelectedIDs.removeAll()
        selectedItemID = nil
        if didArchive {
            selectedDestination = .library(.archived)
        }
        reload()
    }

    /// Tags shared by every selected item — the ones a bulk "remove" can meaningfully offer.
    var commonTagsInMultiSelection: [String] {
        let selected = multiSelectedItems
        guard let first = selected.first else { return [] }
        var shared = Set(first.tags.map { $0.lowercased() })
        for item in selected.dropFirst() {
            shared.formIntersection(item.tags.map { $0.lowercased() })
        }
        return Array(Set(selected.flatMap(\.tags)).filter { shared.contains($0.lowercased()) }).sorted()
    }

    func saveItem(_ draft: SecretItemDraft) {
        do {
            let item = try container.itemRepository.saveItem(draft)
            reload()
            selectedItemID = item.id
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    func saveWorkspace(_ draft: WorkspaceDraft) {
        _ = createWorkspace(draft)
    }

    @discardableResult
    func createWorkspace(_ draft: WorkspaceDraft) -> WorkspaceEntity? {
        do {
            let workspace = try container.workspaceRepository.saveWorkspace(draft)
            reload()
            return workspace
        } catch {
            alertMessage = error.localizedDescription
            return nil
        }
    }

    @discardableResult
    func saveTemplate(_ draft: TemplateDraft) -> SecretFieldTemplateEntity? {
        do {
            let template = try container.templateRepository.saveTemplate(draft, isBuiltIn: false)
            reload()
            return template
        } catch {
            alertMessage = error.localizedDescription
            return nil
        }
    }

    func deleteTemplate(_ template: SecretFieldTemplateEntity) {
        do {
            try container.templateRepository.deleteTemplate(template)
            reload()
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    func duplicateSelectedItem() {
        guard let selectedItem else { return }
        duplicate(selectedItem)
    }

    func archiveSelectedItem() {
        guard let selectedItem else { return }
        archive(selectedItem)
    }

    func restoreSelectedItem() {
        guard let selectedItem else { return }
        restore(selectedItem)
    }

    func edit(_ item: SecretItemEntity) {
        selectedItemID = item.id
        activeSheet = .editItem(item.id)
    }

    func duplicate(_ item: SecretItemEntity) {
        do {
            let copy = try container.itemRepository.duplicateItem(item)
            reload()
            selectedItemID = copy.id
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    func toggleFavorite(for item: SecretItemEntity) {
        var draft = makeDraft(from: item)
        draft.isFavorite.toggle()
        saveItem(draft)
    }

    func toggleFavoriteForSelectedItem() {
        guard let selectedItem else { return }
        toggleFavorite(for: selectedItem)
    }

    func archive(_ item: SecretItemEntity) {
        updateArchiveState(for: item, isArchived: true)
    }

    func restore(_ item: SecretItemEntity) {
        updateArchiveState(for: item, isArchived: false)
    }

    // MARK: - Deletion confirmation

    func requestDeletion(of items: [SecretItemEntity]) {
        guard !items.isEmpty else { return }
        itemsPendingDeletion = items
    }

    func requestDeletion(of item: SecretItemEntity) {
        requestDeletion(of: [item])
    }

    func requestDeletionOfSelectedItem() {
        guard let selectedItem else { return }
        requestDeletion(of: selectedItem)
    }

    func requestDeletionOfMultiSelection() {
        requestDeletion(of: multiSelectedItems)
    }

    func cancelItemDeletion() {
        itemsPendingDeletion = []
    }

    func confirmItemDeletion() {
        let targets = itemsPendingDeletion
        itemsPendingDeletion = []
        guard !targets.isEmpty else { return }
        let deletedIDs = Set(targets.map(\.id))
        do {
            for item in targets {
                try container.itemRepository.deleteItem(item)
            }
        } catch {
            alertMessage = error.localizedDescription
        }
        multiSelectedIDs.subtract(deletedIDs)
        if let selectedItemID, deletedIDs.contains(selectedItemID) {
            self.selectedItemID = nil
        }
        reload()
    }

    var itemDeletionTitle: String {
        switch itemsPendingDeletion.count {
        case 0: "Delete item?"
        case 1: "Delete “\(itemsPendingDeletion[0].title)”?"
        default: "Delete \(itemsPendingDeletion.count) items?"
        }
    }

    var itemDeletionConfirmLabel: String {
        itemsPendingDeletion.count > 1 ? "Delete \(itemsPendingDeletion.count) Items" : "Delete"
    }

    var itemDeletionMessage: String {
        let secretCount = itemsPendingDeletion.reduce(0) { total, item in
            total + Self.visibleFields(in: resolvedFields(for: item)).filter(\.isSensitive).count
        }
        let base = itemsPendingDeletion.count > 1
            ? "These items and all their fields will be permanently deleted."
            : "This item and all its fields will be permanently deleted."
        guard secretCount > 0 else { return "\(base) This cannot be undone." }
        let noun = secretCount == 1 ? "stored secret" : "stored secrets"
        return "\(base) That includes \(secretCount) \(noun). This cannot be undone — consider archiving instead."
    }

    // MARK: - Vault health

    /// Audits stored secrets for weak, reused and stale entries.
    /// Findings deliberately carry only item titles and field labels — never secret values —
    /// so the report itself is safe to show, screenshot, or read aloud.
    ///
    /// Findings the owner dismissed are moved to `ignoredFindings` rather than dropped, so the
    /// sheet can still say how many are hidden and offer to bring them back.
    func vaultHealthReport() -> VaultHealthReport {
        let active = items.filter { !$0.isArchived }
        var findings: [VaultHealthFinding] = []

        // Group sensitive values to spot reuse. Hashed so plaintext never lands in the report.
        var occurrencesByDigest: [String: [(item: SecretItemEntity, key: String, label: String)]] = [:]

        for item in active {
            let fields = Self.visibleFields(in: resolvedFields(for: item))
            for field in fields where field.isSensitive {
                let digest = Self.digest(field.value)
                occurrencesByDigest[digest, default: []].append((item, field.key, field.label))

                let strength = PasswordStrength.evaluate(field.value)
                if strength.needsAttention {
                    findings.append(
                        VaultHealthFinding(
                            id: "weak-\(item.id.uuidString)-\(field.key)",
                            kind: .weak,
                            itemID: item.id,
                            itemTitle: item.title,
                            detail: "\(field.label) — \(strength.label.lowercased())",
                            fieldKey: field.key,
                            valueDigest: digest
                        )
                    )
                }
            }
        }

        for (digest, occurrences) in occurrencesByDigest {
            let distinctItems = Set(occurrences.map(\.item.id))
            guard distinctItems.count > 1 else { continue }
            let titles = occurrences.map(\.item.title).sorted()
            for occurrence in occurrences {
                let others = titles.filter { $0 != occurrence.item.title }
                findings.append(
                    VaultHealthFinding(
                        id: "reused-\(occurrence.item.id.uuidString)-\(occurrence.label)",
                        kind: .reused,
                        itemID: occurrence.item.id,
                        itemTitle: occurrence.item.title,
                        detail: "\(occurrence.label) — also used in \(others.joined(separator: ", "))",
                        fieldKey: occurrence.key,
                        valueDigest: digest
                    )
                )
            }
        }

        let staleCutoff = Date().addingTimeInterval(-Self.staleItemInterval)
        for item in active {
            // Dated from the password's own rotation when history knows it, so editing a
            // title no longer makes a years-old credential look freshly reviewed.
            let reference = item.healthReferenceDate
            guard reference < staleCutoff else { continue }
            let months = Int(Date().timeIntervalSince(reference) / (30 * 24 * 3600))
            let detail = item.passwordLastChangedAt == nil
                ? "Not updated in about \(months) months"
                : "Password not rotated in about \(months) months"
            findings.append(
                VaultHealthFinding(
                    id: "stale-\(item.id.uuidString)",
                    kind: .stale,
                    itemID: item.id,
                    itemTitle: item.title,
                    detail: detail,
                    referenceDate: reference
                )
            )
        }

        let ignoresByItem = Dictionary(active.map { ($0.id, $0.ignoredHealthIssues) }, uniquingKeysWith: { first, _ in first })
        let isSilenced = { (finding: VaultHealthFinding) in
            (ignoresByItem[finding.itemID] ?? []).contains { finding.isSilenced(by: $0) }
        }

        let sorter: (VaultHealthFinding, VaultHealthFinding) -> Bool = {
            if $0.kind != $1.kind { return $0.kind.severity < $1.kind.severity }
            return $0.itemTitle.localizedCaseInsensitiveCompare($1.itemTitle) == .orderedAscending
        }

        return VaultHealthReport(
            auditedItemCount: active.count,
            findings: findings.filter { !isSilenced($0) }.sorted(by: sorter),
            ignoredFindings: findings.filter(isSilenced).sorted(by: sorter)
        )
    }

    /// Dismisses a finding for the value that produced it. Rotating that secret makes the
    /// finding come back on its own.
    func ignoreHealthFinding(_ finding: VaultHealthFinding) {
        guard let item = items.first(where: { $0.id == finding.itemID }) else { return }
        let record = finding.ignoreRecord
        guard !item.ignoredHealthIssues.contains(where: { $0.id == record.id }) else { return }
        item.ignoredHealthIssues.append(record)
        persistIgnoredHealthIssues()
    }

    func restoreIgnoredFinding(_ finding: VaultHealthFinding) {
        guard let item = items.first(where: { $0.id == finding.itemID }) else { return }
        item.ignoredHealthIssues.removeAll { finding.isSilenced(by: $0) }
        persistIgnoredHealthIssues()
    }

    func restoreAllIgnoredFindings() {
        for item in items where !item.ignoredHealthIssues.isEmpty {
            item.ignoredHealthIssues = []
        }
        persistIgnoredHealthIssues()
    }

    /// Writes the vault directly: dismissals live on the item but are not an edit to it, so
    /// they must not bump `updatedAt` or land in the audit trail.
    private func persistIgnoredHealthIssues() {
        do {
            try container.memoryStore.persist()
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    /// Items untouched for a year are surfaced as worth rotating or retiring.
    private static let staleItemInterval: TimeInterval = 365 * 24 * 3600

    /// Must stay the same function the repository uses to prune dismissals — a mismatch
    /// would make every ignore look orphaned and get swept away on the next save.
    private static func digest(_ value: String) -> String {
        SecretItemRepository.digest(value)
    }

    // MARK: - Linked .env files
    //
    // A `.env` is not a one-off import: it changes, and re-importing it by hand meant
    // find file → copy → paste → save, every time. An item now remembers the file it came
    // from and can pull the latest contents in one click — or push its contents back out.

    /// Compares the linked file with what the vault holds.
    ///
    /// Both sides are digested at the last successful sync, so a change can be attributed to
    /// the file, to the vault, or to both, instead of guessing from timestamps.
    func linkedFileStatus(for item: SecretItemEntity) -> LinkedFileStatus {
        guard let link = item.linkedFile else { return .unlinked }
        guard let contents = try? container.linkedFiles.read(link) else { return .unavailable }

        let fileDigest = LinkedFileService.digest(contents)
        let vaultDigest = LinkedFileService.digest(envContents(for: item))
        let fileMoved = link.syncedDigest != nil && link.syncedDigest != fileDigest
        let vaultMoved = link.syncedVaultDigest != nil && link.syncedVaultDigest != vaultDigest

        switch (fileMoved, vaultMoved) {
        case (false, false): return .upToDate
        case (true, false): return .fileChanged
        case (false, true): return .vaultChanged
        case (true, true): return .diverged
        }
    }

    /// The `.env` text this item currently represents.
    func envContents(for item: SecretItemEntity) -> String {
        let fields = Self.visibleFields(in: resolvedFields(for: item))
        if item.linkedFile?.parsedIntoFields == false, let blob = fields.first(where: { $0.key == "env" }) {
            return blob.value
        }
        return CopyFormatter.envFileContents(fields: fields)
    }

    /// Pulls the current file contents into the item.
    @discardableResult
    func updateItemFromLinkedFile(_ item: SecretItemEntity) -> Bool {
        guard let link = item.linkedFile else {
            alertMessage = LinkedFileError.noLink.localizedDescription
            return false
        }
        do {
            let contents = try container.linkedFiles.read(link)
            // A pull rewrites every field, so it gets the same undo cover as a bulk edit.
            captureUndo("Update from file")

            var draft = makeDraft(from: item)
            draft.id = item.id
            applyEnvImportContent(
                to: &draft,
                raw: contents,
                parseIntoEntries: link.parsedIntoFields,
                suggestedTitle: nil
            )

            var updatedLink = link
            updatedLink.syncedDigest = LinkedFileService.digest(contents)
            updatedLink.syncedAt = .now
            draft.linkedFile = updatedLink

            let saved = try container.itemRepository.saveItem(draft)
            // Digest the result rather than the draft: normalisation can change it.
            updatedLink.syncedVaultDigest = LinkedFileService.digest(envContents(for: saved))
            saved.linkedFile = updatedLink
            try container.memoryStore.persist()

            reload()
            selectedItemID = saved.id
            lastActionMessage = "Updated “\(saved.title)” from \(link.fileName)."
            return true
        } catch {
            alertMessage = error.localizedDescription
            return false
        }
    }

    /// Writes the item's contents back over the linked file.
    @discardableResult
    func writeLinkedFile(from item: SecretItemEntity) -> Bool {
        guard let link = item.linkedFile else {
            alertMessage = LinkedFileError.noLink.localizedDescription
            return false
        }
        do {
            let contents = envContents(for: item)
            try container.linkedFiles.write(contents, to: link)
            var updatedLink = link
            updatedLink.syncedDigest = LinkedFileService.digest(contents)
            updatedLink.syncedVaultDigest = LinkedFileService.digest(contents)
            updatedLink.syncedAt = .now
            item.linkedFile = updatedLink
            try container.memoryStore.persist()
            invalidateFilteredCache()
            lastActionMessage = "Wrote \(link.fileName)."
            return true
        } catch {
            alertMessage = error.localizedDescription
            return false
        }
    }

    /// Attaches a file to an item, or replaces the existing link.
    func linkFile(at url: URL, to item: SecretItemEntity, parsedIntoFields: Bool) {
        var link = container.linkedFiles.makeLink(to: url, parsedIntoFields: parsedIntoFields)
        if let contents = try? container.linkedFiles.read(link) {
            link.syncedDigest = LinkedFileService.digest(contents)
        }
        link.syncedVaultDigest = LinkedFileService.digest(envContents(for: item))
        link.syncedAt = .now
        item.linkedFile = link
        do {
            try container.memoryStore.persist()
            invalidateFilteredCache()
            lastActionMessage = "Linked to \(link.fileName)."
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    func unlinkFile(from item: SecretItemEntity) {
        item.linkedFile = nil
        try? container.memoryStore.persist()
        invalidateFilteredCache()
    }

    /// Opens a picker and links the chosen file. `showsHiddenFiles` matters: `.env` is hidden.
    func chooseLinkedFile(for item: SecretItemEntity, parsedIntoFields: Bool) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.canChooseDirectories = false
        panel.prompt = "Link"
        panel.message = "Choose the .env file this item mirrors."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        linkFile(at: url, to: item, parsedIntoFields: parsedIntoFields)
    }

    /// Items whose linked file changed on disk. Recomputed when the window regains focus.
    private(set) var itemsWithOutdatedLinks: [UUID] = []

    /// Rechecks every linked file. Called when the window comes forward, so a `.env` edited
    /// in an editor shows up as "changed" without any polling.
    func refreshLinkedFileStatuses() {
        guard container.settings.checksLinkedFilesOnFocus,
              container.sessionManager.lockState == .unlocked else { return }
        itemsWithOutdatedLinks = items
            .filter { $0.linkedFile != nil }
            .filter { linkedFileStatus(for: $0) == .fileChanged }
            .map(\.id)
    }

    var outdatedLinkedFileCount: Int { itemsWithOutdatedLinks.count }

    // MARK: - Secret value history

    /// Fields on this item that have at least one recorded previous value.
    func fieldsWithHistory(for item: SecretItemEntity) -> [FieldResolvedValue] {
        resolvedFields(for: item).filter { !$0.previousValues.isEmpty }
    }

    var isValueHistoryEnabled: Bool {
        container.settings.keepsSecretValueHistory
    }

    func copyPreviousValue(_ version: SecretValueVersion, label: String) {
        maybeWarnForSensitiveCopy(isSensitive: true)
        container.clipboard.copy(version.value, label: "\(label) (previous)")
    }

    /// Puts an old value back into the field. The value being replaced is itself pushed onto
    /// the history, so restoring is reversible too.
    func restorePreviousValue(_ version: SecretValueVersion, fieldKey: String, in item: SecretItemEntity) {
        var draft = makeDraft(from: item)
        draft.id = item.id
        guard let index = draft.fieldDrafts.firstIndex(where: { $0.key == fieldKey }) else { return }
        guard draft.fieldDrafts[index].value != version.value else { return }
        captureUndo("Value restore")
        draft.fieldDrafts[index].value = version.value
        saveItem(draft)
        lastActionMessage = "Restored the previous value of “\(draft.fieldDrafts[index].label)”."
    }

    func purgeValueHistory(for item: SecretItemEntity) {
        do {
            captureUndo("History purge")
            try container.itemRepository.purgeValueHistory(for: item)
            reload()
            lastActionMessage = "Previous values for “\(item.title)” deleted."
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    func purgeAllValueHistory() {
        do {
            captureUndo("History purge")
            try container.itemRepository.purgeAllValueHistory()
            reload()
            lastActionMessage = "All stored previous values deleted."
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    /// How many previous values are stored across the whole vault — shown in Settings so the
    /// trade-off is visible rather than implicit.
    var storedPreviousValueCount: Int {
        items.reduce(0) { total, item in
            total + item.fields.reduce(0) { $0 + $1.previousValues.count }
        }
    }

    func selectItem(id: UUID) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        revealAndSelectItemFromPalette(item)
    }

    func openFieldURL(_ field: FieldResolvedValue) {
        guard let url = FieldURLSupport.url(from: field.value) else {
            alertMessage = "“\(field.label)” doesn't contain a web address that can be opened."
            return
        }
        NSWorkspace.shared.open(url)
    }

    func copyGeneratedPassword(_ password: String) {
        guard !password.isEmpty else { return }
        maybeWarnForSensitiveCopy(isSensitive: true)
        container.clipboard.copy(password, label: "Generated password")
    }

    func copyField(_ field: FieldResolvedValue) {
        maybeWarnForSensitiveCopy(isSensitive: field.isSensitive)
        container.clipboard.copy(field.value, label: field.label)
    }

    func copyEnv() {
        guard let selectedItem else { return }
        copyEnv(for: selectedItem)
    }

    func copyJSON() {
        guard let selectedItem else { return }
        copyJSON(for: selectedItem)
    }

    func copyConnectionString() {
        guard let selectedItem else { return }
        copyConnectionString(for: selectedItem)
    }

    func copyEnv(for item: SecretItemEntity) {
        let fields = Self.visibleFields(in: resolvedFields(for: item))
        maybeWarnForSensitiveCopy(isSensitive: fields.contains(where: \.isSensitive))
        container.clipboard.copy(CopyFormatter.envString(for: item, fields: fields), label: ".env")
    }

    func copyJSON(for item: SecretItemEntity) {
        let fields = Self.visibleFields(in: resolvedFields(for: item))
        guard let json = try? CopyFormatter.jsonString(for: item, fields: fields) else { return }
        maybeWarnForSensitiveCopy(isSensitive: fields.contains(where: \.isSensitive))
        container.clipboard.copy(json, label: "JSON")
    }

    func copyConnectionString(for item: SecretItemEntity) {
        let fields = Self.visibleFields(in: resolvedFields(for: item))
        guard let value = try? CopyFormatter.databaseConnectionString(for: item, fields: fields) else { return }
        maybeWarnForSensitiveCopy(isSensitive: fields.contains(where: \.isSensitive))
        container.clipboard.copy(value, label: "Connection String")
    }

    // MARK: - Undo

    /// One reversible step: the whole vault as it was, plus what the action was called.
    private struct UndoStep {
        let snapshot: VaultSnapshot
        let label: String
    }

    /// Single-level undo for actions that destroy or rewrite data in bulk.
    ///
    /// Snapshots are cheap relative to the operations they guard (delete, bulk edit,
    /// restore-from-backup), and one level is enough to cover "that wasn't what I meant"
    /// without turning the vault into a document store.
    @ObservationIgnored private var undoStep: UndoStep?

    var undoActionLabel: String? { undoStep?.label }

    /// Captures the current vault before a destructive action.
    private func captureUndo(_ label: String) {
        guard container.sessionManager.lockState == .unlocked else { return }
        undoStep = UndoStep(snapshot: container.memoryStore.makeSnapshot(), label: label)
    }

    func undoLastDestructiveAction() {
        guard let step = undoStep else { return }
        undoStep = nil
        do {
            try container.memoryStore.replaceContents(with: step.snapshot)
            reload()
            lastActionMessage = "Undid \(step.label.lowercased())."
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    @discardableResult
    func exportSelectedItems(password: String, confirmation: String) async -> Bool {
        guard container.sessionManager.lockState == .unlocked else {
            alertMessage = TransferError.missingPassword.localizedDescription
            return false
        }
        guard !password.isEmpty else {
            alertMessage = TransferError.missingPassword.localizedDescription
            return false
        }
        guard password == confirmation else {
            alertMessage = TransferError.exportPasswordMismatch.localizedDescription
            return false
        }
        let backup = ExportedBackupPayload(
            vault: container.memoryStore.makeSnapshot(),
            settings: container.settings.makeSettingsSnapshot()
        )
        isWorking = true
        defer { isWorking = false }
        do {
            // Wrapping the export key is a full Argon2id pass; on the main actor it froze
            // the sheet for about a second with no indication anything was happening.
            let data = try await container.exportService.exportFullBackup(backup: backup, password: password)
            pendingExportData = data
            return true
        } catch {
            alertMessage = error.localizedDescription
            return false
        }
    }

    /// True while a long crypto operation is running, so sheets can show a spinner.
    var isWorking = false

    /// Run after the export SwiftUI sheet dismisses; presents the system save UI via SwiftUI `fileExporter` (works with App Sandbox write entitlement).
    func completeExportAfterSheetDismissed() {
        guard let data = pendingExportData else { return }
        pendingExportData = nil
        exportFileDocument = JSONExportDocument(data: data)
        isPresentingExportFileExporter = true
    }

    func handleExportFileCompletion(_ result: Result<URL, Error>) {
        exportFileDocument = nil
        isPresentingExportFileExporter = false
        if case let .failure(error) = result {
            let ns = error as NSError
            if ns.domain == NSCocoaErrorDomain, ns.code == NSUserCancelledError { return }
            alertMessage = error.localizedDescription
        }
    }

    func applyImportFilePickerResult(_ result: Result<[URL], Error>) {
        switch result {
        case let .failure(error):
            let ns = error as NSError
            if ns.domain == NSCocoaErrorDomain, ns.code == NSUserCancelledError { return }
            alertMessage = error.localizedDescription
        case let .success(urls):
            guard let url = urls.first else { return }
            let gotAccess = url.startAccessingSecurityScopedResource()
            defer {
                if gotAccess { url.stopAccessingSecurityScopedResource() }
            }
            guard let data = try? Data(contentsOf: url) else {
                alertMessage = "Could not read the selected file."
                return
            }
            pendingImportFileData = data
            importExportSelectedFileName = url.lastPathComponent
        }
    }

    /// Clears file-picker selection when the import sheet closes.
    func onImportExportSheetDismissed() {
        pendingImportFileData = nil
        importExportSelectedFileName = nil
    }

    // MARK: - Backup import
    //
    // Restoring a backup used to run the moment the password was accepted: a v3 file silently
    // replaced every workspace, item, template and preference in the vault, with no summary,
    // no confirmation and no way back. It is now a two-step flow — decrypt and summarise,
    // then apply the way the owner chooses — and the previous vault is copied aside first.

    /// Decrypted backup waiting for the owner to choose how to apply it.
    @ObservationIgnored private var stagedImport: ImportedPayload?
    /// Summary of `stagedImport`, shown by the preview sheet.
    private(set) var importPreview: ImportPreview?

    /// Decrypts the chosen file and produces a summary. Nothing is written yet.
    @discardableResult
    func prepareImport(password: String) async -> Bool {
        guard container.sessionManager.lockState == .unlocked else {
            alertMessage = "Unlock the vault before importing."
            return false
        }
        guard !password.isEmpty else {
            alertMessage = TransferError.missingPassword.localizedDescription
            return false
        }
        guard let fileData = pendingImportFileData else {
            alertMessage = TransferError.importFileMissing.localizedDescription
            return false
        }

        isWorking = true
        defer { isWorking = false }

        do {
            let imported = try await container.exportService.importPayload(from: fileData, password: password)
            stagedImport = imported
            importPreview = makePreview(for: imported, fileName: importExportSelectedFileName ?? "backup.pstore")
            return true
        } catch {
            alertMessage = error.localizedDescription
            return false
        }
    }

    func cancelStagedImport() {
        stagedImport = nil
        importPreview = nil
    }

    private func makePreview(for imported: ImportedPayload, fileName: String) -> ImportPreview {
        switch imported {
        case let .fullBackup(backup):
            let existing = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            var identical = 0
            var conflicting = 0
            for incoming in backup.vault.items {
                guard let current = existing[incoming.id] else { continue }
                if Self.isSameContent(current, incoming) { identical += 1 } else { conflicting += 1 }
            }
            return ImportPreview(
                itemCount: backup.vault.items.count,
                workspaceCount: backup.vault.workspaces.count,
                templateCount: backup.vault.customTemplates.count,
                createdAt: nil,
                fileName: fileName,
                conflictingItemCount: conflicting,
                identicalItemCount: identical,
                isLegacyFormat: false
            )
        case let .legacyItems(payloads):
            return ImportPreview(
                itemCount: payloads.count,
                workspaceCount: Set(payloads.compactMap(\.workspaceName)).count,
                templateCount: 0,
                createdAt: nil,
                fileName: fileName,
                conflictingItemCount: 0,
                identicalItemCount: 0,
                isLegacyFormat: true
            )
        }
    }

    /// Compares an in-memory item with a snapshot on the fields a person would call content.
    private static func isSameContent(_ item: SecretItemEntity, _ snapshot: SecretItemSnapshot) -> Bool {
        guard item.title == snapshot.title,
              item.typeRawValue == snapshot.typeRawValue,
              item.notes == snapshot.notes,
              item.tagsRawValue == snapshot.tagsRawValue,
              item.fields.count == snapshot.fields.count else { return false }
        let current = Dictionary(item.fields.map { ($0.fieldKey, $0.plainValue) }, uniquingKeysWith: { first, _ in first })
        return snapshot.fields.allSatisfy { current[$0.fieldKey] == $0.plainValue }
    }

    /// Writes the staged backup into the vault.
    @discardableResult
    func applyStagedImport(mode: ImportPreview.Mode) -> ImportOutcome? {
        guard let imported = stagedImport else {
            alertMessage = TransferError.importFileMissing.localizedDescription
            return nil
        }

        // Two safety nets: an in-session undo, and a copy of the encrypted files so the
        // import survives being wrong even after a relaunch.
        captureUndo(mode == .replace ? "Vault replacement" : "Backup merge")
        try? container.sessionManager.writeRollbackCopy()

        do {
            let outcome: ImportOutcome
            switch imported {
            case let .fullBackup(backup):
                outcome = try applyFullBackup(backup, mode: mode)
            case let .legacyItems(payloads):
                outcome = try applyLegacyItems(payloads, mode: mode)
            }
            stagedImport = nil
            importPreview = nil
            pendingImportFileData = nil
            importExportSelectedFileName = nil
            reload()
            lastActionMessage = outcome.summary
            return outcome
        } catch {
            alertMessage = error.localizedDescription
            return nil
        }
    }

    private func applyFullBackup(_ backup: ExportedBackupPayload, mode: ImportPreview.Mode) throws -> ImportOutcome {
        switch mode {
        case .replace:
            try container.memoryStore.replaceContents(with: backup.vault)
            container.settings.applySettings(from: backup.settings)
            // The restored preference and the Keychain entry must not disagree: a backup that
            // says "biometrics on" does not by itself put a usable key in this Mac's Keychain.
            container.sessionManager.syncBiometricPreferenceIfUnlocked()
            return ImportOutcome(
                mode: .replace,
                addedItems: backup.vault.items.count,
                addedWorkspaces: backup.vault.workspaces.count,
                skippedIdentical: 0
            )
        case .merge:
            return try mergeSnapshot(backup.vault)
        }
    }

    /// Adds what the backup has and the vault does not. Nothing existing is overwritten.
    ///
    /// An incoming item whose id already exists is imported as a *new* item rather than
    /// replacing the local one — losing a local edit to a silent id collision would defeat
    /// the point of offering merge at all. Byte-identical items are skipped.
    private func mergeSnapshot(_ snapshot: VaultSnapshot) throws -> ImportOutcome {
        var addedWorkspaces = 0
        var workspaceRemap: [UUID: UUID] = [:]
        let existingWorkspaces = try container.workspaceRepository.fetchAll(includeArchived: true)
        let existingWorkspaceIDs = Set(existingWorkspaces.map(\.id))

        for incoming in snapshot.workspaces {
            if existingWorkspaceIDs.contains(incoming.id) {
                workspaceRemap[incoming.id] = incoming.id
                continue
            }
            if let sameName = existingWorkspaces.first(where: {
                $0.name.localizedCaseInsensitiveCompare(incoming.name) == .orderedSame
            }) {
                workspaceRemap[incoming.id] = sameName.id
                continue
            }
            let created = try container.workspaceRepository.saveWorkspace(
                WorkspaceDraft(
                    id: nil,
                    name: incoming.name,
                    icon: incoming.icon,
                    colorHex: incoming.colorHex,
                    notes: incoming.notes
                )
            )
            workspaceRemap[incoming.id] = created.id
            addedWorkspaces += 1
        }

        let existingItems = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var added = 0
        var skipped = 0

        for incoming in snapshot.items {
            if let current = existingItems[incoming.id] {
                if Self.isSameContent(current, incoming) {
                    skipped += 1
                    continue
                }
            }
            var draft = Self.draft(from: incoming, workspaceID: incoming.workspaceID.flatMap { workspaceRemap[$0] })
            if existingItems[incoming.id] != nil {
                // Same id, different contents: keep both, and say which one arrived.
                draft.id = nil
                draft.title = "\(incoming.title) (imported)"
            }
            _ = try container.itemRepository.saveItem(draft)
            added += 1
        }

        return ImportOutcome(mode: .merge, addedItems: added, addedWorkspaces: addedWorkspaces, skippedIdentical: skipped)
    }

    private static func draft(from snapshot: SecretItemSnapshot, workspaceID: UUID?) -> SecretItemDraft {
        SecretItemDraft(
            id: snapshot.id,
            title: snapshot.title,
            type: SecretItemType(rawValue: snapshot.typeRawValue) ?? .generic,
            workspaceID: workspaceID,
            environment: snapshot.environmentRawValue == EnvironmentKind.custom.rawValue
                ? .custom(snapshot.customEnvironmentName ?? "Custom")
                : .preset(EnvironmentKind(rawValue: snapshot.environmentRawValue) ?? .dev),
            notes: snapshot.notes,
            tags: snapshot.tagsRawValue.split(separator: ",").map(String.init),
            isFavorite: snapshot.isFavorite,
            isArchived: snapshot.isArchived,
            fieldDrafts: snapshot.fields.sorted { $0.sortOrder < $1.sortOrder }.enumerated().map { index, field in
                FieldDraft(
                    key: field.fieldKey,
                    label: field.labelSnapshot,
                    value: field.plainValue,
                    kind: FieldKind(rawValue: field.kindRawValue) ?? .text,
                    isSensitive: field.isSensitive,
                    isCopyable: field.isCopyable,
                    isMasked: field.isMasked,
                    sortOrder: index
                )
            },
            templateID: snapshot.templateID,
            linkedFile: snapshot.linkedFile
        )
    }

    private func applyLegacyItems(_ payloads: [ExportedItemPayload], mode: ImportPreview.Mode) throws -> ImportOutcome {
        guard !payloads.isEmpty else {
            throw TransferError.invalidExportFile
        }
        // A legacy export carries items only, so "replace" would delete workspaces and
        // templates the file cannot restore. It always merges.
        for payload in payloads {
            let workspaceID = try resolveOrCreateWorkspaceID(named: payload.workspaceName)
            let draft = makeDraft(fromExportedPayload: payload, workspaceID: workspaceID)
            _ = try container.itemRepository.saveItem(draft)
        }
        return ImportOutcome(mode: .merge, addedItems: payloads.count, addedWorkspaces: 0, skippedIdentical: 0)
    }

    // MARK: Rollback

    /// Date of the pre-import copy on disk, if one exists.
    var rollbackCopyDate: Date? {
        container.sessionManager.rollbackCopyDate()
    }

    /// Puts the pre-import vault back and locks, so the restored file is read from scratch.
    func restoreRollbackCopy() {
        do {
            try container.sessionManager.restoreRollbackCopy()
            lastActionMessage = "Previous vault restored. Unlock to continue."
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    func discardRollbackCopy() {
        container.sessionManager.discardRollbackCopy()
    }

    private func resolveOrCreateWorkspaceID(named name: String?) throws -> UUID? {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return nil }
        let all = try container.workspaceRepository.fetchAll(includeArchived: true)
        if let match = all.first(where: { $0.name.localizedCaseInsensitiveCompare(trimmed) == .orderedSame }) {
            return match.id
        }
        let created = try container.workspaceRepository.saveWorkspace(
            WorkspaceDraft(id: nil, name: trimmed, icon: "shippingbox", colorHex: "#4A7AFF", notes: "")
        )
        return created.id
    }

    private func environmentFromExport(_ title: String) -> EnvironmentValue {
        if let kind = EnvironmentKind.allCases.first(where: { $0.title == title }) {
            return .preset(kind)
        }
        if title == EnvironmentKind.custom.title {
            return .custom("Custom")
        }
        return .custom(title)
    }

    private func makeDraft(fromExportedPayload payload: ExportedItemPayload, workspaceID: UUID?) -> SecretItemDraft {
        let type = SecretItemType.allCases.first { $0.title == payload.type } ?? .generic
        let fieldDrafts = payload.fields.enumerated().map { index, field in
            FieldDraft(
                id: UUID(),
                key: field.key,
                label: field.label,
                value: field.value,
                kind: FieldKind(rawValue: field.kind) ?? .text,
                isSensitive: field.isSensitive,
                isCopyable: true,
                isMasked: field.isSensitive,
                sortOrder: index
            )
        }
        return SecretItemDraft(
            id: nil,
            title: payload.title,
            type: type,
            workspaceID: workspaceID,
            environment: environmentFromExport(payload.environment),
            notes: payload.notes,
            tags: payload.tags,
            isFavorite: payload.isFavorite,
            fieldDrafts: fieldDrafts,
            templateID: nil
        )
    }

    /// Reads a `.env` file from an open panel; returns UTF-8 text, suggested item title, and the file name for UI feedback.
    func readEnvFileForImport() -> (content: String, suggestedTitle: String, pickedFileName: String)? {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        guard let string = try? String(contentsOf: url, encoding: .utf8) else {
            alertMessage = "Unable to read the selected .env file as UTF-8 text."
            return nil
        }
        return (string, importedEnvTitle(from: url), url.lastPathComponent)
    }

    func prepareEnvImport(from source: EnvImportSource, parseIntoEntries: Bool = true) -> SecretItemDraft? {
        switch source {
        case let .file(url):
            guard let string = try? String(contentsOf: url, encoding: .utf8) else {
                alertMessage = "Unable to read the selected .env file as UTF-8 text."
                return nil
            }
            return buildEnvImportDraft(
                from: string,
                suggestedTitle: importedEnvTitle(from: url),
                parseIntoEntries: parseIntoEntries
            )
        case let .pastedText(text):
            return buildEnvImportDraft(from: text, suggestedTitle: "Imported .env", parseIntoEntries: parseIntoEntries)
        }
    }

    /// Merges imported `.env` text into an in-progress draft (workspace, tags, title left intact when appropriate).
    func applyEnvImportContent(
        to draft: inout SecretItemDraft,
        raw: String,
        parseIntoEntries: Bool,
        suggestedTitle: String?
    ) {
        let trimmedTitle = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let titleForBuild: String
        if let suggestedTitle, !suggestedTitle.isEmpty {
            titleForBuild = suggestedTitle
        } else if trimmedTitle.isEmpty {
            titleForBuild = "Imported .env"
        } else {
            titleForBuild = trimmedTitle
        }

        let built = buildEnvImportDraft(from: raw, suggestedTitle: titleForBuild, parseIntoEntries: parseIntoEntries)
        draft.fieldDrafts = built.fieldDrafts
        draft.notes = built.notes

        guard trimmedTitle.isEmpty else { return }
        if let suggestedTitle, !suggestedTitle.isEmpty {
            draft.title = suggestedTitle
        } else {
            draft.title = built.title
        }
    }

    func draftForSelectedItem() -> SecretItemDraft {
        selectedItem.map(makeDraft(from:)) ?? newItemDraft()
    }

    /// Editor draft for a specific item, independent of what is selected.
    func draft(forItemID id: UUID) -> SecretItemDraft {
        items.first(where: { $0.id == id }).map(makeDraft(from:)) ?? draftForSelectedItem()
    }

    func item(withID id: UUID) -> SecretItemEntity? {
        items.first(where: { $0.id == id })
    }

    func newItemDraft(template: SecretFieldTemplateEntity? = nil) -> SecretItemDraft {
        let template = template ?? defaultTemplate(for: .generic)
        return SecretItemDraft(
            title: "",
            type: template?.itemType ?? .generic,
            workspaceID: preferredWorkspaceID,
            environment: preferredEnvironment,
            notes: "",
            tags: [],
            isFavorite: false,
            fieldDrafts: (template?.fieldDefinitions.sorted { $0.sortOrder < $1.sortOrder } ?? []).map {
                FieldDraft(
                    key: $0.key,
                    label: $0.label,
                    value: "",
                    kind: $0.kind,
                    isSensitive: $0.isSensitive,
                    isCopyable: $0.isCopyable,
                    isMasked: $0.isMaskedByDefault,
                    sortOrder: $0.sortOrder
                )
            },
            templateID: template?.id
        )
    }

    func defaultTemplate(for type: SecretItemType) -> SecretFieldTemplateEntity? {
        templates.first(where: { $0.itemType == type && $0.isBuiltIn })
            ?? templates.first(where: { $0.itemType == type })
    }

    /// Updates the draft's item type. When no field has stored content yet, replaces `fieldDrafts`
    /// with the default template for `newType`. When any value or secret reference is present,
    /// only `type` changes so existing data is never cleared.
    func applyItemTypeChange(to draft: inout SecretItemDraft, newType: SecretItemType) {
        guard draft.type != newType else { return }

        if Self.draftHasAnyStoredFieldContent(draft) {
            draft.type = newType
            return
        }

        let oldByKey = Dictionary(draft.fieldDrafts.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        let template = defaultTemplate(for: newType)
        let defs = template?.fieldDefinitions.sorted { $0.sortOrder < $1.sortOrder } ?? []

        draft.type = newType
        draft.templateID = template?.id

        guard !defs.isEmpty else { return }

        draft.fieldDrafts = defs.enumerated().map { index, def in
            if let old = oldByKey[def.key] {
                FieldDraft(
                    id: old.id,
                    key: def.key,
                    label: def.label,
                    value: old.value,
                    kind: def.kind,
                    isSensitive: def.isSensitive,
                    isCopyable: def.isCopyable,
                    isMasked: def.isMaskedByDefault,
                    sortOrder: index,
                    secretReference: old.secretReference
                )
            } else {
                FieldDraft(
                    key: def.key,
                    label: def.label,
                    value: "",
                    kind: def.kind,
                    isSensitive: def.isSensitive,
                    isCopyable: def.isCopyable,
                    isMasked: def.isMaskedByDefault,
                    sortOrder: index
                )
            }
        }
    }

    private static func draftHasAnyStoredFieldContent(_ draft: SecretItemDraft) -> Bool {
        draft.fieldDrafts.contains { fieldHasStoredContent($0) }
    }

    private static func fieldHasStoredContent(_ field: FieldDraft) -> Bool {
        if field.secretReference != nil { return true }
        return !field.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func draftForWorkspace(_ workspace: WorkspaceEntity?) -> WorkspaceDraft {
        guard let workspace else { return .empty }
        return WorkspaceDraft(id: workspace.id, name: workspace.name, icon: workspace.icon, colorHex: workspace.colorHex, notes: workspace.notes)
    }

    func draftForTemplate(_ template: SecretFieldTemplateEntity?) -> TemplateDraft {
        guard let template else {
            return TemplateDraft(name: "", itemType: .customTemplate, fieldDefinitions: [])
        }
        return TemplateDraft(
            id: template.isBuiltIn ? nil : template.id,
            name: template.name,
            itemType: template.itemType,
            fieldDefinitions: template.fieldDefinitions.sorted { $0.sortOrder < $1.sortOrder }.map {
                .init(
                    id: $0.id,
                    key: $0.key,
                    label: $0.label,
                    kind: $0.kind,
                    isSensitive: $0.isSensitive,
                    isCopyable: $0.isCopyable,
                    isMaskedByDefault: $0.isMaskedByDefault,
                    sortOrder: $0.sortOrder
                )
            }
        )
    }

    func workspace(for id: UUID?) -> WorkspaceEntity? {
        guard let id else { return nil }
        return workspaces.first(where: { $0.id == id })
    }

    func template(for id: UUID?) -> SecretFieldTemplateEntity? {
        guard let id else { return nil }
        return templates.first(where: { $0.id == id })
    }

    func resolvedFields(for item: SecretItemEntity) -> [FieldResolvedValue] {
        (try? container.itemRepository.resolveFields(for: item)) ?? []
    }

    static func visibleFields(in fields: [FieldResolvedValue]) -> [FieldResolvedValue] {
        fields.filter { !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    private var preferredWorkspaceID: UUID? {
        switch selectedDestination {
        case let .workspace(id):
            id
        default:
            selectedItem?.workspace?.id ?? workspaces.first?.id
        }
    }

    private var preferredEnvironment: EnvironmentValue {
        switch selectedDestination {
        case let .environment(environment):
            Self.environmentValue(from: environment)
        default:
            selectedItem?.environmentValue ?? .preset(.dev)
        }
    }

    private static func environmentValue(from title: String) -> EnvironmentValue {
        if let kind = EnvironmentKind.allCases.first(where: { $0.title == title && $0 != .custom }) {
            return .preset(kind)
        }
        return .custom(title)
    }

    private func makeDraft(from item: SecretItemEntity) -> SecretItemDraft {
        SecretItemDraft(
            id: item.id,
            title: item.title,
            type: item.type,
            workspaceID: item.workspace?.id,
            environment: item.environmentValue,
            notes: item.notes,
            tags: item.tags,
            isFavorite: item.isFavorite,
            isArchived: item.isArchived,
            fieldDrafts: resolvedFields(for: item).enumerated().map { index, field in
                FieldDraft(
                    key: field.key,
                    label: field.label,
                    value: field.value,
                    kind: field.kind,
                    isSensitive: field.isSensitive,
                    isCopyable: field.isCopyable,
                    isMasked: field.isMasked,
                    sortOrder: index,
                    secretReference: item.fields.first(where: { $0.fieldKey == field.key })?.secretReference
                )
            },
            templateID: item.template?.id,
            linkedFile: item.linkedFile
        )
    }

    private func normalizeSelection() {
        if case let .workspace(id) = selectedDestination, workspace(for: id) == nil {
            selectedDestination = .library(.allItems)
        }
        syncSelectedItem()
    }

    private func syncSelectedItem() {
        if let selectedItemID, filteredItems.contains(where: { $0.id == selectedItemID }) {
            return
        }
        selectedItemID = nil
    }

    private func applyUITestLaunchOverrides() {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("--uitesting") else { return }

        if let destinationArgument = arguments.first(where: { $0.hasPrefix("--ui-select-destination=") }) {
            let token = String(destinationArgument.dropFirst("--ui-select-destination=".count))
            if token == "all-items" {
                selectedDestination = .library(.allItems)
            } else if token.hasPrefix("workspace:") {
                let workspaceToken = String(token.dropFirst("workspace:".count))
                if let workspace = workspaces.first(where: { Self.launchToken(for: $0.name) == workspaceToken }) {
                    selectedDestination = .workspace(workspace.id)
                }
            }
        }

        if let itemArgument = arguments.first(where: { $0.hasPrefix("--ui-select-item=") }) {
            let token = String(itemArgument.dropFirst("--ui-select-item=".count))
            if let item = items.first(where: { Self.launchToken(for: $0.title) == token }) {
                selectedItemID = item.id
            }
        }
    }

    private static func launchToken(for value: String) -> String {
        value
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .replacingOccurrences(of: "[^a-zA-Z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
            .lowercased()
    }

    /// Archives or restores in place.
    ///
    /// This used to jump the sidebar to Archived (or All Items) afterwards, so archiving one
    /// item while working inside a workspace threw you out of that workspace. The selection
    /// is simply cleared when the item leaves the current destination.
    private func updateArchiveState(for item: SecretItemEntity, isArchived: Bool) {
        var draft = makeDraft(from: item)
        draft.id = item.id
        draft.isArchived = isArchived
        do {
            let saved = try container.itemRepository.saveItem(draft)
            reload()
            if filteredItems.contains(where: { $0.id == saved.id }) {
                selectedItemID = saved.id
            } else {
                selectedItemID = nil
                lastActionMessage = isArchived
                    ? "“\(saved.title)” archived."
                    : "“\(saved.title)” restored."
            }
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    // MARK: - Transient status message

    /// Short confirmation shown in the list footer — used when something succeeded but the
    /// result moved out of view, which otherwise looks like nothing happened.
    var lastActionMessage: String? {
        didSet {
            guard lastActionMessage != nil else { return }
            statusMessageDismissal?.cancel()
            statusMessageDismissal = Task { [weak self] in
                try? await Task.sleep(for: .seconds(4))
                guard !Task.isCancelled else { return }
                self?.lastActionMessage = nil
            }
        }
    }

    @ObservationIgnored private var statusMessageDismissal: Task<Void, Never>?

    private func buildEnvImportDraft(from string: String, suggestedTitle: String, parseIntoEntries: Bool) -> SecretItemDraft {
        if parseIntoEntries {
            makeEnvImportDraft(from: string, suggestedTitle: suggestedTitle)
        } else {
            makeEnvRawTextDraft(from: string, suggestedTitle: suggestedTitle)
        }
    }

    /// Parses `KEY=value` lines into separate fields; if nothing parses, keeps one multiline block.
    private func makeEnvImportDraft(from string: String, suggestedTitle: String) -> SecretItemDraft {
        let parsed = container.envImport.parse(string)
        let fieldDrafts: [FieldDraft]
        if parsed.entries.isEmpty {
            fieldDrafts = [
                FieldDraft(
                    key: "env",
                    label: ".env",
                    value: string,
                    kind: .multiline,
                    isSensitive: true,
                    isCopyable: true,
                    isMasked: true,
                    sortOrder: 0
                )
            ]
        } else {
            fieldDrafts = parsed.entries.enumerated().map { index, entry in
                FieldDraft(
                    key: entry.key,
                    label: entry.key,
                    value: entry.value,
                    kind: .text,
                    isSensitive: entry.isSensitive,
                    isCopyable: true,
                    isMasked: entry.isSensitive,
                    sortOrder: index
                )
            }
        }

        return SecretItemDraft(
            title: suggestedTitle,
            type: .envGroup,
            workspaceID: preferredWorkspaceID,
            environment: preferredEnvironment,
            notes: parsed.notes,
            tags: [],
            isFavorite: false,
            fieldDrafts: fieldDrafts,
            templateID: templates.first(where: { $0.itemType == .envGroup })?.id
        )
    }

    /// Stores the entire file as a single multiline `.env` field (no parsing).
    private func makeEnvRawTextDraft(from string: String, suggestedTitle: String) -> SecretItemDraft {
        SecretItemDraft(
            title: suggestedTitle,
            type: .envGroup,
            workspaceID: preferredWorkspaceID,
            environment: preferredEnvironment,
            notes: "",
            tags: [],
            isFavorite: false,
            fieldDrafts: [
                FieldDraft(
                    key: "env",
                    label: ".env",
                    value: string,
                    kind: .multiline,
                    isSensitive: true,
                    isCopyable: true,
                    isMasked: true,
                    sortOrder: 0
                )
            ],
            templateID: templates.first(where: { $0.itemType == .envGroup })?.id
        )
    }

    private func maybeWarnForSensitiveCopy(isSensitive: Bool) {
        guard isSensitive, container.clipboard.shouldWarnAboutSensitiveCopy else { return }
        container.clipboard.markSensitiveCopyWarningShown()
        alertMessage = "Copied secrets go through the macOS system clipboard and can be read by clipboard managers or other apps while present."
    }

    private func matchesDestination(_ item: SecretItemEntity) -> Bool {
        switch selectedDestination {
        case let .library(section):
            return Self.matches(section: section, item: item)
        case let .workspace(id):
            // The type filter narrows within the workspace. It used to widen to the whole
            // vault while the header still named the workspace, so the title described a
            // scope the list was not showing.
            return item.workspace?.id == id && !item.isArchived
        case let .tag(tag):
            return item.tags.contains(tag) && !item.isArchived
        case let .environment(environment):
            return item.environmentValue.title == environment && !item.isArchived
        }
    }

    /// Shared by the list filter and the sidebar badges so a count can never disagree with
    /// what clicking it shows.
    private static func matches(section: LibrarySection, item: SecretItemEntity) -> Bool {
        switch section {
        case .allItems:
            !item.isArchived
        case .favorites:
            item.isFavorite && !item.isArchived
        // "Recent" used to be an exact copy of "All Items" with a different sort — same rows,
        // same badge. It now means what it says: things actually opened.
        case .recent:
            !item.isArchived && item.lastAccessedAt != nil
        case .archived:
            item.isArchived
        }
    }

    private func matchesSearchAndType(_ item: SecretItemEntity) -> Bool {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let typeMatch = selectedType == nil || item.type == selectedType
        guard !query.isEmpty else { return typeMatch }
        return typeMatch && matchesQuery(item, query: query)
    }

    /// Every whitespace-separated token has to match somewhere, so "postgres prod" narrows
    /// instead of matching either word.
    private func matchesQuery(_ item: SecretItemEntity, query: String) -> Bool {
        let tokens = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !tokens.isEmpty else { return true }
        return tokens.allSatisfy { token in
            item.title.localizedCaseInsensitiveContains(token)
                || item.notes.localizedCaseInsensitiveContains(token)
                || item.tags.contains(where: { $0.localizedCaseInsensitiveContains(token) })
                || item.environmentValue.title.localizedCaseInsensitiveContains(token)
                || item.type.title.localizedCaseInsensitiveContains(token)
                || item.workspace?.name.localizedCaseInsensitiveContains(token) == true
                || item.fields.contains { field in
                    if field.labelSnapshot.localizedCaseInsensitiveContains(token) { return true }
                    // Non-sensitive values only: matching on a password or token would let the
                    // search box confirm a secret's contents without ever revealing it.
                    guard !field.isSensitive else { return false }
                    return field.plainValue.localizedCaseInsensitiveContains(token)
                }
        }
    }

    /// "Recent" is the one destination that defines its own order — it exists to answer
    /// "what did I just use?" — so it ignores the chosen sort. Everywhere else the sort is
    /// the owner's choice rather than a hard-coded A-Z.
    private var effectiveSortOrder: ItemSortOrder {
        if case .library(.recent) = selectedDestination { return .recentlyUsed }
        return sortOrder
    }

    private func sortComparator(lhs: SecretItemEntity, rhs: SecretItemEntity) -> Bool {
        switch effectiveSortOrder {
        case .title:
            break
        case .recentlyUsed:
            // Never used sorts below everything used, rather than pretending it was used at
            // the epoch or at its edit date.
            let lhsDate = lhs.lastAccessedAt
            let rhsDate = rhs.lastAccessedAt
            if lhsDate != rhsDate {
                switch (lhsDate, rhsDate) {
                case let (l?, r?): return l > r
                case (_?, nil): return true
                case (nil, _?): return false
                default: break
                }
            }
        case .recentlyUpdated:
            if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
        case .newestFirst:
            if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
        }
        return compareByTitleThenWorkspace(lhs: lhs, rhs: rhs)
    }

    private func compareByTitleThenWorkspace(lhs: SecretItemEntity, rhs: SecretItemEntity) -> Bool {
        let titleComparison = lhs.title.localizedCaseInsensitiveCompare(rhs.title)
        if titleComparison != .orderedSame {
            return titleComparison == .orderedAscending
        }

        let lhsWorkspace = lhs.workspace?.name ?? ""
        let rhsWorkspace = rhs.workspace?.name ?? ""
        let workspaceComparison = lhsWorkspace.localizedCaseInsensitiveCompare(rhsWorkspace)
        if workspaceComparison != .orderedSame {
            return workspaceComparison == .orderedAscending
        }

        let environmentComparison = lhs.environmentValue.title.localizedCaseInsensitiveCompare(rhs.environmentValue.title)
        if environmentComparison != .orderedSame {
            return environmentComparison == .orderedAscending
        }

        return lhs.id.uuidString < rhs.id.uuidString
    }

    private func templateSortComparator(lhs: SecretFieldTemplateEntity, rhs: SecretFieldTemplateEntity) -> Bool {
        if lhs.isBuiltIn != rhs.isBuiltIn {
            return lhs.isBuiltIn && !rhs.isBuiltIn
        }
        let lhsPriority = templatePriority(for: lhs.itemType)
        let rhsPriority = templatePriority(for: rhs.itemType)
        if lhsPriority != rhsPriority {
            return lhsPriority < rhsPriority
        }
        return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
    }

    private func templatePriority(for type: SecretItemType) -> Int {
        switch type {
        case .generic:
            0
        case .websiteService:
            1
        case .apiCredential:
            2
        case .database:
            3
        case .serverSSH:
            4
        case .savedCommand:
            5
        case .s3Compatible:
            6
        case .envGroup:
            7
        case .customTemplate:
            8
        }
    }

    func suggestedEnvImportTitle(for url: URL) -> String {
        importedEnvTitle(from: url)
    }

    private func importedEnvTitle(from url: URL) -> String {
        let trimmedName = url.deletingPathExtension().lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedName.isEmpty {
            return trimmedName
        }
        return url.lastPathComponent
    }
}

@MainActor
@Observable
final class MenuBarViewModel {
    let vault: VaultViewModel
    var searchText = ""

    init(vault: VaultViewModel) {
        self.vault = vault
    }

    var quickItems: [SecretItemEntity] {
        vault.items
            .filter(\.isFavorite)
            .filter { !quickFields(for: $0).isEmpty }
            .filter {
                searchText.isEmpty
                || $0.title.localizedCaseInsensitiveContains(searchText)
                || $0.tags.contains(where: { tag in tag.localizedCaseInsensitiveContains(searchText) })
                || quickFields(for: $0).contains(where: {
                    $0.label.localizedCaseInsensitiveContains(searchText)
                        || $0.key.localizedCaseInsensitiveContains(searchText)
                })
            }
            .sorted {
                let lhsDate = $0.lastAccessedAt ?? $0.updatedAt
                let rhsDate = $1.lastAccessedAt ?? $1.updatedAt
                if lhsDate != rhsDate { return lhsDate > rhsDate }
                return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
            }
            .prefix(8)
            .map { $0 }
    }

    func quickFields(for item: SecretItemEntity) -> [FieldResolvedValue] {
        vault.resolvedFields(for: item)
            .filter(\.isCopyable)
            .filter { !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
}
