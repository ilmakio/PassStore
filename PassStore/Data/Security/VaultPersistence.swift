import CommonCrypto
import CryptoKit
import Darwin
import Foundation
import Sodium

enum VaultCryptoError: LocalizedError, Equatable {
    case invalidEnvelope
    case invalidWrappedKey
    case keyDerivationFailed(CCStatus)
    case vaultLocked
    case metadataMissing
    case emptyPassword
    case passwordTooShort(Int)
    case incorrectPassword
    case incorrectCurrentPassword
    case newPasswordMustDiffer
    case securityOperationInProgress
    case unsupportedVaultVersion
    case vaultContentsTooLarge

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
        case let .passwordTooShort(minimum):
            "Password must be at least \(minimum) characters."
        case .incorrectPassword:
            "Incorrect password."
        case .incorrectCurrentPassword:
            "That is not your current master password."
        case .newPasswordMustDiffer:
            "The new password must be different from the current password."
        case .securityOperationInProgress:
            "Wait for the current security operation to finish, then try again."
        case .unsupportedVaultVersion:
            "This vault was created by a newer PassStore version. Update PassStore before opening it."
        case .vaultContentsTooLarge:
            "The vault contains more data than PassStore can load safely."
        }
    }
}

nonisolated struct VaultCryptoService: Sendable {
    private static let minimumArgonMemory = 8 * 1_024
    private static let maximumArgonMemory = 256 * 1_024 * 1_024
    private static let maximumArgonOperations = 10
    private static let maximumPBKDF2Iterations = 10_000_000

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
        guard vaultKey.count == 32,
              (1...Self.maximumArgonOperations).contains(defaultOpsLimit),
              (Self.minimumArgonMemory...Self.maximumArgonMemory).contains(defaultMemLimit) else {
            throw VaultCryptoError.invalidWrappedKey
        }
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
              nonceData.count == 12,
              ciphertext.count == 32,
              tag.count == 16,
              let nonce = try? AES.GCM.Nonce(data: nonceData) else {
            throw VaultCryptoError.invalidWrappedKey
        }

        let algorithm = wrappedKey.kdfAlgorithm ?? "pbkdf2-sha256"
        let derivedKey: SymmetricKey
        switch algorithm {
        case "argon2id":
            let opsLimit = wrappedKey.iterations
            let memLimit = wrappedKey.memoryLimit ?? defaultMemLimit
            let sodium = Sodium()
            guard salt.count == sodium.pwHash.SaltBytes,
                  (1...Self.maximumArgonOperations).contains(opsLimit),
                  (Self.minimumArgonMemory...Self.maximumArgonMemory).contains(memLimit) else {
                throw VaultCryptoError.invalidWrappedKey
            }
            derivedKey = try deriveKeyArgon2id(password: password, salt: Array(salt), opsLimit: opsLimit, memLimit: memLimit)
        case "pbkdf2-sha256":
            guard (8...1_024).contains(salt.count),
                  (1...Self.maximumPBKDF2Iterations).contains(wrappedKey.iterations) else {
                throw VaultCryptoError.invalidWrappedKey
            }
            derivedKey = try deriveKeyPBKDF2(password: password, salt: salt, iterations: wrappedKey.iterations)
        default:
            throw VaultCryptoError.invalidWrappedKey
        }

        let sealedBox = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag)
        do {
            return try AES.GCM.open(sealedBox, using: derivedKey)
        } catch CryptoKitError.authenticationFailure {
            // Only failure to authenticate the wrapped vault key proves the password is
            // wrong. A later authentication failure while opening the vault payload means
            // the encrypted file is corrupt and must not advance the brute-force lockout.
            throw VaultCryptoError.incorrectPassword
        }
    }

    func encryptVault(_ snapshot: VaultSnapshot, using vaultKey: Data) throws -> VaultEnvelope {
        guard vaultKey.count == 32 else { throw VaultCryptoError.invalidEnvelope }
        try snapshot.validateResourceLimits()
        var payload = try JSONEncoder.vaultEncoder.encode(snapshot)
        defer { Self.overwrite(&payload) }
        return try encryptEnvelopePayload(payload, using: vaultKey)
    }

    /// Encrypts an already encoded payload with the active vault key. Used for small
    /// vault-adjacent records (currently rollback settings) that must not be stored as
    /// readable JSON next to the encrypted vault.
    func encryptEnvelopePayload(_ payload: Data, using vaultKey: Data) throws -> VaultEnvelope {
        guard vaultKey.count == 32 else { throw VaultCryptoError.invalidEnvelope }
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
        guard vaultKey.count == 32,
              envelope.version == 1,
              let nonceData = Data(base64Encoded: envelope.nonce),
              let ciphertext = Data(base64Encoded: envelope.ciphertext),
              let tag = Data(base64Encoded: envelope.tag),
              nonceData.count == 12,
              tag.count == 16,
              let nonce = try? AES.GCM.Nonce(data: nonceData) else {
            throw VaultCryptoError.invalidEnvelope
        }
        let key = SymmetricKey(data: vaultKey)
        let sealedBox = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag)
        return try AES.GCM.open(sealedBox, using: key)
    }

    func decryptVault(_ envelope: VaultEnvelope, using vaultKey: Data) throws -> VaultSnapshot {
        guard envelope.version == 1 else { throw VaultCryptoError.unsupportedVaultVersion }
        var payload = try decryptEnvelopePayload(envelope, using: vaultKey)
        defer { Self.overwrite(&payload) }
        let snapshot = try JSONDecoder.vaultDecoder.decode(VaultSnapshot.self, from: payload)
        try snapshot.validateResourceLimits()
        return snapshot
    }

    /// Best-effort clearing for temporary plaintext and key buffers owned by this service.
    /// `Data` is copy-on-write, so callers still avoid retaining aliases across this call.
    static func overwrite(_ data: inout Data) {
        data.withUnsafeMutableBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            memset(base, 0, buffer.count)
        }
        data.removeAll(keepingCapacity: false)
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

