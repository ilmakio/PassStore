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

    @Test func typeFilterShowsItemsAcrossWorkspacesWhenWorkspaceWasSelected() throws {
        let container = AppContainer.preview()
        let viewModel = VaultViewModel(container: container)

        let backend = try #require(viewModel.workspaces.first(where: { $0.name == "Pokéos API" }))
        let infra = try #require(viewModel.workspaces.first(where: { $0.name == "Personal Infra" }))

        viewModel.selectDestination(.workspace(infra.id))
        #expect(viewModel.filteredItems.allSatisfy { $0.workspace?.id == infra.id })

        viewModel.setSelectedType(.database)
        #expect(viewModel.filteredItems.contains { $0.title == "Primary Postgres" })
        #expect(viewModel.filteredItems.allSatisfy { $0.type == .database })
        #expect(viewModel.filteredItems.contains { $0.workspace?.id == backend.id })
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
