import Foundation
import Testing
@testable import PassStore

/// Covers the 1.2.0 behaviour changes: non-destructive backup restore, secret value history,
/// linked `.env` files, `.env` round-tripping, sorting, and the fixes to what counts as an
/// edit and what counts as a weak password.
@MainActor
struct PolishAndRecoveryTests {

    // MARK: - Helpers

    private func makeContainer(_ label: String) -> AppContainer {
        let defaults = UserDefaults(suiteName: "\(label)-\(UUID().uuidString)")!
        let container = AppContainer(
            inMemory: true,
            defaults: defaults,
            keyStore: InMemoryVaultKeyStore(isBiometricHardwareAvailable: false),
            encryptedVaultStore: InMemoryEncryptedVaultStore()
        )
        container.sessionManager.createVaultSynchronously(password: "test-password")
        return container
    }

    private func draft(
        title: String,
        id: UUID? = nil,
        secret: String = "value-one",
        workspaceID: UUID? = nil
    ) -> SecretItemDraft {
        SecretItemDraft(
            id: id,
            title: title,
            type: .generic,
            workspaceID: workspaceID,
            environment: .preset(.dev),
            notes: "",
            tags: [],
            isFavorite: false,
            fieldDrafts: [
                FieldDraft(key: "password", label: "Password", value: secret, kind: .secret, isSensitive: true, isMasked: true, sortOrder: 0)
            ],
            templateID: nil
        )
    }

    // MARK: - Backup restore

    @Test func mergingABackupAddsMissingItemsAndKeepsExistingOnes() async throws {
        let source = makeContainer("MergeSource")
        let sourceViewModel = VaultViewModel(container: source)
        _ = try source.itemRepository.saveItem(draft(title: "From Backup"))
        sourceViewModel.reload()

        let backup = ExportedBackupPayload(
            vault: source.memoryStore.makeSnapshot(),
            settings: source.settings.makeSettingsSnapshot()
        )
        let data = try source.exportService.exportFullBackupSynchronously(backup: backup, password: "backup-password")

        let target = makeContainer("MergeTarget")
        let viewModel = VaultViewModel(container: target)
        _ = try target.itemRepository.saveItem(draft(title: "Already Mine"))
        viewModel.reload()

        viewModel.stageImport(data: data, fileName: "backup.pstore")
        #expect(await viewModel.prepareImport(password: "backup-password"))
        let outcome = try #require(viewModel.applyStagedImport(mode: .merge))

        #expect(outcome.addedItems == 1)
        #expect(viewModel.items.contains { $0.title == "Already Mine" })
        #expect(viewModel.items.contains { $0.title == "From Backup" })
    }

    @Test func mergingTheSameBackupTwiceAddsNothingTheSecondTime() async throws {
        let source = makeContainer("MergeTwiceSource")
        _ = try source.itemRepository.saveItem(draft(title: "Only Once"))

        let backup = ExportedBackupPayload(
            vault: source.memoryStore.makeSnapshot(),
            settings: source.settings.makeSettingsSnapshot()
        )
        let data = try source.exportService.exportFullBackupSynchronously(backup: backup, password: "backup-password")

        let target = makeContainer("MergeTwiceTarget")
        let viewModel = VaultViewModel(container: target)

        viewModel.stageImport(data: data, fileName: "backup.pstore")
        #expect(await viewModel.prepareImport(password: "backup-password"))
        _ = viewModel.applyStagedImport(mode: .merge)
        let afterFirst = viewModel.items.count

        viewModel.stageImport(data: data, fileName: "backup.pstore")
        #expect(await viewModel.prepareImport(password: "backup-password"))
        let second = try #require(viewModel.applyStagedImport(mode: .merge))

        #expect(second.addedItems == 0)
        #expect(second.skippedIdentical == 1)
        #expect(viewModel.items.count == afterFirst)
    }

    /// A backup whose item shares an id with a local item but differs in content must not
    /// silently overwrite the local one.
    @Test func mergingAConflictingItemKeepsBothCopies() async throws {
        let sharedID = UUID()

        let source = makeContainer("ConflictSource")
        _ = try source.itemRepository.saveItem(draft(title: "Server Key", id: sharedID, secret: "backup-value"))
        let backup = ExportedBackupPayload(
            vault: source.memoryStore.makeSnapshot(),
            settings: source.settings.makeSettingsSnapshot()
        )
        let data = try source.exportService.exportFullBackupSynchronously(backup: backup, password: "backup-password")

        let target = makeContainer("ConflictTarget")
        let viewModel = VaultViewModel(container: target)
        _ = try target.itemRepository.saveItem(draft(title: "Server Key", id: sharedID, secret: "local-value"))
        viewModel.reload()

        viewModel.stageImport(data: data, fileName: "backup.pstore")
        #expect(await viewModel.prepareImport(password: "backup-password"))
        _ = viewModel.applyStagedImport(mode: .merge)

        let local = try #require(viewModel.items.first { $0.id == sharedID })
        #expect(local.fields.first?.plainValue == "local-value")
        #expect(viewModel.items.contains { $0.title.contains("(imported)") })
    }

    @Test func replacingCanBeUndone() async throws {
        let source = makeContainer("ReplaceSource")
        _ = try source.itemRepository.saveItem(draft(title: "Replacement"))
        let backup = ExportedBackupPayload(
            vault: source.memoryStore.makeSnapshot(),
            settings: source.settings.makeSettingsSnapshot()
        )
        let data = try source.exportService.exportFullBackupSynchronously(backup: backup, password: "backup-password")

        let target = makeContainer("ReplaceTarget")
        let viewModel = VaultViewModel(container: target)
        _ = try target.itemRepository.saveItem(draft(title: "Original"))
        viewModel.reload()

        viewModel.stageImport(data: data, fileName: "backup.pstore")
        #expect(await viewModel.prepareImport(password: "backup-password"))
        _ = viewModel.applyStagedImport(mode: .replace)

        #expect(!viewModel.items.contains { $0.title == "Original" })
        #expect(viewModel.undoActionLabel != nil)

        viewModel.undoLastDestructiveAction()

        #expect(viewModel.items.contains { $0.title == "Original" })
        #expect(!viewModel.items.contains { $0.title == "Replacement" })
    }

