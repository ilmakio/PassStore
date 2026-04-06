import Foundation
import LocalAuthentication
import Security

enum VaultKeyStoreError: LocalizedError {
    case itemNotFound
    case invalidData
    case unexpectedStatus(OSStatus)

    var errorDescription: String? {
        switch self {
        case .itemNotFound:
            "Biometric vault key not found."
        case .invalidData:
            "Vault key data is invalid."
        case let .unexpectedStatus(status):
            if status == errSecMissingEntitlement {
                "Biometric unlock is unavailable in this build because Keychain access is not properly entitled."
            } else {
                "Keychain error: \(status)"
            }
        }
    }
}

final class KeychainVaultKeyStore: VaultKeyStore {
    private let service: String
    private let account: String
    private let legacySecretService: String

    init(
        service: String = "app.makio.PassStore.vaultkey",
        account: String = "biometric-unlock",
        legacySecretService: String = "app.makio.DevVault.secret"
    ) {
        self.service = service
        self.account = account
        self.legacySecretService = legacySecretService
    }

    var isBiometricHardwareAvailable: Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
    }

    func saveVaultKey(_ key: Data, requireBiometrics: Bool) throws {
        // The vault key must never be stored without biometric access control when hardware supports it;
        // PassStore only calls this with `true` from `VaultSessionManager.syncBiometricState`.
        guard requireBiometrics else {
            throw VaultKeyStoreError.invalidData
        }

        try deleteVaultKey()

        guard let accessControl = SecAccessControlCreateWithFlags(
            nil,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            .biometryCurrentSet,
            nil
        ) else {
            throw VaultKeyStoreError.invalidData
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: key,
            kSecAttrAccessControl as String: accessControl
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw VaultKeyStoreError.unexpectedStatus(status)
        }
    }

    func readVaultKey(prompt: String) throws -> Data {
        let context = LAContext()
        context.localizedReason = prompt

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationContext as String: context
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status != errSecItemNotFound else { throw VaultKeyStoreError.itemNotFound }
        guard status == errSecSuccess else { throw VaultKeyStoreError.unexpectedStatus(status) }
        guard let data = result as? Data else {
            throw VaultKeyStoreError.invalidData
        }
        return data
    }

    func deleteVaultKey() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw VaultKeyStoreError.unexpectedStatus(status)
        }
    }

    func clearLegacySecrets() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: legacySecretService
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw VaultKeyStoreError.unexpectedStatus(status)
        }
    }
}

final class InMemoryVaultKeyStore: VaultKeyStore {
    var isBiometricHardwareAvailable: Bool
    private var key: Data?
    private var legacySecretsCleared = false

    init(isBiometricHardwareAvailable: Bool = true) {
        self.isBiometricHardwareAvailable = isBiometricHardwareAvailable
    }

    func saveVaultKey(_ key: Data, requireBiometrics: Bool) throws {
        self.key = key
    }

    func readVaultKey(prompt: String) throws -> Data {
        guard let key else { throw VaultKeyStoreError.itemNotFound }
        return key
    }

    func deleteVaultKey() throws {
        key = nil
    }

    func clearLegacySecrets() throws {
        legacySecretsCleared = true
    }
}
