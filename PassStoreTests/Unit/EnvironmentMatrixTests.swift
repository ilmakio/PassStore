import Foundation
import Testing
@testable import PassStore

@MainActor
struct EnvironmentMatrixTests {
    // MARK: - The comparison itself

    private func entry(
        _ key: String,
        _ digest: String,
        isBlank: Bool = false,
        isSensitive: Bool = false,
        itemID: UUID = UUID()
    ) -> EnvironmentMatrixInput.Entry {
        EnvironmentMatrixInput.Entry(
            key: key,
            valueDigest: digest,
            isBlank: isBlank,
            isSensitive: isSensitive,
            itemID: itemID
        )
    }

    private func column(
        _ title: String,
        _ entries: [EnvironmentMatrixInput.Entry],
        itemCount: Int = 1
    ) -> EnvironmentMatrixInput.Column {
        EnvironmentMatrixInput.Column(
            matchKey: title.lowercased(),
            title: title,
            systemImage: WorkspaceEnvironment.value(forTitle: title).kind.systemImage,
            itemCount: itemCount,
            entries: entries
        )
    }

    @Test func missingKeysAreCountedPerRow() {
        let matrix = EnvironmentMatrix(EnvironmentMatrixInput(columns: [
            column("Local", [entry("DATABASE_URL", "a"), entry("DEBUG", "b")]),
            column("Prod", [entry("DATABASE_URL", "c")])
        ]))

        #expect(matrix.rows.map(\.key) == ["DATABASE_URL", "DEBUG"])
        #expect(matrix.rows[0].missingCount == 0)
        #expect(matrix.rows[1].missingCount == 1)
        #expect(matrix.missingCount == 1)
        #expect(matrix.rows[1].cells[1].presence == .missing)
    }

    /// An empty value in a `.env` is a decision; an absent line is an omission. They are not the
    /// same thing and the grid does not draw them the same way.
    @Test func aBlankValueIsNotTheSameAsAMissingOne() {
        let matrix = EnvironmentMatrix(EnvironmentMatrixInput(columns: [
            column("Local", [entry("SENTRY_DSN", "", isBlank: true)]),
            column("Prod", [entry("OTHER", "x")])
        ]))

        #expect(matrix.rows[0].cells[0].presence == .blank)
        #expect(matrix.rows[0].cells[1].presence == .missing)
        #expect(matrix.rows[0].cells[0].valueDigest == nil)
    }

    /// The finding that makes the whole screen worth having.
    @Test func theSameSecretInTwoEnvironmentsIsReported() {
        let matrix = EnvironmentMatrix(EnvironmentMatrixInput(columns: [
            column("Local", [entry("STRIPE_KEY", "same", isSensitive: true)]),
            column("Staging", [entry("STRIPE_KEY", "different", isSensitive: true)]),
            column("Prod", [entry("STRIPE_KEY", "same", isSensitive: true)])
        ]))

        let row = matrix.rows[0]
        #expect(row.hasSharedSecret)
        #expect(row.sharedSecretColumnKeys == ["local", "prod"])
        #expect(matrix.sharedSecretCount == 1)
    }

    /// `PORT=3000` being identical everywhere is how ports work. Only secrets are flagged.
    @Test func identicalNonSensitiveValuesAreNotAFinding() {
        let matrix = EnvironmentMatrix(EnvironmentMatrixInput(columns: [
            column("Local", [entry("PORT", "3000")]),
            column("Prod", [entry("PORT", "3000")])
        ]))

        #expect(matrix.rows[0].hasSharedSecret == false)
        #expect(matrix.sharedSecretCount == 0)
    }

    @Test func blankValuesDoNotCountAsSharedSecrets() {
        let matrix = EnvironmentMatrix(EnvironmentMatrixInput(columns: [
            column("Local", [entry("TOKEN", "", isBlank: true, isSensitive: true)]),
            column("Prod", [entry("TOKEN", "", isBlank: true, isSensitive: true)])
        ]))

        #expect(matrix.rows[0].hasSharedSecret == false)
    }

    @Test func twoSecretsDefiningTheSameKeyInOneEnvironmentAreFlagged() {
        let matrix = EnvironmentMatrix(EnvironmentMatrixInput(columns: [
            column("Prod", [entry("DATABASE_URL", "a"), entry("DATABASE_URL", "b")], itemCount: 2)
        ]))

        #expect(matrix.rows[0].cells[0].sourceCount == 2)
        #expect(matrix.rows[0].isDefinedTwiceSomewhere)
    }