    @Test func aRollbackCopyIsTakenBeforeAnImportIsApplied() async throws {
        let source = makeContainer("RollbackSource")
        _ = try source.itemRepository.saveItem(draft(title: "Incoming"))
        let backup = ExportedBackupPayload(
            vault: source.memoryStore.makeSnapshot(),
            settings: source.settings.makeSettingsSnapshot()
        )
        let data = try source.exportService.exportFullBackupSynchronously(backup: backup, password: "backup-password")

        let target = makeContainer("RollbackTarget")
        let viewModel = VaultViewModel(container: target)
        #expect(viewModel.rollbackCopyDate == nil)

        viewModel.stageImport(data: data, fileName: "backup.pstore")
        #expect(await viewModel.prepareImport(password: "backup-password"))
        _ = viewModel.applyStagedImport(mode: .replace)

        #expect(viewModel.rollbackCopyDate != nil)
    }

    // MARK: - Secret value history

    @Test func replacingASecretKeepsThePreviousValue() throws {
        let container = makeContainer("ValueHistory")
        let viewModel = VaultViewModel(container: container)

        let saved = try container.itemRepository.saveItem(draft(title: "Rotating", secret: "first-secret"))
        _ = try container.itemRepository.saveItem(draft(title: "Rotating", id: saved.id, secret: "second-secret"))
        viewModel.reload()

        let item = try #require(viewModel.items.first { $0.title == "Rotating" })
        let field = try #require(item.fields.first)
        #expect(field.plainValue == "second-secret")
        #expect(field.previousValues.map(\.value) == ["first-secret"])
    }

    @Test func fillingAnEmptyFieldForTheFirstTimeRecordsNoHistory() throws {
        let container = makeContainer("ValueHistoryEmpty")
        let saved = try container.itemRepository.saveItem(draft(title: "New", secret: ""))
        _ = try container.itemRepository.saveItem(draft(title: "New", id: saved.id, secret: "first-secret"))

        let field = try #require(saved.fields.first)
        #expect(field.previousValues.isEmpty)
    }

    @Test func valueHistoryIsCapped() throws {
        let container = makeContainer("ValueHistoryCap")
        var saved = try container.itemRepository.saveItem(draft(title: "Churn", secret: "value-0"))
        for index in 1...(SecretItemRepository.valueHistoryLimit + 4) {
            saved = try container.itemRepository.saveItem(draft(title: "Churn", id: saved.id, secret: "value-\(index)"))
        }

        let field = try #require(saved.fields.first)
        #expect(field.previousValues.count == SecretItemRepository.valueHistoryLimit)
        // Newest first: the most recently replaced value leads.
        #expect(field.previousValues.first?.value.hasPrefix("value-") == true)
    }

    @Test func turningHistoryOffStopsNewVersionsBeingRecorded() throws {
        let container = makeContainer("ValueHistoryOff")
        container.settings.keepsSecretValueHistory = false

        let saved = try container.itemRepository.saveItem(draft(title: "Quiet", secret: "first"))
        let updated = try container.itemRepository.saveItem(draft(title: "Quiet", id: saved.id, secret: "second"))

        #expect(updated.fields.first?.previousValues.isEmpty == true)
    }

    @Test func restoringAPreviousValuePutsItBackAndKeepsTheReplacedOne() throws {
        let container = makeContainer("ValueRestore")
        let viewModel = VaultViewModel(container: container)

        let saved = try container.itemRepository.saveItem(draft(title: "Restorable", secret: "old-secret"))
        _ = try container.itemRepository.saveItem(draft(title: "Restorable", id: saved.id, secret: "new-secret"))
        viewModel.reload()

        let item = try #require(viewModel.items.first { $0.title == "Restorable" })
        let version = try #require(viewModel.fieldsWithHistory(for: item).first?.previousValues.first)
        viewModel.restorePreviousValue(version, fieldKey: "password", in: item)

        let restored = try #require(viewModel.items.first { $0.title == "Restorable" })
        let field = try #require(restored.fields.first)
        #expect(field.plainValue == "old-secret")
        #expect(field.previousValues.contains { $0.value == "new-secret" })
    }

    @Test func purgingHistoryRemovesStoredValuesButKeepsTheChangeLog() throws {
        let container = makeContainer("ValuePurge")
        let viewModel = VaultViewModel(container: container)

        let saved = try container.itemRepository.saveItem(draft(title: "Purgeable", secret: "one"))
        _ = try container.itemRepository.saveItem(draft(title: "Purgeable", id: saved.id, secret: "two"))
        viewModel.reload()
        #expect(viewModel.storedPreviousValueCount == 1)

        viewModel.purgeAllValueHistory()

        #expect(viewModel.storedPreviousValueCount == 0)
        let item = try #require(viewModel.items.first { $0.title == "Purgeable" })
        #expect(!item.changeHistory.isEmpty)
    }

    @Test func lockingClearsStoredPreviousValues() throws {
        let container = makeContainer("ValueLock")
        let saved = try container.itemRepository.saveItem(draft(title: "Locked", secret: "one"))
        _ = try container.itemRepository.saveItem(draft(title: "Locked", id: saved.id, secret: "two"))

        let field = try #require(saved.fields.first)
        #expect(!field.previousValues.isEmpty)

        container.sessionManager.lock()
        #expect(field.previousValues.isEmpty)
    }

    // MARK: - What counts as an edit

    @Test func favouritingAnItemDoesNotCountAsModifyingIt() throws {
        let container = makeContainer("FavouriteTimestamp")
        let viewModel = VaultViewModel(container: container)
        let saved = try container.itemRepository.saveItem(draft(title: "Starred"))
        viewModel.reload()

        let before = saved.updatedAt
        let item = try #require(viewModel.items.first { $0.title == "Starred" })
        viewModel.toggleFavorite(for: item)

        let after = try #require(viewModel.items.first { $0.title == "Starred" })
        #expect(after.updatedAt == before)
        #expect(after.isFavorite)
        // It is still recorded — it just is not an edit.
        #expect(after.changeHistory.contains { $0.kind == .favoriteEnabled })
    }

