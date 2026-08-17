import Foundation
import Testing
@testable import PassStore

@MainActor
struct WorkspaceEnvironmentTests {
    private func makeContainer(_ label: String, store: EncryptedVaultStore? = nil) -> AppContainer {
        let container = AppContainer(
            inMemory: true,
            defaults: UserDefaults(suiteName: "WorkspaceEnvironments-\(label)-\(UUID().uuidString)")!,
            keyStore: InMemoryVaultKeyStore(isBiometricHardwareAvailable: false),
            encryptedVaultStore: store ?? InMemoryEncryptedVaultStore()
        )
        container.sessionManager.createVaultSynchronously(password: "test-password")
        return container
    }

    private func itemDraft(
        title: String,
        workspaceID: UUID?,
        environment: EnvironmentValue,
        id: UUID? = nil
    ) -> SecretItemDraft {
        SecretItemDraft(
            id: id,
            title: title,
            type: .generic,
            workspaceID: workspaceID,
            environment: environment,
            notes: "",
            tags: [],
            isFavorite: false,
            fieldDrafts: [
                FieldDraft(key: "token", label: "Token", value: "value-\(title)", kind: .secret, isSensitive: true, sortOrder: 0)
            ],
            templateID: nil
        )
    }

    // MARK: - Sanitizing

    @Test func presetDeclarationsKeepTheirCanonicalName() {
        var renamedPreset = WorkspaceEnvironment(name: "Production", kind: .prod)
        renamedPreset.name = "Production"
        let sanitized = WorkspaceEnvironment.sanitizedList([renamedPreset])

        // A preset that kept a name of its own would stop matching the items that carry the
        // kind's own title, which is what actually decides where a secret lives.
        #expect(sanitized.count == 1)
        #expect(sanitized[0].name == "Prod")
        #expect(sanitized[0].matchKey == "prod")
    }

    @Test func duplicateAndEmptyDeclarationsCollapse() {
        let sanitized = WorkspaceEnvironment.sanitizedList([
            WorkspaceEnvironment(name: "Prod", kind: .prod, sortOrder: 0),
            WorkspaceEnvironment(name: "prod", kind: .custom, sortOrder: 1),
            WorkspaceEnvironment(name: "   ", kind: .custom, sortOrder: 2),
            WorkspaceEnvironment(name: "QA", kind: .custom, sortOrder: 3)
        ])

        #expect(sanitized.map(\.title) == ["Prod", "QA"])
        #expect(sanitized.map(\.sortOrder) == [0, 1])
    }

    @Test func declarationListIsBounded() {
        let many = (0..<200).map {
            WorkspaceEnvironment(name: "Env \($0)", kind: .custom, sortOrder: $0)
        }
        #expect(WorkspaceEnvironment.sanitizedList(many).count == WorkspaceEnvironment.maximumPerWorkspace)
    }

    @Test func repeatedDeclarationIDsAreReissued() {
        let shared = UUID()
        let sanitized = WorkspaceEnvironment.sanitizedList([
            WorkspaceEnvironment(id: shared, name: "Local", kind: .local, sortOrder: 0),
            WorkspaceEnvironment(id: shared, name: "QA", kind: .custom, sortOrder: 1)
        ])

        // Two declarations sharing an id would make the editor's rename diff ambiguous.
        #expect(sanitized.count == 2)
        #expect(sanitized[0].id != sanitized[1].id)
    }

    /// The environment's file name is later matched against a folder the owner linked, so it has
    /// to be a bare file name and never a path.
    @Test func environmentFileNameCannotDescribeAPath() {
        #expect(WorkspaceEnvironment.sanitizedFileName("../../.ssh/id_rsa") == "id_rsa")
        #expect(WorkspaceEnvironment.sanitizedFileName("/etc/passwd") == "passwd")
        #expect(WorkspaceEnvironment.sanitizedFileName("..") == nil)
        #expect(WorkspaceEnvironment.sanitizedFileName("   ") == nil)
        #expect(WorkspaceEnvironment.sanitizedFileName(".env.production") == ".env.production")
    }

    /// Environments are told apart by glyph, not by colour: colour is what says which workspace a
    /// row belongs to, and one signal cannot mean two things.
    @Test func eachEnvironmentHasItsOwnGlyphAndNoColourOfItsOwn() {
        let kinds = EnvironmentKind.allCases
        let glyphs = kinds.map(\.systemImage)

        #expect(Set(glyphs).count == kinds.count)
        #expect(WorkspaceEnvironment(name: "Prod", kind: .prod).systemImage == EnvironmentKind.prod.systemImage)
        #expect(WorkspaceEnvironment(name: "QA", kind: .custom).systemImage == EnvironmentKind.custom.systemImage)
    }

