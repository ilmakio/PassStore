import Foundation
import Testing
@testable import PassStore

/// Covers the 1.1.1 additions: the per-item audit trail, dismissible health findings,
/// bulk edits across a multi-selection, master password history, and the draft
/// normalization that now happens at the repository boundary.
@MainActor
struct AuditAndBulkEditTests {

    // MARK: - Change history

    @Test func savingANewItemRecordsACreatedEntry() throws {
        let container = AppContainer.preview()
        let saved = try container.itemRepository.saveItem(makeDraft(title: "Fresh Item"))

        #expect(saved.changeHistory.count == 1)
        #expect(saved.changeHistory.first?.kind == .created)
    }

    @Test func editingTitleAndNotesRecordsASingleDetailsEntry() throws {
        let container = AppContainer.preview()
        let saved = try container.itemRepository.saveItem(makeDraft(title: "Before"))

        var draft = makeDraft(title: "After")
        draft.id = saved.id
        draft.notes = "Changed notes too"
        let updated = try container.itemRepository.saveItem(draft)

        // Title and notes are one logical edit, not two entries.
        let details = updated.changeHistory.filter { $0.kind == .detailsUpdated }
        #expect(details.count == 1)
        #expect(updated.changeHistory.contains { $0.kind == .created })
    }

    @Test func rotatingAPasswordFieldIsRecordedAsARotationAndDatesTheCredential() throws {
        let container = AppContainer.preview()
        var draft = makeDraft(title: "Login")
        draft.fieldDrafts = [
            FieldDraft(key: "password", label: "Password", value: "first-password-value", kind: .secret, isSensitive: true, isMasked: true, sortOrder: 0)
        ]
        let saved = try container.itemRepository.saveItem(draft)
        #expect(saved.passwordLastChangedAt == nil)

        draft.id = saved.id
        draft.fieldDrafts[0].value = "second-password-value"
        let updated = try container.itemRepository.saveItem(draft)

        #expect(updated.changeHistory.contains { $0.kind == .passwordRotated })
        #expect(updated.passwordLastChangedAt != nil)
    }

    @Test func changingANonPasswordSecretIsRecordedWithoutClaimingARotation() throws {
        let container = AppContainer.preview()
        var draft = makeDraft(title: "API Client")
        draft.fieldDrafts = [
            FieldDraft(key: "apiKey", label: "API Key", value: "key-one", kind: .secret, isSensitive: true, isMasked: true, sortOrder: 0)
        ]
        let saved = try container.itemRepository.saveItem(draft)

        draft.id = saved.id
        draft.fieldDrafts[0].value = "key-two"
        let updated = try container.itemRepository.saveItem(draft)

        #expect(updated.changeHistory.contains { $0.kind == .sensitiveValueChanged })
        #expect(!updated.changeHistory.contains { $0.kind == .passwordRotated })
        // Only password rotations date a credential for the staleness audit.
        #expect(updated.passwordLastChangedAt == nil)
    }

    @Test func addingAndRemovingFieldsIsRecordedWithLabels() throws {
        let container = AppContainer.preview()
        var draft = makeDraft(title: "Server")
        draft.fieldDrafts = [
            FieldDraft(key: "host", label: "Host", value: "example.dev", kind: .text, isSensitive: false, sortOrder: 0)
        ]
        let saved = try container.itemRepository.saveItem(draft)

        draft.id = saved.id
        draft.fieldDrafts = [
            FieldDraft(key: "port", label: "Port", value: "5432", kind: .number, isSensitive: false, sortOrder: 0)
        ]
        let updated = try container.itemRepository.saveItem(draft)

        #expect(updated.changeHistory.contains { $0.kind == .fieldAdded && $0.detail == "Port" })
        #expect(updated.changeHistory.contains { $0.kind == .fieldRemoved && $0.detail == "Host" })
    }

    @Test func archivingAndRestoringAreRecorded() throws {
        let container = AppContainer.preview()
        let saved = try container.itemRepository.saveItem(makeDraft(title: "Archivable"))

        var draft = makeDraft(title: "Archivable")
        draft.id = saved.id
        draft.isArchived = true
        _ = try container.itemRepository.saveItem(draft)
        draft.isArchived = false
        let restored = try container.itemRepository.saveItem(draft)

        #expect(restored.changeHistory.contains { $0.kind == .archived })
        #expect(restored.changeHistory.contains { $0.kind == .restored })
    }