    @Test func changingAValueDoesCountAsModifyingIt() throws {
        let container = makeContainer("EditTimestamp")
        let saved = try container.itemRepository.saveItem(draft(title: "Edited", secret: "before"))
        let before = saved.updatedAt

        let updated = try container.itemRepository.saveItem(draft(title: "Edited", id: saved.id, secret: "after"))
        #expect(updated.updatedAt > before)
    }

    // MARK: - Library sections and sorting

    /// Something you just made belongs in Recent — it is where you would go looking for it.
    @Test func aNewlyCreatedItemAppearsAtTheTopOfRecent() throws {
        let container = makeContainer("RecentNewItem")
        let viewModel = VaultViewModel(container: container)

        let older = try container.itemRepository.saveItem(draft(title: "Older"))
        older.lastAccessedAt = Date().addingTimeInterval(-3600)
        let created = try container.itemRepository.saveItem(draft(title: "Just Imported"))
        viewModel.reload()

        #expect(created.lastAccessedAt != nil)

        viewModel.selectDestination(.library(.recent))
        #expect(viewModel.filteredItems.first?.title == "Just Imported")
        #expect(viewModel.itemCount(in: .recent) == 2)
    }

    @Test func recentIsOrderedByUseRatherThanName() throws {
        let container = makeContainer("RecentSection")
        let viewModel = VaultViewModel(container: container)
        let alpha = try container.itemRepository.saveItem(draft(title: "Alpha"))
        alpha.lastAccessedAt = Date().addingTimeInterval(-600)
        let zulu = try container.itemRepository.saveItem(draft(title: "Zulu"))
        zulu.lastAccessedAt = Date().addingTimeInterval(-60)
        viewModel.reload()

        // Sorting by name is ignored here: Recent defines its own order.
        viewModel.sortOrder = .title
        viewModel.selectDestination(.library(.recent))
        #expect(viewModel.filteredItems.map(\.title) == ["Zulu", "Alpha"])

        // An archived item drops out of Recent even though it has been used.
        var archived = viewModel.draft(forItemID: alpha.id)
        archived.id = alpha.id
        archived.isArchived = true
        viewModel.saveItem(archived)
        viewModel.selectDestination(.library(.recent))
        #expect(viewModel.filteredItems.map(\.title) == ["Zulu"])
    }

    /// Choosing an item in the command palette has to land on that item's detail, including
    /// when it lives in a workspace other than the one being viewed.
    @Test func openingAnItemFromThePaletteSelectsItInAnotherWorkspace() throws {
        let container = makeContainer("PaletteReveal")
        let viewModel = VaultViewModel(container: container)
        let alpha = try container.workspaceRepository.saveWorkspace(
            WorkspaceDraft(id: nil, name: "Alpha", icon: "shippingbox", colorHex: "#4A7AFF", notes: "")
        )
        let beta = try container.workspaceRepository.saveWorkspace(
            WorkspaceDraft(id: nil, name: "Beta", icon: "server.rack", colorHex: "#2AA198", notes: "")
        )
        _ = try container.itemRepository.saveItem(draft(title: "In Alpha", workspaceID: alpha.id))
        let target = try container.itemRepository.saveItem(draft(title: "In Beta", workspaceID: beta.id))
        viewModel.reload()

        viewModel.selectDestination(.workspace(alpha.id))
        #expect(viewModel.selectedItem == nil)

        viewModel.selectItem(id: target.id)

        #expect(viewModel.selectedItemID == target.id)
        #expect(viewModel.selectedItem?.title == "In Beta")
        #expect(viewModel.filteredItems.contains { $0.id == target.id })
    }

    /// The list draws its own selection, so range and toggle behaviour is implemented rather
    /// than inherited from AppKit — and therefore worth pinning down.
    @Test func shiftClickSelectsTheRangeAndCommandClickTogglesOneRow() throws {
        let container = makeContainer("SelectionRange")
        let viewModel = VaultViewModel(container: container)
        for title in ["A", "B", "C", "D"] {
            _ = try container.itemRepository.saveItem(draft(title: title))
        }
        viewModel.reload()
        viewModel.sortOrder = .title

        let rows = viewModel.filteredItems
        #expect(rows.map(\.title) == ["A", "B", "C", "D"])

        viewModel.select(rows[0])
        viewModel.extendSelection(to: rows[2])
        #expect(viewModel.multiSelectedItems.map(\.title) == ["A", "B", "C"])
        #expect(viewModel.selectedItemID == rows[2].id)

        // Extending backwards from the new anchor covers the other direction.
        viewModel.select(rows[3])
        viewModel.extendSelection(to: rows[1])
        #expect(viewModel.multiSelectedItems.map(\.title) == ["B", "C", "D"])

        // ⌘-click removes a single row from the run.
        viewModel.toggleMultiSelect(rows[2])
        #expect(viewModel.multiSelectedItems.map(\.title) == ["B", "D"])
        #expect(viewModel.isSelected(rows[1]))
        #expect(!viewModel.isSelected(rows[2]))
    }

    /// ⌘-clicking a second row must add to what is already highlighted. It used to start a
    /// fresh selection from the row just clicked, silently dropping the current one.
    @Test func commandClickExtendsTheExistingSingleSelection() throws {
        let container = makeContainer("SelectionCommandClick")
        let viewModel = VaultViewModel(container: container)
        for title in ["A", "B", "C"] {
            _ = try container.itemRepository.saveItem(draft(title: title))
        }
        viewModel.reload()
        viewModel.sortOrder = .title
        let rows = viewModel.filteredItems

        viewModel.select(rows[0])
        viewModel.toggleMultiSelect(rows[2])

        #expect(viewModel.multiSelectedItems.map(\.title) == ["A", "C"])
        #expect(viewModel.selectedItemID == rows[2].id)
    }

    @Test func escapeClearsTheWholeSelection() throws {
        let container = makeContainer("SelectionEscape")
        let viewModel = VaultViewModel(container: container)
        for title in ["A", "B"] {
            _ = try container.itemRepository.saveItem(draft(title: title))
        }
        viewModel.reload()
        let rows = viewModel.filteredItems

        viewModel.select(rows[0])
        viewModel.toggleMultiSelect(rows[1])
        #expect(viewModel.isMultiSelecting)

        viewModel.clearMultiSelection()
        #expect(!viewModel.isMultiSelecting)
        #expect(viewModel.selectedItemID == nil)
        #expect(viewModel.listSelection.isEmpty)
    }

