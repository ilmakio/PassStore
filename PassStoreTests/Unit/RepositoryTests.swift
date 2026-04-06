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
}
