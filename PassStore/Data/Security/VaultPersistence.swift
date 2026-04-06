import CommonCrypto
import CryptoKit
import Foundation
import Sodium

enum VaultCryptoError: LocalizedError {
    case invalidEnvelope
    case invalidWrappedKey
    case keyDerivationFailed(CCStatus)
    case vaultLocked
    case metadataMissing
    case emptyPassword

    var errorDescription: String? {
        switch self {
        case .invalidEnvelope:
            "Encrypted vault payload is invalid."
        case .invalidWrappedKey:
            "Wrapped vault key is invalid."
        case let .keyDerivationFailed(status):
            "Key derivation failed: \(status)"
        case .vaultLocked:
            "Unlock the vault first."
        case .metadataMissing:
            "Vault metadata is missing."
        case .emptyPassword:
            "Password cannot be empty."
        }
    }
}

struct VaultCryptoService {
    let defaultIterations: Int
    /// Argon2id opslimit (number of passes). Default: 3 = OPSLIMIT_MODERATE.
    let defaultOpsLimit: Int
    /// Argon2id memory limit in bytes. Default: 268_435_456 = MEMLIMIT_MODERATE (256 MB).
    let defaultMemLimit: Int

    init(defaultIterations: Int = 600_000, defaultOpsLimit: Int = 3, defaultMemLimit: Int = 268_435_456) {
        self.defaultIterations = defaultIterations
        self.defaultOpsLimit = defaultOpsLimit
        self.defaultMemLimit = defaultMemLimit
    }

    func generateVaultKey() -> Data {
        SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
    }

    func wrapVaultKey(_ vaultKey: Data, password: String) throws -> WrappedVaultKey {
        // Generate a 16-byte salt (crypto_pwhash_SALTBYTES) for Argon2id.
        let sodium = Sodium()
        guard let saltBytes = sodium.randomBytes.buf(length: sodium.pwHash.SaltBytes) else {
            throw VaultCryptoError.keyDerivationFailed(CCStatus(kCCParamError))
        }
        let salt = Data(saltBytes)
        let opsLimit = defaultOpsLimit
        let memLimit = defaultMemLimit
        let derivedKey = try deriveKeyArgon2id(password: password, salt: saltBytes, opsLimit: opsLimit, memLimit: memLimit)
        let sealed = try AES.GCM.seal(vaultKey, using: derivedKey)
        return WrappedVaultKey(
            kdfAlgorithm: "argon2id",
            salt: salt.base64EncodedString(),
            iterations: opsLimit,
            memoryLimit: memLimit,
            nonce: Data(sealed.nonce).base64EncodedString(),
            ciphertext: sealed.ciphertext.base64EncodedString(),
            tag: sealed.tag.base64EncodedString()
        )
    }