    /// An environment nobody has filled in yet is not "missing" every key in the project.
    @Test func anEmptyEnvironmentIsNotMissingEverything() {
        let matrix = EnvironmentMatrix(EnvironmentMatrixInput(columns: [
            column("Local", [entry("A", "1"), entry("B", "2")]),
            column("Staging", [], itemCount: 0)
        ]))

        #expect(matrix.missingCount == 0)
        #expect(matrix.rowsNeedingAttention.isEmpty)
    }

    @Test func keysAreComparedIgnoringCaseAndKeepTheirFirstSpelling() {
        let matrix = EnvironmentMatrix(EnvironmentMatrixInput(columns: [
            column("Local", [entry("API_KEY", "a")]),
            column("Prod", [entry("api_key", "b")])
        ]))

        #expect(matrix.rows.count == 1)
        #expect(matrix.rows[0].key == "API_KEY")
        #expect(matrix.rows[0].missingCount == 0)
    }

    @Test func onlyTroubleRowsSurviveTheFilter() {
        let matrix = EnvironmentMatrix(EnvironmentMatrixInput(columns: [
            column("Local", [entry("FINE", "a"), entry("MISSING_IN_PROD", "b")]),
            column("Prod", [entry("FINE", "c")])
        ]))

        #expect(matrix.rowsNeedingAttention.map(\.key) == ["MISSING_IN_PROD"])
    }

    // MARK: - Built from a real vault

    @Test func theMatrixIsBuiltFromTheWorkspacesOwnSecretsAndCarriesNoValues() throws {
        let container = AppContainer(
            inMemory: true,
            defaults: UserDefaults(suiteName: "EnvironmentMatrix-\(UUID().uuidString)")!,
            keyStore: InMemoryVaultKeyStore(isBiometricHardwareAvailable: false),
            encryptedVaultStore: InMemoryEncryptedVaultStore()
        )
        container.sessionManager.createVaultSynchronously(password: "test-password")
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
        let other = try #require(viewModel.createWorkspace(
            WorkspaceDraft(name: "Other", icon: "shippingbox", colorHex: "#4A7AFF", notes: "")
        ))

        // The same API key in local and production — and one key production never got.
        _ = try container.itemRepository.saveItem(SecretItemDraft(
            title: "Local env",
            type: .envGroup,
            workspaceID: workspace.id,
            environment: .preset(.local),
            notes: "",
            tags: [],
            isFavorite: false,
            fieldDrafts: [
                FieldDraft(key: "STRIPE_KEY", label: "STRIPE_KEY", value: "sk_shared", kind: .secret, isSensitive: true, sortOrder: 0),
                FieldDraft(key: "DEBUG", label: "DEBUG", value: "true", kind: .text, isSensitive: false, sortOrder: 1)
            ],
            templateID: nil
        ))
        _ = try container.itemRepository.saveItem(SecretItemDraft(
            title: "Prod env",
            type: .envGroup,
            workspaceID: workspace.id,
            environment: .preset(.prod),
            notes: "",
            tags: [],
            isFavorite: false,
            fieldDrafts: [
                FieldDraft(key: "STRIPE_KEY", label: "STRIPE_KEY", value: "sk_shared", kind: .secret, isSensitive: true, sortOrder: 0)
            ],
            templateID: nil
        ))
        _ = try container.itemRepository.saveItem(SecretItemDraft(
            title: "Someone else's env",
            type: .envGroup,
            workspaceID: other.id,
            environment: .preset(.prod),
            notes: "",
            tags: [],
            isFavorite: false,
            fieldDrafts: [
                FieldDraft(key: "NOT_MINE", label: "NOT_MINE", value: "x", kind: .text, isSensitive: false, sortOrder: 0)
            ],
            templateID: nil
        ))
        viewModel.reload()

        let matrix = viewModel.environmentMatrix(inWorkspace: workspace.id)

        #expect(matrix.columns.map(\.title) == ["Local", "Prod"])
        #expect(matrix.rows.map(\.key) == ["STRIPE_KEY", "DEBUG"])
        #expect(matrix.rows[0].hasSharedSecret)
        #expect(matrix.rows[1].missingCount == 1)
        #expect(viewModel.canCompareEnvironments(inWorkspace: workspace.id))
        #expect(viewModel.canCompareEnvironments(inWorkspace: other.id) == false)

        // Nothing in the matrix is a value. The digest of a secret is not the secret, and the
        // plaintext must not be reachable through any cell.
        let digests = matrix.rows.flatMap { $0.cells.compactMap(\.valueDigest) }
        #expect(!digests.isEmpty)
        #expect(!digests.contains("sk_shared"))
        #expect(!digests.contains { $0.contains("sk_") })
    }
}
