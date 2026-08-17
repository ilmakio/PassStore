import Foundation
import Testing
@testable import PassStore

/// The whole-file status can only offer to replace everything in one direction, which is the wrong
/// size of decision when one variable moved — and the reason people copied values by hand around
/// it. These cover the per-variable answer: which side moved, and applying just that one.
struct EnvFieldDriftTests {
    private func field(_ key: String, _ value: String, order: Int = 0) -> FieldResolvedValue {
        FieldResolvedValue(
            id: UUID(), key: key, label: key, value: value, kind: .text,
            isSensitive: false, isCopyable: true, isMasked: false, sortOrder: order
        )
    }

    @Test func driftNamesTheSideThatMoved() {
        let synced = [
            field("SAME", "one", order: 0),
            field("FILE_MOVED", "two", order: 1),
            field("VAULT_MOVED", "three", order: 2),
            field("BOTH_MOVED", "four", order: 3),
            field("ONLY_HERE", "five", order: 4)
        ]
        let baseline = EnvImportService.fieldDigests(of: synced)

        let fileNow = """
        SAME=one
        FILE_MOVED=two-from-disk
        VAULT_MOVED=three
        BOTH_MOVED=four-from-disk
        ONLY_IN_FILE=six
        """
        var fieldsNow = synced
        fieldsNow[2] = field("VAULT_MOVED", "three-edited", order: 2)
        fieldsNow[3] = field("BOTH_MOVED", "four-edited", order: 3)

        let drift = EnvImportService.drift(between: fileNow, and: fieldsNow, baseline: baseline)

        #expect(drift["SAME"] == nil)
        #expect(drift["FILE_MOVED"] == .fileChanged)
        #expect(drift["VAULT_MOVED"] == .vaultChanged)
        #expect(drift["BOTH_MOVED"] == .diverged)
        #expect(drift["ONLY_HERE"] == .onlyInVault)
        #expect(drift["ONLY_IN_FILE"] == .onlyInFile)
    }

    /// A link made before per-variable digests existed has no baseline, so which side moved is
    /// genuinely unknown. Saying so is better than picking a direction.
    @Test func withoutABaselineADifferenceIsUnattributed() {
        let drift = EnvImportService.drift(
            between: "TOKEN=from-disk\n",
            and: [field("TOKEN", "from-vault")],
            baseline: nil
        )

        #expect(drift["TOKEN"] == .diverged)
    }

    /// Both sides landing on the same value is not a difference, whatever the baseline says.
    @Test func matchingValuesAreNeverReportedAsDrift() {
        let drift = EnvImportService.drift(
            between: "TOKEN=same\n",
            and: [field("TOKEN", "same")],
            baseline: ["TOKEN": LinkedFileService.digest("something-older")]
        )

        #expect(drift.isEmpty)
    }

    /// A repeated variable resolves the way dotenv readers resolve it: the last one wins.
    @Test func aRepeatedVariableIsComparedAgainstTheLastOne() {
        let drift = EnvImportService.drift(
            between: "TOKEN=first\nTOKEN=second\n",
            and: [field("TOKEN", "second")],
            baseline: ["TOKEN": LinkedFileService.digest("second")]
        )

        #expect(drift.isEmpty)
    }
}

@MainActor
struct EnvFieldSyncTests {
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

    private func writeTemporaryEnvFile(_ contents: String) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("passstore-field-sync-\(UUID().uuidString)")
            .appendingPathComponent(".env")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func linkedItem(
        _ viewModel: VaultViewModel,
        url: URL,
        title: String = "Project env"
    ) async throws -> SecretItemEntity {
        let contents = try String(contentsOf: url, encoding: .utf8)
        var draft = try #require(viewModel.prepareEnvImport(from: .pastedText(contents), parseIntoEntries: true))
        draft.title = title
        let item = try #require(viewModel.saveNewItem(draft, linkingTo: nil, parsedIntoFields: true))
        await viewModel.linkFile(at: url, to: item, parsedIntoFields: true, acceptCurrentContentsAsSynced: true)
        return try #require(viewModel.items.first { $0.id == item.id })
    }

