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
        let data = try source.exportService.exportFullBackupSynchronously(backup: backup, password: "pw")

        let target = makeContainer("MergeTwiceTarget")
        let viewModel = VaultViewModel(container: target)

        viewModel.stageImport(data: data, fileName: "backup.pstore")
        #expect(await viewModel.prepareImport(password: "pw"))
        _ = viewModel.applyStagedImport(mode: .merge)
        let afterFirst = viewModel.items.count

        viewModel.stageImport(data: data, fileName: "backup.pstore")
        #expect(await viewModel.prepareImport(password: "pw"))
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
        let data = try source.exportService.exportFullBackupSynchronously(backup: backup, password: "pw")

        let target = makeContainer("ConflictTarget")
        let viewModel = VaultViewModel(container: target)
        _ = try target.itemRepository.saveItem(draft(title: "Server Key", id: sharedID, secret: "local-value"))
        viewModel.reload()

        viewModel.stageImport(data: data, fileName: "backup.pstore")
        #expect(await viewModel.prepareImport(password: "pw"))
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
        let data = try source.exportService.exportFullBackupSynchronously(backup: backup, password: "pw")

        let target = makeContainer("ReplaceTarget")
        let viewModel = VaultViewModel(container: target)
        _ = try target.itemRepository.saveItem(draft(title: "Original"))
        viewModel.reload()

        viewModel.stageImport(data: data, fileName: "backup.pstore")
        #expect(await viewModel.prepareImport(password: "pw"))
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
        let data = try source.exportService.exportFullBackupSynchronously(backup: backup, password: "pw")

        let target = makeContainer("RollbackTarget")
        let viewModel = VaultViewModel(container: target)
        #expect(viewModel.rollbackCopyDate == nil)

        viewModel.stageImport(data: data, fileName: "backup.pstore")
        #expect(await viewModel.prepareImport(password: "pw"))
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

    @Test func recentOnlyContainsItemsThatHaveActuallyBeenOpened() throws {
        let container = makeContainer("RecentSection")
        let viewModel = VaultViewModel(container: container)
        _ = try container.itemRepository.saveItem(draft(title: "Untouched"))
        let opened = try container.itemRepository.saveItem(draft(title: "Opened"))
        viewModel.reload()

        #expect(viewModel.itemCount(in: .recent) == 0)

        viewModel.select(viewModel.items.first { $0.id == opened.id })
        viewModel.reload()

        viewModel.selectDestination(.library(.recent))
        #expect(viewModel.filteredItems.map(\.title) == ["Opened"])
        #expect(viewModel.itemCount(in: .recent) == 1)
        #expect(viewModel.itemCount(in: .allItems) == 2)
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

    @Test func writingAndReadingBackPreservesKeysAndValues() {
        let fields = [
            FieldResolvedValue(id: UUID(), key: "Api_Key", label: "API key", value: "abc 123", kind: .secret, isSensitive: true, isCopyable: true, isMasked: true, sortOrder: 0),
            FieldResolvedValue(id: UUID(), key: "NOTE", label: "Note", value: "has # hash", kind: .text, isSensitive: false, isCopyable: true, isMasked: false, sortOrder: 1),
            FieldResolvedValue(id: UUID(), key: "MULTI", label: "Multi", value: "a\nb", kind: .multiline, isSensitive: false, isCopyable: true, isMasked: false, sortOrder: 2)
        ]

        let text = CopyFormatter.envFileContents(fields: fields)
        let parsed = EnvImportService().parse(text)
        let byKey = Dictionary(parsed.entries.map { ($0.key, $0.value) }, uniquingKeysWith: { first, _ in first })

        // Key casing survives: it used to be upper-cased, which renamed the variable.
        #expect(byKey["Api_Key"] == "abc 123")
        #expect(byKey["NOTE"] == "has # hash")
        #expect(byKey["MULTI"] == "a\nb")
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