    func unwrapVaultKey(_ wrappedKey: WrappedVaultKey, password: String) throws -> Data {
        guard let salt = Data(base64Encoded: wrappedKey.salt),
              let nonceData = Data(base64Encoded: wrappedKey.nonce),
              let ciphertext = Data(base64Encoded: wrappedKey.ciphertext),
              let tag = Data(base64Encoded: wrappedKey.tag),
              let nonce = try? AES.GCM.Nonce(data: nonceData) else {
            throw VaultCryptoError.invalidWrappedKey
        }

        let algorithm = wrappedKey.kdfAlgorithm ?? "pbkdf2-sha256"
        let derivedKey: SymmetricKey
        switch algorithm {
        case "argon2id":
            let opsLimit = wrappedKey.iterations
            let memLimit = wrappedKey.memoryLimit ?? defaultMemLimit
            derivedKey = try deriveKeyArgon2id(password: password, salt: Array(salt), opsLimit: opsLimit, memLimit: memLimit)
        default:
            // Legacy PBKDF2-SHA256 path (nil or "pbkdf2-sha256").
            derivedKey = try deriveKeyPBKDF2(password: password, salt: salt, iterations: wrappedKey.iterations)
        }

        let sealedBox = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag)
        return try AES.GCM.open(sealedBox, using: derivedKey)
    }

    func encryptVault(_ snapshot: VaultSnapshot, using vaultKey: Data) throws -> VaultEnvelope {
        let payload = try JSONEncoder.vaultEncoder.encode(snapshot)
        let key = SymmetricKey(data: vaultKey)
        let sealed = try AES.GCM.seal(payload, using: key)
        return VaultEnvelope(
            version: 1,
            nonce: Data(sealed.nonce).base64EncodedString(),
            ciphertext: sealed.ciphertext.base64EncodedString(),
            tag: sealed.tag.base64EncodedString(),
            createdAt: .now
        )
    }

    func decryptEnvelopePayload(_ envelope: VaultEnvelope, using vaultKey: Data) throws -> Data {
        guard let nonceData = Data(base64Encoded: envelope.nonce),
              let ciphertext = Data(base64Encoded: envelope.ciphertext),
              let tag = Data(base64Encoded: envelope.tag),
              let nonce = try? AES.GCM.Nonce(data: nonceData) else {
            throw VaultCryptoError.invalidEnvelope
        }
        let key = SymmetricKey(data: vaultKey)
        let sealedBox = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag)
        return try AES.GCM.open(sealedBox, using: key)
    }

    func decryptVault(_ envelope: VaultEnvelope, using vaultKey: Data) throws -> VaultSnapshot {
        let payload = try decryptEnvelopePayload(envelope, using: vaultKey)
        return try JSONDecoder.vaultDecoder.decode(VaultSnapshot.self, from: payload)
    }

    // MARK: - Key derivation

    /// Argon2id key derivation (memory-hard, GPU/ASIC resistant).
    /// Salt must be exactly crypto_pwhash_SALTBYTES (16 bytes).
    private func deriveKeyArgon2id(password: String, salt: [UInt8], opsLimit: Int, memLimit: Int) throws -> SymmetricKey {
        var passwordBytes = Array(password.utf8)
        defer {
            for i in 0..<passwordBytes.count { passwordBytes[i] = 0 }
        }
        let sodium = Sodium()
        guard var resultBytes = sodium.pwHash.hash(
            outputLength: 32,
            passwd: passwordBytes,
            salt: salt,
            opsLimit: opsLimit,
            memLimit: memLimit,
            alg: .Argon2ID13
        ) else {
            throw VaultCryptoError.keyDerivationFailed(CCStatus(kCCParamError))
        }
        defer {
            for i in 0..<resultBytes.count { resultBytes[i] = 0 }
        }
        return SymmetricKey(data: Data(resultBytes))
    }

    /// Legacy PBKDF2-HMAC-SHA256 key derivation. Used to read existing vaults.
    private func deriveKeyPBKDF2(password: String, salt: Data, iterations: Int) throws -> SymmetricKey {
        var passwordData = Data(password.utf8)
        defer {
            passwordData.withUnsafeMutableBytes { buf in
                guard let base = buf.baseAddress else { return }
                memset(base, 0, buf.count)
            }
        }
        var derived = Data(count: 32)
        defer {
            derived.withUnsafeMutableBytes { buf in
                guard let base = buf.baseAddress else { return }
                memset(base, 0, buf.count)
            }
        }
        let derivedCount = derived.count
        let status: CCStatus = derived.withUnsafeMutableBytes { derivedBytes in
            salt.withUnsafeBytes { saltBytes in
                if passwordData.isEmpty {
                    // Empty UTF-8 password: PBKDF length is 0; use a non-null dummy base.
                    return withUnsafeBytes(of: UInt8(0)) { dummy in
                        CCKeyDerivationPBKDF(
                            CCPBKDFAlgorithm(kCCPBKDF2),
                            dummy.baseAddress,
                            0,
                            saltBytes.bindMemory(to: UInt8.self).baseAddress,
                            salt.count,
                            CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                            UInt32(iterations),
                            derivedBytes.bindMemory(to: UInt8.self).baseAddress,
                            derivedCount
                        )
                    }
                }
                return passwordData.withUnsafeBytes { passwordBytes in
                    guard let passwordBase = passwordBytes.bindMemory(to: UInt8.self).baseAddress else {
                        return CCStatus(kCCParamError)
                    }
                    return CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordBase,
                        passwordData.count,
                        saltBytes.bindMemory(to: UInt8.self).baseAddress,
                        salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        UInt32(iterations),
                        derivedBytes.bindMemory(to: UInt8.self).baseAddress,
                        derivedCount
                    )
                }
            }
        }
        guard status == kCCSuccess else {
            throw VaultCryptoError.keyDerivationFailed(status)
        }
        return SymmetricKey(data: derived)
    }
}

