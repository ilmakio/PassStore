import Foundation
import Security
import Testing
@testable import PassStore

@MainActor
struct VaultSessionTests {
    @Test func masterPasswordUnlockFlow() throws {
        let defaults = UserDefaults(suiteName: "VaultSessionTests-\(UUID().uuidString)")!
        let memoryStore = VaultMemoryStore()
        let session = VaultSessionManager(
            defaults: defaults,
            settings: AppSettingsStore(defaults: defaults),
            cryptoService: VaultCryptoService(defaultIterations: 2_000, defaultOpsLimit: 1, defaultMemLimit: 8_192),
            vaultStore: InMemoryEncryptedVaultStore(),
            keyStore: InMemoryVaultKeyStore(isBiometricHardwareAvailable: true),
            memoryStore: memoryStore
        )

        #expect(session.lockState == .setupRequired)

        session.createVaultSynchronously(password: "test-secret")

        #expect(session.lockState == .unlocked)
        #expect(memoryStore.isUnlocked)

        session.lock()
        #expect(session.lockState == .locked)
        #expect(session.unlockWithPasswordSynchronously("test-secret"))
        #expect(session.lockState == .unlocked)
    }

    @Test func changingMasterPasswordRewrapsTheVaultAndKeepsDataReadable() async throws {
        let defaults = UserDefaults(suiteName: "VaultPasswordChange-\(UUID().uuidString)")!
        let memoryStore = VaultMemoryStore()
        let vaultStore = InMemoryEncryptedVaultStore()
        let session = VaultSessionManager(
            defaults: defaults,
            settings: AppSettingsStore(defaults: defaults),
            cryptoService: VaultCryptoService(defaultIterations: 2_000, defaultOpsLimit: 1, defaultMemLimit: 8_192),
            vaultStore: vaultStore,
            keyStore: InMemoryVaultKeyStore(isBiometricHardwareAvailable: true),
            memoryStore: memoryStore
        )

        session.createVaultSynchronously(password: "original-password")
        let repository = SecretItemRepository(store: memoryStore)
        _ = try repository.saveItem(SecretItemDraft(
            title: "Survives Rotation",
            type: .generic,
            workspaceID: nil,
            environment: .preset(.prod),
            notes: "",
            tags: [],
            isFavorite: false,
            fieldDrafts: [
                FieldDraft(key: "secret", label: "Secret", value: "keep-me", kind: .secret, isSensitive: true, isMasked: true, sortOrder: 0)
            ],
            templateID: nil
        ))

        try await session.changeMasterPassword(current: "original-password", to: "a-brand-new-password")

        session.lock()
        #expect(session.lockState == .locked)

        // New password unlocks the same data.
        #expect(session.unlockWithPasswordSynchronously("a-brand-new-password"))
        let survived = memoryStore.items.contains { $0.title == "Survives Rotation" }
        #expect(survived)
        let restored = try repository.resolveFields(for: #require(memoryStore.items.first))
        #expect(restored.first?.value == "keep-me")

        // Old password is rejected. Asserted last on purpose: a failed attempt arms the
        // progressive brute-force delay, which would reject the next unlock for a second.
        session.lock()
        #expect(!session.unlockWithPasswordSynchronously("original-password"))
        #expect(session.lockState == .locked)
    }

    @Test func changingMasterPasswordRejectsWrongCurrentShortAndUnchangedPasswords() async throws {
        let defaults = UserDefaults(suiteName: "VaultPasswordChangeGuards-\(UUID().uuidString)")!
        let session = VaultSessionManager(
            defaults: defaults,
            settings: AppSettingsStore(defaults: defaults),
            cryptoService: VaultCryptoService(defaultIterations: 2_000, defaultOpsLimit: 1, defaultMemLimit: 8_192),
            vaultStore: InMemoryEncryptedVaultStore(),
            keyStore: InMemoryVaultKeyStore(isBiometricHardwareAvailable: true),
            memoryStore: VaultMemoryStore()
        )
        session.createVaultSynchronously(password: "original-password")

        await #expect(throws: VaultCryptoError.self) {
            try await session.changeMasterPassword(current: "wrong-password", to: "a-brand-new-password")
        }
        await #expect(throws: VaultCryptoError.self) {
            try await session.changeMasterPassword(current: "original-password", to: "short")
        }
        await #expect(throws: VaultCryptoError.newPasswordMustDiffer) {
            try await session.changeMasterPassword(
                current: "original-password",
                to: "original-password"
            )
        }

        // Both rejections must leave the original password working.
        session.lock()
        #expect(session.unlockWithPasswordSynchronously("original-password"))
    }

    @Test func biometricUnlockUsesStoredVaultKey() async throws {
        let defaults = UserDefaults(suiteName: "VaultBiometricTests-\(UUID().uuidString)")!
        let memoryStore = VaultMemoryStore()
        let session = VaultSessionManager(
            defaults: defaults,
            settings: AppSettingsStore(defaults: defaults),
            cryptoService: VaultCryptoService(defaultIterations: 2_000, defaultOpsLimit: 1, defaultMemLimit: 8_192),
            vaultStore: InMemoryEncryptedVaultStore(),
            keyStore: InMemoryVaultKeyStore(isBiometricHardwareAvailable: true),
            memoryStore: memoryStore
        )

        session.createVaultSynchronously(password: "test-secret")
        session.lock()

        let unlocked = await session.unlockWithBiometrics()
        #expect(unlocked)
        #expect(session.lockState == .unlocked)
    }

    @Test func createVaultFallsBackWhenKeychainAccessIsUnavailable() throws {
        let defaults = UserDefaults(suiteName: "VaultKeychainFallbackTests-\(UUID().uuidString)")!
        let memoryStore = VaultMemoryStore()
        let session = VaultSessionManager(
            defaults: defaults,
            settings: AppSettingsStore(defaults: defaults),
            cryptoService: VaultCryptoService(defaultIterations: 2_000, defaultOpsLimit: 1, defaultMemLimit: 8_192),
            vaultStore: InMemoryEncryptedVaultStore(),
            keyStore: FailingVaultKeyStore(),
            memoryStore: memoryStore
        )

        session.createVaultSynchronously(password: "test-secret")

        #expect(session.lockState == .unlocked)
        #expect(memoryStore.isUnlocked)
        #expect(session.lastErrorMessage == nil)
        #expect(session.isBiometricAvailable == false)

        session.lock()

        #expect(session.unlockWithPasswordSynchronously("test-secret"))
        #expect(session.lockState == .unlocked)
        #expect(session.lastErrorMessage == nil)
    }
}

nonisolated private final class FailingVaultKeyStore: VaultKeyStore, @unchecked Sendable {
    var isBiometricHardwareAvailable = true

    func saveVaultKey(_ key: Data, requireBiometrics: Bool) throws {
        throw VaultKeyStoreError.unexpectedStatus(errSecMissingEntitlement)
    }

    func readVaultKey(prompt: String) throws -> Data {
        throw VaultKeyStoreError.itemNotFound
    }

    func deleteVaultKey() throws {
        throw VaultKeyStoreError.unexpectedStatus(errSecMissingEntitlement)
    }

    func clearLegacySecrets() throws {
        throw VaultKeyStoreError.unexpectedStatus(errSecMissingEntitlement)
    }
}
