import Foundation

protocol VaultKeyStore: AnyObject {
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
}

protocol WorkspaceRepositoryProtocol: AnyObject {
    func fetchAll(includeArchived: Bool) throws -> [WorkspaceEntity]
    @discardableResult func saveWorkspace(_ draft: WorkspaceDraft) throws -> WorkspaceEntity
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
