import Foundation
import Testing
@testable import PassStore

/// A vault kept in a folder something else syncs can be open on two Macs at once, and neither can
/// see the other. Nothing here is about the syncing — PassStore does none — and everything is about
/// the one thing that goes wrong when it happens: the second save quietly throwing away the first.
@MainActor
struct VaultLocationTests {

    // MARK: - Harness

    /// A folder-backed vault with a cheap KDF and no Keychain, plus a location store whose
    /// bookmarks are plain paths — security-scoped bookmarks need a real user selection and cannot
    /// be made in a test.
    private static func makeContainer(
        directory: URL,
        suite: String = UUID().uuidString
    ) -> AppContainer {
        AppContainer(
            inMemory: true,
            defaults: UserDefaults(suiteName: "VaultLocationTests-\(suite)")!,
            keyStore: InMemoryVaultKeyStore(isBiometricHardwareAvailable: false),
            encryptedVaultStore: FileEncryptedVaultStore(baseDirectory: directory),
            locationStore: makeLocationStore(defaultDirectory: directory, suite: suite)
        )
    }

    private static func makeLocationStore(
        defaultDirectory: URL,
        suite: String
    ) -> VaultLocationStore {
        VaultLocationStore(
            defaults: UserDefaults(suiteName: "VaultLocationTests-loc-\(suite)")!,
            defaultDirectory: defaultDirectory,
            makeBookmark: { Data($0.path.utf8) },
            resolveBookmark: { (URL(fileURLWithPath: String(decoding: $0, as: UTF8.self)), false) },
            beginAccess: { _ in true },
            endAccess: { _ in }
        )
    }