@MainActor
final class VaultMemoryStore {
    var workspaces: [WorkspaceEntity] = []
    var items: [SecretItemEntity] = []
    var customTemplates: [SecretFieldTemplateEntity] = []
    private let builtInTemplates: [SecretFieldTemplateEntity]
    private var persistHandler: (() throws -> Void)?

    init(builtInTemplates: [SecretFieldTemplateEntity]? = nil) {
        self.builtInTemplates = builtInTemplates ?? BuiltInTemplates.entities()
    }

    var isUnlocked: Bool {
        persistHandler != nil
    }

    var allTemplates: [SecretFieldTemplateEntity] {
        builtInTemplates + customTemplates
    }

    func activate(snapshot: VaultSnapshot, persistHandler: @escaping () throws -> Void) {
        self.persistHandler = persistHandler
        load(snapshot)
    }

    func clear() {
        // Overwrite sensitive field values before releasing to ARC.
        for item in items {
            for field in item.fields where field.isSensitive {
                field.plainValue = String(repeating: "\0", count: field.plainValue.count)
                field.plainValue = ""
            }
        }
        workspaces = []
        items = []
        customTemplates = []
        persistHandler = nil
    }

    func requireUnlocked() throws {
        guard isUnlocked else { throw VaultCryptoError.vaultLocked }
    }

    func persist() throws {
        try requireUnlocked()
        try persistHandler?()
    }

    /// Replaces the entire vault contents with the given snapshot and persists.
    func replaceContents(with snapshot: VaultSnapshot) throws {
        try requireUnlocked()
        load(snapshot)
        try persist()
    }

    func makeSnapshot() -> VaultSnapshot {
        let workspaceSnapshots = workspaces.map {
            WorkspaceSnapshot(
                id: $0.id,
                name: $0.name,
                icon: $0.icon,
                colorHex: $0.colorHex,
                notes: $0.notes,
                isArchived: $0.isArchived,
                createdAt: $0.createdAt,
                updatedAt: $0.updatedAt,
                sortOrder: $0.sortOrder
            )
        }

        let itemSnapshots = items.map { item in
            SecretItemSnapshot(
                id: item.id,
                title: item.title,
                typeRawValue: item.typeRawValue,
                environmentRawValue: item.environmentRawValue,
                customEnvironmentName: item.customEnvironmentName,
                notes: item.notes,
                tagsRawValue: item.tagsRawValue,
                isFavorite: item.isFavorite,
                isArchived: item.isArchived,
                createdAt: item.createdAt,
                updatedAt: item.updatedAt,
                lastAccessedAt: item.lastAccessedAt,
                workspaceID: item.workspace?.id,
                templateID: item.template?.id,
                fields: item.fields.map {
                    FieldValueSnapshot(
                        id: $0.id,
                        fieldKey: $0.fieldKey,
                        labelSnapshot: $0.labelSnapshot,
                        kindRawValue: $0.kindRawValue,
                        isSensitive: $0.isSensitive,
                        isCopyable: $0.isCopyable,
                        isMasked: $0.isMasked,
                        sortOrder: $0.sortOrder,
                        plainValue: $0.plainValue
                    )
                }.sorted { $0.sortOrder < $1.sortOrder }
            )
        }

        let templateSnapshots = customTemplates.map { template in
            TemplateSnapshot(
                id: template.id,
                itemTypeRawValue: template.itemTypeRawValue,
                name: template.name,
                createdAt: template.createdAt,
                updatedAt: template.updatedAt,
                fieldDefinitions: template.fieldDefinitions.map {
                    TemplateFieldSnapshot(
                        id: $0.id,
                        key: $0.key,
                        label: $0.label,
                        kindRawValue: $0.kindRawValue,
                        isSensitive: $0.isSensitive,
                        isCopyable: $0.isCopyable,
                        isMaskedByDefault: $0.isMaskedByDefault,
                        sortOrder: $0.sortOrder
                    )
                }.sorted { $0.sortOrder < $1.sortOrder }
            )
        }

        return VaultSnapshot(
            workspaces: workspaceSnapshots,
            items: itemSnapshots,
            customTemplates: templateSnapshots
        )
    }