    // MARK: - Resolution

    @Test func derivedEnvironmentsFollowLifecycleOrderNotTheAlphabet() {
        let derived = WorkspaceEnvironment.derived(fromPresentTitles: ["Prod", "Dev", "QA", "Local", "prod"])

        #expect(derived.map(\.title) == ["Local", "Dev", "Prod", "QA"])
    }

    @Test func resolvedListUnionsDeclarationsWithEnvironmentsInUse() {
        let resolved = WorkspaceEnvironment.resolvedList(
            declared: [
                WorkspaceEnvironment(name: "Prod", kind: .prod, sortOrder: 0),
                WorkspaceEnvironment(name: "Local", kind: .local, sortOrder: 1)
            ],
            presentTitles: ["Local", "Staging", "QA"]
        )

        // Declared order is explicit and comes first; whatever the items use but the project
        // never declared follows, in lifecycle order, marked as not declared.
        #expect(resolved.map(\.title) == ["Prod", "Local", "Staging", "QA"])
        #expect(resolved.map(\.isDeclared) == [true, true, false, false])
    }

    @Test func aTitleThatMatchesAPresetResolvesToThatPreset() {
        #expect(WorkspaceEnvironment.value(forTitle: "prod").kind == .prod)
        #expect(WorkspaceEnvironment.value(forTitle: "Client QA").kind == .custom)
        #expect(WorkspaceEnvironment.value(forTitle: "Client QA").customName == "Client QA")
    }

    // MARK: - Persistence

    /// The encoded form of a workspace that declares nothing has to stay byte-identical to 1.2:
    /// backup conflict identity is a digest of this JSON.
    @Test func workspaceWithoutDeclarationsEncodesWithoutTheNewKey() throws {
        let snapshot = WorkspaceSnapshot(
            id: UUID(),
            name: "Acme",
            icon: "shippingbox",
            colorHex: "#4A7AFF",
            notes: "",
            isArchived: false,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_100),
            sortOrder: 0
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let encoded = try #require(String(data: try encoder.encode(snapshot), encoding: .utf8))

        #expect(!encoded.contains("environments"))

        let decoded = try JSONDecoder().decode(WorkspaceSnapshot.self, from: Data(encoded.utf8))
        #expect(decoded.environments == nil)
    }

