import Foundation
import Testing
@testable import PassStore

/// Copying a `.env` out of PassStore has to give back the file its owner wrote — their comments
/// where they put them, their section banners, their ordering, their quoting — with the values the
/// vault holds now. Regenerating the document from the item's fields loses all of that, and the
/// comments are usually the only record of what a variable is for.
struct EnvLayoutTests {
    static let sample = """
    # ==============================================================
    # DEV-ONLY — Not deployed, local development convenience
    # ==============================================================

    LOG_LEVEL=info
    DISABLE_SAFEGUARD=true

    # REFLECTS USERS.md
    CURRENT_USER=LUKE
    # IP hashing salt for client-ip anonymization (matches Vercel)
    IP_HASH_SALT=7f3c9d

    # AFTERSHIP
    AFTERSHIP_API_KEY=abc123
    AFTERSHIP_WEBHOOK_SECRET=

    # Sentry — DSN for local logging (no prod yet)
      export SENTRY_DSN='https://example@sentry.invalid/42'
    PORT=5432 # the default

    PRIVATE_KEY="-----BEGIN KEY-----
    abcdef
    -----END KEY-----"
    """

    /// The fields an import of `text` produces, in file order.
    static func fields(from text: String) -> [FieldResolvedValue] {
        EnvImportService().parse(text).entries.enumerated().map { index, entry in
            FieldResolvedValue(
                id: UUID(),
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

    @Test func renderingALayoutReproducesTheFileItCameFrom() {
        let layout = EnvImportService.layout(of: Self.sample)
        let rendered = CopyFormatter.envFileFromLayout(layout, with: Self.fields(from: Self.sample))

        #expect(rendered == Self.sample)
    }

    @Test func changingOneValueChangesOnlyItsLine() {
        let layout = EnvImportService.layout(of: Self.sample)
        var fields = Self.fields(from: Self.sample)
        let index = fields.firstIndex { $0.key == "LOG_LEVEL" }
        #expect(index != nil)
        fields[index ?? 0] = FieldResolvedValue(
            id: fields[index ?? 0].id,
            key: "LOG_LEVEL",
            label: "LOG_LEVEL",
            value: "debug",
            kind: .text,
            isSensitive: false,
            isCopyable: true,
            isMasked: false,
            sortOrder: fields[index ?? 0].sortOrder
        )

        let rendered = CopyFormatter.envFileFromLayout(layout, with: fields)
        let before = Self.sample.components(separatedBy: "\n")
        let after = rendered.components(separatedBy: "\n")

        #expect(before.count == after.count)
        let differences = zip(before, after).filter { $0 != $1 }
        #expect(differences.count == 1)
        #expect(differences.first?.1 == "LOG_LEVEL=debug")
    }

    /// The layout holds no values, so there is nothing to fall back on for a variable the item no
    /// longer has. Emitting the line with an empty value would claim the owner had emptied it.
    @Test func aVariableTheItemNoLongerHoldsLeavesNoStaleLineBehind() {
        let layout = EnvImportService.layout(of: "# note\nKEEP=yes\nGONE=was-here\n")
        let rendered = CopyFormatter.envFileFromLayout(layout, with: [
            FieldResolvedValue(id: UUID(), key: "KEEP", label: "KEEP", value: "yes", kind: .text, isSensitive: false, isCopyable: true, isMasked: false, sortOrder: 0)
        ])

        #expect(rendered == "# note\nKEEP=yes\n")
        #expect(!rendered.contains("GONE"))
    }

    @Test func aVariableAddedInPassStoreIsAppended() {
        let layout = EnvImportService.layout(of: "# note\nKNOWN=yes\n")
        let rendered = CopyFormatter.envFileFromLayout(layout, with: [
            FieldResolvedValue(id: UUID(), key: "KNOWN", label: "KNOWN", value: "yes", kind: .text, isSensitive: false, isCopyable: true, isMasked: false, sortOrder: 0),
            FieldResolvedValue(id: UUID(), key: "ADDED", label: "ADDED", value: "later", kind: .text, isSensitive: false, isCopyable: true, isMasked: false, sortOrder: 1)
        ])

        #expect(rendered == "# note\nKNOWN=yes\nADDED=\"later\"\n")
    }

    @Test func aValueWrittenAcrossSeveralLinesStaysThatWay() {
        let original = """
        KEY="-----BEGIN-----
        second
        -----END-----"
        """
        let layout = EnvImportService.layout(of: original)
        let rendered = CopyFormatter.envFileFromLayout(layout, with: [
            FieldResolvedValue(
                id: UUID(), key: "KEY", label: "KEY",
                value: "-----BEGIN-----\nrotated\n-----END-----",
                kind: .multiline, isSensitive: true, isCopyable: true, isMasked: true, sortOrder: 0
            )
        ])

        #expect(rendered == "KEY=\"-----BEGIN-----\nrotated\n-----END-----\"")
        #expect(EnvImportService().parse(rendered).entries.first?.value == "-----BEGIN-----\nrotated\n-----END-----")
    }

    /// A `.env` says which comment is about which variable by position. This is the reading of
    /// that, and it is what puts each note beside its own entry instead of in one block.
    @Test func theOutlineAttachesEachCommentToTheVariablesUnderIt() {
        let outline = EnvImportService.layout(of: Self.sample).outline

        // The banner block, separated from what follows by a blank line, is a heading. The rules
        // drawn with `=` are not part of it.
        #expect(outline.sections.count == 1)
        let section = try? #require(outline.sections.first)
        #expect(section?.title == "DEV-ONLY — Not deployed, local development convenience")
        #expect(section?.detail.isEmpty == true)

        let groups = section?.groups ?? []
        #expect(groups.first?.comments.isEmpty == true)
        #expect(groups.first?.keys == ["LOG_LEVEL", "DISABLE_SAFEGUARD"])

        let byFirstKey = Dictionary(
            groups.compactMap { group in group.keys.first.map { ($0, group) } },
            uniquingKeysWith: { first, _ in first }
        )
        #expect(byFirstKey["CURRENT_USER"]?.comments == ["REFLECTS USERS.md"])
        #expect(byFirstKey["IP_HASH_SALT"]?.comments == ["IP hashing salt for client-ip anonymization (matches Vercel)"])
        // A block above a run of variables introduces the run, not only its first line.
        #expect(byFirstKey["AFTERSHIP_API_KEY"]?.keys == ["AFTERSHIP_API_KEY", "AFTERSHIP_WEBHOOK_SECRET"])
        #expect(byFirstKey["AFTERSHIP_API_KEY"]?.comments == ["AFTERSHIP"])
        // The note written after a value belongs to that value.
        #expect(outline.trailingComments["PORT"] == "the default")
    }

    @Test func aFileOfPlainAssignmentsHasNothingWorthStoring() {
        #expect(EnvImportService.layout(of: "A=1\nB=2\n").isTrivial)
        #expect(!EnvImportService.layout(of: "# why\nA=1\n").isTrivial)
        #expect(!EnvImportService.layout(of: "export A=1\n").isTrivial)
        #expect(!EnvImportService.layout(of: "A=\"1\"\n").isTrivial)
    }

    @Test func aLayoutSurvivesBeingWrittenToTheVaultAndReadBack() throws {
        let layout = EnvImportService.layout(of: Self.sample)
        let snapshot = SecretItemSnapshot(
            id: UUID(),
            title: "Project env",
            typeRawValue: SecretItemType.envGroup.rawValue,
            environmentRawValue: EnvironmentKind.dev.rawValue,
            customEnvironmentName: nil,
            notes: "",
            tagsRawValue: "",
            isFavorite: false,
            isArchived: false,
            createdAt: .now,
            updatedAt: .now,
            lastAccessedAt: nil,
            workspaceID: nil,
            templateID: nil,
            fields: [],
            envLayout: layout
        )

        let encoded = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(SecretItemSnapshot.self, from: encoded)

        #expect(decoded.envLayout == layout)
        let rendered = CopyFormatter.envFileFromLayout(
            try #require(decoded.envLayout),
            with: Self.fields(from: Self.sample)
        )
        #expect(rendered == Self.sample)
    }

    /// A vault written before layouts existed has no `envLayout` key at all.
    @Test func anItemFromAnEarlierVaultDecodesWithoutALayout() throws {
        let json = """
        {
          "id": "00000000-0000-0000-0000-000000000001",
          "title": "Older item",
          "typeRawValue": "envGroup",
          "environmentRawValue": "dev",
          "notes": "",
          "tagsRawValue": "",
          "isFavorite": false,
          "isArchived": false,
          "createdAt": 0,
          "updatedAt": 0,
          "fields": []
        }
        """
        let decoded = try JSONDecoder().decode(SecretItemSnapshot.self, from: Data(json.utf8))
        #expect(decoded.envLayout == nil)
    }
}

@MainActor
struct EnvLayoutIntegrationTests {
    private func makeViewModel(_ label: String) -> VaultViewModel {
        let defaults = UserDefaults(suiteName: "\(label)-\(UUID().uuidString)")!
        let container = AppContainer(
            inMemory: true,
            defaults: defaults,
            keyStore: InMemoryVaultKeyStore(isBiometricHardwareAvailable: false),
            encryptedVaultStore: InMemoryEncryptedVaultStore()
        )
        container.sessionManager.createVaultSynchronously(password: "test-password")
        return VaultViewModel(container: container)
    }

    private func writeTemporaryEnvFile(_ contents: String) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("passstore-layout-\(UUID().uuidString)")
            .appendingPathComponent(".env")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @Test func copyingAnImportedEnvGivesBackTheFileThatWasImported() throws {
        let viewModel = makeViewModel("EnvCopyOriginal")
        var draft = try #require(viewModel.prepareEnvImport(from: .pastedText(EnvLayoutTests.sample), parseIntoEntries: true))
        draft.title = "Project env"
        let item = try #require(viewModel.saveNewItem(draft, linkingTo: nil, parsedIntoFields: true))

        #expect(item.envLayout != nil)
        #expect(viewModel.envDocumentContents(for: item) == EnvLayoutTests.sample)
        // The comments are no longer flattened into the notes box.
        #expect(item.notes.isEmpty)
        // And the values-only form is still available for anything that strips comments.
        let valuesOnly = CopyFormatter.envFileContents(fields: viewModel.resolvedFields(for: item))
        #expect(!valuesOnly.contains("#"))
        #expect(valuesOnly.contains("LOG_LEVEL=\"info\""))
    }

    /// Pulling a file used to overwrite the item's notes with the file's comments flattened into
    /// one block, which took away notes the owner had written themselves.
    @Test func pullingAFileLeavesTheOwnersNotesAlone() async throws {
        let viewModel = makeViewModel("EnvPullNotes")
        let url = try writeTemporaryEnvFile("# first\nTOKEN=old\n")
        defer { try? FileManager.default.removeItem(at: url) }

        var draft = try #require(viewModel.prepareEnvImport(from: .file(url), parseIntoEntries: true))
        draft.title = "Project env"
        draft.notes = "Rotate this every quarter."
        let item = try #require(viewModel.saveNewItem(draft, linkingTo: nil, parsedIntoFields: true))
        await viewModel.linkFile(at: url, to: item, parsedIntoFields: true, acceptCurrentContentsAsSynced: true)

        try "# first\n# and a second comment\nTOKEN=new\n".write(to: url, atomically: true, encoding: .utf8)
        #expect(await viewModel.updateItemFromLinkedFile(try #require(viewModel.items.first { $0.id == item.id })))

        let updated = try #require(viewModel.items.first { $0.id == item.id })
        #expect(updated.notes == "Rotate this every quarter.")
        // The pull brought the file's new shape in with its new value.
        #expect(viewModel.envDocumentContents(for: updated) == "# first\n# and a second comment\nTOKEN=new\n")
    }

    /// An item imported before layouts existed picks the formatting up when it is linked.
    @Test func linkingAFileTeachesAnOlderItemItsFormatting() async throws {
        let viewModel = makeViewModel("EnvAdoptLayout")
        let contents = "# header\nTOKEN=old\n"
        let url = try writeTemporaryEnvFile(contents)
        defer { try? FileManager.default.removeItem(at: url) }

        var draft = try #require(viewModel.prepareEnvImport(from: .pastedText(contents), parseIntoEntries: true))
        draft.title = "Older env"
        draft.envLayout = nil
        let item = try #require(viewModel.saveNewItem(draft, linkingTo: nil, parsedIntoFields: true))
        #expect(item.envLayout == nil)

        await viewModel.linkFile(at: url, to: item, parsedIntoFields: true, acceptCurrentContentsAsSynced: true)

        let linked = try #require(viewModel.items.first { $0.id == item.id })
        #expect(linked.envLayout != nil)
        #expect(viewModel.envDocumentContents(for: linked) == contents)
    }

    /// Editing an item must not cost it the formatting of the file it came from.
    @Test func editingAnItemKeepsItsStoredFormatting() throws {
        let viewModel = makeViewModel("EnvEditKeepsLayout")
        var draft = try #require(viewModel.prepareEnvImport(from: .pastedText("# header\nTOKEN=old\n"), parseIntoEntries: true))
        draft.title = "Project env"
        let item = try #require(viewModel.saveNewItem(draft, linkingTo: nil, parsedIntoFields: true))

        var edit = viewModel.draft(forItemID: item.id)
        edit.id = item.id
        let index = try #require(edit.fieldDrafts.firstIndex { $0.key == "TOKEN" })
        edit.fieldDrafts[index].value = "new"
        viewModel.saveItem(edit)

        let saved = try #require(viewModel.items.first { $0.id == item.id })
        #expect(saved.envLayout != nil)
        #expect(viewModel.envDocumentContents(for: saved) == "# header\nTOKEN=new\n")
    }

    /// A duplicate is not linked to the same file, but it is still the same `.env`.
    @Test func duplicatingAnItemKeepsItsFormatting() throws {
        let viewModel = makeViewModel("EnvDuplicateLayout")
        var draft = try #require(viewModel.prepareEnvImport(from: .pastedText("# header\nTOKEN=old\n"), parseIntoEntries: true))
        draft.title = "Project env"
        let item = try #require(viewModel.saveNewItem(draft, linkingTo: nil, parsedIntoFields: true))

        let duplicate = try viewModel.container.itemRepository.duplicateItem(item)

        #expect(duplicate.linkedFile == nil)
        #expect(duplicate.envLayout == item.envLayout)
    }
}