    @Test func aVariableChangedOnDiskIsReportedAgainstThatVariable() async throws {
        let container = makeContainer("EnvDriftReport")
        let viewModel = VaultViewModel(container: container)
        let url = try writeTemporaryEnvFile("# header\nTOKEN=old\nPORT=5432\n")
        defer { try? FileManager.default.removeItem(at: url) }
        let item = try await linkedItem(viewModel, url: url)

        #expect(await viewModel.linkedFileStatus(for: item) == .upToDate)
        #expect(viewModel.envFieldDrift(for: item, key: "TOKEN") == nil)

        try "# header\nTOKEN=new\nPORT=5432\n".write(to: url, atomically: true, encoding: .utf8)
        #expect(await viewModel.linkedFileStatus(for: item) == .fileChanged)

        #expect(viewModel.envFieldDrift(for: item, key: "TOKEN") == .fileChanged)
        // Everything else in the file is where it was, and says so.
        #expect(viewModel.envFieldDrift(for: item, key: "PORT") == nil)
    }

    @Test func aLocalEditIsAttributedToTheItemNotTheFile() async throws {
        let container = makeContainer("EnvDriftLocal")
        let viewModel = VaultViewModel(container: container)
        let url = try writeTemporaryEnvFile("TOKEN=old\nPORT=5432\n")
        defer { try? FileManager.default.removeItem(at: url) }
        let item = try await linkedItem(viewModel, url: url)

        var edit = viewModel.draft(forItemID: item.id)
        edit.id = item.id
        let index = try #require(edit.fieldDrafts.firstIndex { $0.key == "TOKEN" })
        edit.fieldDrafts[index].value = "edited-here"
        viewModel.saveItem(edit)
        let saved = try #require(viewModel.items.first { $0.id == item.id })

        #expect(await viewModel.linkedFileStatus(for: saved) == .vaultChanged)
        #expect(viewModel.envFieldDrift(for: saved, key: "TOKEN") == .vaultChanged)
    }

    @Test func pullingOneVariableLeavesTheOthersAndTheFileAlone() async throws {
        let container = makeContainer("EnvPullOne")
        let viewModel = VaultViewModel(container: container)
        let url = try writeTemporaryEnvFile("# header\nTOKEN=old\nPORT=5432\n")
        defer { try? FileManager.default.removeItem(at: url) }
        let item = try await linkedItem(viewModel, url: url)

        // Both variables move on disk.
        let onDisk = "# header\nTOKEN=new\nPORT=6543\n"
        try onDisk.write(to: url, atomically: true, encoding: .utf8)
        _ = await viewModel.linkedFileStatus(for: item)

        #expect(await viewModel.updateFieldFromLinkedFile(key: "TOKEN", in: item))

        let updated = try #require(viewModel.items.first { $0.id == item.id })
        let values = Dictionary(updated.fields.map { ($0.fieldKey, $0.plainValue) }, uniquingKeysWith: { first, _ in first })
        #expect(values["TOKEN"] == "new")
        // The variable that was not chosen is untouched, and still reported.
        #expect(values["PORT"] == "5432")
        #expect(viewModel.envFieldDrift(for: updated, key: "TOKEN") == nil)
        #expect(viewModel.envFieldDrift(for: updated, key: "PORT") == .fileChanged)
        // Pulling never writes.
        #expect(try String(contentsOf: url, encoding: .utf8) == onDisk)
        // Neither whole-file digest is moved while anything is still unresolved: recording the
        // file as seen would swallow the change to PORT nobody has looked at yet. The file-level
        // status therefore reports both sides as having moved, which they have — the vault's
        // TOKEN came from this file, but the last agreed state is still the one before the pull.
        #expect(await viewModel.linkedFileStatus(for: updated) == .diverged)
        // The value it replaced is still recoverable.
        #expect(updated.fields.contains { $0.previousValues.contains { $0.value == "old" } })
    }

    @Test func pushingOneVariableLeavesTheRestOfTheFileAlone() async throws {
        let container = makeContainer("EnvPushOne")
        let viewModel = VaultViewModel(container: container)
        let url = try writeTemporaryEnvFile("# header\nTOKEN=old\nPORT=5432\n")
        defer { try? FileManager.default.removeItem(at: url) }
        let item = try await linkedItem(viewModel, url: url)

        // The item's value moves, and the file gains a comment and a variable of its own.
        var edit = viewModel.draft(forItemID: item.id)
        edit.id = item.id
        let index = try #require(edit.fieldDrafts.firstIndex { $0.key == "TOKEN" })
        edit.fieldDrafts[index].value = "mine"
        viewModel.saveItem(edit)
        try "# header\n# added on disk\nTOKEN=old\nPORT=5432\nUNTRACKED=keep\n".write(to: url, atomically: true, encoding: .utf8)
        let saved = try #require(viewModel.items.first { $0.id == item.id })
        _ = await viewModel.linkedFileStatus(for: saved)

        #expect(await viewModel.writeFieldToLinkedFile(key: "TOKEN", from: saved))

        #expect(try String(contentsOf: url, encoding: .utf8) == "# header\n# added on disk\nTOKEN=mine\nPORT=5432\nUNTRACKED=keep\n")
        #expect(viewModel.envFieldDrift(for: saved, key: "TOKEN") == nil)
    }