// MARK: - Off-main key derivation
//
// Argon2id is deliberately expensive: 256 MB and three passes take the better part of a
// second. Running that on the main actor froze the whole window on every unlock, every
// password change and every backup — and because the work was synchronous, the `isBusy`
// flag was set and cleared within one runloop turn, so no spinner ever rendered.
//
// Only pure value types cross the boundary here (`Data`, the Codable envelopes, and the
// service itself), so no store or view model is touched off the main actor.

extension VaultCryptoService {
    func wrapVaultKeyOffMain(_ vaultKey: Data, password: String) async throws -> WrappedVaultKey {
        try await Task.detached(priority: .userInitiated) { [self] in
            try wrapVaultKey(vaultKey, password: password)
        }.value
    }

    func unwrapVaultKeyOffMain(_ wrappedKey: WrappedVaultKey, password: String) async throws -> Data {
        try await Task.detached(priority: .userInitiated) { [self] in
            try unwrapVaultKey(wrappedKey, password: password)
        }.value
    }

    /// Unwraps the vault key and decrypts the payload in a single hop off the main actor.
    func openVaultOffMain(
        metadata: VaultMetadata,
        envelope: VaultEnvelope,
        password: String
    ) async throws -> (vaultKey: Data, snapshot: VaultSnapshot) {
        try await Task.detached(priority: .userInitiated) { [self] in
            var vaultKey = try unwrapVaultKey(metadata.wrappedVaultKey, password: password)
            do {
                let snapshot = try decryptVault(envelope, using: vaultKey)
                return (vaultKey, snapshot)
            } catch {
                // On success ownership is transferred to the caller, which clears it. On a
                // decode/authentication failure there is no caller-owned result to do that.
                Self.overwrite(&vaultKey)
                throw error
            }
        }.value
    }
}

extension VaultSnapshot {
    /// Structural limits for decrypted local vaults and imported backups. The encrypted file
    /// has a byte limit too, but a small JSON document can still expand into pathological
    /// numbers of objects and make a malicious backup exhaust memory or monopolise the UI.
    nonisolated func validateResourceLimits() throws {
        guard workspaces.count <= 10_000,
              items.count <= 100_000,
              customTemplates.count <= 10_000,
              masterPasswordHistory.count <= 10_000,
              (privateSidebarTagsOrder?.count ?? 0) <= 500,
              (privateSidebarEnvironmentsOrder?.count ?? 0) <= 500 else {
            throw VaultCryptoError.vaultContentsTooLarge
        }

        let privateOrderValues = (privateSidebarTagsOrder ?? [])
            + (privateSidebarEnvironmentsOrder ?? [])
        guard privateOrderValues.allSatisfy({ $0.utf8.count <= 1_024 }) else {
            throw VaultCryptoError.vaultContentsTooLarge
        }

        var totalFields = 0
        for item in items {
            guard item.fields.count <= 2_000,
                  item.changeHistory.count <= 10_000,
                  item.ignoredHealthIssues.count <= 10_000,
                  item.fields.count <= 1_000_000 - totalFields else {
                throw VaultCryptoError.vaultContentsTooLarge
            }
            totalFields += item.fields.count
            for field in item.fields where field.previousValues.count > 1_000 {
                throw VaultCryptoError.vaultContentsTooLarge
            }
        }

        for template in customTemplates where template.fieldDefinitions.count > 2_000 {
            throw VaultCryptoError.vaultContentsTooLarge
        }
    }
}

@MainActor
final class VaultMemoryStore {
    var workspaces: [WorkspaceEntity] = []
    var items: [SecretItemEntity] = []
    var customTemplates: [SecretFieldTemplateEntity] = []
    /// Newest-first record of master password changes. Kept here rather than in `VaultMetadata`
    /// because the metadata file is written unencrypted.
    var masterPasswordHistory: [MasterPasswordChangeEntry] = []
    private let builtInTemplates: [SecretFieldTemplateEntity]
    private var persistHandler: (() throws -> Void)?

    /// Pending coalesced write scheduled by `persistSoon`.
    private var deferredPersist: Task<Void, Never>?
    /// Set when a deferred write is owed, so `flushPendingPersist` knows whether to do anything.
    private var hasUnsavedDeferredChanges = false
    private var transactionDepth = 0
    private var transactionNeedsPersist = false

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
        // The session decides whether outstanding low-priority changes should be flushed
        // (ordinary lock) or discarded (erase/rollback) before clearing plaintext.
        discardPendingPersist()