    /// An arrow press at the end of the list still collapses a multi-selection to one row.
    @Test func arrowKeysCollapseAMultiSelection() throws {
        let container = makeContainer("SelectionArrows")
        let viewModel = VaultViewModel(container: container)
        for title in ["A", "B"] {
            _ = try container.itemRepository.saveItem(draft(title: title))
        }
        viewModel.reload()
        viewModel.sortOrder = .title
        let rows = viewModel.filteredItems

        viewModel.select(rows[1])
        viewModel.toggleMultiSelect(rows[0])
        #expect(viewModel.isMultiSelecting)

        // Already at the top, so the row does not change — but the run does collapse.
        viewModel.moveSelection(by: -1)
        #expect(!viewModel.isMultiSelecting)
        #expect(viewModel.selectedItemID == rows[0].id)
    }

    @Test func shiftClickWithoutAnAnchorJustSelects() throws {
        let container = makeContainer("SelectionNoAnchor")
        let viewModel = VaultViewModel(container: container)
        let item = try container.itemRepository.saveItem(draft(title: "Only One"))
        viewModel.reload()

        viewModel.extendSelection(to: item)
        #expect(viewModel.selectedItemID == item.id)
        #expect(!viewModel.isMultiSelecting)
    }

    @Test func recentDefinesItsOwnOrderAndSaysSo() throws {
        let container = makeContainer("RecentSortLock")
        let viewModel = VaultViewModel(container: container)
        viewModel.sortOrder = .title

        viewModel.selectDestination(.library(.allItems))
        #expect(!viewModel.isSortOrderFixedByDestination)
        #expect(viewModel.effectiveSortOrder == .title)

        viewModel.selectDestination(.library(.recent))
        #expect(viewModel.isSortOrderFixedByDestination)
        #expect(viewModel.effectiveSortOrder == .recentlyUsed)
    }

    @Test func aTypeFilterStaysVisibleWhenTheDestinationChanges() throws {
        let container = makeContainer("FilterVisibility")
        let viewModel = VaultViewModel(container: container)
        let workspace = try container.workspaceRepository.saveWorkspace(
            WorkspaceDraft(id: nil, name: "Infra", icon: "server.rack", colorHex: "#4A7AFF", notes: "")
        )
        _ = try container.itemRepository.saveItem(draft(title: "Generic One", workspaceID: workspace.id))
        viewModel.reload()

        viewModel.setSelectedType(.database)
        #expect(viewModel.hasActiveFilters)

        // Moving to another destination keeps the filter, which is why the list header has to
        // show it rather than leaving a mysteriously short list.
        viewModel.selectDestination(.workspace(workspace.id))
        #expect(viewModel.selectedType == .database)
        #expect(viewModel.hasActiveFilters)
        #expect(viewModel.filteredItems.isEmpty)

        viewModel.clearFilters()
        #expect(!viewModel.hasActiveFilters)
        #expect(viewModel.filteredItems.map(\.title) == ["Generic One"])
    }

    @Test func sortOrderChangesTheListOrder() throws {
        let container = makeContainer("SortOrder")
        let viewModel = VaultViewModel(container: container)
        _ = try container.itemRepository.saveItem(draft(title: "Zebra"))
        _ = try container.itemRepository.saveItem(draft(title: "Alpha"))
        viewModel.reload()

        viewModel.sortOrder = .title
        #expect(viewModel.filteredItems.map(\.title) == ["Alpha", "Zebra"])

        viewModel.sortOrder = .newestFirst
        #expect(viewModel.filteredItems.first?.title == "Alpha")
    }

    @Test func archivingKeepsTheSidebarWhereItWas() throws {
        let container = makeContainer("ArchiveDestination")
        let viewModel = VaultViewModel(container: container)
        let workspace = try container.workspaceRepository.saveWorkspace(
            WorkspaceDraft(id: nil, name: "Infra", icon: "server.rack", colorHex: "#4A7AFF", notes: "")
        )
        _ = try container.itemRepository.saveItem(draft(title: "Boxed", workspaceID: workspace.id))
        viewModel.reload()
        viewModel.selectDestination(.workspace(workspace.id))

        let item = try #require(viewModel.items.first { $0.title == "Boxed" })
        viewModel.archive(item)

        #expect(viewModel.selectedDestination == .workspace(workspace.id))
        #expect(viewModel.lastActionMessage != nil)
    }

    // MARK: - Duplicates

    @Test func duplicatingTwiceProducesDistinctTitles() throws {
        let container = makeContainer("DuplicateNaming")
        let saved = try container.itemRepository.saveItem(draft(title: "Token"))

        _ = try container.itemRepository.duplicateItem(saved)
        _ = try container.itemRepository.duplicateItem(saved)

        let titles = Set(container.memoryStore.items.map(\.title))
        #expect(titles.contains("Token Copy"))
        #expect(titles.contains("Token Copy 2"))
    }

    // MARK: - Linked .env files

    /// Importing from a file used to throw the source URL away, so the item you had just
    /// built from a file had to be linked to that same file by hand afterwards.
    @Test func importingFromAFileLinksTheItemToItImmediately() async throws {
        let container = makeContainer("EnvAutoLink")
        let viewModel = VaultViewModel(container: container)

        let url = try writeTemporaryEnvFile("API_KEY=first\nPORT=5432\n")
        defer { try? FileManager.default.removeItem(at: url) }

        let picked = try #require(viewModel.readEnvFile(at: url))
        var draft = try #require(viewModel.prepareEnvImport(from: .pastedText(picked.contents), parseIntoEntries: true))
        draft.title = picked.suggestedTitle
        let item = try #require(viewModel.saveNewItem(draft, linkingTo: url, parsedIntoFields: true))

        for _ in 0..<200 where item.linkedFile == nil {
            try await Task.sleep(for: .milliseconds(1))
        }

        let link = try #require(item.linkedFile)
        #expect(link.displayPath == url.path)
        #expect(link.syncedDigest != nil)
        #expect(link.syncedVaultDigest != nil)
        let status = await viewModel.linkedFileStatus(for: item)
        #expect(status == .upToDate)
    }

