import Foundation
import Testing
@testable import PassStore

@MainActor
struct RepositoryTests {
    @Test func vaultCiphertextDoesNotExposePlaintextSecrets() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let vaultStore = FileEncryptedVaultStore(baseDirectory: directory)
        let container = AppContainer(
            inMemory: false,
            defaults: UserDefaults(suiteName: "RepositoryTests-\(UUID().uuidString)")!,
            keyStore: InMemoryVaultKeyStore(isBiometricHardwareAvailable: true),
            encryptedVaultStore: vaultStore
        )
        container.sessionManager.createVault(password: "test-secret")

        let template = try #require(container.templateRepository.fetchAll().first(where: { $0.itemType == SecretItemType.apiCredential }))
        _ = try container.itemRepository.saveItem(SecretItemDraft(
            title: "Repo Test",
            type: .apiCredential,
            workspaceID: nil,
            environment: .preset(.dev),
            notes: "Sensitive note",
            tags: ["api"],
            isFavorite: false,
            fieldDrafts: [
                FieldDraft(key: "apiKey", label: "API Key", value: "shhh", kind: .secret, isSensitive: true, isMasked: true, sortOrder: 0),
                FieldDraft(key: "baseUrl", label: "Base URL", value: "https://example.com", kind: .url, isSensitive: false, sortOrder: 1)
            ],
            templateID: template.id
        ))

        let envelopeString = try String(contentsOf: directory.appendingPathComponent("vault.enc"), encoding: .utf8)
        let metadataString = try String(contentsOf: directory.appendingPathComponent("vault.meta"), encoding: .utf8)

        #expect(!envelopeString.contains("Repo Test"))
        #expect(!envelopeString.contains("shhh"))
        #expect(!envelopeString.contains("Sensitive note"))
        #expect(!metadataString.contains("shhh"))
    }

    /// Renaming a field so its slug collides with an existing one used to trap in
    /// `Dictionary(uniqueKeysWithValues:)` inside `saveItem`.
    @Test func savingDuplicateFieldKeysKeepsBothFieldsInsteadOfTrapping() throws {
        let container = AppContainer.preview()

        let saved = try container.itemRepository.saveItem(SecretItemDraft(
            title: "Duplicate Keys",
            type: .generic,
            workspaceID: nil,
            environment: .preset(.dev),
            notes: "",
            tags: [],
            isFavorite: false,
            fieldDrafts: [
                FieldDraft(key: "host", label: "Host", value: "first.example.dev", kind: .text, isSensitive: false, sortOrder: 0),
                FieldDraft(key: "host", label: "Host", value: "second.example.dev", kind: .text, isSensitive: false, sortOrder: 1)
            ],
            templateID: nil
        ))

        #expect(saved.fields.count == 2)
        let resolved = try container.itemRepository.resolveFields(for: saved)
        #expect(resolved.map(\.key) == ["host", "host_2"])
        #expect(resolved.map(\.value) == ["first.example.dev", "second.example.dev"])
    }

    @Test func withUniqueKeysLeavesDistinctKeysUntouchedAndNamesEmptyOnes() {
        let deduped = SecretItemRepository.withUniqueKeys([
            FieldDraft(key: "host", label: "Host", kind: .text, isSensitive: false, sortOrder: 0),
            FieldDraft(key: "port", label: "Port", kind: .number, isSensitive: false, sortOrder: 1),
            FieldDraft(key: "", label: "Unnamed", kind: .text, isSensitive: false, sortOrder: 2),
            FieldDraft(key: "", label: "Also unnamed", kind: .text, isSensitive: false, sortOrder: 3)
        ])

        #expect(deduped.map(\.key) == ["host", "port", "field", "field_2"])
    }

    @Test func deletingWorkspaceKeepsItsItemsAndClearsTheirWorkspace() throws {
        let container = AppContainer.preview()
        let workspace = try #require(
            container.workspaceRepository.fetchAll(includeArchived: false)
                .first(where: { $0.name == "Pokéos API" })
        )
        let itemCountBefore = try container.itemRepository.fetchAll(includeArchived: true).count
        let owned = try container.itemRepository.fetchAll(includeArchived: true)
            .filter { $0.workspace?.id == workspace.id }
        #expect(!owned.isEmpty)

        try container.workspaceRepository.deleteWorkspace(workspace)

        let remaining = try container.itemRepository.fetchAll(includeArchived: true)
        #expect(remaining.count == itemCountBefore)
        #expect(remaining.allSatisfy { $0.workspace?.id != workspace.id })
        #expect(try container.workspaceRepository.fetchAll(includeArchived: true).allSatisfy { $0.id != workspace.id })
    }
}