    /// The audit trail is rendered unmasked in the detail pane, so a leak here would print
    /// a password on screen next to the field that hides it.
    @Test func historyNeverStoresSecretValues() throws {
        let container = AppContainer.preview()
        let secret = "correct-horse-battery-staple-42"
        var draft = makeDraft(title: "Leak Check")
        draft.fieldDrafts = [
            FieldDraft(key: "password", label: "Password", value: "initial-value", kind: .secret, isSensitive: true, isMasked: true, sortOrder: 0)
        ]
        let saved = try container.itemRepository.saveItem(draft)

        draft.id = saved.id
        draft.fieldDrafts[0].value = secret
        let updated = try container.itemRepository.saveItem(draft)

        for entry in updated.changeHistory {
            #expect(entry.detail?.contains(secret) != true)
            #expect(!entry.kindRawValue.contains(secret))
        }
    }

    @Test func historyIsCappedSoAVaultCannotGrowWithoutBound() throws {
        let container = AppContainer.preview()
        var draft = makeDraft(title: "Busy Item")
        draft.fieldDrafts = [
            FieldDraft(key: "note_field", label: "Note", value: "v0", kind: .text, isSensitive: false, sortOrder: 0)
        ]
        let saved = try container.itemRepository.saveItem(draft)
        draft.id = saved.id

        for index in 1...(SecretItemRepository.historyLimit + 10) {
            draft.fieldDrafts[0].value = "v\(index)"
            _ = try container.itemRepository.saveItem(draft)
        }

        let item = try #require(container.memoryStore.items.first(where: { $0.id == saved.id }))
        #expect(item.changeHistory.count == SecretItemRepository.historyLimit)
    }

    @Test func readingAnItemDoesNotWriteHistory() throws {
        let container = AppContainer.preview()
        let saved = try container.itemRepository.saveItem(makeDraft(title: "Read Only"))
        let before = saved.changeHistory.count

        try container.itemRepository.recordItemAccess(saved)

        #expect(saved.changeHistory.count == before)
    }

    // MARK: - Draft normalization

    @Test func tagsAreTrimmedDedupedAndStrippedOfCommas() throws {
        let container = AppContainer.preview()
        var draft = makeDraft(title: "Tagged")
        draft.tags = ["  api  ", "API", "", "prod,staging", "api"]
        let saved = try container.itemRepository.saveItem(draft)

        // "prod,staging" would otherwise split into two tags on the next load, because tags
        // are persisted as one comma-joined string.
        #expect(saved.tags == ["api", "prod staging"])
    }

    @Test func titleIsTrimmedButFieldValuesAreLeftExactlyAsEntered() throws {
        let container = AppContainer.preview()
        var draft = makeDraft(title: "   Padded Title   ")
        draft.fieldDrafts = [
            FieldDraft(key: "password", label: "  Password  ", value: "  keep me  ", kind: .secret, isSensitive: true, isMasked: true, sortOrder: 0)
        ]
        let saved = try container.itemRepository.saveItem(draft)

        #expect(saved.title == "Padded Title")
        #expect(saved.fields.first?.labelSnapshot == "Password")
        // Trimming a stored secret would silently corrupt it.
        #expect(saved.fields.first?.plainValue == "  keep me  ")
    }

    @Test func blankCustomEnvironmentFallsBackInsteadOfPersistingAnEmptyName() throws {
        let container = AppContainer.preview()
        var draft = makeDraft(title: "Env Check")
        draft.environment = .custom("   ")
        let saved = try container.itemRepository.saveItem(draft)

        #expect(saved.environmentValue.title != "")
        #expect(saved.environmentValue.kind == .dev)
    }

    // MARK: - Health findings: ignore and restore