    @Test func resolvingTheLastDifferenceMarksTheItemInSync() async throws {
        let container = makeContainer("EnvResolveLast")
        let viewModel = VaultViewModel(container: container)
        let url = try writeTemporaryEnvFile("# header\nTOKEN=old\n")
        defer { try? FileManager.default.removeItem(at: url) }
        let item = try await linkedItem(viewModel, url: url)

        try "# header\nTOKEN=new\n".write(to: url, atomically: true, encoding: .utf8)
        _ = await viewModel.linkedFileStatus(for: item)
        #expect(await viewModel.updateFieldFromLinkedFile(key: "TOKEN", in: item))

        let updated = try #require(viewModel.items.first { $0.id == item.id })
        #expect(viewModel.linkedFileStatuses[updated.id] == .upToDate)
        #expect(await viewModel.linkedFileStatus(for: updated) == .upToDate)
    }

    @Test func aVariableOnlyInTheFileCanBeAddedToTheItem() async throws {
        let container = makeContainer("EnvAddMissing")
        let viewModel = VaultViewModel(container: container)
        let url = try writeTemporaryEnvFile("TOKEN=old\n")
        defer { try? FileManager.default.removeItem(at: url) }
        let item = try await linkedItem(viewModel, url: url)

        try "TOKEN=old\nSTRIPE_SECRET=sk_live\n".write(to: url, atomically: true, encoding: .utf8)
        _ = await viewModel.linkedFileStatus(for: item)
        #expect(viewModel.envFieldsOnlyInFile(for: item) == ["STRIPE_SECRET"])

        #expect(await viewModel.updateFieldFromLinkedFile(key: "STRIPE_SECRET", in: item))

        let updated = try #require(viewModel.items.first { $0.id == item.id })
        let added = try #require(updated.fields.first { $0.fieldKey == "STRIPE_SECRET" })
        #expect(added.plainValue == "sk_live")
        // It arrives treated the way an import would treat it, not as plain text.
        #expect(added.isSensitive)
        #expect(added.isMasked)
        #expect(viewModel.envFieldsOnlyInFile(for: updated).isEmpty)
    }

    /// A variable the item holds and the file does not is offered as an addition to the file, and
    /// pushing it appends the line rather than rewriting anything.
    @Test func aVariableOnlyInTheItemCanBeAddedToTheFile() async throws {
        let container = makeContainer("EnvAddToFile")
        let viewModel = VaultViewModel(container: container)
        let url = try writeTemporaryEnvFile("# header\nTOKEN=old\n")
        defer { try? FileManager.default.removeItem(at: url) }
        let item = try await linkedItem(viewModel, url: url)

        var edit = viewModel.draft(forItemID: item.id)
        edit.id = item.id
        edit.fieldDrafts.append(
            FieldDraft(key: "NEW_ONE", label: "NEW_ONE", value: "added here", kind: .text, isSensitive: false, sortOrder: 5)
        )
        viewModel.saveItem(edit)
        let saved = try #require(viewModel.items.first { $0.id == item.id })
        _ = await viewModel.linkedFileStatus(for: saved)
        #expect(viewModel.envFieldDrift(for: saved, key: "NEW_ONE") == .onlyInVault)

        #expect(await viewModel.writeFieldToLinkedFile(key: "NEW_ONE", from: saved))

        #expect(try String(contentsOf: url, encoding: .utf8) == "# header\nTOKEN=old\nNEW_ONE=\"added here\"\n")
    }

    /// The per-variable states are cached while the vault is unlocked; locking has to take them
    /// with it, like everything else derived from vault contents.
    @Test func lockingClearsTheDriftCache() async throws {
        let container = makeContainer("EnvDriftLock")
        let viewModel = VaultViewModel(container: container)
        let url = try writeTemporaryEnvFile("TOKEN=old\n")
        defer { try? FileManager.default.removeItem(at: url) }
        let item = try await linkedItem(viewModel, url: url)

        try "TOKEN=new\n".write(to: url, atomically: true, encoding: .utf8)
        _ = await viewModel.linkedFileStatus(for: item)
        #expect(!viewModel.envFieldDrift.isEmpty)

        container.sessionManager.lock()

        #expect(viewModel.envFieldDrift.isEmpty)
    }
}
