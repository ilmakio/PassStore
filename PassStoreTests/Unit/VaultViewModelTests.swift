import Foundation
import Testing
@testable import PassStore

@MainActor
struct VaultViewModelTests {
    @Test func sidebarDestinationsFilterItemsByWorkspaceTagAndEnvironment() throws {
        let container = AppContainer.preview()
        let viewModel = VaultViewModel(container: container)

        let backend = try #require(viewModel.workspaces.first(where: { $0.name == "Pokéos API" }))
        viewModel.selectDestination(.workspace(backend.id))
        #expect(!viewModel.filteredItems.isEmpty)
        #expect(viewModel.filteredItems.allSatisfy { $0.workspace?.id == backend.id })

        viewModel.selectDestination(.tag("frontend"))
        #expect(viewModel.filteredItems.count == 1)
        #expect(viewModel.filteredItems.first?.title == "Frontend .env")

        viewModel.selectDestination(.environment("Prod"))
        #expect(viewModel.filteredItems.count == 1)
        #expect(viewModel.filteredItems.first?.title == "Primary Postgres")
    }

    /// The type filter narrows *within* the current workspace.
    ///
    /// It used to widen to the whole vault while the header still named the workspace, so the
    /// title described a scope the list was not showing.
    @Test func typeFilterNarrowsWithinTheSelectedWorkspace() throws {
        let container = AppContainer.preview()
        let viewModel = VaultViewModel(container: container)

        let backend = try #require(viewModel.workspaces.first(where: { $0.name == "Pokéos API" }))
        let infra = try #require(viewModel.workspaces.first(where: { $0.name == "Personal Infra" }))

        viewModel.selectDestination(.workspace(infra.id))
        #expect(viewModel.filteredItems.allSatisfy { $0.workspace?.id == infra.id })

        viewModel.setSelectedType(.database)
        #expect(viewModel.filteredItems.allSatisfy { $0.type == .database })
        #expect(viewModel.filteredItems.allSatisfy { $0.workspace?.id == infra.id })
        #expect(!viewModel.filteredItems.contains { $0.workspace?.id == backend.id })

        // Browsing by type from the library still spans every workspace.
        viewModel.selectDestination(.library(.allItems))
        viewModel.setSelectedType(.database)
        #expect(viewModel.filteredItems.contains { $0.title == "Primary Postgres" })
    }

    @Test func visibleFieldsExcludeResolvedEmptyValues() {
        let visible = VaultViewModel.visibleFields(in: [
            .init(id: UUID(), key: "host", label: "Host", value: "db.example.dev", kind: .text, isSensitive: false, isCopyable: true, isMasked: false, sortOrder: 0),
            .init(id: UUID(), key: "privateKey", label: "Private Key", value: "", kind: .multiline, isSensitive: true, isCopyable: true, isMasked: true, sortOrder: 1),
            .init(id: UUID(), key: "note", label: "Note", value: "   ", kind: .text, isSensitive: false, isCopyable: true, isMasked: false, sortOrder: 2)
        ])

        #expect(visible.count == 1)
        #expect(visible.first?.key == "host")
    }

    @Test func newItemDraftUsesTemplateAndWorkspaceDefaultsFromCurrentContext() throws {
        let container = AppContainer.preview()
        let viewModel = VaultViewModel(container: container)

        let backend = try #require(viewModel.workspaces.first(where: { $0.name == "Pokéos API" }))
        let databaseTemplate = try #require(viewModel.defaultTemplate(for: .database))

        viewModel.selectDestination(.workspace(backend.id))
        let workspaceDraft = viewModel.newItemDraft(template: databaseTemplate)

        #expect(workspaceDraft.workspaceID == backend.id)
        #expect(workspaceDraft.templateID == databaseTemplate.id)
        #expect(workspaceDraft.type == .database)
        #expect(workspaceDraft.fieldDrafts.map(\.key) == ["db_engine", "host", "port", "database", "username", "password"])

        viewModel.selectDestination(.environment("Staging"))
        let environmentDraft = viewModel.newItemDraft(template: databaseTemplate)
        #expect(environmentDraft.environment == .preset(.staging))
    }

