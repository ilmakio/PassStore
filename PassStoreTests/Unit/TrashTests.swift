import Foundation
import Testing
@testable import PassStore

/// Deleting used to be final, softened only by one level of in-memory undo that died with the
/// session. Deleting the wrong secret is not a mistake anybody should pay for permanently, and a
/// password manager is exactly where that mistake is most expensive.
@MainActor
struct TrashTests {

    private func draft(_ title: String) -> SecretItemDraft {
        var draft = SecretItemDraft.empty
        draft.title = title
        draft.fieldDrafts = [
            FieldDraft(
                key: "secret",
                label: "Secret",
                value: "Kx7-\(title)-value-nobody-guesses",
                kind: .secret,
                isSensitive: true,
                isMasked: true,
                sortOrder: 0
            )
        ]
        return draft
    }

    // MARK: - Moving to the trash

    @Test func deletingMovesAnItemToTheTrashInsteadOfDestroyingIt() throws {
        let container = AppContainer.preview()
        let saved = try container.itemRepository.saveItem(draft("Wrongly Deleted"))

        try container.itemRepository.trashItem(saved)

        let stored = try #require(
            container.itemRepository.fetchAll(includeArchived: true).first { $0.id == saved.id }
        )
        #expect(stored.isDeleted)
        #expect(stored.deletedAt != nil)
        // Its fields are untouched: recovering it has to give back a working secret.
        #expect(stored.fields.contains { $0.fieldKey == "secret" && !$0.plainValue.isEmpty })
    }

    @Test func aTrashedItemLeavesEveryDestinationExceptTheTrash() {
        let container = AppContainer.preview()
        let viewModel = VaultViewModel(container: container)
        viewModel.saveItem(draft("Vanishing"))

        let item = viewModel.items.first { $0.title == "Vanishing" }
        #expect(item != nil)

        viewModel.requestDeletion(of: item!)
        viewModel.confirmItemDeletion()

        #expect(!viewModel.items.contains { $0.title == "Vanishing" })
        #expect(viewModel.deletedItems.contains { $0.title == "Vanishing" })
        #expect(viewModel.trashCount == 1)

        // Not in All Items, and not counted there either.
        viewModel.selectDestination(.library(.allItems))
        #expect(!viewModel.filteredItems.contains { $0.title == "Vanishing" })

        // Present in the trash, which is the one place it belongs.
        viewModel.selectDestination(.library(.recentlyDeleted))
        #expect(viewModel.filteredItems.contains { $0.title == "Vanishing" })
        #expect(viewModel.itemCount(in: .recentlyDeleted) == 1)
        // The preview vault is seeded, so this is about the deleted one being absent rather than
        // about the count reaching zero.
        #expect(!viewModel.filteredItems.isEmpty || viewModel.items.isEmpty)
        viewModel.selectDestination(.library(.allItems))
        #expect(!viewModel.items.contains { $0.title == "Vanishing" })
    }

    /// Search reads the live list, so a deleted secret must not surface in it — finding a secret you
    /// deleted and copying it would be worse than not finding it.
    @Test func theTrashIsOutOfReachOfSearchAndTheHealthReport() {
        let container = AppContainer.preview()
        let viewModel = VaultViewModel(container: container)

        var weak = draft("Weak And Deleted")
        weak.fieldDrafts[0].value = "abc"
        viewModel.saveItem(weak)

        let item = viewModel.items.first { $0.title == "Weak And Deleted" }!
        viewModel.requestDeletion(of: item)
        viewModel.confirmItemDeletion()

        viewModel.selectDestination(.library(.allItems))
        viewModel.searchText = "Weak"
        #expect(viewModel.filteredItems.isEmpty)

        let report = viewModel.vaultHealthReport()
        #expect(!report.findings.contains { $0.itemTitle == "Weak And Deleted" })
    }

    @Test func theSidebarOnlyOffersTheTrashWhenThereIsSomethingInIt() {
        let container = AppContainer.preview()
        let viewModel = VaultViewModel(container: container)
        #expect(!viewModel.visibleLibrarySections.contains(.recentlyDeleted))

        viewModel.saveItem(draft("Soon Deleted"))
        let item = viewModel.items.first { $0.title == "Soon Deleted" }!
        viewModel.requestDeletion(of: item)
        viewModel.confirmItemDeletion()

        #expect(viewModel.visibleLibrarySections.contains(.recentlyDeleted))
    }

    /// The row must not disappear from under somebody standing on it.
    @Test func theTrashRowStaysWhileYouAreLookingAtIt() {
        let container = AppContainer.preview()
        let viewModel = VaultViewModel(container: container)
        viewModel.saveItem(draft("Only One"))
        let item = viewModel.items.first { $0.title == "Only One" }!
        viewModel.requestDeletion(of: item)
        viewModel.confirmItemDeletion()

        viewModel.selectDestination(.library(.recentlyDeleted))
        viewModel.restoreFromTrash(viewModel.deletedItems)

        #expect(viewModel.trashCount == 0)
        #expect(viewModel.visibleLibrarySections.contains(.recentlyDeleted))
    }

    // MARK: - Recovering

    @Test func puttingBackRestoresTheItemWhereItWas() throws {
        let container = AppContainer.preview()
        let viewModel = VaultViewModel(container: container)

        let workspace = try #require(container.workspaceRepository.fetchAll(includeArchived: false).first)
        var toDelete = draft("Recovered")
        toDelete.workspaceID = workspace.id
        toDelete.isFavorite = true
        viewModel.saveItem(toDelete)

        let item = viewModel.items.first { $0.title == "Recovered" }!
        viewModel.requestDeletion(of: item)
        viewModel.confirmItemDeletion()
        #expect(viewModel.trashCount == 1)

        viewModel.restoreFromTrash(viewModel.deletedItems)

        let restored = try #require(viewModel.items.first { $0.title == "Recovered" })
        #expect(!restored.isDeleted)
        // Put back where it was, not somewhere tidier.
        #expect(restored.workspace?.id == workspace.id)
        #expect(restored.isFavorite)
        #expect(viewModel.trashCount == 0)
    }

    @Test func bothTransitionsAreRecordedInTheAuditTrail() throws {
        let container = AppContainer.preview()
        let saved = try container.itemRepository.saveItem(draft("Audited"))

        try container.itemRepository.trashItem(saved)
        var stored = try #require(container.itemRepository.fetchAll(includeArchived: true).first { $0.id == saved.id })
        #expect(stored.changeHistory.contains { $0.kind == .trashed })

        try container.itemRepository.restoreItemFromTrash(stored)
        stored = try #require(container.itemRepository.fetchAll(includeArchived: true).first { $0.id == saved.id })
        #expect(stored.changeHistory.contains { $0.kind == .untrashed })
    }

    // MARK: - Destroying

    @Test func deletingFromTheTrashIsPermanentAndSaysSo() throws {
        let container = AppContainer.preview()
        let viewModel = VaultViewModel(container: container)
        viewModel.saveItem(draft("Doomed"))

        let item = viewModel.items.first { $0.title == "Doomed" }!
        viewModel.requestDeletion(of: item)
        #expect(!viewModel.pendingDeletionIsPermanent)
        #expect(viewModel.itemDeletionConfirmLabel == "Delete")
        viewModel.confirmItemDeletion()

        let trashed = try #require(viewModel.deletedItems.first { $0.title == "Doomed" })
        viewModel.requestDeletion(of: trashed)
        // The same command, and now it means it.
        #expect(viewModel.pendingDeletionIsPermanent)
        #expect(viewModel.itemDeletionConfirmLabel == "Delete Forever")
        #expect(viewModel.itemDeletionTitle.contains("forever"))
        viewModel.confirmItemDeletion()

        #expect(viewModel.trashCount == 0)
        #expect(try container.itemRepository.fetchAll(includeArchived: true).allSatisfy { $0.title != "Doomed" })
    }

    @Test func emptyingDestroysEverythingInTheTrashAndNothingElse() throws {
        let container = AppContainer.preview()
        let viewModel = VaultViewModel(container: container)
        viewModel.saveItem(draft("Keep Me"))
        viewModel.saveItem(draft("Bin One"))
        viewModel.saveItem(draft("Bin Two"))

        for title in ["Bin One", "Bin Two"] {
            let item = viewModel.items.first { $0.title == title }!
            viewModel.requestDeletion(of: item)
            viewModel.confirmItemDeletion()
        }
        #expect(viewModel.trashCount == 2)

        viewModel.emptyTrash()

        #expect(viewModel.trashCount == 0)
        #expect(viewModel.items.contains { $0.title == "Keep Me" })
        let titles = try container.itemRepository.fetchAll(includeArchived: true).map(\.title)
        #expect(!titles.contains("Bin One"))
        #expect(!titles.contains("Bin Two"))
    }

    /// Emptying is bulk and irreversible, so it takes an undo step like every other action of that
    /// shape in this app.
    @Test func emptyingCanBeUndoneUntilTheVaultLocks() throws {
        let container = AppContainer.preview()
        let viewModel = VaultViewModel(container: container)
        viewModel.saveItem(draft("Rescued"))

        let item = viewModel.items.first { $0.title == "Rescued" }!
        viewModel.requestDeletion(of: item)
        viewModel.confirmItemDeletion()
        viewModel.emptyTrash()
        #expect(viewModel.trashCount == 0)

        #expect(viewModel.undoActionLabel != nil)
        viewModel.undoLastDestructiveAction()
        #expect(viewModel.trashCount == 1)
    }

    // MARK: - Retention

    @Test func theTrashEmptiesItselfAfterTheRetentionWindow() throws {
        let container = AppContainer.preview()
        let recent = try container.itemRepository.saveItem(draft("Deleted Today"))
        let ancient = try container.itemRepository.saveItem(draft("Deleted Long Ago"))

        try container.itemRepository.trashItem(recent)
        try container.itemRepository.trashItem(ancient)

        // Backdate one past the window.
        let stale = try #require(container.itemRepository.fetchAll(includeArchived: true).first { $0.id == ancient.id })
        stale.deletedAt = Date().addingTimeInterval(-(SecretItemRepository.trashRetention + 3_600))

        let purged = try container.itemRepository.purgeExpiredTrash()
        #expect(purged == 1)

        let titles = try container.itemRepository.fetchAll(includeArchived: true).map(\.title)
        #expect(titles.contains("Deleted Today"))
        #expect(!titles.contains("Deleted Long Ago"))
    }

    @Test func purgingLeavesAnUntouchedVaultAlone() throws {
        let container = AppContainer.preview()
        _ = try container.itemRepository.saveItem(draft("Alive"))
        let purged = try container.itemRepository.purgeExpiredTrash()
        #expect(purged == 0)
        #expect(try container.itemRepository.fetchAll(includeArchived: true).contains { $0.title == "Alive" })
    }

    @Test func theRetentionWindowIsStatedInDaysForTheInterface() {
        #expect(SecretItemRepository.trashRetentionDays == 30)
    }

    // MARK: - Persistence

    @Test func theTrashSurvivesASnapshotRoundTrip() throws {
        let container = AppContainer.preview()
        let saved = try container.itemRepository.saveItem(draft("Persisted"))
        try container.itemRepository.trashItem(saved)

        let encoded = try JSONEncoder().encode(container.memoryStore.makeSnapshot())
        let decoded = try JSONDecoder().decode(VaultSnapshot.self, from: encoded)

        let item = try #require(decoded.items.first { $0.title == "Persisted" })
        #expect(item.deletedAt != nil)
    }

    /// A vault written before the trash existed has no such key and must decode as "nothing is
    /// deleted", not as "everything is".
    @Test func anItemFromAnEarlierVaultIsNotInTheTrash() throws {
        let container = AppContainer.preview()
        _ = try container.itemRepository.saveItem(draft("Legacy"))

        var json = try JSONSerialization.jsonObject(
            with: try JSONEncoder().encode(container.memoryStore.makeSnapshot())
        ) as! [String: Any]
        json["items"] = (json["items"] as! [[String: Any]]).map { item in
            var item = item
            item.removeValue(forKey: "deletedAt")
            return item
        }

        let decoded = try JSONDecoder().decode(
            VaultSnapshot.self,
            from: try JSONSerialization.data(withJSONObject: json)
        )
        #expect(decoded.items.allSatisfy { $0.deletedAt == nil })
    }
}