    private static func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("passstore-location-\(UUID().uuidString)", isDirectory: true)
    }

    private static func draft(_ title: String) -> SecretItemDraft {
        var draft = SecretItemDraft.empty
        draft.title = title
        return draft
    }

    // MARK: - The write marker

    @Test func everySaveMovesTheWriteCounterForward() throws {
        let directory = Self.temporaryDirectory()
        let container = Self.makeContainer(directory: directory)
        container.sessionManager.createVaultSynchronously(password: "location-test")

        let store = FileEncryptedVaultStore(baseDirectory: directory)
        let afterCreation = try store.loadMetadata().writeCounter
        #expect(afterCreation > 0)

        _ = try container.itemRepository.saveItem(Self.draft("First"))
        let afterFirst = try FileEncryptedVaultStore(baseDirectory: directory).loadMetadata().writeCounter
        #expect(afterFirst > afterCreation)

        _ = try container.itemRepository.saveItem(Self.draft("Second"))
        let afterSecond = try FileEncryptedVaultStore(baseDirectory: directory).loadMetadata().writeCounter
        #expect(afterSecond > afterFirst)
    }

    @Test func theWriterIsRecordedWithoutNamingTheMachine() throws {
        let directory = Self.temporaryDirectory()
        let container = Self.makeContainer(directory: directory)
        container.sessionManager.createVaultSynchronously(password: "location-test")

        let metadata = try FileEncryptedVaultStore(baseDirectory: directory).loadMetadata()
        let writer = try #require(metadata.lastWriterID)
        #expect(UUID(uuidString: writer) != nil)
        // The plaintext metadata file must not carry anything that identifies the Mac.
        #expect(!writer.contains(ProcessInfo.processInfo.hostName))
    }

    /// A vault written by 1.3 or earlier has no counter at all, and must still open.
    @Test func metadataWithoutACounterDecodesAtZero() throws {
        let legacy = """
        {"version":1,"biometricUnlockEnabled":false,"updatedAt":0,
         "wrappedVaultKey":{"salt":"c2FsdA==","iterations":1,"nonce":"bm9uY2U=","ciphertext":"Yw==","tag":"dA=="}}
        """
        // The same plain decoder the vault store uses.
        let metadata = try JSONDecoder().decode(VaultMetadata.self, from: Data(legacy.utf8))
        #expect(metadata.writeCounter == 0)
        #expect(metadata.lastWriterID == nil)
    }

    // MARK: - Two Macs, one vault

    /// The case this whole mechanism exists for: the other Mac saved first, and this one must not
    /// paper over it.
    @Test func aSaveIsRefusedWhenSomethingElseWroteTheVaultFirst() throws {
        let directory = Self.temporaryDirectory()
        let container = Self.makeContainer(directory: directory)
        container.sessionManager.createVaultSynchronously(password: "location-test")
        _ = try container.itemRepository.saveItem(Self.draft("Mine"))

        try Self.simulateForeignWrite(in: directory)

        #expect(throws: VaultCryptoError.vaultChangedElsewhere) {
            try container.sessionManager.saveCurrentVault()
        }
        #expect(container.sessionManager.hasForeignChange)
    }

    @Test func takingTheOtherVersionReplacesWhatThisSessionHeld() throws {
        let directory = Self.temporaryDirectory()
        let first = Self.makeContainer(directory: directory, suite: "first")
        first.sessionManager.createVaultSynchronously(password: "location-test")
        _ = try first.itemRepository.saveItem(Self.draft("Written Here"))

        // A second install opening the same folder is exactly the second Mac.
        let second = Self.makeContainer(directory: directory, suite: "second")
        #expect(second.sessionManager.unlockWithPasswordSynchronously("location-test"))
        _ = try second.itemRepository.saveItem(Self.draft("Written There"))

        // The first session is now stale and knows it.
        #expect(throws: VaultCryptoError.vaultChangedElsewhere) {
            try first.sessionManager.saveCurrentVault()
        }

        try first.sessionManager.reloadFromDisk()
        let titles = try first.itemRepository.fetchAll(includeArchived: true).map(\.title)
        #expect(titles.contains("Written There"))
        #expect(!first.sessionManager.hasForeignChange)
        // Saving again is fine now: this session is holding the current version.
        try first.sessionManager.saveCurrentVault()
    }

    @Test func keepingThisVersionWritesOverTheOtherOne() throws {
        let directory = Self.temporaryDirectory()
        let first = Self.makeContainer(directory: directory, suite: "first")
        first.sessionManager.createVaultSynchronously(password: "location-test")
        _ = try first.itemRepository.saveItem(Self.draft("Keep Me"))

        let second = Self.makeContainer(directory: directory, suite: "second")
        #expect(second.sessionManager.unlockWithPasswordSynchronously("location-test"))
        _ = try second.itemRepository.saveItem(Self.draft("Discard Me"))

        #expect(throws: VaultCryptoError.vaultChangedElsewhere) {
            try first.sessionManager.saveCurrentVault()
        }

        try first.sessionManager.overwriteForeignChange()

        // Read the folder back with a third, innocent session.
        let third = Self.makeContainer(directory: directory, suite: "third")
        #expect(third.sessionManager.unlockWithPasswordSynchronously("location-test"))
        let titles = try third.itemRepository.fetchAll(includeArchived: true).map(\.title)
        #expect(titles.contains("Keep Me"))
        #expect(!titles.contains("Discard Me"))
    }

    /// A sync client that restores an older copy makes the counter go *down*. That is still "not
    /// what this session read", and must be reported rather than silently overwritten.
    @Test func aVaultThatWentBackwardsIsAlsoTreatedAsAConflict() throws {
        let directory = Self.temporaryDirectory()
        let container = Self.makeContainer(directory: directory)
        container.sessionManager.createVaultSynchronously(password: "location-test")
        _ = try container.itemRepository.saveItem(Self.draft("Present"))

        try Self.rewriteWriteCounter(in: directory, to: 0)

        #expect(throws: VaultCryptoError.vaultChangedElsewhere) {
            try container.sessionManager.saveCurrentVault()
        }
    }

    /// Unlocking a vault whose counter is not what this install last wrote is normal — it is what
    /// happens every time the other Mac has been working — and must not look like a conflict.
    @Test func unlockingAVaultSomebodyElseWroteIsNotAConflict() throws {
        let directory = Self.temporaryDirectory()
        let container = Self.makeContainer(directory: directory)
        container.sessionManager.createVaultSynchronously(password: "location-test")
        _ = try container.itemRepository.saveItem(Self.draft("Before Lock"))
        container.sessionManager.lock()

        try Self.simulateForeignWrite(in: directory)

        #expect(container.sessionManager.unlockWithPasswordSynchronously("location-test"))
        #expect(!container.sessionManager.hasForeignChange)
        try container.sessionManager.saveCurrentVault()
    }

    // MARK: - Moving the vault

    @Test func movingTheVaultCarriesItAcrossAndClearsTheOldFolder() throws {
        let origin = Self.temporaryDirectory()
        let destination = Self.temporaryDirectory()
        let container = Self.makeContainer(directory: origin)
        container.sessionManager.createVaultSynchronously(password: "location-test")
        _ = try container.itemRepository.saveItem(Self.draft("Travelling"))

        try container.relocation.moveVault(to: destination)

        let fm = FileManager.default
        #expect(fm.fileExists(atPath: destination.appendingPathComponent("vault.package").path))
        #expect(!fm.fileExists(atPath: origin.appendingPathComponent("vault.package").path))
        #expect(container.relocation.isUsingCustomDirectory)

        // And the vault in the new folder is a working vault, not just the right bytes.
        let reopened = Self.makeContainer(directory: destination, suite: "reopened")
        #expect(reopened.sessionManager.unlockWithPasswordSynchronously("location-test"))
        let titles = try reopened.itemRepository.fetchAll(includeArchived: true).map(\.title)
        #expect(titles.contains("Travelling"))
    }

    /// Moving on top of somebody's existing vault would destroy it. It is a different operation
    /// with a different name, and this one refuses.
    @Test func movingRefusesAFolderThatAlreadyHoldsAVault() throws {
        let origin = Self.temporaryDirectory()
        let occupied = Self.temporaryDirectory()

        let other = Self.makeContainer(directory: occupied, suite: "occupier")
        other.sessionManager.createVaultSynchronously(password: "other-vault")

        let container = Self.makeContainer(directory: origin)
        container.sessionManager.createVaultSynchronously(password: "location-test")

        #expect(throws: VaultCryptoError.vaultAlreadyPresentInFolder) {
            try container.relocation.moveVault(to: occupied)
        }
        // The occupant is untouched and still opens with its own password.
        let reopened = Self.makeContainer(directory: occupied, suite: "occupier-again")
        #expect(reopened.sessionManager.unlockWithPasswordSynchronously("other-vault"))
    }

    @Test func movingIsRefusedWhileLocked() throws {
        let origin = Self.temporaryDirectory()
        let destination = Self.temporaryDirectory()
        let container = Self.makeContainer(directory: origin)
        container.sessionManager.createVaultSynchronously(password: "location-test")
        container.sessionManager.lock()

        #expect(throws: VaultCryptoError.vaultLocked) {
            try container.relocation.moveVault(to: destination)
        }
        #expect(FileManager.default.fileExists(atPath: origin.appendingPathComponent("vault.package").path))
    }

    // MARK: - Opening a vault that is already somewhere

    @Test func openingAVaultElsewhereLocksAndPointsAtIt() throws {
        let mine = Self.temporaryDirectory()
        let theirs = Self.temporaryDirectory()

        let other = Self.makeContainer(directory: theirs, suite: "theirs")
        other.sessionManager.createVaultSynchronously(password: "their-password")
        _ = try other.itemRepository.saveItem(Self.draft("Their Secret"))

        let container = Self.makeContainer(directory: mine)
        container.sessionManager.createVaultSynchronously(password: "my-password")
        #expect(container.sessionManager.lockState == .unlocked)

        try container.relocation.openVault(in: theirs)

        // Locked, because this install has no business assuming its key opens that vault.
        #expect(container.sessionManager.lockState == .locked)
        #expect(container.sessionManager.unlockWithPasswordSynchronously("their-password"))

        let titles = try container.itemRepository.fetchAll(includeArchived: true).map(\.title)
        #expect(titles.contains("Their Secret"))

        // And the password of the vault left behind does not open this one. Checked after the
        // successful unlock on purpose: a wrong guess arms the retry delay, which would then
        // refuse the correct password for a second and make this read as a failure to adopt.
        container.sessionManager.lock()
        #expect(!container.sessionManager.unlockWithPasswordSynchronously("my-password"))
    }

    @Test func openingRefusesAFolderWithNoVaultInIt() throws {
        let mine = Self.temporaryDirectory()
        let empty = Self.temporaryDirectory()
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)

        let container = Self.makeContainer(directory: mine)
        container.sessionManager.createVaultSynchronously(password: "location-test")

        #expect(throws: VaultCryptoError.noVaultInFolder) {
            try container.relocation.openVault(in: empty)
        }
        #expect(container.sessionManager.lockState == .unlocked)
    }

    // MARK: - Location resolution

    @Test func aVaultFolderThatIsGoneFallsBackToTheDefaultAndSaysSo() throws {
        let missing = Self.temporaryDirectory()
        let fallback = Self.temporaryDirectory()
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: "VaultLocationTests-missing-\(suite)")!

        // A folder that was adopted and then vanished — an unmounted drive, a deleted folder.
        defaults.set(Data(missing.path.utf8), forKey: "vault.location.bookmark")
        defaults.set(missing.path, forKey: "vault.location.displayPath")

        let store = VaultLocationStore(
            defaults: defaults,
            defaultDirectory: fallback,
            makeBookmark: { Data($0.path.utf8) },
            resolveBookmark: { (URL(fileURLWithPath: String(decoding: $0, as: UTF8.self)), false) },
            beginAccess: { _ in true },
            endAccess: { _ in }
        )

        #expect(store.problem == .missing)
        #expect(!store.isUsingCustomDirectory)
        #expect(store.activeDirectory == fallback)
        // It still knows what it was looking for, so the UI can name it.
        #expect(store.displayPath.contains(missing.lastPathComponent))
    }

    @Test func forgettingACustomFolderReturnsToTheDefault() throws {
        let chosen = Self.temporaryDirectory()
        let fallback = Self.temporaryDirectory()
        try FileManager.default.createDirectory(at: chosen, withIntermediateDirectories: true)

        let store = Self.makeLocationStore(defaultDirectory: fallback, suite: UUID().uuidString)
        try store.adoptCustomDirectory(chosen)
        #expect(store.isUsingCustomDirectory)
        #expect(store.activeDirectory == chosen)

        store.forgetCustomDirectory()
        #expect(!store.isUsingCustomDirectory)
        #expect(store.activeDirectory == fallback)
    }

    @Test func theInstallIdentifierIsStableAcrossStores() {
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: "VaultLocationTests-install-\(suite)")!
        let directory = Self.temporaryDirectory()

        let first = VaultLocationStore(defaults: defaults, defaultDirectory: directory)
        let minted = first.installIdentifier

        let second = VaultLocationStore(defaults: defaults, defaultDirectory: directory)
        #expect(second.installIdentifier == minted)
    }

    // MARK: - Foreign write helpers

    /// Bumps the counter the way another install's save would, leaving the ciphertext alone.
    private static func simulateForeignWrite(in directory: URL) throws {
        let store = FileEncryptedVaultStore(baseDirectory: directory)
        var metadata = try store.loadMetadata()
        let envelope = try store.loadEnvelope()
        metadata.writeCounter += 1
        metadata.lastWriterID = UUID().uuidString
        metadata.updatedAt = .now
        try store.save(metadata: metadata, envelope: envelope)
    }

    private static func rewriteWriteCounter(in directory: URL, to value: Int) throws {
        let store = FileEncryptedVaultStore(baseDirectory: directory)
        var metadata = try store.loadMetadata()
        let envelope = try store.loadEnvelope()
        metadata.writeCounter = value
        try store.save(metadata: metadata, envelope: envelope)
    }
}