        // Release every piece of decrypted vault content, not only fields the UI happens to
        // mark sensitive. Notes, usernames, paths and even titles can be confidential too.
        for workspace in workspaces {
            Self.clearString(&workspace.name)
            Self.clearString(&workspace.icon)
            Self.clearString(&workspace.colorHex)
            Self.clearString(&workspace.notes)
            workspace.items = []
        }
        for item in items {
            Self.clearString(&item.title)
            Self.clearString(&item.typeRawValue)
            Self.clearString(&item.environmentRawValue)
            if var customName = item.customEnvironmentName {
                Self.clearString(&customName)
                item.customEnvironmentName = nil
            }
            Self.clearString(&item.notes)
            Self.clearString(&item.tagsRawValue)
            for field in item.fields {
                Self.clearString(&field.fieldKey)
                Self.clearString(&field.labelSnapshot)
                Self.clearString(&field.kindRawValue)
                Self.clearString(&field.plainValue)
                if var reference = field.secretReference {
                    Self.clearString(&reference)
                    field.secretReference = nil
                }
                for index in field.previousValues.indices {
                    field.previousValues[index].securelyClear()
                }
                field.previousValues.removeAll(keepingCapacity: false)
                field.item = nil
            }
            item.fields = []
            item.changeHistory = []
            item.ignoredHealthIssues = []
            if var linkedFile = item.linkedFile {
                if var bookmark = linkedFile.bookmark {
                    VaultCryptoService.overwrite(&bookmark)
                }
                linkedFile.bookmark = nil
                linkedFile.displayPath = ""
                linkedFile.syncedDigest = nil
                linkedFile.syncedVaultDigest = nil
                item.linkedFile = nil
            }
            item.workspace = nil
            item.template = nil
        }
        for template in customTemplates {
            Self.clearString(&template.itemTypeRawValue)
            Self.clearString(&template.name)
            for definition in template.fieldDefinitions {
                Self.clearString(&definition.key)
                Self.clearString(&definition.label)
                Self.clearString(&definition.kindRawValue)
                definition.template = nil
            }
            template.fieldDefinitions = []
        }
        workspaces = []
        items = []
        customTemplates = []
        masterPasswordHistory = []
        persistHandler = nil
    }

    private static func clearString(_ value: inout String) {
        guard !value.isEmpty else { return }
        // Swift String does not promise in-place mutable storage, but replacing the reachable
        // value with zeroes before releasing it is the strongest best-effort available here.
        value = String(repeating: "\0", count: value.utf8.count)
        value.removeAll(keepingCapacity: false)
    }

    /// Appends a master password event and persists. Called on vault creation and on every
    /// successful password change.
    func recordMasterPasswordChange(_ kind: MasterPasswordChangeKind, at date: Date = .now) {
        masterPasswordHistory.insert(MasterPasswordChangeEntry(kind: kind, changedAt: date), at: 0)
        masterPasswordHistory = Array(masterPasswordHistory.prefix(Self.masterPasswordHistoryLimit))
    }

    /// Bounded so a long-lived vault can't grow an unbounded audit trail.
    static let masterPasswordHistoryLimit = 50

    func requireUnlocked() throws {
        guard isUnlocked else { throw VaultCryptoError.vaultLocked }
    }

    func persist() throws {
        try requireUnlocked()
        deferredPersist?.cancel()
        deferredPersist = nil
        hasUnsavedDeferredChanges = false
        if transactionDepth > 0 {
            transactionNeedsPersist = true
            return
        }
        try persistHandler?()
    }

    /// Coalesces a multi-entity operation into one encrypted write and restores the exact
    /// pre-operation snapshot if either a mutation or that final write fails.
    func performTransaction<Result>(_ body: () throws -> Result) throws -> Result {
        try requireUnlocked()
        if transactionDepth > 0 {
            transactionDepth += 1
            defer { transactionDepth -= 1 }
            return try body()
        }

        let original = makeSnapshot()
        transactionDepth = 1
        transactionNeedsPersist = false
        do {
            let result = try body()
            transactionDepth = 0
            if transactionNeedsPersist {
                transactionNeedsPersist = false
                try persistHandler?()
            }
            return result
        } catch {
            transactionDepth = 0
            transactionNeedsPersist = false
            load(original)
            // The final handler may have failed after touching one of the two vault files.
            // Best effort restores a coherent encrypted copy of the original snapshot.
            try? persistHandler?()
            throw error
        }
    }

    /// Schedules a coalesced write instead of encrypting the whole vault immediately.
    ///
    /// Used for high-frequency, low-value mutations — currently only "last used" timestamps.
    /// Selecting a row used to re-encrypt and rewrite the entire vault synchronously, so
    /// holding ⌥↓ through a list meant one full AES pass and one disk write per row.
    func persistSoon() {
        guard isUnlocked else { return }
        hasUnsavedDeferredChanges = true
        deferredPersist?.cancel()
        deferredPersist = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.deferredPersistDelay))
            guard !Task.isCancelled, let self else { return }
            self.deferredPersist = nil
            guard self.hasUnsavedDeferredChanges, self.isUnlocked else { return }
            self.hasUnsavedDeferredChanges = false
            try? self.persistHandler?()
        }
    }

    /// Writes any owed coalesced changes right now. Called on lock and on app termination.
    func flushPendingPersist() {
        deferredPersist?.cancel()
        deferredPersist = nil
        guard hasUnsavedDeferredChanges, isUnlocked else {
            hasUnsavedDeferredChanges = false
            return
        }
        hasUnsavedDeferredChanges = false
        try? persistHandler?()
    }

    func discardPendingPersist() {
        deferredPersist?.cancel()
        deferredPersist = nil
        hasUnsavedDeferredChanges = false
    }

    private static let deferredPersistDelay: Double = 2

    /// Replaces the entire vault contents with the given snapshot and persists.
    func replaceContents(with snapshot: VaultSnapshot) throws {
        try performTransaction {
            load(snapshot)
            try persist()
        }
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
                sortOrder: $0.sortOrder,
                // Nil rather than [] so a workspace that declares no environment encodes
                // exactly as it did before 1.3.
                environments: $0.environments.isEmpty ? nil : $0.environments
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
                        plainValue: $0.plainValue,
                        previousValues: $0.previousValues
                    )
                }.sorted {
                    if $0.sortOrder != $1.sortOrder { return $0.sortOrder < $1.sortOrder }
                    return $0.id.uuidString < $1.id.uuidString
                },
                changeHistory: item.changeHistory,
                ignoredHealthIssues: item.ignoredHealthIssues,
                linkedFile: item.linkedFile
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
                }.sorted {
                    if $0.sortOrder != $1.sortOrder { return $0.sortOrder < $1.sortOrder }
                    return $0.id.uuidString < $1.id.uuidString
                }
            )
        }

        return VaultSnapshot(
            workspaces: workspaceSnapshots,
            items: itemSnapshots,
            customTemplates: templateSnapshots,
            masterPasswordHistory: masterPasswordHistory
        )
    }

    private func load(_ snapshot: VaultSnapshot) {
        // Snapshots can come from an imported backup file, so duplicate ids must not trap.
        // Preserve every record while keeping references deterministic: when a malformed
        // snapshot repeats an id, references to that source id resolve to its first record and
        // later records receive stable derived ids instead of being silently discarded.
        var seenWorkspaceIDs: Set<UUID> = []
        var workspaceMap: [UUID: WorkspaceEntity] = [:]
        let loadedWorkspaces = snapshot.workspaces.map { workspaceSnapshot in
            let workspaceID = Self.uniqueID(
                preferred: workspaceSnapshot.id,
                namespace: "workspace",
                seen: &seenWorkspaceIDs
            )
            let workspace = WorkspaceEntity(
                id: workspaceID,
                name: workspaceSnapshot.name,
                icon: workspaceSnapshot.icon,
                colorHex: workspaceSnapshot.colorHex,
                notes: workspaceSnapshot.notes,
                isArchived: workspaceSnapshot.isArchived,
                createdAt: workspaceSnapshot.createdAt,
                updatedAt: workspaceSnapshot.updatedAt,
                sortOrder: workspaceSnapshot.sortOrder,
                // Snapshots also arrive from imported backups, which are untrusted input even
                // after their password is accepted: clamp the list rather than store it as-is.
                environments: WorkspaceEnvironment.sanitizedList(workspaceSnapshot.environments ?? [])
            )
            if workspaceMap[workspaceSnapshot.id] == nil {
                workspaceMap[workspaceSnapshot.id] = workspace
            }
            return workspace
        }

        let builtInTemplateMap = Dictionary(
            builtInTemplates.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var seenTemplateIDs = Set(builtInTemplateMap.keys)
        var customTemplateMap: [UUID: SecretFieldTemplateEntity] = [:]
        let loadedCustomTemplates = snapshot.customTemplates.map { templateSnapshot in
            let templateID = Self.uniqueID(
                preferred: templateSnapshot.id,
                namespace: "custom-template",
                seen: &seenTemplateIDs
            )
            let template = SecretFieldTemplateEntity(
                id: templateID,
                itemType: SecretItemType(rawValue: templateSnapshot.itemTypeRawValue) ?? .customTemplate,
                name: templateSnapshot.name,
                isBuiltIn: false,
                createdAt: templateSnapshot.createdAt,
                updatedAt: templateSnapshot.updatedAt
            )
            var seenDefinitionIDs: Set<UUID> = []
            template.fieldDefinitions = templateSnapshot.fieldDefinitions.map { fieldSnapshot in
                let definitionID = Self.uniqueID(
                    preferred: fieldSnapshot.id,
                    namespace: "template-definition|\(templateID.uuidString)",
                    seen: &seenDefinitionIDs
                )
                return SecretFieldDefinitionEntity(
                    id: definitionID,
                    key: fieldSnapshot.key,
                    label: fieldSnapshot.label,
                    kind: FieldKind(rawValue: fieldSnapshot.kindRawValue) ?? .text,
                    isSensitive: fieldSnapshot.isSensitive,
                    isCopyable: fieldSnapshot.isCopyable,
                    isMaskedByDefault: fieldSnapshot.isMaskedByDefault,
                    sortOrder: fieldSnapshot.sortOrder,
                    template: template
                )
            }.sorted {
                if $0.sortOrder != $1.sortOrder { return $0.sortOrder < $1.sortOrder }
                return $0.id.uuidString < $1.id.uuidString
            }
            // A custom record may maliciously collide with a built-in id. Built-ins remain
            // authoritative; otherwise the first custom record owns the source id.
            if builtInTemplateMap[templateSnapshot.id] == nil,
               customTemplateMap[templateSnapshot.id] == nil {
                customTemplateMap[templateSnapshot.id] = template
            }
            return template
        }

        let templatesByID = builtInTemplateMap.merging(customTemplateMap) { builtIn, _ in builtIn }

        var seenItemIDs: Set<UUID> = []
        let items = snapshot.items.map { itemSnapshot in
            let itemID = Self.uniqueID(
                preferred: itemSnapshot.id,
                namespace: "item",
                seen: &seenItemIDs
            )
            let item = SecretItemEntity(
                id: itemID,
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
                template: itemSnapshot.templateID.flatMap { templatesByID[$0] },
                changeHistory: Self.uniqueChangeHistory(
                    itemSnapshot.changeHistory,
                    namespace: "item-history|\(itemID.uuidString)"
                ),
                ignoredHealthIssues: Self.uniqueIgnoredIssues(itemSnapshot.ignoredHealthIssues),
                linkedFile: itemSnapshot.linkedFile
            )
            var seenFieldIDs: Set<UUID> = []
            item.fields = itemSnapshot.fields.map { fieldSnapshot in
                let fieldID = Self.uniqueID(
                    preferred: fieldSnapshot.id,
                    namespace: "item-field|\(itemID.uuidString)",
                    seen: &seenFieldIDs
                )
                return SecretFieldValueEntity(
                    id: fieldID,
                    fieldKey: fieldSnapshot.fieldKey,
                    labelSnapshot: fieldSnapshot.labelSnapshot,
                    kind: FieldKind(rawValue: fieldSnapshot.kindRawValue) ?? .text,
                    isSensitive: fieldSnapshot.isSensitive,
                    isCopyable: fieldSnapshot.isCopyable,
                    isMasked: fieldSnapshot.isMasked,
                    sortOrder: fieldSnapshot.sortOrder,
                    plainValue: fieldSnapshot.plainValue,
                    previousValues: fieldSnapshot.isSensitive
                        ? Self.uniqueValueHistory(
                            fieldSnapshot.previousValues,
                            namespace: "value-history|\(itemID.uuidString)|\(fieldID.uuidString)"
                        )
                        : [],
                    item: item
                )
            }.sorted {
                if $0.sortOrder != $1.sortOrder { return $0.sortOrder < $1.sortOrder }
                return $0.id.uuidString < $1.id.uuidString
            }
            return item
        }

        var orderedWorkspaces = loadedWorkspaces.sorted {
            if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
            return $0.id.uuidString < $1.id.uuidString
        }
        if orderedWorkspaces.count > 1, orderedWorkspaces.allSatisfy({ $0.sortOrder == 0 }) {
            for (index, ws) in orderedWorkspaces.enumerated() {
                ws.sortOrder = index
            }
        }
        orderedWorkspaces.sort {
            if $0.sortOrder != $1.sortOrder { return $0.sortOrder < $1.sortOrder }
            return $0.id.uuidString < $1.id.uuidString
        }
        workspaces = orderedWorkspaces
        self.items = items
        customTemplates = loadedCustomTemplates.sorted {
            let comparison = $0.name.localizedCaseInsensitiveCompare($1.name)
            if comparison != .orderedSame { return comparison == .orderedAscending }
            return $0.id.uuidString < $1.id.uuidString
        }
        masterPasswordHistory = Self.uniqueMasterPasswordHistory(
            snapshot.masterPasswordHistory,
            namespace: "master-password-history"
        )

        for workspace in workspaces {
            workspace.items = items
                .filter { $0.workspace?.id == workspace.id }
                .sorted { $0.updatedAt > $1.updatedAt }
        }
    }

    /// Produces the same canonical representation used after an unlock without touching the
    /// live entity graph. Backup merge uses this so importing one malformed-but-decodable
    /// file twice remains idempotent even when ids or history entries had to be repaired.
    func normalizedSnapshotCopy(_ snapshot: VaultSnapshot) -> VaultSnapshot {
        let normalizer = VaultMemoryStore(builtInTemplates: builtInTemplates)
        normalizer.activate(snapshot: snapshot, persistHandler: {})
        var normalized = normalizer.makeSnapshot()
        normalized.privateSidebarTagsOrder = snapshot.privateSidebarTagsOrder
        normalized.privateSidebarEnvironmentsOrder = snapshot.privateSidebarEnvironmentsOrder
        normalizer.clear()
        return normalized
    }

    private static func uniqueID(
        preferred: UUID,
        namespace: String,
        seen: inout Set<UUID>
    ) -> UUID {
        if seen.insert(preferred).inserted { return preferred }

        var attempt = 1
        while true {
            let input = Data("\(namespace)|\(preferred.uuidString)|\(attempt)".utf8)
            var bytes = Array(SHA256.hash(data: input).prefix(16))
            bytes[6] = (bytes[6] & 0x0F) | 0x50
            bytes[8] = (bytes[8] & 0x3F) | 0x80
            let candidate = UUID(uuid: (
                bytes[0], bytes[1], bytes[2], bytes[3],
                bytes[4], bytes[5], bytes[6], bytes[7],
                bytes[8], bytes[9], bytes[10], bytes[11],
                bytes[12], bytes[13], bytes[14], bytes[15]
            ))
            if seen.insert(candidate).inserted { return candidate }
            attempt += 1
        }
    }

    private static func uniqueValueHistory(
        _ values: [SecretValueVersion],
        namespace: String
    ) -> [SecretValueVersion] {
        var seen: Set<UUID> = []
        return values
            .enumerated()
            .sorted {
                if $0.element.replacedAt != $1.element.replacedAt {
                    return $0.element.replacedAt > $1.element.replacedAt
                }
                return $0.offset < $1.offset
            }
            .prefix(SecretItemRepository.valueHistoryLimit)
            .map { indexed in
                let value = indexed.element
                let id = uniqueID(preferred: value.id, namespace: namespace, seen: &seen)
                guard id != value.id else { return value }
                return SecretValueVersion(id: id, value: value.value, replacedAt: value.replacedAt)
            }
    }

    private static func uniqueChangeHistory(
        _ entries: [SecretItemChangeEntry],
        namespace: String
    ) -> [SecretItemChangeEntry] {
        var seen: Set<UUID> = []
        return entries
            .enumerated()
            .sorted {
                if $0.element.changedAt != $1.element.changedAt {
                    return $0.element.changedAt > $1.element.changedAt
                }
                return $0.offset < $1.offset
            }
            .prefix(SecretItemRepository.historyLimit)
            .map { indexed in
                let entry = indexed.element
                let id = uniqueID(preferred: entry.id, namespace: namespace, seen: &seen)
                guard id != entry.id else { return entry }
                return SecretItemChangeEntry(
                    id: id,
                    kind: entry.kind,
                    changedAt: entry.changedAt,
                    detail: entry.detail
                )
            }
    }

    private static func uniqueIgnoredIssues(_ issues: [IgnoredHealthIssue]) -> [IgnoredHealthIssue] {
        var seen: Set<String> = []
        var result: [IgnoredHealthIssue] = []
        for issue in issues where seen.insert(issue.id).inserted {
            result.append(issue)
            if result.count == 500 { break }
        }
        return result
    }

    private static func uniqueMasterPasswordHistory(
        _ entries: [MasterPasswordChangeEntry],
        namespace: String
    ) -> [MasterPasswordChangeEntry] {
        var seen: Set<UUID> = []
        return entries
            .enumerated()
            .sorted {
                if $0.element.changedAt != $1.element.changedAt {
                    return $0.element.changedAt > $1.element.changedAt
                }
                return $0.offset < $1.offset
            }
            .prefix(Self.masterPasswordHistoryLimit)
            .map { indexed in
                let entry = indexed.element
                let id = uniqueID(preferred: entry.id, namespace: namespace, seen: &seen)
                guard id != entry.id else { return entry }
                return MasterPasswordChangeEntry(id: id, kind: entry.kind, changedAt: entry.changedAt)
            }
    }
}