    @Test func ignoringAWeakFindingHidesItAndRestoringBringsItBack() throws {
        let container = AppContainer.preview()
        let viewModel = VaultViewModel(container: container)
        viewModel.saveItem(weakSecretDraft(title: "Weak One"))

        let finding = try #require(viewModel.vaultHealthReport().findings.first { $0.kind == .weak && $0.itemTitle == "Weak One" })

        viewModel.ignoreHealthFinding(finding)
        let afterIgnore = viewModel.vaultHealthReport()
        #expect(!afterIgnore.findings.contains { $0.id == finding.id })
        #expect(afterIgnore.ignoredFindings.contains { $0.id == finding.id })

        viewModel.restoreIgnoredFinding(finding)
        #expect(viewModel.vaultHealthReport().findings.contains { $0.id == finding.id })
    }

    /// The point of keying a dismissal to the value: silencing today's weak password must not
    /// silence whatever replaces it.
    @Test func changingTheSecretRevivesAnIgnoredFinding() throws {
        let container = AppContainer.preview()
        let viewModel = VaultViewModel(container: container)
        viewModel.saveItem(weakSecretDraft(title: "Rotating"))

        let item = try #require(viewModel.items.first(where: { $0.title == "Rotating" }))
        let finding = try #require(viewModel.vaultHealthReport().findings.first { $0.kind == .weak && $0.itemID == item.id })
        viewModel.ignoreHealthFinding(finding)
        #expect(!viewModel.vaultHealthReport().findings.contains { $0.itemID == item.id && $0.kind == .weak })

        // Still weak, but a different weak value: the old dismissal no longer applies.
        var draft = weakSecretDraft(title: "Rotating")
        draft.id = item.id
        draft.fieldDrafts[0].value = "xyz"
        viewModel.saveItem(draft)

        #expect(viewModel.vaultHealthReport().findings.contains { $0.itemID == item.id && $0.kind == .weak })
    }

    /// Without pruning, every dismiss-then-rotate cycle would leave a permanent orphan
    /// record in the vault.
    @Test func rotatingASecretDropsTheOrphanedDismissalRecord() throws {
        let container = AppContainer.preview()
        let viewModel = VaultViewModel(container: container)
        viewModel.saveItem(weakSecretDraft(title: "Orphan Check"))

        let item = try #require(viewModel.items.first(where: { $0.title == "Orphan Check" }))
        let finding = try #require(viewModel.vaultHealthReport().findings.first { $0.itemID == item.id && $0.kind == .weak })
        viewModel.ignoreHealthFinding(finding)
        #expect(item.ignoredHealthIssues.count == 1)

        var draft = weakSecretDraft(title: "Orphan Check")
        draft.id = item.id
        draft.fieldDrafts[0].value = "a-completely-different-value"
        viewModel.saveItem(draft)

        let saved = try #require(viewModel.items.first(where: { $0.id == item.id }))
        #expect(saved.ignoredHealthIssues.isEmpty)
    }

    /// A dismissal that still points at the current value must survive unrelated edits,
    /// otherwise renaming an item would silently un-dismiss its findings.
    @Test func editingSomethingElseKeepsADismissalThatStillApplies() throws {
        let container = AppContainer.preview()
        let viewModel = VaultViewModel(container: container)
        viewModel.saveItem(weakSecretDraft(title: "Keeps Dismissal"))

        let item = try #require(viewModel.items.first(where: { $0.title == "Keeps Dismissal" }))
        let finding = try #require(viewModel.vaultHealthReport().findings.first { $0.itemID == item.id && $0.kind == .weak })
        viewModel.ignoreHealthFinding(finding)

        var draft = weakSecretDraft(title: "Keeps Dismissal Renamed")
        draft.id = item.id
        viewModel.saveItem(draft)

        let saved = try #require(viewModel.items.first(where: { $0.id == item.id }))
        #expect(saved.ignoredHealthIssues.count == 1)
        #expect(!viewModel.vaultHealthReport().findings.contains { $0.itemID == item.id && $0.kind == .weak })
    }

    @Test func restoreAllClearsEveryDismissal() throws {
        let container = AppContainer.preview()
        let viewModel = VaultViewModel(container: container)
        viewModel.saveItem(weakSecretDraft(title: "Weak A"))
        viewModel.saveItem(weakSecretDraft(title: "Weak B", secret: "def"))

        for finding in viewModel.vaultHealthReport().findings where finding.kind == .weak {
            viewModel.ignoreHealthFinding(finding)
        }
        #expect(viewModel.vaultHealthReport().ignoredCount > 0)

        viewModel.restoreAllIgnoredFindings()
        #expect(viewModel.vaultHealthReport().ignoredCount == 0)
    }

