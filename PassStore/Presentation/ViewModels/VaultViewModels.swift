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
        items.filter { item in
            switch section {
            case .allItems: !item.isArchived
            case .favorites: item.isFavorite && !item.isArchived
            case .recent: !item.isArchived
            case .archived: item.isArchived
            }
        }.count
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

    var filteredItems: [SecretItemEntity] {
        items
            .filter(matchesDestination)
            .filter(matchesSearchAndType)
            .sorted(by: sortComparator)
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
            workspaces = try container.workspaceRepository.fetchAll(includeArchived: false)
            items = try container.itemRepository.fetchAll(includeArchived: true)
            templates = try container.templateRepository.fetchAll()
            normalizeSelection()
        } catch {
            alertMessage = error.localizedDescription
        }
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

    func select(_ item: SecretItemEntity?) {
        selectedItemID = item?.id
        multiSelectedIDs.removeAll()
        guard let item else { return }
        _ = try? container.itemRepository.recordItemAccess(item)
        reload()
        selectedItemID = item.id
    }

    // MARK: - Multi-selection

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
    func vaultHealthReport() -> VaultHealthReport {
        let active = items.filter { !$0.isArchived }
        var findings: [VaultHealthFinding] = []

        // Group sensitive values to spot reuse. Hashed so plaintext never lands in the report.
        var occurrencesByDigest: [String: [(item: SecretItemEntity, label: String)]] = [:]

        for item in active {
            let fields = Self.visibleFields(in: resolvedFields(for: item))
            for field in fields where field.isSensitive {
                let digest = Self.digest(field.value)
                occurrencesByDigest[digest, default: []].append((item, field.label))

                let strength = PasswordStrength.evaluate(field.value)
                if strength.needsAttention {
                    findings.append(
                        VaultHealthFinding(
                            id: "weak-\(item.id.uuidString)-\(field.key)",
                            kind: .weak,
                            itemID: item.id,
                            itemTitle: item.title,
                            detail: "\(field.label) — \(strength.label.lowercased())"
                        )
                    )
                }
            }
        }

        for (_, occurrences) in occurrencesByDigest {
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
                        detail: "\(occurrence.label) — also used in \(others.joined(separator: ", "))"
                    )
                )
            }
        }

        let staleCutoff = Date().addingTimeInterval(-Self.staleItemInterval)
        for item in active where item.updatedAt < staleCutoff {
            let months = Int(Date().timeIntervalSince(item.updatedAt) / (30 * 24 * 3600))
            findings.append(
                VaultHealthFinding(
                    id: "stale-\(item.id.uuidString)",
                    kind: .stale,
                    itemID: item.id,
                    itemTitle: item.title,
                    detail: "Not updated in about \(months) months"
                )
            )
        }

        return VaultHealthReport(
            auditedItemCount: active.count,
            findings: findings.sorted {
                if $0.kind != $1.kind { return $0.kind.severity < $1.kind.severity }
                return $0.itemTitle.localizedCaseInsensitiveCompare($1.itemTitle) == .orderedAscending
            }
        )
    }

    /// Items untouched for a year are surfaced as worth rotating or retiring.
    private static let staleItemInterval: TimeInterval = 365 * 24 * 3600

    private static func digest(_ value: String) -> String {
        Data(SHA256.hash(data: Data(value.utf8))).base64EncodedString()
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

    @discardableResult
    func exportSelectedItems(password: String, confirmation: String) -> Bool {
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
        do {
            let data = try container.exportService.exportFullBackup(backup: backup, password: password)
            pendingExportData = data
            return true
        } catch {
            alertMessage = error.localizedDescription
            return false
        }
    }

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

    @discardableResult
    func importEncryptedExport(password: String) -> Bool {
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
        do {
            let imported = try container.exportService.importPayload(from: fileData, password: password)
            switch imported {
            case let .fullBackup(backup):
                try container.memoryStore.replaceContents(with: backup.vault)
                container.settings.applySettings(from: backup.settings)
                reload()
            case let .legacyItems(payloads):
                guard !payloads.isEmpty else {
                    alertMessage = "The export file contains no items."
                    return false
                }
                for payload in payloads {
                    let workspaceID = try resolveOrCreateWorkspaceID(named: payload.workspaceName)
                    let draft = makeDraft(fromExportedPayload: payload, workspaceID: workspaceID)
                    _ = try container.itemRepository.saveItem(draft)
                }
                reload()
            }
            pendingImportFileData = nil
            importExportSelectedFileName = nil
            return true
        } catch let error as TransferError {
            alertMessage = error.localizedDescription
            return false
        } catch {
            alertMessage = error.localizedDescription
            return false
        }
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
            templateID: item.template?.id
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

    private func updateArchiveState(for item: SecretItemEntity, isArchived: Bool) {
        var draft = makeDraft(from: item)
        draft.id = item.id
        draft.isArchived = isArchived
        do {
            let saved = try container.itemRepository.saveItem(draft)
            reload()
            selectedDestination = isArchived ? .library(.archived) : .library(.allItems)
            selectedItemID = saved.id
        } catch {
            alertMessage = error.localizedDescription
        }
    }

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
            switch section {
            case .allItems:
                return !item.isArchived
            case .favorites:
                return item.isFavorite && !item.isArchived
            case .recent:
                return !item.isArchived
            case .archived:
                return item.isArchived
            }
        case let .workspace(id):
            // Browsing by type: show matching items across every workspace (not only the last-selected one).
            if selectedType != nil {
                return !item.isArchived
            }
            return item.workspace?.id == id && !item.isArchived
        case let .tag(tag):
            return item.tags.contains(tag) && !item.isArchived
        case let .environment(environment):
            return item.environmentValue.title == environment && !item.isArchived
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

    private func sortComparator(lhs: SecretItemEntity, rhs: SecretItemEntity) -> Bool {
        if case .library(.recent) = selectedDestination {
            if lhs.updatedAt != rhs.updatedAt {
                return lhs.updatedAt > rhs.updatedAt
            }
            if lhs.createdAt != rhs.createdAt {
                return lhs.createdAt > rhs.createdAt
            }
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
