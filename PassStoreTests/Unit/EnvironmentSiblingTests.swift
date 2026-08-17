import Foundation
import Testing
@testable import PassStore

/// Secrets that answer to the same name inside one workspace are one secret in several
/// environments, and the regressions found while reviewing the environments work.
@MainActor
struct EnvironmentSiblingTests {
    private func makeContainer(_ label: String) -> AppContainer {
        let container = AppContainer(
            inMemory: true,
            defaults: UserDefaults(suiteName: "Siblings-\(label)-\(UUID().uuidString)")!,
            keyStore: InMemoryVaultKeyStore(isBiometricHardwareAvailable: false),
            encryptedVaultStore: InMemoryEncryptedVaultStore()
        )
        container.sessionManager.createVaultSynchronously(password: "test-password")
        return container
    }

    private func itemDraft(
        title: String,
        workspaceID: UUID?,
        environment: EnvironmentValue,
        value: String = "secret"
    ) -> SecretItemDraft {
        SecretItemDraft(
            id: nil,
            title: title,
            type: .generic,
            workspaceID: workspaceID,
            environment: environment,
            notes: "",
            tags: [],
            isFavorite: false,
            fieldDrafts: [
                FieldDraft(
                    key: "DATABASE_URL",
                    label: "Database URL",
                    value: value,
                    kind: .secret,
                    isSensitive: true,
                    sortOrder: 0
                )
            ],
            templateID: nil
        )
    }

    private func workspaceDraft(
        id: UUID? = nil,
        name: String = "Acme",
        environments: [WorkspaceEnvironment] = []
    ) -> WorkspaceDraft {
        WorkspaceDraft(
            id: id,
            name: name,
            icon: "shippingbox",
            colorHex: "#4A7AFF",
            notes: "",
            environments: environments
        )
    }

    // MARK: - Renaming declarations

    /// Renames used to be applied one after another against the live vault, so the second one
    /// picked up the items the first had just moved: swapping two names emptied one environment
    /// into the other instead of exchanging them.
    @Test func swappingTwoEnvironmentNamesExchangesTheirItems() throws {
        let container = makeContainer("Swap")
        let viewModel = VaultViewModel(container: container)
        var alpha = WorkspaceEnvironment(name: "Alpha", kind: .custom, sortOrder: 0)
        var beta = WorkspaceEnvironment(name: "Beta", kind: .custom, sortOrder: 1)
        let workspace = try #require(
            viewModel.createWorkspace(workspaceDraft(environments: [alpha, beta]))
        )
        _ = try container.itemRepository.saveItem(
            itemDraft(title: "A-secret", workspaceID: workspace.id, environment: .custom("Alpha"))
        )
        _ = try container.itemRepository.saveItem(
            itemDraft(title: "B-secret", workspaceID: workspace.id, environment: .custom("Beta"))
        )
        viewModel.reload()

        // Both declarations keep their id and trade names, which is exactly what the editor emits.
        alpha.name = "Beta"
        beta.name = "Alpha"
        viewModel.saveWorkspace(workspaceDraft(id: workspace.id, environments: [alpha, beta]))