    @Test func renamingWorkspaceRefreshesSelectedDestinationMetadataImmediately() throws {
        let container = AppContainer.preview()
        let viewModel = VaultViewModel(container: container)

        let workspace = try #require(viewModel.workspaces.first(where: { $0.name == "Pokéos API" }))
        viewModel.selectDestination(.workspace(workspace.id))

        viewModel.saveWorkspace(.init(
            id: workspace.id,
            name: "Core Control Plane",
            icon: "bolt.horizontal.circle.fill",
            colorHex: "#FF7A00",
            notes: "Renamed workspace"
        ))

        guard case let .workspace(selectedWorkspaceID) = viewModel.selectedDestination else {
            Issue.record("Expected selected destination to remain on the edited workspace.")
            return
        }

        #expect(selectedWorkspaceID == workspace.id)
        #expect(viewModel.destinationTitle == "Core Control Plane")
        #expect(viewModel.destinationSystemImage == "bolt.horizontal.circle.fill")
        #expect(viewModel.workspace(for: workspace.id)?.colorHex == "#FF7A00")
        #expect(!viewModel.filteredItems.isEmpty)
        #expect(viewModel.filteredItems.allSatisfy { $0.workspace?.id == workspace.id })
        #expect(viewModel.filteredItems.allSatisfy { $0.workspace?.name == "Core Control Plane" })
    }

    @Test func togglingFavoriteUpdatesSelectedItemAndFavoritesListImmediately() throws {
        let container = AppContainer.preview()
        let viewModel = VaultViewModel(container: container)

        let item = try #require(viewModel.items.first(where: { $0.title == "Edge Storage" }))
        viewModel.selectDestination(.library(.allItems))
        viewModel.select(item)

        #expect(viewModel.selectedItem?.isFavorite == false)

        viewModel.toggleFavoriteForSelectedItem()

        #expect(viewModel.selectedItem?.id == item.id)
        #expect(viewModel.selectedItem?.isFavorite == true)
        #expect(viewModel.items.first(where: { $0.id == item.id })?.isFavorite == true)

        viewModel.selectDestination(.library(.favorites))
        #expect(viewModel.filteredItems.contains(where: { $0.id == item.id }))
    }