    @Test func editingTheFileOnDiskIsReportedAndCanBePulledIn() async throws {
        let container = makeContainer("EnvPull")
        let viewModel = VaultViewModel(container: container)

        let url = try writeTemporaryEnvFile("API_KEY=first\n")
        defer { try? FileManager.default.removeItem(at: url) }

        let picked = try #require(viewModel.readEnvFile(at: url))
        var draft = try #require(viewModel.prepareEnvImport(from: .pastedText(picked.contents), parseIntoEntries: true))
        draft.title = "Project env"
        let item = try #require(viewModel.saveNewItem(draft, linkingTo: nil, parsedIntoFields: true))
        await viewModel.linkFile(at: url, to: item, parsedIntoFields: true, acceptCurrentContentsAsSynced: true)
        let initialStatus = await viewModel.linkedFileStatus(for: item)
        #expect(initialStatus == .upToDate)

        // Someone edits the file in an editor.
        try "API_KEY=second\nNEW_ONE=added\n".write(to: url, atomically: true, encoding: .utf8)
        let changedStatus = await viewModel.linkedFileStatus(for: item)
        #expect(changedStatus == .fileChanged)

        await viewModel.refreshLinkedFileStatuses()
        #expect(viewModel.itemsWithOutdatedLinks.contains(item.id))

        let didPull = await viewModel.updateItemFromLinkedFile(item)
        #expect(didPull)

        let updated = try #require(viewModel.items.first { $0.id == item.id })
        let values = Dictionary(updated.fields.map { ($0.fieldKey, $0.plainValue) }, uniquingKeysWith: { first, _ in first })
        #expect(values["API_KEY"] == "second")
        #expect(values["NEW_ONE"] == "added")
        let finalStatus = await viewModel.linkedFileStatus(for: updated)
        #expect(finalStatus == .upToDate)
        // The value it replaced is still recoverable.
        #expect(updated.fields.contains { $0.previousValues.contains { $0.value == "first" } })
    }

    @Test func writingBackReplacesTheFileContents() async throws {
        let container = makeContainer("EnvPush")
        let viewModel = VaultViewModel(container: container)

        let url = try writeTemporaryEnvFile("TOKEN=old\n")
        defer { try? FileManager.default.removeItem(at: url) }

        let picked = try #require(viewModel.readEnvFile(at: url))
        var draft = try #require(viewModel.prepareEnvImport(from: .pastedText(picked.contents), parseIntoEntries: true))
        draft.title = "Writable env"
        let item = try #require(viewModel.saveNewItem(draft, linkingTo: nil, parsedIntoFields: true))
        await viewModel.linkFile(at: url, to: item, parsedIntoFields: true, acceptCurrentContentsAsSynced: true)

        // Change the stored value, then push it out.
        var edit = viewModel.draft(forItemID: item.id)
        edit.id = item.id
        if let index = edit.fieldDrafts.firstIndex(where: { $0.key == "TOKEN" }) {
            edit.fieldDrafts[index].value = "new"
        }
        viewModel.saveItem(edit)

        let saved = try #require(viewModel.items.first { $0.id == item.id })
        let changedStatus = await viewModel.linkedFileStatus(for: saved)
        #expect(changedStatus == .vaultChanged)
        let didWrite = await viewModel.writeLinkedFile(from: saved)
        #expect(didWrite)

        let onDisk = try String(contentsOf: url, encoding: .utf8)
        // The line keeps the shape the file gave it: an unquoted value that is still safe
        // unquoted is not re-quoted just because PassStore wrote it.
        #expect(onDisk == "TOKEN=new\n")
        #expect(EnvImportService().parse(onDisk).entries.first(where: { $0.key == "TOKEN" })?.value == "new")
        let finalStatus = await viewModel.linkedFileStatus(for: saved)
        #expect(finalStatus == .upToDate)
    }

    /// A file that cannot be read cannot be merged into. Writing the regenerated document over
    /// it instead — which is what the fallback used to do — deletes every comment and every
    /// untracked variable in somebody's `.env`.
    @Test func aWriteIsRefusedWhenTheLinkedFileCannotBeRead() async throws {
        let container = makeContainer("EnvUnreadable")
        let viewModel = VaultViewModel(container: container)

        let url = try writeTemporaryEnvFile("# keep me\nTOKEN=old\n")
        defer { try? FileManager.default.removeItem(at: url) }
        let item = try await linkedEnvItem(viewModel, url: url, title: "Unreadable env")

        // A byte that is not valid UTF-8 — a latin-1 accent pasted into the file, say.
        let bytes = Data([0x54, 0x4F, 0x4B, 0x45, 0x4E, 0x3D, 0xFF, 0x0A])
        try bytes.write(to: url)

        let didWrite = await viewModel.writeLinkedFile(from: item, allowingFileChanges: true)
        #expect(!didWrite)
        let onDisk = try Data(contentsOf: url)
        #expect(onDisk == bytes)
        #expect(viewModel.alertMessage != nil)
    }

    /// Accepting an on-disk change means merging into what is on disk *now*. The precondition
    /// for the write is the text that was merged, so a change arriving in between is refused
    /// rather than silently replaced.
    @Test func overwritingAChangedFileKeepsWhatOnlyTheFileHolds() async throws {
        let container = makeContainer("EnvMergeBase")
        let viewModel = VaultViewModel(container: container)

        let url = try writeTemporaryEnvFile("# header\nTOKEN=old\n")
        defer { try? FileManager.default.removeItem(at: url) }
        let item = try await linkedEnvItem(viewModel, url: url, title: "Diverging env")

        // The file gains a comment and a variable the item knows nothing about…
        let editedOnDisk = "# header\n# added later\nTOKEN=old\nUNTRACKED=keep\n"
        try editedOnDisk.write(to: url, atomically: true, encoding: .utf8)
        // …while the stored value changes too.
        var edit = viewModel.draft(forItemID: item.id)
        edit.id = item.id
        let tokenIndex = try #require(edit.fieldDrafts.firstIndex { $0.key == "TOKEN" })
        edit.fieldDrafts[tokenIndex].value = "new"
        viewModel.saveItem(edit)
        let saved = try #require(viewModel.items.first { $0.id == item.id })
        #expect(await viewModel.linkedFileStatus(for: saved) == .diverged)

        // Without an explicit decision the on-disk edit is not written over.
        #expect(!(await viewModel.writeLinkedFile(from: saved)))
        #expect(try String(contentsOf: url, encoding: .utf8) == editedOnDisk)

        #expect(await viewModel.writeLinkedFile(from: saved, allowingFileChanges: true))
        #expect(try String(contentsOf: url, encoding: .utf8) == "# header\n# added later\nTOKEN=new\nUNTRACKED=keep\n")
    }