    @Test func declaredEnvironmentsSurviveALockAndRelaunch() throws {
        let store = InMemoryEncryptedVaultStore()
        let defaults = UserDefaults(suiteName: "WorkspaceEnvironments-Relaunch-\(UUID().uuidString)")!
        let container = AppContainer(
            inMemory: true,
            defaults: defaults,
            keyStore: InMemoryVaultKeyStore(isBiometricHardwareAvailable: false),
            encryptedVaultStore: store
        )
        container.sessionManager.createVaultSynchronously(password: "test-password")

        let workspace = try container.workspaceRepository.saveWorkspace(
            WorkspaceDraft(
                name: "Acme API",
                icon: "server.rack",
                colorHex: "#4A7AFF",
                notes: "",
                environments: [
                    WorkspaceEnvironment(name: "Local", kind: .local, sortOrder: 0),
                    WorkspaceEnvironment(name: "Prod", kind: .prod, isEnabled: false, sortOrder: 1, envFileName: ".env.production")
                ]
            )
        )
        container.sessionManager.lock()

        let relaunched = AppContainer(
            inMemory: true,
            defaults: defaults,
            keyStore: InMemoryVaultKeyStore(isBiometricHardwareAvailable: false),
            encryptedVaultStore: store
        )
        #expect(relaunched.sessionManager.unlockWithPasswordSynchronously("test-password"))

        let restored = try #require(
            try relaunched.workspaceRepository.fetchAll(includeArchived: true)
                .first(where: { $0.id == workspace.id })
        )
        #expect(restored.environments.map(\.title) == ["Local", "Prod"])
        #expect(restored.environments[1].isEnabled == false)
        #expect(restored.environments[1].envFileName == ".env.production")
    }

    /// A backup is attacker-controlled data even once its password has been accepted.
    @Test func environmentsFromAnImportedSnapshotAreClamped() throws {
        let container = makeContainer("UntrustedSnapshot")
        let hostile = (0..<80).map {
            WorkspaceEnvironment(
                // Distinct prefixes: names that only differ past the length cap are the same
                // name once clamped, and would collapse before the count limit was reached.
                name: "\($0)-" + String(repeating: "x", count: 500),
                kind: .custom,
                sortOrder: $0
            )
        } + [WorkspaceEnvironment(name: "Prod", kind: .custom, sortOrder: 999, envFileName: "../../../etc/passwd")]

        try container.memoryStore.replaceContents(with: VaultSnapshot(
            workspaces: [
                WorkspaceSnapshot(
                    id: UUID(),
                    name: "Imported",
                    icon: "shippingbox",
                    colorHex: "#4A7AFF",
                    notes: "",
                    isArchived: false,
                    createdAt: .now,
                    updatedAt: .now,
                    sortOrder: 0,
                    environments: hostile
                )
            ],
            items: [],
            customTemplates: []
        ))

        let loaded = try #require(try container.workspaceRepository.fetchAll().first)
        let longestName = loaded.environments.map(\.name.count).max() ?? 0
        let fileNamesWithSeparators = loaded.environments.compactMap(\.envFileName).filter { $0.contains("/") }

        #expect(loaded.environments.count == WorkspaceEnvironment.maximumPerWorkspace)
        #expect(longestName <= WorkspaceEnvironment.maximumNameLength)
        #expect(fileNamesWithSeparators.isEmpty)
    }

    // MARK: - View model behaviour

    @Test func renamingADeclaredEnvironmentTakesItsItemsWithIt() throws {
        let container = makeContainer("Rename")
        let viewModel = VaultViewModel(container: container)
        let staging = WorkspaceEnvironment(name: "Staging", kind: .staging, sortOrder: 0)
        let workspace = try #require(viewModel.createWorkspace(
            WorkspaceDraft(name: "Acme", icon: "shippingbox", colorHex: "#4A7AFF", notes: "", environments: [staging])
        ))
        _ = try container.itemRepository.saveItem(
            itemDraft(title: "Staging DB", workspaceID: workspace.id, environment: .preset(.staging))
        )
        _ = try container.itemRepository.saveItem(
            itemDraft(title: "Local DB", workspaceID: workspace.id, environment: .preset(.local))
        )
        viewModel.reload()

        var renamed = staging
        renamed.kind = .custom
        renamed.name = "Pre-production"
        viewModel.saveWorkspace(
            WorkspaceDraft(
                id: workspace.id,
                name: "Acme",
                icon: "shippingbox",
                colorHex: "#4A7AFF",
                notes: "",
                environments: [renamed]
            )
        )

        let moved = try #require(viewModel.items.first(where: { $0.title == "Staging DB" }))
        #expect(moved.environmentValue.title == "Pre-production")
        // Untouched environments stay untouched.
        let other = try #require(viewModel.items.first(where: { $0.title == "Local DB" }))
        #expect(other.environmentValue.title == "Local")
        // And the move is recorded like any other edit.
        let recordedEnvironmentChange = moved.changeHistory.map(\.kind).contains(.environmentChanged)
        #expect(recordedEnvironmentChange)
        #expect(viewModel.environments(inWorkspace: workspace.id).map(\.title) == ["Pre-production", "Local"])
    }

    @Test func switchingAnEnvironmentOffKeepsItReachableWhileItHoldsItems() throws {
        let container = makeContainer("Offered")
        let viewModel = VaultViewModel(container: container)
        let workspace = try #require(viewModel.createWorkspace(
            WorkspaceDraft(
                name: "Acme",
                icon: "shippingbox",
                colorHex: "#4A7AFF",
                notes: "",
                environments: [
                    WorkspaceEnvironment(name: "Local", kind: .local, sortOrder: 0),
                    WorkspaceEnvironment(name: "Prod", kind: .prod, sortOrder: 1)
                ]
            )
        ))
        _ = try container.itemRepository.saveItem(
            itemDraft(title: "Prod DB", workspaceID: workspace.id, environment: .preset(.prod))
        )
        viewModel.reload()

        viewModel.setEnvironmentEnabled(false, matchKey: "prod", inWorkspace: workspace.id)
        viewModel.setEnvironmentEnabled(false, matchKey: "local", inWorkspace: workspace.id)

        let offered = viewModel.offeredEnvironments(inWorkspace: workspace.id)
        // Prod still holds a secret, so switching it off must not put that secret out of reach.
        // Local is empty, so it goes away as asked.
        #expect(offered.map(\.title) == ["Prod"])
        #expect(offered[0].isEnabled == false)
        #expect(viewModel.itemCount(inWorkspace: workspace.id, environmentTitle: "Prod") == 1)
    }

    @Test func undeclaringAnEnvironmentLeavesTheItemsWhereTheyAre() throws {
        let container = makeContainer("Undeclare")
        let viewModel = VaultViewModel(container: container)
        let workspace = try #require(viewModel.createWorkspace(
            WorkspaceDraft(
                name: "Acme",
                icon: "shippingbox",
                colorHex: "#4A7AFF",
                notes: "",
                environments: [WorkspaceEnvironment(name: "Prod", kind: .prod, sortOrder: 0)]
            )
        ))
        _ = try container.itemRepository.saveItem(
            itemDraft(title: "Prod DB", workspaceID: workspace.id, environment: .preset(.prod))
        )
        viewModel.reload()

        viewModel.undeclareEnvironment(matchKey: "prod", inWorkspace: workspace.id)

        let resolved = viewModel.environments(inWorkspace: workspace.id)
        #expect(resolved.map(\.title) == ["Prod"])
        #expect(resolved[0].isDeclared == false)
        #expect(viewModel.items.first(where: { $0.title == "Prod DB" })?.environmentValue.title == "Prod")
    }

    @Test func aWorkspaceWithOneEnvironmentIsNotAProject() throws {
        let container = makeContainer("Structure")
        let viewModel = VaultViewModel(container: container)
        let workspace = try #require(viewModel.createWorkspace(
            WorkspaceDraft(name: "Client X", icon: "shippingbox", colorHex: "#4A7AFF", notes: "")
        ))
        _ = try container.itemRepository.saveItem(
            itemDraft(title: "One", workspaceID: workspace.id, environment: .preset(.dev))
        )
        viewModel.reload()

        // Everything in one environment: the row stays as flat as it was in 1.2.
        #expect(viewModel.hasEnvironmentStructure(inWorkspace: workspace.id) == false)

        _ = try container.itemRepository.saveItem(
            itemDraft(title: "Two", workspaceID: workspace.id, environment: .preset(.prod))
        )
        viewModel.reload()
        #expect(viewModel.hasEnvironmentStructure(inWorkspace: workspace.id))
    }

    @Test func adoptingEnvironmentsInUseDeclaresThemInLifecycleOrder() throws {
        let container = makeContainer("Adopt")
        let viewModel = VaultViewModel(container: container)
        let workspace = try #require(viewModel.createWorkspace(
            WorkspaceDraft(name: "Acme", icon: "shippingbox", colorHex: "#4A7AFF", notes: "")
        ))
        for (title, environment) in [("P", EnvironmentValue.preset(.prod)), ("L", .preset(.local)), ("Q", .custom("QA"))] {
            _ = try container.itemRepository.saveItem(
                itemDraft(title: title, workspaceID: workspace.id, environment: environment)
            )
        }
        viewModel.reload()

        viewModel.declareEnvironmentsInUse(inWorkspace: workspace.id)

        let resolved = viewModel.environments(inWorkspace: workspace.id)
        #expect(resolved.map(\.title) == ["Local", "Prod", "QA"])
        #expect(resolved.map(\.isDeclared) == [true, true, true])
    }

    /// A merge adds what the backup has and the vault does not, and overwrites nothing — so an
    /// incoming copy of a workspace must neither replace the declarations in use locally nor
    /// import a second copy of the workspace just because the two lists differ.
    @Test func mergingABackupDoesNotOverwriteLocalDeclarations() async throws {
        let workspaceID = UUID()
        let source = makeContainer("MergeSource")
        _ = try source.workspaceRepository.saveWorkspace(
            WorkspaceDraft(
                id: workspaceID,
                name: "Acme",
                icon: "shippingbox",
                colorHex: "#4A7AFF",
                notes: "",
                environments: [WorkspaceEnvironment(name: "Prod", kind: .prod, sortOrder: 0)]
            )
        )
        let backup = try source.exportService.exportFullBackupSynchronously(
            backup: ExportedBackupPayload(
                vault: source.memoryStore.makeSnapshot(),
                settings: source.settings.makeSettingsSnapshot()
            ),
            password: "backup-password"
        )

        let target = makeContainer("MergeTarget")
        let viewModel = VaultViewModel(container: target)
        _ = try target.workspaceRepository.saveWorkspace(
            WorkspaceDraft(
                id: workspaceID,
                name: "Acme",
                icon: "shippingbox",
                colorHex: "#4A7AFF",
                notes: "",
                environments: [WorkspaceEnvironment(name: "Local", kind: .local, sortOrder: 0)]
            )
        )
        viewModel.reload()

        viewModel.stageImport(data: backup, fileName: "backup.pstore")
        #expect(await viewModel.prepareImport(password: "backup-password"))
        let outcome = try #require(viewModel.applyStagedImport(mode: .merge))

        #expect(outcome.addedWorkspaces == 0)
        #expect(viewModel.workspaces.count == 1)
        let merged = try #require(viewModel.workspaces.first(where: { $0.id == workspaceID }))
        #expect(merged.environments.map(\.title) == ["Local"])
    }
}
