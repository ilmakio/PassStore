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

        session.createVault(password: "test-secret")

        #expect(session.lockState == .unlocked)
        #expect(memoryStore.isUnlocked)

        session.lock()
        #expect(session.lockState == .locked)
        #expect(session.unlockWithPassword("test-secret"))
        #expect(session.lockState == .unlocked)
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

        session.createVault(password: "test-secret")
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

        session.createVault(password: "test-secret")

        #expect(session.lockState == .unlocked)
        #expect(memoryStore.isUnlocked)
        #expect(session.lastErrorMessage == nil)
        #expect(session.isBiometricAvailable == false)

        session.lock()

        #expect(session.unlockWithPassword("test-secret"))
        #expect(session.lockState == .unlocked)
        #expect(session.lastErrorMessage == nil)
    }
}

private final class FailingVaultKeyStore: VaultKeyStore {
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