        #expect(viewModel.items.first { $0.title == "A-secret" }?.environmentValue.title == "Beta")
        #expect(viewModel.items.first { $0.title == "B-secret" }?.environmentValue.title == "Alpha")
        #expect(viewModel.itemCount(inWorkspace: workspace.id, environmentTitle: "Alpha") == 1)
        #expect(viewModel.itemCount(inWorkspace: workspace.id, environmentTitle: "Beta") == 1)
    }

    /// A chain has the same shape as a swap: Alpha becomes Beta while Beta becomes Gamma, and
    /// nothing may cascade from the first move into the second.
    @Test func chainedRenamesDoNotCascade() throws {
        let container = makeContainer("Chain")
        let viewModel = VaultViewModel(container: container)
        var alpha = WorkspaceEnvironment(name: "Alpha", kind: .custom, sortOrder: 0)
        var beta = WorkspaceEnvironment(name: "Beta", kind: .custom, sortOrder: 1)
        let workspace = try #require(
            viewModel.createWorkspace(workspaceDraft(environments: [alpha, beta]))
        )
        _ = try container.itemRepository.saveItem(
            itemDraft(title: "A-secret", workspaceID: workspace.id, environment: .custom("Alpha"))
        )
        _ = try container.itemRepository.saveItem(
            itemDraft(title: "B-secret", workspaceID: workspace.id, environment: .custom("Beta"))
        )
        viewModel.reload()

        alpha.name = "Beta"
        beta.name = "Gamma"
        viewModel.saveWorkspace(workspaceDraft(id: workspace.id, environments: [alpha, beta]))

        #expect(viewModel.items.first { $0.title == "A-secret" }?.environmentValue.title == "Beta")
        #expect(viewModel.items.first { $0.title == "B-secret" }?.environmentValue.title == "Gamma")
    }

    // MARK: - Selection

    /// The breadcrumb links live inside a secret's own detail pane, so following one has to keep
    /// that secret open — clearing the selection closed the pane the click was made in.
    @Test func followingTheBreadcrumbKeepsTheSecretOpen() throws {
        let container = makeContainer("Breadcrumb")
        let viewModel = VaultViewModel(container: container)
        let workspace = try #require(viewModel.createWorkspace(
            workspaceDraft(environments: [WorkspaceEnvironment(name: "Prod", kind: .prod, sortOrder: 0)])
        ))
        let saved = try container.itemRepository.saveItem(
            itemDraft(title: "Prod DB", workspaceID: workspace.id, environment: .preset(.prod))
        )
        viewModel.reload()
        viewModel.select(viewModel.items.first { $0.id == saved.id })

        viewModel.revealDestinationKeepingSelection(.workspaceEnvironment(workspace.id, "Prod"))
        #expect(viewModel.selectedItem?.id == saved.id)

        viewModel.revealDestinationKeepingSelection(.workspace(workspace.id))
        #expect(viewModel.selectedItem?.id == saved.id)
    }

    /// Choosing a scope from the sidebar still shows the scope rather than whatever secret
    /// happened to be selected.
    @Test func choosingAWorkspaceFromTheSidebarStillClearsTheSelection() throws {
        let container = makeContainer("SidebarPick")
        let viewModel = VaultViewModel(container: container)
        let workspace = try #require(viewModel.createWorkspace(workspaceDraft()))
        let saved = try container.itemRepository.saveItem(
            itemDraft(title: "Prod DB", workspaceID: workspace.id, environment: .preset(.prod))
        )
        viewModel.reload()
        viewModel.select(viewModel.items.first { $0.id == saved.id })

        viewModel.selectDestination(.workspace(workspace.id))
        #expect(viewModel.selectedItem == nil)
    }

    /// Switching off an empty environment while standing in it left the header naming a scope
    /// that neither the sidebar nor the chip bar drew, with no row to go back to.
    @Test func switchingOffTheEnvironmentYouAreInFallsBackToTheWorkspace() throws {
        let container = makeContainer("Stranded")
        let viewModel = VaultViewModel(container: container)
        let workspace = try #require(viewModel.createWorkspace(workspaceDraft(environments: [
            WorkspaceEnvironment(name: "Local", kind: .local, sortOrder: 0),
            WorkspaceEnvironment(name: "Staging", kind: .staging, sortOrder: 1)
        ])))
        _ = try container.itemRepository.saveItem(
            itemDraft(title: "Local DB", workspaceID: workspace.id, environment: .preset(.local))
        )
        viewModel.reload()

        viewModel.selectDestination(.workspaceEnvironment(workspace.id, "Staging"))
        viewModel.setEnvironmentVisible(false, matchKey: "staging", inWorkspace: workspace.id)

        #expect(viewModel.selectedDestination == .workspace(workspace.id))
        #expect(viewModel.selectedEnvironmentMatchKey == nil)
    }

    /// Switching one off while it still holds secrets must not move you: the environment stays
    /// reachable precisely so those secrets do not disappear behind a layout preference.
    @Test func switchingOffAnEnvironmentThatHoldsItemsKeepsYouInIt() throws {
        let container = makeContainer("StillHeld")
        let viewModel = VaultViewModel(container: container)
        let workspace = try #require(viewModel.createWorkspace(workspaceDraft(environments: [
            WorkspaceEnvironment(name: "Prod", kind: .prod, sortOrder: 0),
            WorkspaceEnvironment(name: "Local", kind: .local, sortOrder: 1)
        ])))
        _ = try container.itemRepository.saveItem(
            itemDraft(title: "Prod DB", workspaceID: workspace.id, environment: .preset(.prod))
        )
        viewModel.reload()

        viewModel.selectDestination(.workspaceEnvironment(workspace.id, "Prod"))
        viewModel.setEnvironmentVisible(false, matchKey: "prod", inWorkspace: workspace.id)

        #expect(viewModel.selectedEnvironmentMatchKey == "prod")
    }

    /// The environment caches are derived from an unlocked vault and hold environment names and
    /// value digests, so locking has to drop them rather than merely stop reading them.
    @Test func lockingLeavesNoDerivedEnvironmentStateBehind() throws {
        let container = makeContainer("Lock")
        let viewModel = VaultViewModel(container: container)
        let workspace = try #require(viewModel.createWorkspace(workspaceDraft(environments: [
            WorkspaceEnvironment(name: "Local", kind: .local, sortOrder: 0),
            WorkspaceEnvironment(name: "Prod", kind: .prod, sortOrder: 1)
        ])))
        _ = try container.itemRepository.saveItem(
            itemDraft(title: "Database", workspaceID: workspace.id, environment: .preset(.prod))
        )
        viewModel.reload()

        // Warm every cache.
        #expect(viewModel.presentEnvironmentTitles(inWorkspace: workspace.id) == ["Prod"])
        #expect(viewModel.environments(inWorkspace: workspace.id).count == 2)
        _ = viewModel.environmentMatrix(inWorkspace: workspace.id)

        viewModel.clearUnlockedState()

        #expect(viewModel.presentEnvironmentTitles(inWorkspace: workspace.id).isEmpty)
        #expect(viewModel.environments(inWorkspace: workspace.id).isEmpty)
        #expect(viewModel.environmentMatrix(inWorkspace: workspace.id).rows.isEmpty)
        #expect(viewModel.environmentUsage(inWorkspace: workspace.id).counts.isEmpty)
    }

    // MARK: - Siblings

    @Test func theSameNameInSeveralEnvironmentsIsOneSecret() throws {
        let container = makeContainer("Family")
        let viewModel = VaultViewModel(container: container)
        let workspace = try #require(viewModel.createWorkspace(workspaceDraft(environments: [
            WorkspaceEnvironment(name: "Local", kind: .local, sortOrder: 0),
            WorkspaceEnvironment(name: "Staging", kind: .staging, sortOrder: 1),
            WorkspaceEnvironment(name: "Prod", kind: .prod, sortOrder: 2)
        ])))
        let local = try container.itemRepository.saveItem(
            itemDraft(title: "Database", workspaceID: workspace.id, environment: .preset(.local))
        )
        let prod = try container.itemRepository.saveItem(
            itemDraft(title: "Database", workspaceID: workspace.id, environment: .preset(.prod))
        )
        // Same environment, different name: not part of this family.
        _ = try container.itemRepository.saveItem(
            itemDraft(title: "Stripe", workspaceID: workspace.id, environment: .preset(.prod))
        )
        viewModel.reload()

        let item = try #require(viewModel.items.first { $0.id == local.id })
        let siblings = viewModel.environmentSiblings(of: item)

        #expect(siblings.map(\.environment.title) == ["Local", "Staging", "Prod"])
        #expect(siblings.map(\.exists) == [true, false, true])
        #expect(siblings.first { $0.isCurrent }?.environment.title == "Local")
        #expect(siblings.first { $0.environment.title == "Prod" }?.item?.id == prod.id)
    }

    /// The link is the name, and names are matched the way environment titles are — a stray
    /// capital or a trailing space does not split a family in two.
    @Test func theNameIsMatchedLooselyEnoughToSurviveTyping() throws {
        let container = makeContainer("Loose")
        let viewModel = VaultViewModel(container: container)
        let workspace = try #require(viewModel.createWorkspace(workspaceDraft(environments: [
            WorkspaceEnvironment(name: "Local", kind: .local, sortOrder: 0),
            WorkspaceEnvironment(name: "Prod", kind: .prod, sortOrder: 1)
        ])))
        let local = try container.itemRepository.saveItem(
            itemDraft(title: "database url", workspaceID: workspace.id, environment: .preset(.local))
        )
        _ = try container.itemRepository.saveItem(
            itemDraft(title: "  Database URL  ", workspaceID: workspace.id, environment: .preset(.prod))
        )
        viewModel.reload()

        let item = try #require(viewModel.items.first { $0.id == local.id })
        #expect(viewModel.environmentSiblings(of: item).allSatisfy { $0.exists })
    }

    /// A secret of the same name in a *different* workspace is a different secret.
    @Test func theFamilyStopsAtTheWorkspaceBoundary() throws {
        let container = makeContainer("Boundary")
        let viewModel = VaultViewModel(container: container)
        let acme = try #require(viewModel.createWorkspace(workspaceDraft(name: "Acme", environments: [
            WorkspaceEnvironment(name: "Local", kind: .local, sortOrder: 0),
            WorkspaceEnvironment(name: "Prod", kind: .prod, sortOrder: 1)
        ])))
        let other = try #require(viewModel.createWorkspace(workspaceDraft(name: "Other")))
        let mine = try container.itemRepository.saveItem(
            itemDraft(title: "Database", workspaceID: acme.id, environment: .preset(.local))
        )
        _ = try container.itemRepository.saveItem(
            itemDraft(title: "Database", workspaceID: other.id, environment: .preset(.prod))
        )
        viewModel.reload()

        let item = try #require(viewModel.items.first { $0.id == mine.id })
        let siblings = viewModel.environmentSiblings(of: item)
        #expect(siblings.first { $0.environment.title == "Prod" }?.exists == false)
    }

    @Test func switchingToASiblingOpensItAndFollowsTheListIntoItsEnvironment() throws {
        let container = makeContainer("Switch")
        let viewModel = VaultViewModel(container: container)
        let workspace = try #require(viewModel.createWorkspace(workspaceDraft(environments: [
            WorkspaceEnvironment(name: "Local", kind: .local, sortOrder: 0),
            WorkspaceEnvironment(name: "Prod", kind: .prod, sortOrder: 1)
        ])))
        let local = try container.itemRepository.saveItem(
            itemDraft(title: "Database", workspaceID: workspace.id, environment: .preset(.local))
        )
        let prod = try container.itemRepository.saveItem(
            itemDraft(title: "Database", workspaceID: workspace.id, environment: .preset(.prod))
        )
        viewModel.reload()

        viewModel.selectDestination(.workspaceEnvironment(workspace.id, "Local"))
        viewModel.select(viewModel.items.first { $0.id == local.id })

        let item = try #require(viewModel.selectedItem)
        let target = try #require(
            viewModel.environmentSiblings(of: item).first { $0.environment.title == "Prod" }
        )
        viewModel.selectEnvironmentSibling(target)

        #expect(viewModel.selectedItem?.id == prod.id)
        // The list behind the pane has to hold the row that is now selected.
        #expect(viewModel.selectedDestination == .workspaceEnvironment(workspace.id, "Prod"))
        #expect(viewModel.filteredItems.contains { $0.id == prod.id })
    }

    private func twoEnvironmentWorkspace(
        _ label: String
    ) throws -> (VaultViewModel, AppContainer, WorkspaceEntity) {
        let container = makeContainer(label)
        let viewModel = VaultViewModel(container: container)
        let workspace = try #require(viewModel.createWorkspace(workspaceDraft(environments: [
            WorkspaceEnvironment(name: "Local", kind: .local, sortOrder: 0),
            WorkspaceEnvironment(name: "Prod", kind: .prod, sortOrder: 1)
        ])))
        return (viewModel, container, workspace)
    }

    private func mixedDraft(title: String, workspaceID: UUID, environment: EnvironmentValue) -> SecretItemDraft {
        SecretItemDraft(
            id: nil,
            title: title,
            type: .generic,
            workspaceID: workspaceID,
            environment: environment,
            notes: "",
            tags: [],
            isFavorite: false,
            fieldDrafts: [
                FieldDraft(key: "DB_HOST", label: "Host", value: "localhost",
                           kind: .text, isSensitive: false, sortOrder: 0),
                FieldDraft(key: "DB_PASSWORD", label: "Password", value: "hunter2",
                           kind: .secret, isSensitive: true, sortOrder: 1)
            ],
            templateID: nil
        )
    }

    // MARK: - Copying into another environment

    /// The default answer: settings come across, secrets do not. It is the same rule the key
    /// check uses when it reports a shared secret, so the two cannot contradict each other.
    @Test func copyingCarriesSettingsAndLeavesSecretsEmptyByDefault() throws {
        let (viewModel, container, workspace) = try twoEnvironmentWorkspace("CopyDefault")
        let local = try container.itemRepository.saveItem(
            mixedDraft(title: "Database", workspaceID: workspace.id, environment: .preset(.local))
        )
        viewModel.reload()

        viewModel.beginEnvironmentCopy(itemIDs: [local.id], to: .preset(.prod))
        let plan = try #require(viewModel.environmentCopy)
        #expect(plan.mode == .settingsOnly)
        #expect(plan.fields.map(\.key) == ["DB_HOST", "DB_PASSWORD"])
        #expect(plan.fields.map(\.copiesValue) == [true, false])

        viewModel.performEnvironmentCopy()

        let copy = try #require(viewModel.items.first {
            $0.title == "Database" && $0.environmentValue.title == "Prod"
        })
        let fields = viewModel.resolvedFields(for: copy)
        #expect(fields.first { $0.key == "DB_HOST" }?.value == "localhost")
        #expect(fields.first { $0.key == "DB_PASSWORD" }?.value == "")

        // The original is untouched, and the sheet is put away.
        let original = try #require(viewModel.items.first { $0.id == local.id })
        #expect(viewModel.resolvedFields(for: original).first { $0.key == "DB_PASSWORD" }?.value == "hunter2")
        #expect(viewModel.environmentCopy == nil)
    }

    /// Asking for a straight duplicate gets one.
    @Test func copyingEveryValueMakesADuplicate() throws {
        let (viewModel, container, workspace) = try twoEnvironmentWorkspace("CopyAll")
        let local = try container.itemRepository.saveItem(
            mixedDraft(title: "Database", workspaceID: workspace.id, environment: .preset(.local))
        )
        viewModel.reload()

        viewModel.beginEnvironmentCopy(itemIDs: [local.id], to: .preset(.prod))
        viewModel.setEnvironmentCopyMode(.all)
        viewModel.performEnvironmentCopy()

        let copy = try #require(viewModel.items.first {
            $0.title == "Database" && $0.environmentValue.title == "Prod"
        })
        let fields = viewModel.resolvedFields(for: copy)
        #expect(fields.first { $0.key == "DB_PASSWORD" }?.value == "hunter2")
    }

    /// A field ticked off is not created at all, and a per-field answer survives being set after
    /// the overall one.
    @Test func perFieldChoicesOverrideThePreset() throws {
        let (viewModel, container, workspace) = try twoEnvironmentWorkspace("CopyFields")
        let local = try container.itemRepository.saveItem(
            mixedDraft(title: "Database", workspaceID: workspace.id, environment: .preset(.local))
        )
        viewModel.reload()

        viewModel.beginEnvironmentCopy(itemIDs: [local.id], to: .preset(.prod))
        let plan = try #require(viewModel.environmentCopy)
        let host = try #require(plan.fields.first { $0.key == "DB_HOST" })
        let password = try #require(plan.fields.first { $0.key == "DB_PASSWORD" })

        viewModel.setEnvironmentCopyField(included: false, fieldID: host.id)
        viewModel.setEnvironmentCopyField(copiesValue: true, fieldID: password.id)
        viewModel.performEnvironmentCopy()

        let copy = try #require(viewModel.items.first {
            $0.title == "Database" && $0.environmentValue.title == "Prod"
        })
        let fields = viewModel.resolvedFields(for: copy)
        #expect(fields.map(\.key) == ["DB_PASSWORD"])
        #expect(fields.first?.value == "hunter2")
    }

    /// Choosing an overall answer resets the per-field ones — the presets are how you get most of
    /// the way there.
    @Test func changingThePresetResetsTheFieldChoices() throws {
        let (viewModel, container, workspace) = try twoEnvironmentWorkspace("CopyReset")
        let local = try container.itemRepository.saveItem(
            mixedDraft(title: "Database", workspaceID: workspace.id, environment: .preset(.local))
        )
        viewModel.reload()

        viewModel.beginEnvironmentCopy(itemIDs: [local.id], to: .preset(.prod))
        let password = try #require(viewModel.environmentCopy?.fields.first { $0.key == "DB_PASSWORD" })
        viewModel.setEnvironmentCopyField(copiesValue: true, fieldID: password.id)

        viewModel.setEnvironmentCopyMode(.none)
        #expect(viewModel.environmentCopy?.fields.allSatisfy { !$0.copiesValue } == true)
    }

    /// Copying into an environment that already has a secret of this name is allowed, but said
    /// out loud first.
    @Test func aNameAlreadyInTheDestinationIsReported() throws {
        let (viewModel, container, workspace) = try twoEnvironmentWorkspace("CopyClash")
        let local = try container.itemRepository.saveItem(
            mixedDraft(title: "Database", workspaceID: workspace.id, environment: .preset(.local))
        )
        _ = try container.itemRepository.saveItem(
            mixedDraft(title: "Database", workspaceID: workspace.id, environment: .preset(.prod))
        )
        viewModel.reload()

        viewModel.beginEnvironmentCopy(itemIDs: [local.id], to: .preset(.prod))
        #expect(viewModel.environmentCopyConflict() == "Database")
    }

    /// The environment it is already in is not offered as somewhere to copy it to.
    @Test func theCurrentEnvironmentIsNotADestination() throws {
        let (viewModel, container, workspace) = try twoEnvironmentWorkspace("CopyDest")
        let local = try container.itemRepository.saveItem(
            mixedDraft(title: "Database", workspaceID: workspace.id, environment: .preset(.local))
        )
        viewModel.reload()

        #expect(viewModel.environmentDestinations(forItemIDs: [local.id]).map(\.title) == ["Prod"])
    }

    // MARK: - Moving between environments

    @Test func movingKeepsTheSameSecretAndTakesItsHistoryAlong() throws {
        let (viewModel, container, workspace) = try twoEnvironmentWorkspace("Move")
        let local = try container.itemRepository.saveItem(
            mixedDraft(title: "Database", workspaceID: workspace.id, environment: .preset(.local))
        )
        viewModel.reload()

        viewModel.moveItems([local.id], toEnvironment: .preset(.prod))

        // Same record, not a second one.
        #expect(viewModel.items.count { $0.title == "Database" } == 1)
        let moved = try #require(viewModel.items.first { $0.id == local.id })
        #expect(moved.environmentValue.title == "Prod")
        #expect(viewModel.resolvedFields(for: moved).first { $0.key == "DB_PASSWORD" }?.value == "hunter2")
        #expect(moved.changeHistory.map(\.kind).contains(.environmentChanged))
        #expect(viewModel.itemCount(inWorkspace: workspace.id, environmentTitle: "Local") == 0)
    }

    /// Moving into an environment the workspace does not have yet adds it, the same way saving a
    /// secret there would.
    @Test func movingIntoANewEnvironmentAddsItToTheWorkspace() throws {
        let (viewModel, container, workspace) = try twoEnvironmentWorkspace("MoveNew")
        let local = try container.itemRepository.saveItem(
            mixedDraft(title: "Database", workspaceID: workspace.id, environment: .preset(.local))
        )
        viewModel.reload()

        viewModel.moveItems([local.id], toEnvironment: .custom("QA"))

        #expect(viewModel.workspace(for: workspace.id)?.environments.map(\.title) == ["Local", "Prod", "QA"])
    }

    /// Moving several at once, and a secret already in the destination is left alone.
    @Test func movingASelectionSkipsWhatIsAlreadyThere() throws {
        let (viewModel, container, workspace) = try twoEnvironmentWorkspace("MoveMany")
        let a = try container.itemRepository.saveItem(
            mixedDraft(title: "A", workspaceID: workspace.id, environment: .preset(.local))
        )
        let b = try container.itemRepository.saveItem(
            mixedDraft(title: "B", workspaceID: workspace.id, environment: .preset(.prod))
        )
        viewModel.reload()

        viewModel.moveItems([a.id, b.id], toEnvironment: .preset(.prod))

        #expect(viewModel.itemCount(inWorkspace: workspace.id, environmentTitle: "Prod") == 2)
        #expect(viewModel.itemCount(inWorkspace: workspace.id, environmentTitle: "Local") == 0)
    }

    /// A workspace with one environment has nothing to read across, so the band stays away.
    @Test func aSecretWithNowhereElseToBeHasNoSwitcher() throws {
        let container = makeContainer("Alone")
        let viewModel = VaultViewModel(container: container)
        let workspace = try #require(viewModel.createWorkspace(workspaceDraft()))
        let saved = try container.itemRepository.saveItem(
            itemDraft(title: "Database", workspaceID: workspace.id, environment: .preset(.prod))
        )
        viewModel.reload()

        let item = try #require(viewModel.items.first { $0.id == saved.id })
        #expect(viewModel.hasEnvironmentSiblings(of: item) == false)
    }

    // MARK: - Discovery mapping

    private func discovered(_ fileName: String) -> DiscoveredEnvFile {
        DiscoveredEnvFile(
            fileName: fileName,
            relativePath: fileName,
            byteCount: 12,
            suggestedEnvironment: EnvFileClassifier.environment(forFileName: fileName),
            isTemplate: EnvFileClassifier.isTemplate(fileName),
            isAlreadyLinked: false
        )
    }

    private func resolved(_ environments: [WorkspaceEnvironment]) -> [ResolvedWorkspaceEnvironment] {
        WorkspaceEnvironment.resolvedList(declared: environments, presentTitles: [])
    }

    /// A declaration that names a file is the project's own convention, so it beats guessing the
    /// environment from the file's name — which is the only thing `envFileName` is for.
    @Test func aDeclaredFileMappingDecidesWhereADiscoveredFileLands() {
        // The file name says "production"; this project says that file is its QA environment.
        let environments = resolved([
            WorkspaceEnvironment(name: "QA", kind: .custom, sortOrder: 0, envFileName: ".env.production"),
            WorkspaceEnvironment(name: "Prod", kind: .prod, sortOrder: 1)
        ])

        let landed = VaultViewModel.environment(
            for: discovered(".env.production"),
            declaredIn: environments
        )
        #expect(landed.title == "QA")
    }

    @Test func fileMappingsAreMatchedWithoutRegardToCase() {
        let environments = resolved([
            WorkspaceEnvironment(name: "QA", kind: .custom, sortOrder: 0, envFileName: ".ENV.Production")
        ])
        #expect(
            VaultViewModel.environment(for: discovered(".env.production"), declaredIn: environments).title == "QA"
        )
    }

    /// Without a mapping the file name decides, and an environment the project already has beats
    /// inventing a second one that merely reads the same.
    @Test func anUnmappedFileFallsBackToTheNameAndPrefersWhatTheProjectHas() {
        let declaredProd = resolved([WorkspaceEnvironment(name: "Prod", kind: .prod, sortOrder: 0)])
        #expect(
            VaultViewModel.environment(for: discovered(".env.production"), declaredIn: declaredProd).title
                == "Prod"
        )

        // "QA" is spelled by the project; the file says "qa". They are the same environment, so
        // the import must not create a second one called "Qa".
        let declaredQA = resolved([WorkspaceEnvironment(name: "QA", kind: .custom, sortOrder: 0)])
        #expect(
            VaultViewModel.environment(for: discovered(".env.qa"), declaredIn: declaredQA).title == "QA"
        )
        #expect(
            VaultViewModel.environment(for: discovered(".env.production"), declaredIn: declaredQA).title
                == "Prod"
        )
    }
}