    @Test func dismissingAFindingDoesNotCountAsAnEditToTheItem() throws {
        let container = AppContainer.preview()
        let viewModel = VaultViewModel(container: container)
        viewModel.saveItem(weakSecretDraft(title: "Untouched"))

        let item = try #require(viewModel.items.first(where: { $0.title == "Untouched" }))
        let updatedAt = item.updatedAt
        let historyCount = item.changeHistory.count

        let finding = try #require(viewModel.vaultHealthReport().findings.first { $0.itemID == item.id })
        viewModel.ignoreHealthFinding(finding)

        #expect(item.updatedAt == updatedAt)
        #expect(item.changeHistory.count == historyCount)
    }

    /// Before 1.1.1 the staleness audit read `updatedAt`, so renaming an item reset the clock
    /// on a password that had not actually been rotated in years.
    @Test func stalenessFollowsThePasswordRotationDateRatherThanTheLastEdit() throws {
        let container = AppContainer.preview()
        let viewModel = VaultViewModel(container: container)
        var draft = makeDraft(title: "Old Credential")
        draft.fieldDrafts = [
            FieldDraft(key: "password", label: "Password", value: "Str0ng-Passw0rd-Value!", kind: .secret, isSensitive: true, isMasked: true, sortOrder: 0)
        ]
        viewModel.saveItem(draft)

        let item = try #require(viewModel.items.first(where: { $0.title == "Old Credential" }))
        let twoYearsAgo = Date().addingTimeInterval(-2 * 365 * 24 * 3600)
        item.changeHistory = [SecretItemChangeEntry(kind: .passwordRotated, changedAt: twoYearsAgo, detail: "Password")]
        item.updatedAt = .now

        let stale = viewModel.vaultHealthReport().findings.filter { $0.kind == .stale && $0.itemID == item.id }
        #expect(stale.count == 1)
        #expect(stale.first?.detail.contains("Password not rotated") == true)
    }

    // MARK: - Bulk edit

    @Test func bulkEditAddsAndRemovesTagsAcrossTheSelection() throws {
        let container = AppContainer.preview()
        let viewModel = VaultViewModel(container: container)
        viewModel.selectDestination(.library(.allItems))

        var first = makeDraft(title: "Bulk One")
        first.tags = ["legacy", "keep"]
        var second = makeDraft(title: "Bulk Two")
        second.tags = ["legacy"]
        viewModel.saveItem(first)
        viewModel.saveItem(second)

        selectItems(named: ["Bulk One", "Bulk Two"], in: viewModel)

        var edit = BulkEditDraft.empty
        edit.tagsToAdd = ["reviewed"]
        edit.tagsToRemove = ["legacy"]
        viewModel.applyBulkEdit(edit)

        let one = try #require(viewModel.items.first(where: { $0.title == "Bulk One" }))
        let two = try #require(viewModel.items.first(where: { $0.title == "Bulk Two" }))
        #expect(one.tags.sorted() == ["keep", "reviewed"])
        #expect(two.tags == ["reviewed"])
    }

    @Test func bulkEditMovesItemsToAWorkspaceAndSetsEnvironment() throws {
        let container = AppContainer.preview()
        let viewModel = VaultViewModel(container: container)
        viewModel.selectDestination(.library(.allItems))

        let workspace = try #require(viewModel.createWorkspace(WorkspaceDraft(id: nil, name: "Target WS", icon: "shippingbox", colorHex: "#4A7AFF", notes: "")))
        viewModel.saveItem(makeDraft(title: "Movable One"))
        viewModel.saveItem(makeDraft(title: "Movable Two"))
        selectItems(named: ["Movable One", "Movable Two"], in: viewModel)

        var edit = BulkEditDraft.empty
        edit.workspaceAction = .move(workspace.id)
        edit.environmentAction = .set(.preset(.prod))
        viewModel.applyBulkEdit(edit)

        for title in ["Movable One", "Movable Two"] {
            let item = try #require(viewModel.items.first(where: { $0.title == title }))
            #expect(item.workspace?.id == workspace.id)
            #expect(item.environmentValue.title == EnvironmentKind.prod.title)
        }
    }