final class FileEncryptedVaultStore: EncryptedVaultStore {
    private static let maximumVaultFileSize = 256 * 1_024 * 1_024
    private let directoryURL: URL
    private let envelopeURL: URL
    private let metadataURL: URL
    private let primaryPackageURL: URL
    private var cachedPrimaryPackage: PrimaryPackage?

    private struct PrimaryPackage: Codable {
        let metadata: VaultMetadata
        let envelope: VaultEnvelope
    }

    init(fileManager: FileManager = .default, baseDirectory: URL? = nil, bundleIdentifier: String = Bundle.main.bundleIdentifier ?? "app.makio.PassStore") {
        let rootDirectory = baseDirectory
            ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                .appendingPathComponent(bundleIdentifier, isDirectory: true)
        self.directoryURL = rootDirectory
        self.envelopeURL = rootDirectory.appendingPathComponent("vault.enc", isDirectory: false)
        self.metadataURL = rootDirectory.appendingPathComponent("vault.meta", isDirectory: false)
        self.primaryPackageURL = rootDirectory.appendingPathComponent("vault.package", isDirectory: false)
    }

    func hasVault() -> Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: primaryPackageURL.path)
            || (fm.fileExists(atPath: envelopeURL.path) && fm.fileExists(atPath: metadataURL.path))
    }

    func loadMetadata() throws -> VaultMetadata {
        if let package = try loadPrimaryPackageIfPresent() {
            return package.metadata
        }
        let data = try readBoundedData(from: metadataURL)
        return try JSONDecoder.vaultDecoder.decode(VaultMetadata.self, from: data)
    }

    func loadEnvelope() throws -> VaultEnvelope {
        if let package = try loadPrimaryPackageIfPresent() {
            return package.envelope
        }
        let data = try readBoundedData(from: envelopeURL)
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
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directoryURL.path)
        let packageData = try JSONEncoder.vaultEncoder.encode(
            PrimaryPackage(metadata: metadata, envelope: envelope)
        )
        guard packageData.count <= Self.maximumVaultFileSize else {
            throw VaultCryptoError.vaultContentsTooLarge
        }
        let metadataData = try JSONEncoder.vaultEncoder.encode(metadata)
        let envelopeData = try JSONEncoder.vaultEncoder.encode(envelope)

        // This package is authoritative. One atomic rename means metadata (including the
        // wrapped master key) and ciphertext can never come from different save attempts.
        try writeOwnerOnlyAtomically(packageData, to: primaryPackageURL)
        cachedPrimaryPackage = PrimaryPackage(metadata: metadata, envelope: envelope)

        // Keep the 1.1.1 pair as a best-effort downgrade mirror. A mirror failure must not
        // turn an already durable package save into a reported failure or trigger rollback.
        do {
            try writeOwnerOnlyAtomically(metadataData, to: metadataURL)
            try writeOwnerOnlyAtomically(envelopeData, to: envelopeURL)
        } catch {
            // The package above remains complete and is always preferred by this version.
        }
    }

    func resetSecureVault() throws {
        cachedPrimaryPackage = nil
        // Try every target even if one deletion fails, then report the first failure. Erase
        // must not silently leave a rollback copy or half of the primary vault behind.
        var targets = [
            envelopeURL,
            metadataURL,
            primaryPackageURL,
            rollbackPackageURL,
            rollbackEnvelopeURL,
            rollbackMetadataURL,
        ]
        if let candidates = try? FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil
        ) {
            targets.append(contentsOf: candidates.filter { url in
                let name = url.lastPathComponent
                return name.hasPrefix(".vault.") && name.hasSuffix(".tmp")
            })
        }
        try removeExistingFiles(targets)
    }

    // MARK: - Rollback copy

    private var rollbackEnvelopeURL: URL { directoryURL.appendingPathComponent("vault.enc.rollback", isDirectory: false) }
    private var rollbackMetadataURL: URL { directoryURL.appendingPathComponent("vault.meta.rollback", isDirectory: false) }
    private var rollbackPackageURL: URL { directoryURL.appendingPathComponent("vault.rollback", isDirectory: false) }

    private struct RollbackPackage: Codable {
        let metadata: VaultMetadata
        let envelope: VaultEnvelope
        /// Present in all newly written packages.
        let settingsEnvelope: VaultEnvelope?
        /// Decode-only compatibility with pre-release 1.2 packages. Kept optional so new
        /// packages serialize `null`, never the owner's tags or environment names.
        let settings: ExportedSettingsPayload?
        let takenAt: Date

        init(
            metadata: VaultMetadata,
            envelope: VaultEnvelope,
            settingsEnvelope: VaultEnvelope,
            takenAt: Date
        ) {
            self.metadata = metadata
            self.envelope = envelope
            self.settingsEnvelope = settingsEnvelope
            self.settings = nil
            self.takenAt = takenAt
        }
    }

    /// Snapshots the on-disk vault before a destructive operation (currently: restoring a
    /// backup). The copy stays encrypted with the same key, so this adds no new exposure —
    /// it only means "replace my whole vault" is survivable across a relaunch.
    func writeRollbackCopy(settingsEnvelope: VaultEnvelope) throws {
        guard hasVault() else {
            throw VaultCryptoError.metadataMissing
        }
        let package = RollbackPackage(
            metadata: try loadMetadata(),
            envelope: try loadEnvelope(),
            settingsEnvelope: settingsEnvelope,
            takenAt: .now
        )
        let data = try JSONEncoder.vaultEncoder.encode(package)
        guard data.count <= Self.maximumVaultFileSize else {
            throw VaultCryptoError.vaultContentsTooLarge
        }
        // One atomic package prevents a crash between copying metadata and ciphertext from
        // leaving a mismatched rollback pair. The old rollback remains valid until this write
        // has succeeded.
        try writeOwnerOnlyAtomically(data, to: rollbackPackageURL)
        try removeExistingFiles([rollbackEnvelopeURL, rollbackMetadataURL])
    }

    func rollbackCopyDate() -> Date? {
        let fm = FileManager.default
        if let data = try? readBoundedData(from: rollbackPackageURL),
           let package = try? JSONDecoder.vaultDecoder.decode(RollbackPackage.self, from: data) {
            return package.takenAt
        }
        guard fm.fileExists(atPath: rollbackEnvelopeURL.path), fm.fileExists(atPath: rollbackMetadataURL.path) else {
            return nil
        }
        return (try? fm.attributesOfItem(atPath: rollbackEnvelopeURL.path)[.modificationDate]) as? Date
    }

    @discardableResult
    func restoreRollbackCopy() throws -> RollbackSettingsPayload? {
        let fm = FileManager.default
        let metadata: VaultMetadata
        let envelope: VaultEnvelope
        let settings: RollbackSettingsPayload?
        if fm.fileExists(atPath: rollbackPackageURL.path) {
            let data = try readBoundedData(from: rollbackPackageURL)
            let package = try JSONDecoder.vaultDecoder.decode(RollbackPackage.self, from: data)
            metadata = package.metadata
            envelope = package.envelope
            if let settingsEnvelope = package.settingsEnvelope {
                settings = .encrypted(settingsEnvelope)
            } else if let legacySettings = package.settings {
                settings = .legacyPlaintext(legacySettings)
            } else {
                settings = nil
            }
        } else {
            // Read the 1.2 beta's two-file format once so existing rollback copies remain useful.
            guard fm.fileExists(atPath: rollbackEnvelopeURL.path), fm.fileExists(atPath: rollbackMetadataURL.path) else {
                throw VaultCryptoError.metadataMissing
            }
            metadata = try JSONDecoder.vaultDecoder.decode(
                VaultMetadata.self,
                from: readBoundedData(from: rollbackMetadataURL)
            )
            envelope = try JSONDecoder.vaultDecoder.decode(
                VaultEnvelope.self,
                from: readBoundedData(from: rollbackEnvelopeURL)
            )
            settings = nil
        }
        try save(metadata: metadata, envelope: envelope)
        // The session discards the copy only after settings and biometric state have also
        // been restored. Until then it remains a valid recovery point.
        return settings
    }

    func discardRollbackCopy() throws {
        try removeExistingFiles([rollbackPackageURL, rollbackEnvelopeURL, rollbackMetadataURL])
    }

    func resetLegacyArtifacts() throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: directoryURL.path) else { return }
        let candidates = try fileManager.contentsOfDirectory(at: directoryURL, includingPropertiesForKeys: nil)
        let legacyURLs = candidates.filter { url in
            url.lastPathComponent.hasSuffix(".store")
            || url.lastPathComponent.hasSuffix(".store-shm")
            || url.lastPathComponent.hasSuffix(".store-wal")
            || url.lastPathComponent == "default.store"
            || url.lastPathComponent == "default.store-shm"
            || url.lastPathComponent == "default.store-wal"
        }
        try removeExistingFiles(legacyURLs)
    }

    private func removeExistingFiles(_ urls: [URL]) throws {
        let fileManager = FileManager.default
        var firstFailure: Error?
        for url in urls where fileManager.fileExists(atPath: url.path) {
            do {
                try fileManager.removeItem(at: url)
            } catch {
                if firstFailure == nil { firstFailure = error }
            }
        }
        if let firstFailure { throw firstFailure }
    }

    /// The atomic package is authoritative whenever it exists. Compatibility mirrors are
    /// accepted only when no package has ever been written (a genuine 1.1.1 vault); silently
    /// falling back after a corrupt package could combine stale/mismatched mirror generations
    /// and turn detected corruption into an unexplained rollback or failed authentication.
    private func loadPrimaryPackageIfPresent() throws -> PrimaryPackage? {
        if let cachedPrimaryPackage { return cachedPrimaryPackage }
        let fm = FileManager.default
        guard fm.fileExists(atPath: primaryPackageURL.path) else { return nil }
        let data = try readBoundedData(from: primaryPackageURL)
        let package = try JSONDecoder.vaultDecoder.decode(PrimaryPackage.self, from: data)
        cachedPrimaryPackage = package
        return package
    }

    /// Writes a fully flushed 0600 temporary file and only then atomically renames it over the
    /// destination. Applying permissions after `Data.write(.atomic)` leaves a bad edge case:
    /// chmod can fail after the new vault is already live, making callers roll memory back while
    /// disk contains the newer state.
    private func writeOwnerOnlyAtomically(_ data: Data, to destination: URL) throws {
        let fm = FileManager.default
        let temporary = directoryURL.appendingPathComponent(
            ".\(destination.lastPathComponent).\(UUID().uuidString).tmp",
            isDirectory: false
        )
        guard fm.createFile(
            atPath: temporary.path,
            contents: nil,
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw CocoaError(.fileWriteUnknown)
        }

        do {
            let handle = try FileHandle(forWritingTo: temporary)
            do {
                try handle.write(contentsOf: data)
                try handle.synchronize()
                try handle.close()
            } catch {
                try? handle.close()
                throw error
            }
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)

            let result = temporary.path.withCString { source in
                destination.path.withCString { target in
                    Darwin.rename(source, target)
                }
            }
            guard result == 0 else {
                let code = errno
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
            }
        } catch {
            if fm.fileExists(atPath: temporary.path) {
                try? fm.removeItem(at: temporary)
            }
            throw error
        }
    }

    private func readBoundedData(from url: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: Self.maximumVaultFileSize + 1) ?? Data()
        guard data.count <= Self.maximumVaultFileSize else {
            throw VaultCryptoError.vaultContentsTooLarge
        }
        return data
    }
}

final class InMemoryEncryptedVaultStore: EncryptedVaultStore {
    private var metadata: VaultMetadata?
    private var envelope: VaultEnvelope?
    private var rollback: (metadata: VaultMetadata, envelope: VaultEnvelope, settingsEnvelope: VaultEnvelope, takenAt: Date)?

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
        rollback = nil
    }

    func resetLegacyArtifacts() throws {}

    func writeRollbackCopy(settingsEnvelope: VaultEnvelope) throws {
        guard let metadata, let envelope else { throw VaultCryptoError.metadataMissing }
        rollback = (metadata, envelope, settingsEnvelope, Date())
    }

    func rollbackCopyDate() -> Date? { rollback?.takenAt }

    @discardableResult
    func restoreRollbackCopy() throws -> RollbackSettingsPayload? {
        guard let rollback else { throw VaultCryptoError.metadataMissing }
        metadata = rollback.metadata
        envelope = rollback.envelope
        return .encrypted(rollback.settingsEnvelope)
    }

    func discardRollbackCopy() throws {
        rollback = nil
    }
}

private extension JSONEncoder {
    nonisolated static var vaultEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

private extension JSONDecoder {
    nonisolated static var vaultDecoder: JSONDecoder { JSONDecoder() }
}