    private func load(_ snapshot: VaultSnapshot) {
        let workspaceMap = Dictionary(uniqueKeysWithValues: snapshot.workspaces.map {
            ($0.id, WorkspaceEntity(
                id: $0.id,
                name: $0.name,
                icon: $0.icon,
                colorHex: $0.colorHex,
                notes: $0.notes,
                isArchived: $0.isArchived,
                createdAt: $0.createdAt,
                updatedAt: $0.updatedAt,
                sortOrder: $0.sortOrder
            ))
        })

        let customTemplateMap = Dictionary(uniqueKeysWithValues: snapshot.customTemplates.map { templateSnapshot in
            let template = SecretFieldTemplateEntity(
                id: templateSnapshot.id,
                itemType: SecretItemType(rawValue: templateSnapshot.itemTypeRawValue) ?? .customTemplate,
                name: templateSnapshot.name,
                isBuiltIn: false,
                createdAt: templateSnapshot.createdAt,
                updatedAt: templateSnapshot.updatedAt
            )
            template.fieldDefinitions = templateSnapshot.fieldDefinitions.map { fieldSnapshot in
                SecretFieldDefinitionEntity(
                    id: fieldSnapshot.id,
                    key: fieldSnapshot.key,
                    label: fieldSnapshot.label,
                    kind: FieldKind(rawValue: fieldSnapshot.kindRawValue) ?? .text,
                    isSensitive: fieldSnapshot.isSensitive,
                    isCopyable: fieldSnapshot.isCopyable,
                    isMaskedByDefault: fieldSnapshot.isMaskedByDefault,
                    sortOrder: fieldSnapshot.sortOrder,
                    template: template
                )
            }.sorted { $0.sortOrder < $1.sortOrder }
            return (template.id, template)
        })

        let builtInTemplateMap = Dictionary(uniqueKeysWithValues: builtInTemplates.map { ($0.id, $0) })
        let templatesByID = builtInTemplateMap.merging(customTemplateMap) { _, new in new }

        let items = snapshot.items.map { itemSnapshot in
            let item = SecretItemEntity(
                id: itemSnapshot.id,
                title: itemSnapshot.title,
                type: SecretItemType(rawValue: itemSnapshot.typeRawValue) ?? .generic,
                environment: itemSnapshot.environmentRawValue == EnvironmentKind.custom.rawValue
                    ? .custom(itemSnapshot.customEnvironmentName ?? "Custom")
                    : .preset(EnvironmentKind(rawValue: itemSnapshot.environmentRawValue) ?? .dev),
                notes: itemSnapshot.notes,
                tags: itemSnapshot.tagsRawValue
                    .split(separator: ",")
                    .map(String.init),
                isFavorite: itemSnapshot.isFavorite,
                isArchived: itemSnapshot.isArchived,
                createdAt: itemSnapshot.createdAt,
                updatedAt: itemSnapshot.updatedAt,
                lastAccessedAt: itemSnapshot.lastAccessedAt,
                workspace: itemSnapshot.workspaceID.flatMap { workspaceMap[$0] },
                template: itemSnapshot.templateID.flatMap { templatesByID[$0] }
            )
            item.fields = itemSnapshot.fields.map { fieldSnapshot in
                SecretFieldValueEntity(
                    id: fieldSnapshot.id,
                    fieldKey: fieldSnapshot.fieldKey,
                    labelSnapshot: fieldSnapshot.labelSnapshot,
                    kind: FieldKind(rawValue: fieldSnapshot.kindRawValue) ?? .text,
                    isSensitive: fieldSnapshot.isSensitive,
                    isCopyable: fieldSnapshot.isCopyable,
                    isMasked: fieldSnapshot.isMasked,
                    sortOrder: fieldSnapshot.sortOrder,
                    plainValue: fieldSnapshot.plainValue,
                    item: item
                )
            }.sorted { $0.sortOrder < $1.sortOrder }
            return item
        }

        let loadedWorkspaces = workspaceMap.values.sorted { $0.updatedAt > $1.updatedAt }
        if loadedWorkspaces.count > 1, loadedWorkspaces.allSatisfy({ $0.sortOrder == 0 }) {
            for (index, ws) in loadedWorkspaces.enumerated() {
                ws.sortOrder = index
            }
        }
        workspaces = loadedWorkspaces.sorted { $0.sortOrder < $1.sortOrder }
        self.items = items
        customTemplates = customTemplateMap.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        for workspace in workspaces {
            workspace.items = items
                .filter { $0.workspace?.id == workspace.id }
                .sorted { $0.updatedAt > $1.updatedAt }
        }
    }
}

