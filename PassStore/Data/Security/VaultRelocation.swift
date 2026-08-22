import Foundation

/// Moves the vault to a folder of the owner's choosing, and opens one that is already there.
///
/// Two separate operations on purpose. "Put my vault in this folder" and "open the vault that is
/// in this folder" look similar in a file picker and could not be less alike in what they do to
/// your data — one writes, one adopts, and guessing which was meant is not a risk worth taking
/// with the only copy of somebody's secrets.
@MainActor
final class VaultRelocationService {
    private let locationStore: VaultLocationStore
    private let sessionManager: VaultSessionManager
    private let vaultStore: EncryptedVaultStore

    init(
        locationStore: VaultLocationStore,
        sessionManager: VaultSessionManager,
        vaultStore: EncryptedVaultStore
    ) {
        self.locationStore = locationStore
        self.sessionManager = sessionManager
        self.vaultStore = vaultStore
    }

    /// False for the in-memory store used by previews and tests, which has no folder to move.
    var canRelocate: Bool { vaultStore is RelocatableVaultStore }

    private var relocatable: RelocatableVaultStore? { vaultStore as? RelocatableVaultStore }

    var currentDirectoryPath: String { locationStore.displayPath }
    var isUsingCustomDirectory: Bool { locationStore.isUsingCustomDirectory }
    var locationProblem: VaultLocationProblem? { locationStore.problem }

    /// True when `folder` already holds a vault.
    func folderHoldsVault(_ folder: URL) -> Bool {
        FileManager.default.fileExists(
            atPath: folder.appendingPathComponent("vault.package", isDirectory: false).path
        )
    }

    // MARK: - Moving this vault

    /// Copies this vault into `folder`, proves the copy opens, and only then removes the original.
    ///
    /// Requires an unlocked vault, because "proves the copy opens" means decrypting it. Verifying
    /// the bytes match would prove the copy is faithful and nothing about whether it is usable.
    func moveVault(to folder: URL) throws {
        guard let relocatable else { throw VaultCryptoError.vaultLocked }
        guard sessionManager.lockState == .unlocked else { throw VaultCryptoError.vaultLocked }
        guard !folderHoldsVault(folder) else { throw VaultCryptoError.vaultAlreadyPresentInFolder }

        let origin = relocatable.currentDirectory
        guard folder.standardizedFileURL != origin.standardizedFileURL else { return }

        // Anything still owed from this session belongs in the file that is about to be copied.
        sessionManager.flushPendingWrites()

        let copied = try relocatable.copyArtifacts(to: folder)

        relocatable.relocate(to: folder)
        do {
            try sessionManager.verifyOnDiskVaultReadable()
            try locationStore.adoptCustomDirectory(folder)
            // One real save in the new home: it confirms the folder is writable now rather than
            // at some later moment when the owner is in the middle of something.
            try sessionManager.saveCurrentVault()
        } catch {
            // Nothing has been deleted yet, so going back is only a matter of pointing at the
            // folder that still holds the working vault.
            relocatable.relocate(to: origin)
            for url in copied { try? FileManager.default.removeItem(at: url) }
            throw error
        }

        // The move is complete and verified; the copy left behind is now a stale duplicate of a
        // vault that has moved on, which is worse than no copy at all.
        let departed = FileEncryptedVaultStore(baseDirectory: origin)
        try? departed.removeArtifactsFromCurrentDirectory()
    }

    /// Puts the vault back in Application Support.
    func moveVaultToDefaultLocation() throws {
        guard let relocatable else { throw VaultCryptoError.vaultLocked }
        let target = locationStore.defaultDirectory
        guard relocatable.currentDirectory.standardizedFileURL != target.standardizedFileURL else {
            locationStore.forgetCustomDirectory()
            return
        }
        guard sessionManager.lockState == .unlocked else { throw VaultCryptoError.vaultLocked }

        sessionManager.flushPendingWrites()
        let origin = relocatable.currentDirectory
        let copied = try relocatable.copyArtifacts(to: target)

        relocatable.relocate(to: target)
        do {
            try sessionManager.verifyOnDiskVaultReadable()
            locationStore.forgetCustomDirectory()
            try sessionManager.saveCurrentVault()
        } catch {
            relocatable.relocate(to: origin)
            for url in copied { try? FileManager.default.removeItem(at: url) }
            throw error
        }

        let departed = FileEncryptedVaultStore(baseDirectory: origin)
        try? departed.removeArtifactsFromCurrentDirectory()
    }

    // MARK: - Opening a vault that is already somewhere

    /// Points PassStore at an existing vault and locks, so it can be unlocked with its own
    /// password.
    ///
    /// This is the second Mac. Nothing is copied and nothing is written: the vault in that folder
    /// is already whole, and this install has no business assuming its key is the right one.
    func openVault(in folder: URL) throws {
        guard let relocatable else { throw VaultCryptoError.vaultLocked }
        guard folderHoldsVault(folder) else { throw VaultCryptoError.noVaultInFolder }

        let origin = relocatable.currentDirectory
        // Locking first drops the plaintext of the vault being left behind. Adopting a different
        // vault while the previous one is still unlocked in memory is how a save ends up writing
        // one vault's contents into another's file.
        sessionManager.lock()

        relocatable.relocate(to: folder)
        do {
            try locationStore.adoptCustomDirectory(folder)
        } catch {
            relocatable.relocate(to: origin)
            throw error
        }
        sessionManager.refreshAfterVaultFileChange()
    }
}