    @Test func writingWhenTheFileAlreadyMatchesLeavesItUntouched() async throws {
        let container = makeContainer("EnvNoopWrite")
        let viewModel = VaultViewModel(container: container)

        let url = try writeTemporaryEnvFile("# header\nTOKEN=old\n")
        defer { try? FileManager.default.removeItem(at: url) }
        let item = try await linkedEnvItem(viewModel, url: url, title: "Unchanged env")
        let modifiedBefore = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date

        #expect(await viewModel.writeLinkedFile(from: item, allowingFileChanges: true))

        #expect(try String(contentsOf: url, encoding: .utf8) == "# header\nTOKEN=old\n")
        let modifiedAfter = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
        #expect(modifiedAfter == modifiedBefore)
    }

    /// Imports a `.env`, saves it and links the two, returning the stored item.
    private func linkedEnvItem(
        _ viewModel: VaultViewModel,
        url: URL,
        title: String
    ) async throws -> SecretItemEntity {
        let picked = try #require(viewModel.readEnvFile(at: url))
        var draft = try #require(viewModel.prepareEnvImport(from: .pastedText(picked.contents), parseIntoEntries: true))
        draft.title = title
        let item = try #require(viewModel.saveNewItem(draft, linkingTo: nil, parsedIntoFields: true))
        await viewModel.linkFile(at: url, to: item, parsedIntoFields: true, acceptCurrentContentsAsSynced: true)
        return try #require(viewModel.items.first { $0.id == item.id })
    }

    @Test func aMissingLinkedFileIsReportedRatherThanFailingSilently() async throws {
        let container = makeContainer("EnvMissing")
        let viewModel = VaultViewModel(container: container)

        let url = try writeTemporaryEnvFile("A=1\n")
        let picked = try #require(viewModel.readEnvFile(at: url))
        var draft = try #require(viewModel.prepareEnvImport(from: .pastedText(picked.contents), parseIntoEntries: true))
        draft.title = "Vanishing env"
        let item = try #require(viewModel.saveNewItem(draft, linkingTo: nil, parsedIntoFields: true))
        await viewModel.linkFile(at: url, to: item, parsedIntoFields: true, acceptCurrentContentsAsSynced: true)

        try FileManager.default.removeItem(at: url)
        let status = await viewModel.linkedFileStatus(for: item)
        #expect(status == .unavailable)
    }

    private func writeTemporaryEnvFile(_ contents: String) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("passstore-test-\(UUID().uuidString)")
            .appendingPathComponent(".env")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: - Automatic unlock

    /// Locking on purpose must not be undone by a Touch ID prompt a second later.
    @Test func lockingSuppressesTheAutomaticBiometricPrompt() {
        let defaults = UserDefaults(suiteName: "AutoUnlockSuppression-\(UUID().uuidString)")!
        let container = AppContainer(
            inMemory: true,
            defaults: defaults,
            keyStore: InMemoryVaultKeyStore(isBiometricHardwareAvailable: true),
            encryptedVaultStore: InMemoryEncryptedVaultStore()
        )
        container.settings.biometricsEnabled = true
        container.sessionManager.createVaultSynchronously(password: "test-password")

        container.sessionManager.lock()

        #expect(container.sessionManager.suppressesAutomaticUnlock)
        // The manual button stays available — only the automatic prompt is held back.
        #expect(container.sessionManager.canAttemptBiometricUnlock)
        #expect(!container.sessionManager.shouldOfferAutomaticUnlock)

        // Leaving the app and coming back is a different intent, and does prompt again.
        container.sessionManager.allowAutomaticUnlockOnNextActivation()
        #expect(container.sessionManager.shouldOfferAutomaticUnlock)
    }

    @Test func lockingDoesNotClearAFailedAttemptPenalty() {
        let defaults = UserDefaults(suiteName: "LockoutPersistence-\(UUID().uuidString)")!
        let container = AppContainer(
            inMemory: true,
            defaults: defaults,
            keyStore: InMemoryVaultKeyStore(isBiometricHardwareAvailable: false),
            encryptedVaultStore: InMemoryEncryptedVaultStore()
        )
        container.sessionManager.createVaultSynchronously(password: "test-password")
        container.sessionManager.lock()

        #expect(!container.sessionManager.unlockWithPasswordSynchronously("wrong-password"))

        // Locking again must not be a way to shrug off the penalty.
        container.sessionManager.lock()
        #expect(!container.sessionManager.unlockWithPasswordSynchronously("test-password"))
        #expect(container.sessionManager.lastErrorMessage?.contains("Try again") == true)
    }

    // MARK: - Quick copy

    @Test func quickCopyPrefersThePasswordField() throws {
        let container = makeContainer("QuickCopy")
        let viewModel = VaultViewModel(container: container)
        _ = try container.itemRepository.saveItem(SecretItemDraft(
            id: nil,
            title: "Server",
            type: .serverSSH,
            workspaceID: nil,
            environment: .preset(.prod),
            notes: "",
            tags: [],
            isFavorite: false,
            fieldDrafts: [
                FieldDraft(key: "host", label: "Host", value: "example.dev", kind: .text, isSensitive: false, sortOrder: 0),
                FieldDraft(key: "password", label: "Password", value: "hunter2", kind: .secret, isSensitive: true, sortOrder: 1)
            ],
            templateID: nil
        ))
        viewModel.reload()

        let item = try #require(viewModel.items.first)
        #expect(viewModel.primaryCopyField(for: item)?.key == "password")
    }
}

// MARK: - .env parsing and formatting

struct EnvRoundTripTests {
    @Test func quotedValuesLoseTheirQuotesAndKeepTheirContent() {
        let parsed = EnvImportService().parse("""
        GREETING="hello world"
        LITERAL='no $expansion here'
        BARE=plain
        """)

        let byKey = Dictionary(parsed.entries.map { ($0.key, $0.value) }, uniquingKeysWith: { first, _ in first })
        #expect(byKey["GREETING"] == "hello world")
        #expect(byKey["LITERAL"] == "no $expansion here")
        #expect(byKey["BARE"] == "plain")
    }