    @Test func bulkEditAppliesFavoriteAndArchiveFlags() throws {
        let container = AppContainer.preview()
        let viewModel = VaultViewModel(container: container)
        viewModel.selectDestination(.library(.allItems))
        viewModel.saveItem(makeDraft(title: "Flagged One"))
        viewModel.saveItem(makeDraft(title: "Flagged Two"))
        selectItems(named: ["Flagged One", "Flagged Two"], in: viewModel)

        var edit = BulkEditDraft.empty
        edit.favoriteAction = .enable
        edit.archiveAction = .enable
        viewModel.applyBulkEdit(edit)

        for title in ["Flagged One", "Flagged Two"] {
            let item = try #require(viewModel.items.first(where: { $0.title == title }))
            #expect(item.isFavorite)
            #expect(item.isArchived)
        }
        // Archived items leave the current destination, so the view follows them.
        #expect(viewModel.selectedDestination == .library(.archived))
    }

    @Test func anEmptyBulkEditChangesNothing() throws {
        let container = AppContainer.preview()
        let viewModel = VaultViewModel(container: container)
        viewModel.selectDestination(.library(.allItems))
        viewModel.saveItem(makeDraft(title: "Untouched By Bulk"))
        selectItems(named: ["Untouched By Bulk"], in: viewModel)

        let item = try #require(viewModel.items.first(where: { $0.title == "Untouched By Bulk" }))
        let historyCount = item.changeHistory.count

        #expect(!BulkEditDraft.empty.hasChanges)
        viewModel.applyBulkEdit(.empty)

        #expect(item.changeHistory.count == historyCount)
    }

    @Test func bulkEditRecordsHistoryOnEveryItemItTouches() throws {
        let container = AppContainer.preview()
        let viewModel = VaultViewModel(container: container)
        viewModel.selectDestination(.library(.allItems))
        viewModel.saveItem(makeDraft(title: "Audited One"))
        viewModel.saveItem(makeDraft(title: "Audited Two"))
        selectItems(named: ["Audited One", "Audited Two"], in: viewModel)

        var edit = BulkEditDraft.empty
        edit.favoriteAction = .enable
        viewModel.applyBulkEdit(edit)

        for title in ["Audited One", "Audited Two"] {
            let item = try #require(viewModel.items.first(where: { $0.title == title }))
            #expect(item.changeHistory.contains { $0.kind == .favoriteEnabled })
        }
    }

    @Test func commonTagsOnlyOffersTagsSharedByEverySelectedItem() throws {
        let container = AppContainer.preview()
        let viewModel = VaultViewModel(container: container)
        viewModel.selectDestination(.library(.allItems))

        var first = makeDraft(title: "Shared One")
        first.tags = ["common", "only-one"]
        var second = makeDraft(title: "Shared Two")
        second.tags = ["common"]
        viewModel.saveItem(first)
        viewModel.saveItem(second)
        selectItems(named: ["Shared One", "Shared Two"], in: viewModel)

        #expect(viewModel.commonTagsInMultiSelection == ["common"])
    }

    // MARK: - Master password history

    @Test func creatingAVaultRecordsTheInitialEntry() throws {
        let container = AppContainer.preview()

        let history = container.sessionManager.masterPasswordHistory
        #expect(history.contains { $0.kind == .vaultCreated })
        // Created is not a change: there is nothing to report as "last changed" yet.
        #expect(container.sessionManager.masterPasswordLastChangedAt == nil)
    }

    @Test func changingTheMasterPasswordIsRecordedAndSurvivesALockUnlockCycle() throws {
        let defaults = UserDefaults(suiteName: "MasterPasswordHistory-\(UUID().uuidString)")!
        let container = AppContainer(
            inMemory: true,
            defaults: defaults,
            keyStore: InMemoryVaultKeyStore(isBiometricHardwareAvailable: false),
            encryptedVaultStore: InMemoryEncryptedVaultStore()
        )
        container.sessionManager.createVault(password: "original-password")

        try container.sessionManager.changeMasterPassword(current: "original-password", to: "replacement-password")

        #expect(container.sessionManager.masterPasswordLastChangedAt != nil)
        #expect(container.sessionManager.masterPasswordHistory.contains { $0.kind == .changed })

        // The trail lives in the encrypted payload, so it has to come back after a reload.
        container.sessionManager.lock()
        #expect(container.sessionManager.masterPasswordHistory.isEmpty)
        #expect(container.sessionManager.unlockWithPassword("replacement-password"))
        #expect(container.sessionManager.masterPasswordHistory.contains { $0.kind == .changed })
        #expect(container.sessionManager.masterPasswordHistory.contains { $0.kind == .vaultCreated })
    }