    @Test func prepareEnvImportFromPastedTextBuildsEditableDraft() throws {
        let container = AppContainer.preview()
        let viewModel = VaultViewModel(container: container)

        let workspace = try #require(viewModel.workspaces.first(where: { $0.name == "Pokéos API" }))
        viewModel.selectDestination(.workspace(workspace.id))

        let draft = try #require(viewModel.prepareEnvImport(from: .pastedText("""
        # local config
        API_URL=https://example.com
        SESSION_SECRET=abc123
        """)))

        #expect(draft.title == "Imported .env")
        #expect(draft.type == .envGroup)
        #expect(draft.workspaceID == workspace.id)
        #expect(draft.notes == "local config")
        #expect(draft.tags.isEmpty)
        #expect(draft.fieldDrafts.map(\.key) == ["API_URL", "SESSION_SECRET"])
        #expect(draft.fieldDrafts.last?.isSensitive == true)
    }

    @Test func prepareEnvImportFromHiddenFileUsesFileContents() throws {
        let container = AppContainer.preview()
        let viewModel = VaultViewModel(container: container)

        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent(".env")
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try """
        API_URL=https://devvault.local
        ACCESS_KEY=topsecret
        """.write(to: fileURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }

        let draft = try #require(viewModel.prepareEnvImport(from: .file(fileURL)))

        #expect(draft.title == ".env")
        #expect(draft.type == .envGroup)
        #expect(draft.fieldDrafts.count == 2)
        #expect(draft.fieldDrafts[0].key == "API_URL")
        #expect(draft.fieldDrafts[1].key == "ACCESS_KEY")
        #expect(draft.fieldDrafts[1].isSensitive == true)
    }

    @Test func prepareEnvImportRawModeStoresSingleMultilineField() throws {
        let container = AppContainer.preview()
        let viewModel = VaultViewModel(container: container)

        let raw = """
        # not parsed as entries
        API_URL=https://example.com
        SESSION_SECRET=abc123
        """
        let draft = try #require(viewModel.prepareEnvImport(from: .pastedText(raw), parseIntoEntries: false))

        #expect(draft.type == .envGroup)
        #expect(draft.fieldDrafts.count == 1)
        #expect(draft.fieldDrafts[0].key == "env")
        #expect(draft.fieldDrafts[0].kind == .multiline)
        #expect(draft.fieldDrafts[0].value == raw)
        #expect(draft.notes.isEmpty)
    }

    @Test func passwordGeneratorProducesRequestedLength() {
        let password = PasswordGenerator.generate(length: 32)
        #expect(password.count == 32)
        #expect(password.contains { $0.isNumber })
    }

    @Test func passwordGeneratorGuaranteesEveryEnabledClassAppears() {
        let options = PasswordGeneratorOptions(
            length: 12,
            includeLowercase: true,
            includeUppercase: true,
            includeDigits: true,
            includeSymbols: true
        )
        // Probabilistic guarantees deserve repetition rather than a single lucky draw.
        for _ in 0..<200 {
            let password = PasswordGenerator.generate(options: options)
            let hasLower = password.contains(where: \.isLowercase)
            let hasUpper = password.contains(where: \.isUppercase)
            let hasDigit = password.contains(where: \.isNumber)
            let hasSymbol = password.contains { !$0.isLetter && !$0.isNumber }
            #expect(password.count == 12)
            #expect(hasLower)
            #expect(hasUpper)
            #expect(hasDigit)
            #expect(hasSymbol)
        }
    }

    @Test func passwordGeneratorHonoursDisabledClassesAndAmbiguityFilter() {
        var digitsOnly = PasswordGeneratorOptions(length: 20)
        digitsOnly.includeLowercase = false
        digitsOnly.includeUppercase = false
        digitsOnly.includeSymbols = false
        for _ in 0..<50 {
            let onlyDigits = PasswordGenerator.generate(options: digitsOnly).allSatisfy(\.isNumber)
            #expect(onlyDigits)
        }

        var noLookAlikes = PasswordGeneratorOptions(length: 60)
        noLookAlikes.excludeAmbiguous = true
        let ambiguous: Set<Character> = ["0", "O", "o", "1", "l", "I"]
        for _ in 0..<50 {
            let password = PasswordGenerator.generate(options: noLookAlikes)
            let containsAmbiguous = password.contains { ambiguous.contains($0) }
            #expect(!containsAmbiguous)
        }
    }

    @Test func passwordGeneratorFallsBackWhenEveryClassIsDisabled() {
        var options = PasswordGeneratorOptions(length: 16)
        options.includeLowercase = false
        options.includeUppercase = false
        options.includeDigits = false
        options.includeSymbols = false

        #expect(!options.hasUsableCharacterSet)
        let password = PasswordGenerator.generate(options: options)
        let allLowercase = password.allSatisfy(\.isLowercase)
        #expect(password.count == 16)
        #expect(allLowercase)
    }

    @Test func fieldURLSupportUpgradesBareHostsAndRejectsUnsafeSchemes() {
        #expect(FieldURLSupport.url(from: "example.com")?.absoluteString == "https://example.com")
        #expect(FieldURLSupport.url(from: " https://api.example.dev/v1 ")?.host == "api.example.dev")
        #expect(FieldURLSupport.url(from: "http://localhost.dev")?.scheme == "http")

        // Vault contents can come from an imported backup: only web schemes may be handed to the OS.
        #expect(FieldURLSupport.url(from: "file:///etc/passwd") == nil)
        #expect(FieldURLSupport.url(from: "javascript:alert(1)") == nil)
        #expect(FieldURLSupport.url(from: "x-apple-something://run") == nil)
        #expect(FieldURLSupport.url(from: "not a url") == nil)
        #expect(FieldURLSupport.url(from: "") == nil)
        #expect(FieldURLSupport.url(from: "https://a.dev\nhttps://b.dev") == nil)
    }

    @Test func applyItemTypeChangeWithEmptyFieldsUsesNewTemplate() throws {
        let container = AppContainer.preview()
        let viewModel = VaultViewModel(container: container)
        let databaseTemplate = try #require(viewModel.defaultTemplate(for: .database))
        let apiTemplate = try #require(viewModel.defaultTemplate(for: .apiCredential))
        let expectedKeys = apiTemplate.fieldDefinitions.sorted { $0.sortOrder < $1.sortOrder }.map(\.key)

        var draft = viewModel.newItemDraft(template: databaseTemplate)
        #expect(draft.type == .database)
        #expect(draft.fieldDrafts.allSatisfy { $0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })

        viewModel.applyItemTypeChange(to: &draft, newType: .apiCredential)
        #expect(draft.type == .apiCredential)
        #expect(draft.templateID == apiTemplate.id)
        #expect(draft.fieldDrafts.map(\.key) == expectedKeys)
    }

    @Test func deletingSelectedWorkspaceFallsBackToAllItems() throws {
        let container = AppContainer.preview()
        let viewModel = VaultViewModel(container: container)

        let workspace = try #require(viewModel.workspaces.first(where: { $0.name == "Pokéos API" }))
        viewModel.selectDestination(.workspace(workspace.id))
        let ownedCount = viewModel.itemCount(inWorkspace: workspace.id)
        #expect(ownedCount > 0)

        viewModel.requestWorkspaceDeletion(id: workspace.id)
        #expect(viewModel.workspacePendingDeletion?.id == workspace.id)

        viewModel.confirmWorkspaceDeletion()

        #expect(viewModel.workspacePendingDeletion == nil)
        #expect(viewModel.selectedDestination == .library(.allItems))
        #expect(!viewModel.workspaces.contains(where: { $0.id == workspace.id }))
        // Items survive the workspace; they simply become unassigned.
        #expect(viewModel.items.contains(where: { $0.title == "Primary Postgres" }))
        #expect(viewModel.itemCount(inWorkspace: workspace.id) == 0)
        #expect(viewModel.alertMessage == nil)
    }

    @Test func libraryCountsTrackFavoritesAndArchive() throws {
        let container = AppContainer.preview()
        let viewModel = VaultViewModel(container: container)

        let total = viewModel.items.count
        #expect(viewModel.itemCount(in: .allItems) == total)
        #expect(viewModel.itemCount(in: .archived) == 0)
        #expect(viewModel.itemCount(in: .favorites) == viewModel.items.filter(\.isFavorite).count)

        let item = try #require(viewModel.items.first(where: { $0.title == "Edge Storage" }))
        viewModel.archive(item)

        #expect(viewModel.itemCount(in: .archived) == 1)
        #expect(viewModel.itemCount(in: .allItems) == total - 1)
    }

    @Test func moveSelectionWalksTheFilteredListAndStopsAtTheEdges() throws {
        let container = AppContainer.preview()
        let viewModel = VaultViewModel(container: container)
        viewModel.selectDestination(.library(.allItems))

        let visible = viewModel.filteredItems
        #expect(visible.count > 1)

        // With nothing selected, the first move lands on the first row.
        viewModel.moveSelection(by: 1)
        #expect(viewModel.selectedItemID == visible.first?.id)

        viewModel.moveSelection(by: 1)
        #expect(viewModel.selectedItemID == visible[1].id)

        viewModel.moveSelection(by: -1)
        #expect(viewModel.selectedItemID == visible.first?.id)

        // Already at the top: no wrap-around.
        viewModel.moveSelection(by: -1)
        #expect(viewModel.selectedItemID == visible.first?.id)
    }

    @Test func clearFiltersResetsSearchAndTypeButKeepsDestination() throws {
        let container = AppContainer.preview()
        let viewModel = VaultViewModel(container: container)

        let workspace = try #require(viewModel.workspaces.first(where: { $0.name == "Pokéos API" }))
        viewModel.selectDestination(.workspace(workspace.id))
        #expect(!viewModel.hasActiveFilters)

        viewModel.searchText = "postgres"
        viewModel.setSelectedType(.database)
        #expect(viewModel.hasActiveFilters)

        viewModel.clearFilters()

        #expect(!viewModel.hasActiveFilters)
        #expect(viewModel.searchText.isEmpty)
        #expect(viewModel.selectedType == nil)
        #expect(viewModel.selectedDestination == .workspace(workspace.id))
    }

    @Test func bulkArchiveMovesEverySelectedItemInOnePass() throws {
        let container = AppContainer.preview()
        let viewModel = VaultViewModel(container: container)
        viewModel.selectDestination(.library(.allItems))

        let targets = Array(viewModel.filteredItems.prefix(2))
        #expect(targets.count == 2)
        for target in targets {
            viewModel.toggleMultiSelect(target)
        }
        #expect(viewModel.multiSelectedIDs.count == 2)

        viewModel.bulkArchive()

        #expect(viewModel.multiSelectedIDs.isEmpty)
        #expect(viewModel.selectedDestination == .library(.archived))
        #expect(viewModel.itemCount(in: .archived) == 2)
        for target in targets {
            #expect(viewModel.items.first(where: { $0.id == target.id })?.isArchived == true)
        }
        #expect(viewModel.alertMessage == nil)
    }

    @Test func vaultHealthFlagsReusedSecretsWithoutLeakingValues() throws {
        let container = AppContainer.preview()
        let viewModel = VaultViewModel(container: container)

        let shared = "shared-across-two-items"
        for title in ["Service A", "Service B"] {
            viewModel.saveItem(SecretItemDraft(
                title: title,
                type: .generic,
                workspaceID: nil,
                environment: .preset(.prod),
                notes: "",
                tags: [],
                isFavorite: false,
                fieldDrafts: [
                    FieldDraft(key: "secret", label: "Secret", value: shared, kind: .secret, isSensitive: true, isMasked: true, sortOrder: 0)
                ],
                templateID: nil
            ))
        }

        let report = viewModel.vaultHealthReport()
        let reused = report.findings.filter { $0.kind == .reused }
        #expect(reused.count == 2)
        #expect(Set(reused.map(\.itemTitle)) == ["Service A", "Service B"])
        // The report is meant to be safe to show or screenshot.
        let leaksValue = report.findings.contains { $0.detail.contains(shared) }
        #expect(!leaksValue)
    }

    @Test func vaultHealthFlagsWeakSecretsAndStaysCleanForStrongOnes() throws {
        let container = AppContainer.preview()
        let viewModel = VaultViewModel(container: container)

        viewModel.saveItem(SecretItemDraft(
            title: "Weak Login",
            type: .generic,
            workspaceID: nil,
            environment: .preset(.dev),
            notes: "",
            tags: [],
            isFavorite: false,
            fieldDrafts: [
                FieldDraft(key: "secret", label: "Secret", value: "abc", kind: .secret, isSensitive: true, isMasked: true, sortOrder: 0)
            ],
            templateID: nil
        ))

        let report = viewModel.vaultHealthReport()
        let flaggedWeak = report.findings.contains { $0.kind == .weak && $0.itemTitle == "Weak Login" }
        #expect(flaggedWeak)
        #expect(report.auditedItemCount > 0)

        let strong = PasswordGenerator.generate(length: 32)
        #expect(!PasswordStrength.evaluate(strong).needsAttention)
    }

    @Test func searchMatchesAllTokensAndNonSensitiveValuesOnly() throws {
        let container = AppContainer.preview()
        let viewModel = VaultViewModel(container: container)
        viewModel.selectDestination(.library(.allItems))

        // Matches on a non-sensitive field value (the host), which plain label search missed.
        viewModel.searchText = "db.pokeos.internal"
        #expect(viewModel.filteredItems.map(\.title) == ["Primary Postgres"])

        // Every token must match: this narrows rather than widening.
        viewModel.searchText = "postgres nonexistenttoken"
        #expect(viewModel.filteredItems.isEmpty)

        viewModel.searchText = "primary postgres"
        #expect(viewModel.filteredItems.map(\.title) == ["Primary Postgres"])

        // A sensitive value must never be confirmable through the search box.
        viewModel.searchText = "super-secret-password"
        #expect(viewModel.filteredItems.isEmpty)

        viewModel.clearFilters()
        #expect(!viewModel.filteredItems.isEmpty)
    }

    @Test func deletionRequiresConfirmationAndClearsSelection() throws {
        let container = AppContainer.preview()
        let viewModel = VaultViewModel(container: container)
        viewModel.selectDestination(.library(.allItems))

        let targets = Array(viewModel.filteredItems.prefix(2))
        #expect(targets.count == 2)
        let countBefore = viewModel.items.count
        viewModel.select(targets[0])

        viewModel.requestDeletion(of: targets)
        // Nothing is destroyed until the dialog is confirmed.
        #expect(viewModel.items.count == countBefore)
        #expect(viewModel.itemsPendingDeletion.count == 2)
        #expect(viewModel.itemDeletionTitle == "Delete 2 items?")
        #expect(viewModel.itemDeletionConfirmLabel == "Delete 2 Items")

        viewModel.cancelItemDeletion()
        #expect(viewModel.itemsPendingDeletion.isEmpty)
        #expect(viewModel.items.count == countBefore)

        viewModel.requestDeletion(of: targets)
        viewModel.confirmItemDeletion()

        #expect(viewModel.items.count == countBefore - 2)
        #expect(viewModel.itemsPendingDeletion.isEmpty)
        #expect(viewModel.selectedItemID == nil)
        for target in targets {
            let stillPresent = viewModel.items.contains { $0.id == target.id }
            #expect(!stillPresent)
        }
    }

    @Test func singleItemDeletionDialogNamesTheItem() throws {
        let container = AppContainer.preview()
        let viewModel = VaultViewModel(container: container)
        let item = try #require(viewModel.items.first(where: { $0.title == "Primary Postgres" }))

        viewModel.requestDeletion(of: item)
        #expect(viewModel.itemDeletionTitle.contains("Primary Postgres"))
        #expect(viewModel.itemDeletionConfirmLabel == "Delete")
        // Postgres seed has a sensitive password field, so the warning should say so.
        #expect(viewModel.itemDeletionMessage.contains("stored secret"))
    }

    @Test func applyItemTypeChangeWithFilledFieldsPreservesFieldDrafts() throws {
        let container = AppContainer.preview()
        let viewModel = VaultViewModel(container: container)
        let databaseTemplate = try #require(viewModel.defaultTemplate(for: .database))

        var draft = viewModel.newItemDraft(template: databaseTemplate)
        let passwordIndex = try #require(draft.fieldDrafts.firstIndex(where: { $0.key == "password" }))
        draft.fieldDrafts[passwordIndex].value = "stored-secret"
        let keysBefore = draft.fieldDrafts.map(\.key)

        viewModel.applyItemTypeChange(to: &draft, newType: .generic)
        #expect(draft.type == .generic)
        #expect(draft.fieldDrafts.map(\.key) == keysBefore)
        #expect(draft.fieldDrafts[passwordIndex].value == "stored-secret")
    }
}