    @Test func exportPrefixIsNotPartOfTheKey() {
        let parsed = EnvImportService().parse("export API_KEY=abc123")
        #expect(parsed.entries.first?.key == "API_KEY")
        #expect(parsed.entries.first?.value == "abc123")
    }

    @Test func aQuotedValueMaySpanSeveralLines() {
        let parsed = EnvImportService().parse("""
        PRIVATE_KEY="-----BEGIN KEY-----
        abc
        -----END KEY-----"
        NEXT=after
        """)

        let byKey = Dictionary(parsed.entries.map { ($0.key, $0.value) }, uniquingKeysWith: { first, _ in first })
        #expect(byKey["PRIVATE_KEY"]?.contains("BEGIN KEY") == true)
        #expect(byKey["PRIVATE_KEY"]?.contains("END KEY") == true)
        #expect(byKey["NEXT"] == "after")
    }

    @Test func trailingCommentsAreNotPartOfAnUnquotedValue() {
        let parsed = EnvImportService().parse("PORT=5432 # the default")
        #expect(parsed.entries.first?.value == "5432")
    }

    @Test func escapesInsideDoubleQuotesAreExpanded() {
        let parsed = EnvImportService().parse(#"MESSAGE="line one\nline two""#)
        #expect(parsed.entries.first?.value == "line one\nline two")
    }

    /// `key` used to match anywhere in the name, so ordinary variables were imported as
    /// secrets and then masked in the UI.
    @Test func onlyCredentialShapedNamesAreTreatedAsSensitive() {
        #expect(EnvImportService.looksSensitive(key: "API_KEY"))
        #expect(EnvImportService.looksSensitive(key: "DATABASE_PASSWORD"))
        #expect(EnvImportService.looksSensitive(key: "STRIPE_SECRET"))
        #expect(!EnvImportService.looksSensitive(key: "MONKEY_COUNT"))
        #expect(!EnvImportService.looksSensitive(key: "KEYBOARD_LAYOUT"))
        #expect(!EnvImportService.looksSensitive(key: "PORT"))
    }

    private func field(_ key: String, _ value: String, order: Int = 0) -> FieldResolvedValue {
        FieldResolvedValue(
            id: UUID(), key: key, label: key, value: value, kind: .text,
            isSensitive: false, isCopyable: true, isMasked: false, sortOrder: order
        )
    }

    /// Writing used to regenerate the whole document, so the first Write destroyed every
    /// comment and blank line in the owner's file.
    @Test func updatingAFilePreservesCommentsBlankLinesAndOrder() {
        let original = """
        # Production credentials
        # Do not commit

        DB_HOST=old.example.dev
        DB_PORT=5432 # the default

        # Third-party
        STRIPE_KEY=sk_old
        """

        let updated = CopyFormatter.envFileByUpdating(original, with: [
            field("DB_HOST", "new.example.dev", order: 0),
            field("DB_PORT", "6543", order: 1),
            field("STRIPE_KEY", "sk_new", order: 2)
        ])

        #expect(updated.contains("# Production credentials"))
        #expect(updated.contains("# Do not commit"))
        #expect(updated.contains("# Third-party"))
        #expect(updated.contains("\n\n"))
        #expect(updated.contains("DB_HOST=new.example.dev"))
        #expect(updated.contains("sk_new"))
        #expect(!updated.contains("old.example.dev"))
        #expect(!updated.contains("sk_old"))
        // The note beside a value is part of the file, not of the value.
        #expect(updated.contains("# the default"))
        // Order is the file's, not the item's.
        let hostLine = try? #require(updated.components(separatedBy: "\n").firstIndex { $0.hasPrefix("DB_HOST") })
        let stripeLine = try? #require(updated.components(separatedBy: "\n").firstIndex { $0.hasPrefix("STRIPE_KEY") })
        #expect((hostLine ?? 0) < (stripeLine ?? 0))
    }

    /// Every tracked assignment used to be rebuilt, so `LOG_LEVEL=info` came back as
    /// `LOG_LEVEL="info"` and a single Write showed up as a diff on every line of the file.
    @Test func updatingLeavesLinesWhoseValueDidNotChangeByteIdentical() {
        let original = """
        # ==========================
        # DEV-ONLY — local convenience
        # ==========================

        LOG_LEVEL=info
        DISABLE_SAFEGUARD=true

        # REFLECTS USERS.md
          export CURRENT_USER=LUKE
        LITERAL='keep $me exactly'
        PORT=5432 # the default
        EMPTY=
        MULTI="one
        two"
        """

        let updated = CopyFormatter.envFileByUpdating(original, with: [
            field("LOG_LEVEL", "info", order: 0),
            field("DISABLE_SAFEGUARD", "true", order: 1),
            field("CURRENT_USER", "LUKE", order: 2),
            field("LITERAL", "keep $me exactly", order: 3),
            field("PORT", "5432", order: 4),
            field("EMPTY", "", order: 5),
            field("MULTI", "one\ntwo", order: 6)
        ])

        #expect(updated == original)
    }

    @Test func updatingKeepsTheOriginalQuotingStyleWhenTheNewValueAllowsIt() {
        let original = """
        LOG_LEVEL=info
        DSN=postgres://user@localhost:5432/app
        LITERAL='old'
        QUOTED="old"
        """

        let lines = CopyFormatter.envFileByUpdating(original, with: [
            field("LOG_LEVEL", "debug", order: 0),
            field("DSN", "postgres://user@localhost:6543/app", order: 1),
            field("LITERAL", "new $HOME", order: 2),
            field("QUOTED", "new", order: 3)
        ]).components(separatedBy: "\n")

        #expect(lines.contains("LOG_LEVEL=debug"))
        #expect(lines.contains("DSN=postgres://user@localhost:6543/app"))
        // Single quotes are literal, so `$HOME` needs no escaping and the style survives.
        #expect(lines.contains("LITERAL='new $HOME'"))
        #expect(lines.contains("QUOTED=\"new\""))
    }

    /// Preserving the file's shape must never win over keeping the file safe to source.
    @Test func aValueThatNeedsQuotingIsQuotedEvenWhenTheFileHadItBare() {
        let lines = CopyFormatter.envFileByUpdating("TOKEN=abc\nNOTE=plain\nEMPTIED=x\nWRAPS=y\n", with: [
            field("TOKEN", "$(whoami)", order: 0),
            field("NOTE", "two words # not a comment", order: 1),
            field("EMPTIED", "", order: 2),
            field("WRAPS", "a\nb", order: 3)
        ]).components(separatedBy: "\n")

        #expect(lines.contains("TOKEN=\"\\$(whoami)\""))
        #expect(lines.contains("NOTE=\"two words # not a comment\""))
        #expect(lines.contains("EMPTIED=\"\""))
        #expect(lines.contains("WRAPS=\"a\\nb\""))
    }

    @Test func aValueLeftBareStillReadsBackAsItself() {
        let updated = CopyFormatter.envFileByUpdating("A=one\nB=two\n", with: [
            field("A", "a/b:c@d,e=f", order: 0),
            field("B", "two", order: 1)
        ])

        let parsed = EnvImportService().parse(updated)
        let byKey = Dictionary(parsed.entries.map { ($0.key, $0.value) }, uniquingKeysWith: { first, _ in first })
        #expect(byKey["A"] == "a/b:c@d,e=f")
        #expect(byKey["B"] == "two")
    }

    @Test func updatingKeepsUntrackedVariablesAndAppendsNewOnes() {
        let original = """
        KNOWN=one
        MANAGED_ELSEWHERE=leave-me
        """

        let updated = CopyFormatter.envFileByUpdating(original, with: [
            field("KNOWN", "two", order: 0),
            field("BRAND_NEW", "three", order: 1)
        ])

        #expect(updated.contains("MANAGED_ELSEWHERE=leave-me"))
        #expect(updated.contains("KNOWN=two"))
        // An appended variable has no shape to preserve, so it takes the safe quoted form.
        #expect(updated.contains("BRAND_NEW=\"three\""))
    }

    @Test func updatingReplacesAMultiLineValueAndKeepsTheExportPrefix() {
        let original = """
        # key below
        export PRIVATE_KEY="-----BEGIN-----
        abc
        -----END-----"
        AFTER=kept
        """

        let updated = CopyFormatter.envFileByUpdating(original, with: [
            field("PRIVATE_KEY", "replaced", order: 0)
        ])

        #expect(updated.contains("export PRIVATE_KEY=\"replaced\""))
        #expect(updated.contains("# key below"))
        #expect(updated.contains("AFTER=kept"))
        #expect(!updated.contains("BEGIN"))
        // The wrapped lines went with it rather than being orphaned.
        #expect(!updated.contains("abc"))
    }

    @Test func writingAndReadingBackPreservesKeysAndValues() {
        let fields = [
            FieldResolvedValue(id: UUID(), key: "Api_Key", label: "API key", value: "abc 123", kind: .secret, isSensitive: true, isCopyable: true, isMasked: true, sortOrder: 0),
            FieldResolvedValue(id: UUID(), key: "NOTE", label: "Note", value: "has # hash", kind: .text, isSensitive: false, isCopyable: true, isMasked: false, sortOrder: 1),
            FieldResolvedValue(id: UUID(), key: "MULTI", label: "Multi", value: "a\nb", kind: .multiline, isSensitive: false, isCopyable: true, isMasked: false, sortOrder: 2),
            FieldResolvedValue(id: UUID(), key: "SHELL", label: "Shell", value: "$(whoami) `hostname` $HOME", kind: .text, isSensitive: false, isCopyable: true, isMasked: false, sortOrder: 3),
            FieldResolvedValue(id: UUID(), key: "BAD\nINJECTED", label: "Invalid key", value: "safe", kind: .text, isSensitive: false, isCopyable: true, isMasked: false, sortOrder: 4)
        ]

        let text = CopyFormatter.envFileContents(fields: fields)
        let parsed = EnvImportService().parse(text)
        let byKey = Dictionary(parsed.entries.map { ($0.key, $0.value) }, uniquingKeysWith: { first, _ in first })

        // Key casing survives: it used to be upper-cased, which renamed the variable.
        #expect(byKey["Api_Key"] == "abc 123")
        #expect(byKey["NOTE"] == "has # hash")
        #expect(byKey["MULTI"] == "a\nb")
        #expect(byKey["SHELL"] == "$(whoami) `hostname` $HOME")
        #expect(byKey["BAD_INJECTED"] == "safe")
        #expect(text.contains("SHELL=\"\\$(whoami) \\`hostname\\` \\$HOME\""))
        #expect(!text.contains("\nINJECTED="))

        let item = SecretItemEntity(title: "Project\nEVIL=$(whoami)", type: .envGroup)
        let withTitle = CopyFormatter.envString(for: item, fields: fields)
        #expect(withTitle.hasPrefix("# Project\n# EVIL=$(whoami)\n"))
        #expect(!withTitle.contains("\nEVIL=$(whoami)\n"))
    }
}

// MARK: - Password strength

struct PasswordStrengthTests {
    @Test func obviousPasswordsAreWeakRegardlessOfLength() {
        #expect(PasswordStrength.evaluate("password1234").needsAttention)
        #expect(PasswordStrength.evaluate("Password123!").needsAttention)
        #expect(PasswordStrength.evaluate("qwertyuiop").needsAttention)
        #expect(PasswordStrength.evaluate("abcdefghijkl").needsAttention)
        #expect(PasswordStrength.evaluate("aaaaaaaaaaaa").needsAttention)
        #expect(PasswordStrength.evaluate("abcabcabcabc").needsAttention)
    }

    @Test func genuinelyRandomPasswordsAreNotFlagged() {
        #expect(!PasswordStrength.evaluate("7bQ!vz2Lm#94Xr").needsAttention)
        #expect(!PasswordStrength.evaluate(PasswordGenerator.generate(length: 24)).needsAttention)
    }

    @Test func shortPasswordsAreStillTooShort() {
        #expect(PasswordStrength.evaluate("aB3!") == .tooShort)
        #expect(PasswordStrength.evaluate("") == .empty)
    }
}