    // MARK: - Backward compatibility

    /// A 1.1.0 vault has none of the new keys. Decoding must succeed and default to empty
    /// rather than failing and locking the owner out of their own secrets.
    @Test func aVaultWrittenBeforeTheseFeaturesStillDecodes() throws {
        let legacyJSON = """
        {
          "workspaces": [],
          "customTemplates": [],
          "items": [
            {
              "id": "6E4B4D1C-9E9E-4E4E-9E9E-4E4E9E9E4E4E",
              "title": "Legacy Item",
              "typeRawValue": "generic",
              "environmentRawValue": "dev",
              "notes": "",
              "tagsRawValue": "legacy",
              "isFavorite": false,
              "isArchived": false,
              "createdAt": 750000000,
              "updatedAt": 750000000,
              "fields": []
            }
          ]
        }
        """

        let snapshot = try JSONDecoder().decode(VaultSnapshot.self, from: Data(legacyJSON.utf8))

        #expect(snapshot.masterPasswordHistory.isEmpty)
        #expect(snapshot.items.count == 1)
        #expect(snapshot.items[0].changeHistory.isEmpty)
        #expect(snapshot.items[0].ignoredHealthIssues.isEmpty)
        #expect(snapshot.items[0].title == "Legacy Item")
    }

    @Test func newFieldsSurviveAnEncodeDecodeRoundTrip() throws {
        let entry = SecretItemChangeEntry(kind: .passwordRotated, detail: "Password")
        let ignored = IgnoredHealthIssue(kindRawValue: "weak", fieldKey: "password", valueDigest: "digest")
        let snapshot = VaultSnapshot(
            workspaces: [],
            items: [
                SecretItemSnapshot(
                    id: UUID(),
                    title: "Round Trip",
                    typeRawValue: "generic",
                    environmentRawValue: "dev",
                    customEnvironmentName: nil,
                    notes: "",
                    tagsRawValue: "",
                    isFavorite: false,
                    isArchived: false,
                    createdAt: Date(timeIntervalSince1970: 750_000_000),
                    updatedAt: Date(timeIntervalSince1970: 750_000_000),
                    lastAccessedAt: nil,
                    workspaceID: nil,
                    templateID: nil,
                    fields: [],
                    changeHistory: [entry],
                    ignoredHealthIssues: [ignored]
                )
            ],
            customTemplates: [],
            masterPasswordHistory: [MasterPasswordChangeEntry(kind: .changed)]
        )

        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(VaultSnapshot.self, from: data)

        #expect(decoded.items[0].changeHistory.first?.kind == .passwordRotated)
        #expect(decoded.items[0].ignoredHealthIssues.first?.id == ignored.id)
        #expect(decoded.masterPasswordHistory.first?.kind == .changed)
    }

    // MARK: - Helpers

    private func makeDraft(title: String) -> SecretItemDraft {
        SecretItemDraft(
            title: title,
            type: .generic,
            workspaceID: nil,
            environment: .preset(.dev),
            notes: "",
            tags: [],
            isFavorite: false,
            fieldDrafts: [],
            templateID: nil
        )
    }

    private func weakSecretDraft(title: String, secret: String = "abc") -> SecretItemDraft {
        var draft = makeDraft(title: title)
        draft.fieldDrafts = [
            FieldDraft(key: "secret", label: "Secret", value: secret, kind: .secret, isSensitive: true, isMasked: true, sortOrder: 0)
        ]
        return draft
    }

    private func selectItems(named titles: [String], in viewModel: VaultViewModel) {
        viewModel.multiSelectedIDs = Set(
            viewModel.items.filter { titles.contains($0.title) }.map(\.id)
        )
    }
}
