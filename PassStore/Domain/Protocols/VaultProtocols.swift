import Foundation

nonisolated enum RollbackSettingsPayload: Sendable {
    case encrypted(VaultEnvelope)
    /// Compatibility with rollback files created by pre-release 1.2 builds. New rollback
    /// packages never write settings in plaintext.
    case legacyPlaintext(ExportedSettingsPayload)
}

nonisolated protocol VaultKeyStore: AnyObject, Sendable {
    var isBiometricHardwareAvailable: Bool { get }
    func saveVaultKey(_ key: Data, requireBiometrics: Bool) throws
    func readVaultKey(prompt: String) throws -> Data
    func deleteVaultKey() throws
    func clearLegacySecrets() throws
}

protocol EncryptedVaultStore: AnyObject {
    func hasVault() -> Bool
    func loadMetadata() throws -> VaultMetadata
    /// Metadata as it is on disk right now, ignoring anything this process has cached.
    ///
    /// The cached read is right for everything else — it is this process's own last write. It is
    /// exactly wrong for asking "did somebody else write this file?", which is the one question
    /// that must not be answered from memory.
    func loadMetadataFromStorage() throws -> VaultMetadata
    func loadEnvelope() throws -> VaultEnvelope
    func save(metadata: VaultMetadata, envelope: VaultEnvelope) throws
    func resetSecureVault() throws
    func resetLegacyArtifacts() throws

    /// Copies the current vault aside so a destructive operation can be undone after a relaunch.
    /// Still encrypted with the same vault key — this is a copy, not a decryption.
    func writeRollbackCopy(settingsEnvelope: VaultEnvelope) throws
    /// When the rollback copy was taken, or nil if there isn't one.
    func rollbackCopyDate() -> Date?
    /// Puts the rollback copy back in place. Throws if there is none.
    @discardableResult func restoreRollbackCopy() throws -> RollbackSettingsPayload?
    func discardRollbackCopy() throws
}

extension EncryptedVaultStore {
    /// A store that caches nothing reads the same either way, so only the file-backed store —
    /// the one that does cache — has to say anything different.
    func loadMetadataFromStorage() throws -> VaultMetadata {
        try loadMetadata()
    }
}

/// A vault store whose files live in a folder the owner can choose.
///
/// Separate from `EncryptedVaultStore` because the in-memory store used by tests and previews has
/// no folder to move, and giving it one would be a lie the compiler would then insist on.
protocol RelocatableVaultStore: AnyObject {
    var currentDirectory: URL { get }
    /// Copies the vault into `destination`, leaving the originals in place.
    @discardableResult func copyArtifacts(to destination: URL) throws -> [URL]
    /// Deletes the vault files from wherever the store points now.
    func removeArtifactsFromCurrentDirectory() throws
    /// Points the store at another folder for all subsequent reads and writes.
    func relocate(to destination: URL)
}

protocol WorkspaceRepositoryProtocol: AnyObject {
    func fetchAll(includeArchived: Bool) throws -> [WorkspaceEntity]
    @discardableResult func saveWorkspace(_ draft: WorkspaceDraft) throws -> WorkspaceEntity
    @discardableResult func setEnvironments(
        _ environments: [WorkspaceEnvironment],
        onWorkspaceWithID id: UUID
    ) throws -> [WorkspaceEnvironment]
    func setLinkedFolder(_ folder: LinkedFolderReference?, onWorkspaceWithID id: UUID) throws
    func reorderWorkspaces(_ ids: [UUID]) throws
    func deleteWorkspace(_ workspace: WorkspaceEntity) throws
}

protocol SecretItemRepositoryProtocol: AnyObject {
    func fetchAll(includeArchived: Bool) throws -> [SecretItemEntity]
    func resolveFields(for item: SecretItemEntity) throws -> [FieldResolvedValue]
    @discardableResult func saveItem(_ draft: SecretItemDraft) throws -> SecretItemEntity
    /// Updates `lastAccessedAt` and persists without bumping `updatedAt` (so “Recent” sort stays creation/edit based).
    func recordItemAccess(_ item: SecretItemEntity) throws
    @discardableResult func duplicateItem(_ item: SecretItemEntity) throws -> SecretItemEntity
    func deleteItem(_ item: SecretItemEntity) throws
}

protocol TemplateRepositoryProtocol: AnyObject {
    func fetchAll() throws -> [SecretFieldTemplateEntity]
    func seedBuiltInsIfNeeded() throws
    @discardableResult func saveTemplate(_ draft: TemplateDraft, isBuiltIn: Bool) throws -> SecretFieldTemplateEntity
    func deleteTemplate(_ template: SecretFieldTemplateEntity) throws
}
