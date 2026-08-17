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

protocol WorkspaceRepositoryProtocol: AnyObject {
    func fetchAll(includeArchived: Bool) throws -> [WorkspaceEntity]
    @discardableResult func saveWorkspace(_ draft: WorkspaceDraft) throws -> WorkspaceEntity
    @discardableResult func setEnvironments(
        _ environments: [WorkspaceEnvironment],
        onWorkspaceWithID id: UUID
    ) throws -> [WorkspaceEnvironment]
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