final class FileEncryptedVaultStore: EncryptedVaultStore {
    private let directoryURL: URL
    private let envelopeURL: URL
    private let metadataURL: URL

    init(fileManager: FileManager = .default, baseDirectory: URL? = nil, bundleIdentifier: String = Bundle.main.bundleIdentifier ?? "app.makio.PassStore") {
        let rootDirectory = baseDirectory
            ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                .appendingPathComponent(bundleIdentifier, isDirectory: true)
        self.directoryURL = rootDirectory
        self.envelopeURL = rootDirectory.appendingPathComponent("vault.enc", isDirectory: false)
        self.metadataURL = rootDirectory.appendingPathComponent("vault.meta", isDirectory: false)
    }

    func hasVault() -> Bool {
        FileManager.default.fileExists(atPath: envelopeURL.path) && FileManager.default.fileExists(atPath: metadataURL.path)
    }

    func loadMetadata() throws -> VaultMetadata {
        let data = try Data(contentsOf: metadataURL)
        return try JSONDecoder.vaultDecoder.decode(VaultMetadata.self, from: data)
    }

    func loadEnvelope() throws -> VaultEnvelope {
        let data = try Data(contentsOf: envelopeURL)
        return try JSONDecoder.vaultDecoder.decode(VaultEnvelope.self, from: data)
    }

    func save(metadata: VaultMetadata, envelope: VaultEnvelope) throws {
        let fm = FileManager.default
        // Owner-only directory: rwx------ (0700)
        try fm.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let metadataData = try JSONEncoder.vaultEncoder.encode(metadata)
        let envelopeData = try JSONEncoder.vaultEncoder.encode(envelope)
        try metadataData.write(to: metadataURL, options: .atomic)
        try envelopeData.write(to: envelopeURL, options: .atomic)
        // Owner-only files: rw------- (0600)
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: metadataURL.path)
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: envelopeURL.path)
    }

    func resetSecureVault() throws {
        if FileManager.default.fileExists(atPath: envelopeURL.path) {
            try FileManager.default.removeItem(at: envelopeURL)
        }
        if FileManager.default.fileExists(atPath: metadataURL.path) {
            try FileManager.default.removeItem(at: metadataURL)
        }
    }

    func resetLegacyArtifacts() throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: directoryURL.path) else { return }
        let candidates = try fileManager.contentsOfDirectory(at: directoryURL, includingPropertiesForKeys: nil)
        for url in candidates where url.lastPathComponent.hasSuffix(".store")
            || url.lastPathComponent.hasSuffix(".store-shm")
            || url.lastPathComponent.hasSuffix(".store-wal")
            || url.lastPathComponent == "default.store"
            || url.lastPathComponent == "default.store-shm"
            || url.lastPathComponent == "default.store-wal" {
            try? fileManager.removeItem(at: url)
        }
    }
}

final class InMemoryEncryptedVaultStore: EncryptedVaultStore {
    private var metadata: VaultMetadata?
    private var envelope: VaultEnvelope?

    func hasVault() -> Bool {
        metadata != nil && envelope != nil
    }

    func loadMetadata() throws -> VaultMetadata {
        guard let metadata else { throw VaultCryptoError.metadataMissing }
        return metadata
    }

    func loadEnvelope() throws -> VaultEnvelope {
        guard let envelope else { throw VaultCryptoError.invalidEnvelope }
        return envelope
    }

    func save(metadata: VaultMetadata, envelope: VaultEnvelope) throws {
        self.metadata = metadata
        self.envelope = envelope
    }

    func resetSecureVault() throws {
        metadata = nil
        envelope = nil
    }

    func resetLegacyArtifacts() throws {}
}

private extension JSONEncoder {
    static let vaultEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()
}

private extension JSONDecoder {
    static let vaultDecoder = JSONDecoder()
}
