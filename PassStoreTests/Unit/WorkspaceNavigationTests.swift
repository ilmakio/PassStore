import Foundation
import Testing
@testable import PassStore

/// Navigating a workspace by environment: the destination, the tab bar behind it, and what a new
/// secret inherits from where you were standing when you created it.
@MainActor
struct WorkspaceNavigationTests {
    private struct Fixture {
        let container: AppContainer
        let viewModel: VaultViewModel
        let workspaceID: UUID
    }

    private func makeFixture(
        _ label: String,
        declaring environments: [WorkspaceEnvironment] = [
            WorkspaceEnvironment(name: "Local", kind: .local, sortOrder: 0),
            WorkspaceEnvironment(name: "Prod", kind: .prod, sortOrder: 1)
        ],
        items: [(String, EnvironmentValue)] = [("Local DB", .preset(.local)), ("Prod DB", .preset(.prod))]
    ) throws -> Fixture {
        let container = AppContainer(
            inMemory: true,
            defaults: UserDefaults(suiteName: "WorkspaceNavigation-\(label)-\(UUID().uuidString)")!,
            keyStore: InMemoryVaultKeyStore(isBiometricHardwareAvailable: false),
            encryptedVaultStore: InMemoryEncryptedVaultStore()
        )
        container.sessionManager.createVaultSynchronously(password: "test-password")
        let viewModel = VaultViewModel(container: container)
        let workspace = try #require(viewModel.createWorkspace(
            WorkspaceDraft(
                name: "Acme API",
                icon: "server.rack",
                colorHex: "#4A7AFF",
                notes: "",
                environments: environments
            )
        ))
        for (title, environment) in items {
            _ = try container.itemRepository.saveItem(SecretItemDraft(
                title: title,
                type: .generic,
                workspaceID: workspace.id,
                environment: environment,
                notes: "",
                tags: [],
                isFavorite: false,
                fieldDrafts: [
                    FieldDraft(key: "token", label: "Token", value: "v-\(title)", kind: .secret, isSensitive: true, sortOrder: 0)
                ],
                templateID: nil
            ))
        }
        viewModel.reload()
        return Fixture(container: container, viewModel: viewModel, workspaceID: workspace.id)
    }

    @Test func selectingAnEnvironmentNarrowsTheListToIt() throws {
        let fixture = try makeFixture("Narrow")
        let viewModel = fixture.viewModel

        viewModel.selectDestination(.workspace(fixture.workspaceID))
        #expect(viewModel.filteredItems.map(\.title).sorted() == ["Local DB", "Prod DB"])

        viewModel.selectDestination(.workspaceEnvironment(fixture.workspaceID, "Prod"))
        #expect(viewModel.filteredItems.map(\.title) == ["Prod DB"])
        #expect(viewModel.destinationTitle == "Acme API › Prod")
    }

    /// The scoped destination is a workspace *and* an environment. An item in the right
    /// environment of another workspace must not leak into it.
    @Test func anEnvironmentOfOneWorkspaceDoesNotShowAnothersItems() throws {
        let fixture = try makeFixture("Isolation")
        let other = try #require(fixture.viewModel.createWorkspace(
            WorkspaceDraft(name: "Other", icon: "shippingbox", colorHex: "#4A7AFF", notes: "")
        ))
        _ = try fixture.container.itemRepository.saveItem(SecretItemDraft(
            title: "Other Prod",
            type: .generic,
            workspaceID: other.id,
            environment: .preset(.prod),
            notes: "",
            tags: [],
            isFavorite: false,
            fieldDrafts: [],
            templateID: nil
        ))
        fixture.viewModel.reload()

        fixture.viewModel.selectDestination(.workspaceEnvironment(fixture.workspaceID, "Prod"))
        #expect(fixture.viewModel.filteredItems.map(\.title) == ["Prod DB"])

        // The vault-wide environment list still answers the other question.
        fixture.viewModel.selectDestination(.environment("Prod"))
        #expect(fixture.viewModel.filteredItems.map(\.title).sorted() == ["Other Prod", "Prod DB"])
    }

    @Test func environmentTitlesAreMatchedWithoutCaringAboutCase() throws {
        let fixture = try makeFixture(
            "Case",
            declaring: [WorkspaceEnvironment(name: "QA", kind: .custom, sortOrder: 0)],
            items: [("QA DB", .custom("qa"))]
        )

        fixture.viewModel.selectDestination(.workspaceEnvironment(fixture.workspaceID, "QA"))
        #expect(fixture.viewModel.filteredItems.map(\.title) == ["QA DB"])
    }

    @Test func theTabsOnlyAppearWhereThereIsSomethingToDivide() throws {
        let flat = try makeFixture(
            "Flat",
            declaring: [],
            items: [("One", .preset(.dev)), ("Two", .preset(.dev))]
        )
        flat.viewModel.selectDestination(.workspace(flat.workspaceID))
        #expect(flat.viewModel.environmentBarWorkspaceID == nil)

        let project = try makeFixture("Project")
        project.viewModel.selectDestination(.workspace(project.workspaceID))
        #expect(project.viewModel.environmentBarWorkspaceID == project.workspaceID)
        #expect(project.viewModel.environmentBarItems.map(\.title) == ["Local", "Prod"])
        #expect(project.viewModel.selectedEnvironmentMatchKey == nil)

        // Nowhere near a workspace, there is nothing to show tabs for.
        project.viewModel.selectDestination(.library(.allItems))
        #expect(project.viewModel.environmentBarWorkspaceID == nil)
    }

    @Test func cyclingMovesThroughAllAndWrapsAround() throws {
        let fixture = try makeFixture("Cycle")
        let viewModel = fixture.viewModel
        viewModel.selectDestination(.workspace(fixture.workspaceID))

        viewModel.cycleEnvironment(by: 1)
        #expect(viewModel.selectedEnvironmentMatchKey == "local")
        viewModel.cycleEnvironment(by: 1)
        #expect(viewModel.selectedEnvironmentMatchKey == "prod")
        // Past the last environment is back to the whole workspace.
        viewModel.cycleEnvironment(by: 1)
        #expect(viewModel.selectedEnvironmentMatchKey == nil)
        #expect(viewModel.selectedDestination == .workspace(fixture.workspaceID))
        // And backwards from there is the last one.
        viewModel.cycleEnvironment(by: -1)
        #expect(viewModel.selectedEnvironmentMatchKey == "prod")
    }

    @Test func aNewSecretStartsInTheEnvironmentYouAreLookingAt() throws {
        let fixture = try makeFixture("Prefill")
        let viewModel = fixture.viewModel

        viewModel.selectDestination(.workspaceEnvironment(fixture.workspaceID, "Prod"))
        let inProd = viewModel.newItemDraft()
        #expect(inProd.workspaceID == fixture.workspaceID)
        #expect(inProd.environment.title == "Prod")

        // In the workspace as a whole, the first environment the project offers — not whatever
        // the global default happens to be.
        viewModel.selectDestination(.workspace(fixture.workspaceID))
        let inWorkspace = viewModel.newItemDraft()
        #expect(inWorkspace.environment.title == "Local")
    }

    @Test func anEnvironmentThatEmptiesFallsBackToItsWorkspaceNotTheWholeVault() throws {
        let fixture = try makeFixture(
            "Fallback",
            declaring: [],
            items: [("Local DB", .preset(.local)), ("Prod DB", .preset(.prod))]
        )
        let viewModel = fixture.viewModel
        viewModel.selectDestination(.workspaceEnvironment(fixture.workspaceID, "Prod"))

        let prodItem = try #require(viewModel.items.first(where: { $0.title == "Prod DB" }))
        var draft = viewModel.draft(forItemID: prodItem.id)
        draft.environment = .preset(.local)
        viewModel.saveItem(draft)

        #expect(viewModel.selectedDestination == .workspace(fixture.workspaceID))
    }

    /// A declared environment is a statement about the project, so it stays put even when the
    /// last secret leaves it.
    @Test func aDeclaredEnvironmentSurvivesLosingItsLastItem() throws {
        let fixture = try makeFixture("DeclaredEmpty")
        let viewModel = fixture.viewModel
        viewModel.selectDestination(.workspaceEnvironment(fixture.workspaceID, "Prod"))

        let prodItem = try #require(viewModel.items.first(where: { $0.title == "Prod DB" }))
        var draft = viewModel.draft(forItemID: prodItem.id)
        draft.environment = .preset(.local)
        viewModel.saveItem(draft)

        #expect(viewModel.selectedDestination == .workspaceEnvironment(fixture.workspaceID, "Prod"))
        #expect(viewModel.filteredItems.isEmpty)
        #expect(viewModel.emptyDestinationHint.contains("Prod"))
    }

    @Test func deletingTheWorkspaceClearsAnEnvironmentDestination() throws {
        let fixture = try makeFixture("Delete")
        let viewModel = fixture.viewModel
        viewModel.selectDestination(.workspaceEnvironment(fixture.workspaceID, "Prod"))

        viewModel.requestWorkspaceDeletion(id: fixture.workspaceID)
        viewModel.confirmWorkspaceDeletion()

        #expect(viewModel.selectedDestination == .library(.allItems))
        // The secrets themselves are never deleted with the workspace.
        #expect(viewModel.items.count == 2)
    }

    @Test func theTypeFilterStillNarrowsInsideAnEnvironment() throws {
        let fixture = try makeFixture("TypeFilter")
        let viewModel = fixture.viewModel
        _ = try fixture.container.itemRepository.saveItem(SecretItemDraft(
            title: "Prod Env File",
            type: .envGroup,
            workspaceID: fixture.workspaceID,
            environment: .preset(.prod),
            notes: "",
            tags: [],
            isFavorite: false,
            fieldDrafts: [],
            templateID: nil
        ))
        viewModel.reload()

        viewModel.selectDestination(.workspaceEnvironment(fixture.workspaceID, "Prod"))
        #expect(viewModel.filteredItems.count == 2)

        viewModel.setSelectedType(.envGroup)
        #expect(viewModel.filteredItems.map(\.title) == ["Prod Env File"])
    }

    /// A row should not repeat the scope you are standing in: the workspace chip is noise on
    /// every row of that workspace, and so is the environment chip inside that environment.
    @Test func rowsNameOnlyWhatIsNotAlreadyImplied() throws {
        let fixture = try makeFixture("RowScope")
        let viewModel = fixture.viewModel

        viewModel.selectDestination(.library(.allItems))
        #expect(viewModel.itemRowScope == .workspace)

        viewModel.selectDestination(.tag("anything"))
        #expect(viewModel.itemRowScope == .workspace)

        viewModel.selectDestination(.workspace(fixture.workspaceID))
        #expect(viewModel.itemRowScope == .environment)

        viewModel.selectDestination(.workspaceEnvironment(fixture.workspaceID, "Prod"))
        #expect(viewModel.itemRowScope == .none)
    }

    /// Asking the sidebar about a workspace is a question about the workspace, so the detail pane
    /// stops describing whichever secret happened to be selected.
    @Test func enteringAProjectShowsTheProject() throws {
        let fixture = try makeFixture("ClearsSelection")
        let viewModel = fixture.viewModel

        viewModel.selectDestination(.library(.allItems))
        let item = try #require(viewModel.filteredItems.first)
        viewModel.select(item)
        #expect(viewModel.selectedItemID == item.id)

        viewModel.selectDestination(.workspace(fixture.workspaceID))
        #expect(viewModel.selectedItemID == nil)

        // Selecting a row still works normally from there, and switching environment lets go
        // again.
        let inWorkspace = try #require(viewModel.filteredItems.first)
        viewModel.select(inWorkspace)
        #expect(viewModel.selectedItemID == inWorkspace.id)
        viewModel.selectEnvironment(matchKey: "prod")
        #expect(viewModel.selectedItemID == nil)

        // Library destinations are unaffected: they have no scope to describe.
        viewModel.selectDestination(.library(.allItems))
        let again = try #require(viewModel.filteredItems.first)
        viewModel.select(again)
        viewModel.selectDestination(.library(.favorites))
        #expect(viewModel.selectedItemID == nil || viewModel.selectedItemID == again.id)
    }

    /// Reaching an item from the palette must still land on the item, even though the hop goes
    /// through its workspace.
    @Test func thePaletteStillLandsOnTheItemItWasAskedFor() throws {
        let fixture = try makeFixture("PaletteReveal")
        let viewModel = fixture.viewModel
        let item = try #require(viewModel.items.first(where: { $0.title == "Prod DB" }))

        viewModel.revealAndSelectItemFromPalette(item)

        #expect(viewModel.selectedItemID == item.id)
    }

    // MARK: - Overview

    /// The overview describes one project, so its figures must not count the whole vault.
    @Test func theOverviewCountsOnlyItsOwnWorkspace() throws {
        let fixture = try makeFixture("Overview")
        let other = try #require(fixture.viewModel.createWorkspace(
            WorkspaceDraft(name: "Other", icon: "shippingbox", colorHex: "#4A7AFF", notes: "")
        ))
        for (title, workspaceID) in [("Mine", fixture.workspaceID), ("Theirs", other.id)] {
            _ = try fixture.container.itemRepository.saveItem(SecretItemDraft(
                title: title,
                type: .envGroup,
                workspaceID: workspaceID,
                environment: .preset(.local),
                notes: "",
                tags: [],
                isFavorite: false,
                fieldDrafts: [],
                templateID: nil,
                linkedFile: LinkedFileReference(displayPath: "/tmp/\(title).env")
            ))
        }
        fixture.viewModel.reload()

        #expect(fixture.viewModel.linkedFileCount(inWorkspace: fixture.workspaceID) == 1)
        #expect(fixture.viewModel.linkedFileCount(inWorkspace: other.id) == 1)
        #expect(fixture.viewModel.itemCount(inWorkspace: other.id) == 1)
        #expect(fixture.viewModel.itemCount(inWorkspace: fixture.workspaceID) == 3)
    }

    @Test func theOverviewNamesTheEnvironmentsThatAreNotInTheProjectYet() throws {
        let fixture = try makeFixture(
            "Adoption",
            declaring: [WorkspaceEnvironment(name: "Local", kind: .local, sortOrder: 0)]
        )

        #expect(fixture.viewModel.undeclaredEnvironments(inWorkspace: fixture.workspaceID).map(\.title) == ["Prod"])

        fixture.viewModel.declareEnvironmentsInUse(inWorkspace: fixture.workspaceID)
        #expect(fixture.viewModel.undeclaredEnvironments(inWorkspace: fixture.workspaceID).isEmpty)
    }
}
