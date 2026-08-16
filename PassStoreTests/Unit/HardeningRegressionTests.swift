import CryptoKit
import Foundation
import Testing
@testable import PassStore

private enum HardeningTestFailure: Error { case expected, rollbackUnavailable }

@MainActor
struct HardeningRegressionTests {
    private func makeContainer(
        _ label: String,
        keyStore: VaultKeyStore = InMemoryVaultKeyStore(isBiometricHardwareAvailable: false),
        vaultStore: EncryptedVaultStore? = nil
    ) -> AppContainer {
        let defaults = UserDefaults(suiteName: "Hardening-\(label)-\(UUID().uuidString)")!
        let container = AppContainer(
            inMemory: true,
            defaults: defaults,
            keyStore: keyStore,
            encryptedVaultStore: vaultStore ?? InMemoryEncryptedVaultStore()
        )
        container.sessionManager.createVaultSynchronously(password: "test-password")
        return container
    }

    private func itemDraft(
        title: String,
        id: UUID? = nil,
        value: String = "secret",
        isSensitive: Bool = true,
        templateID: UUID? = nil
    ) -> SecretItemDraft {
        SecretItemDraft(
            id: id,
            title: title,
            type: .generic,
            workspaceID: nil,
            environment: .preset(.dev),
            notes: "",
            tags: [],
            isFavorite: false,
            fieldDrafts: [
                FieldDraft(
                    key: "token",
                    label: "Token",
                    value: value,
                    kind: .secret,
                    isSensitive: isSensitive,
                    isCopyable: true,
                    isMasked: isSensitive,
                    sortOrder: 0
                )
            ],
            templateID: templateID
        )
    }

    private func encryptedBackup(from container: AppContainer, password: String = "backup-password") throws -> Data {
        try container.exportService.exportFullBackupSynchronously(
            backup: ExportedBackupPayload(
                vault: container.memoryStore.makeSnapshot(),
                settings: container.settings.makeSettingsSnapshot()
            ),
            password: password
        )
    }

    private func encryptedLegacyBackup(
        items: [ExportedItemPayload],
        password: String = "legacy-password"
    ) throws -> Data {
        let crypto = VaultCryptoService(defaultIterations: 20_000, defaultOpsLimit: 1, defaultMemLimit: 8_192)
        var vaultKey = crypto.generateVaultKey()
        defer { VaultCryptoService.overwrite(&vaultKey) }
        let wrappedKey = try crypto.wrapVaultKey(vaultKey, password: password)
        var plaintext = try JSONEncoder().encode(items)
        defer { VaultCryptoService.overwrite(&plaintext) }
        let sealed = try AES.GCM.seal(plaintext, using: SymmetricKey(data: vaultKey))
        let payload = VaultEnvelope(
            version: 1,
            nonce: Data(sealed.nonce).base64EncodedString(),
            ciphertext: sealed.ciphertext.base64EncodedString(),
            tag: sealed.tag.base64EncodedString(),
            createdAt: .now
        )
        return try JSONEncoder().encode(EncryptedExportEnvelope(
            version: 2,
            kdf: wrappedKey,
            payload: payload,
            createdAt: .now
        ))
    }

    // MARK: - Lock and erase lifecycle

    @Test func systemLockInvalidatesAnUnlockAlreadyInFlight() async throws {
        let defaults = UserDefaults(suiteName: "UnlockRace-\(UUID().uuidString)")!
        let settings = AppSettingsStore(defaults: defaults)
        let memory = VaultMemoryStore()
        let store = InMemoryEncryptedVaultStore()
        let session = VaultSessionManager(
            defaults: defaults,
            settings: settings,
            cryptoService: VaultCryptoService(defaultIterations: 20_000, defaultOpsLimit: 2, defaultMemLimit: 64 * 1_024 * 1_024),
            vaultStore: store,
            keyStore: InMemoryVaultKeyStore(isBiometricHardwareAvailable: false),
            memoryStore: memory
        )
        session.createVaultSynchronously(password: "test-password")
        session.lock()

        let unlock = Task { await session.unlockWithPassword("test-password") }
        for _ in 0..<200 where !session.isBusy { await Task.yield() }
        #expect(session.isBusy)

        session.lockForSystemEvent()
        let didUnlock = await unlock.value

        #expect(!didUnlock)
        #expect(session.lockState == .locked)
        #expect(!memory.isUnlocked)
        #expect(memory.items.isEmpty)
    }

    @Test func supersededBiometricUnlockCannotClearANewerPromptsBusyState() async throws {
        let defaults = UserDefaults(suiteName: "BiometricGeneration-\(UUID().uuidString)")!
        let settings = AppSettingsStore(defaults: defaults)
        let memory = VaultMemoryStore()
        let store = InMemoryEncryptedVaultStore()
        let keyStore = BlockingBiometricKeyStore()
        let session = VaultSessionManager(
            defaults: defaults,
            settings: settings,
            cryptoService: VaultCryptoService(defaultIterations: 20_000, defaultOpsLimit: 1, defaultMemLimit: 8_192),
            vaultStore: store,
            keyStore: keyStore,
            memoryStore: memory
        )
        session.createVaultSynchronously(password: "test-password")
        session.lock()
        defer { keyStore.releaseAllReads() }

        let first = Task { await session.unlockWithBiometrics() }
        for _ in 0..<10_000 where keyStore.startedReadCount < 1 { await Task.yield() }
        #expect(keyStore.startedReadCount == 1)

        session.lock()
        let second = Task { await session.unlockWithBiometrics() }
        for _ in 0..<10_000 where keyStore.startedReadCount < 2 { await Task.yield() }
        #expect(keyStore.startedReadCount == 2)
        #expect(session.isBusy)
        #expect(session.isPresentingBiometricPrompt)

        keyStore.releaseRead(0)
        #expect(!(await first.value))
        // The old task's defer must not make a third unlock possible while #2 still owns
        // the shared progress and prompt flags.
        #expect(session.isBusy)
        #expect(session.isPresentingBiometricPrompt)

        keyStore.releaseRead(1)
        #expect(await second.value)
        #expect(!session.isBusy)
        #expect(!session.isPresentingBiometricPrompt)
    }

    @Test func metadataWriteFailureCannotReturnFalseWhileLeavingTheVaultUnlocked() {
        let store = ToggleSaveStore()
        let keyStore = InMemoryVaultKeyStore(isBiometricHardwareAvailable: true)
        let container = makeContainer("UnlockWriteFailure", keyStore: keyStore, vaultStore: store)
        container.settings.biometricsEnabled = false
        container.sessionManager.lock()

        store.rejectsSaves = true
        #expect(!container.sessionManager.unlockWithPasswordSynchronously("test-password"))
        #expect(container.sessionManager.lockState == .locked)
        #expect(!container.memoryStore.isUnlocked)
        #expect(container.sessionManager.lastErrorMessage == HardeningTestFailure.expected.localizedDescription)

        // An I/O error must not arm the password-guess delay.
        store.rejectsSaves = false
        #expect(container.sessionManager.unlockWithPasswordSynchronously("test-password"))
    }

    @Test func failedMasterPasswordWriteRestoresMetadataAndAuditHistory() async throws {
        let store = OneShotSaveFailureStore()
        let container = makeContainer("PasswordWriteFailure", vaultStore: store)
        let history = container.memoryStore.masterPasswordHistory
        store.failOnSave(numberFromNow: 1)

        await #expect(throws: HardeningTestFailure.self) {
            try await container.sessionManager.changeMasterPassword(
                current: "test-password",
                to: "replacement-password"
            )
        }
        #expect(container.memoryStore.masterPasswordHistory == history)
        #expect(container.sessionManager.lockState == .unlocked)

        container.sessionManager.lock()
        #expect(container.sessionManager.unlockWithPasswordSynchronously("test-password"))
    }

    @Test func failedMasterPasswordRepairLocksInsteadOfLeavingAnAmbiguousSession() async throws {
        let store = ToggleSaveStore()
        let container = makeContainer("PasswordRepairFailure", vaultStore: store)
        store.rejectsSaves = true

        await #expect(throws: (any Error).self) {
            try await container.sessionManager.changeMasterPassword(
                current: "test-password",
                to: "replacement-password"
            )
        }
        #expect(container.sessionManager.lockState == .locked)
        #expect(!container.memoryStore.isUnlocked)
        #expect(container.memoryStore.items.isEmpty)

        // The first failed write never replaced this in-memory store's committed pair.
        store.rejectsSaves = false
        #expect(container.sessionManager.unlockWithPasswordSynchronously("test-password"))
    }

    @Test func failedBiometricPreferenceWriteRestoresKeychainMetadataAndSetting() async throws {
        let store = OneShotSaveFailureStore()
        let keyStore = InMemoryVaultKeyStore(isBiometricHardwareAvailable: true)
        let container = makeContainer("BiometricWriteFailure", keyStore: keyStore, vaultStore: store)
        #expect(container.settings.biometricsEnabled)
        #expect(try store.loadMetadata().biometricUnlockEnabled)

        container.settings.biometricsEnabled = false
        store.failOnSave(numberFromNow: 1)
        #expect(throws: (any Error).self) {
            try container.sessionManager.syncBiometricPreferenceIfUnlocked()
        }

        #expect(container.settings.biometricsEnabled)
        #expect(try store.loadMetadata().biometricUnlockEnabled)
        container.sessionManager.lock()
        #expect(await container.sessionManager.unlockWithBiometrics())
    }

    @Test func biometricSyncRepairsAMissingKeyEvenWhenThePreferenceAlreadyMatches() throws {
        let keyStore = InMemoryVaultKeyStore(isBiometricHardwareAvailable: true)
        let container = makeContainer("BiometricRepair", keyStore: keyStore)
        #expect(container.settings.biometricsEnabled)

        try keyStore.deleteVaultKey()
        #expect(throws: VaultKeyStoreError.self) {
            _ = try keyStore.readVaultKey(prompt: "test")
        }

        try container.sessionManager.syncBiometricPreferenceIfUnlocked()
        #expect(try keyStore.readVaultKey(prompt: "test").count == 32)
    }

    @Test func hostileKDFParametersAreRejectedBeforeResourceIntensiveWork() throws {
        let crypto = VaultCryptoService(defaultIterations: 20_000, defaultOpsLimit: 1, defaultMemLimit: 8_192)
        let key = crypto.generateVaultKey()
        let wrapped = try crypto.wrapVaultKey(key, password: "password")
        let excessiveMemory = WrappedVaultKey(
            kdfAlgorithm: "argon2id",
            salt: wrapped.salt,
            iterations: 1,
            memoryLimit: 2_147_483_647,
            nonce: wrapped.nonce,
            ciphertext: wrapped.ciphertext,
            tag: wrapped.tag
        )
        let unknownAlgorithm = WrappedVaultKey(
            kdfAlgorithm: "untrusted-kdf",
            salt: wrapped.salt,
            iterations: 1,
            memoryLimit: 8_192,
            nonce: wrapped.nonce,
            ciphertext: wrapped.ciphertext,
            tag: wrapped.tag
        )

        #expect(throws: VaultCryptoError.invalidWrappedKey) {
            _ = try crypto.unwrapVaultKey(excessiveMemory, password: "password")
        }
        #expect(throws: VaultCryptoError.invalidWrappedKey) {
            _ = try crypto.unwrapVaultKey(unknownAlgorithm, password: "password")
        }
    }

    @Test func malformedVaultDataDoesNotCountAsAWrongPasswordAttempt() throws {
        let defaults = UserDefaults(suiteName: "MalformedVaultLockout-\(UUID().uuidString)")!
        let store = InMemoryEncryptedVaultStore()
        let container = AppContainer(
            inMemory: true,
            defaults: defaults,
            keyStore: InMemoryVaultKeyStore(isBiometricHardwareAvailable: false),
            encryptedVaultStore: store
        )
        container.sessionManager.createVaultSynchronously(password: "test-password")
        container.sessionManager.lock()
        try store.save(
            metadata: store.loadMetadata(),
            envelope: VaultEnvelope(
                version: 1,
                nonce: "not-base64",
                ciphertext: "not-base64",
                tag: "not-base64",
                createdAt: .now
            )
        )

        #expect(!container.sessionManager.unlockWithPasswordSynchronously("test-password"))
        #expect(defaults.integer(forKey: "security.failedPasswordAttempts") == 0)
    }

    @Test func authenticatedPayloadCorruptionDoesNotCountAsAWrongPasswordAttempt() throws {
        let defaults = UserDefaults(suiteName: "CorruptPayloadLockout-\(UUID().uuidString)")!
        let store = InMemoryEncryptedVaultStore()
        let container = AppContainer(
            inMemory: true,
            defaults: defaults,
            keyStore: InMemoryVaultKeyStore(isBiometricHardwareAvailable: false),
            encryptedVaultStore: store
        )
        container.sessionManager.createVaultSynchronously(password: "test-password")
        container.sessionManager.lock()

        let metadata = try store.loadMetadata()
        let original = try store.loadEnvelope()
        var ciphertext = try #require(Data(base64Encoded: original.ciphertext))
        ciphertext[0] ^= 0x01
        let corrupt = VaultEnvelope(
            version: original.version,
            nonce: original.nonce,
            ciphertext: ciphertext.base64EncodedString(),
            tag: original.tag,
            createdAt: original.createdAt
        )
        try store.save(metadata: metadata, envelope: corrupt)

        #expect(!container.sessionManager.unlockWithPasswordSynchronously("test-password"))
        #expect(defaults.integer(forKey: "security.failedPasswordAttempts") == 0)

        // A correct retry must be accepted immediately once the payload is repaired; a
        // misclassified password failure would impose the one-second lockout here.
        try store.save(metadata: metadata, envelope: original)
        #expect(container.sessionManager.unlockWithPasswordSynchronously("test-password"))
    }

    @Test func hostilePersistedSettingsAreSanitizedAtLaunch() {
        let defaults = UserDefaults(suiteName: "HostileSettings-\(UUID().uuidString)")!
        defaults.set(Double.nan, forKey: "settings.autoLockInterval")
        defaults.set(Double.infinity, forKey: "settings.clipboardClearInterval")
        defaults.set(
            [" \(SecretItemType.generic.rawValue) ", SecretItemType.generic.rawValue, "not-a-type"],
            forKey: "settings.sidebar.typesOrder"
        )
        defaults.set((0..<600).map { " tag-\($0) " }, forKey: "settings.sidebar.tagsOrder")
        defaults.set("not-a-sort", forKey: "settings.itemSortOrder")

        let settings = AppSettingsStore(defaults: defaults)

        #expect(settings.autoLockInterval == 60)
        #expect(settings.clipboardClearInterval == 10)
        #expect(settings.sidebarTypesOrder == [SecretItemType.generic.rawValue])
        #expect(settings.sidebarTagsOrder.isEmpty)
        let legacyPrivateOrders = settings.persistedLegacyPrivateSidebarOrders()
        #expect(legacyPrivateOrders.tags.count == 500)
        #expect(legacyPrivateOrders.tags.first == "tag-0")
        #expect(legacyPrivateOrders.tags.last == "tag-499")
        #expect(settings.itemSortOrder == .title)
    }

    @Test func lockClearsDecryptedImportUndoAndPresentationState() async throws {
        let source = makeContainer("TransientSource")
        _ = try source.itemRepository.saveItem(itemDraft(title: "Incoming"))
        let data = try encryptedBackup(from: source)

        let target = makeContainer("TransientTarget")
        let viewModel = VaultViewModel(container: target)
        let saved = try target.itemRepository.saveItem(itemDraft(title: "Local", value: "one"))
        _ = try target.itemRepository.saveItem(itemDraft(title: "Local", id: saved.id, value: "two"))
        viewModel.reload()
        viewModel.purgeAllValueHistory()
        #expect(viewModel.undoActionLabel != nil)

        viewModel.stageImport(data: data, fileName: "backup.pstore")
        #expect(await viewModel.prepareImport(password: "backup-password"))
        #expect(viewModel.importPreview != nil)
        viewModel.activeSheet = .importPreview

        target.sessionManager.lock()

        #expect(viewModel.items.isEmpty)
        #expect(viewModel.importPreview == nil)
        #expect(viewModel.undoActionLabel == nil)
        #expect(viewModel.activeSheet == nil)
        #expect(!viewModel.isWorking)
    }

    @Test func lockingFlushesADeferredLastAccessWriteBeforeClearingTheKey() throws {
        let store = InMemoryEncryptedVaultStore()
        let container = makeContainer("LockFlush", vaultStore: store)
        let item = try container.itemRepository.saveItem(itemDraft(title: "Recently Used"))
        try container.itemRepository.recordItemAccess(item)
        #expect(item.lastAccessedAt != nil)

        container.sessionManager.lock()

        let crypto = VaultCryptoService(defaultIterations: 20_000, defaultOpsLimit: 1, defaultMemLimit: 8_192)
        var key = try crypto.unwrapVaultKey(try store.loadMetadata().wrappedVaultKey, password: "test-password")
        defer { VaultCryptoService.overwrite(&key) }
        let persisted = try crypto.decryptVault(try store.loadEnvelope(), using: key)
        #expect(persisted.items.first?.lastAccessedAt != nil)
    }

    @Test func privateSidebarLabelsLiveInTheEncryptedVaultAndClearOnLock() throws {
        let defaults = UserDefaults(suiteName: "PrivateSidebar-\(UUID().uuidString)")!
        let store = InMemoryEncryptedVaultStore()
        let container = AppContainer(
            inMemory: true,
            defaults: defaults,
            keyStore: InMemoryVaultKeyStore(isBiometricHardwareAvailable: false),
            encryptedVaultStore: store
        )
        container.sessionManager.createVaultSynchronously(password: "test-password")
        let viewModel = VaultViewModel(container: container)

        viewModel.reorderSidebarTags(["confidential-client-codename"])
        viewModel.reorderSidebarEnvironments(["customer-production"])
        #expect(defaults.stringArray(forKey: "settings.sidebar.tagsOrder") == nil)
        #expect(defaults.stringArray(forKey: "settings.sidebar.environmentsOrder") == nil)

        container.sessionManager.lock()
        #expect(container.settings.sidebarTagsOrder.isEmpty)
        #expect(container.settings.sidebarEnvironmentsOrder.isEmpty)
        #expect(container.sessionManager.unlockWithPasswordSynchronously("test-password"))
        #expect(container.settings.sidebarTagsOrder == ["confidential-client-codename"])
        #expect(container.settings.sidebarEnvironmentsOrder == ["customer-production"])
    }

    @Test func plaintextSidebarLabelsFromEarly12BuildsMigrateOnUnlock() throws {
        let defaults = UserDefaults(suiteName: "PrivateSidebarMigration-\(UUID().uuidString)")!
        let store = InMemoryEncryptedVaultStore()
        let container = AppContainer(
            inMemory: true,
            defaults: defaults,
            keyStore: InMemoryVaultKeyStore(isBiometricHardwareAvailable: false),
            encryptedVaultStore: store
        )
        container.sessionManager.createVaultSynchronously(password: "test-password")

        let crypto = VaultCryptoService(defaultIterations: 20_000, defaultOpsLimit: 1, defaultMemLimit: 8_192)
        let metadata = try store.loadMetadata()
        var key = try crypto.unwrapVaultKey(metadata.wrappedVaultKey, password: "test-password")
        defer { VaultCryptoService.overwrite(&key) }
        var oldSnapshot = container.memoryStore.makeSnapshot()
        oldSnapshot.privateSidebarTagsOrder = nil
        oldSnapshot.privateSidebarEnvironmentsOrder = nil
        try store.save(metadata: metadata, envelope: try crypto.encryptVault(oldSnapshot, using: key))
        container.sessionManager.lock()

        defaults.set(["legacy-client"], forKey: "settings.sidebar.tagsOrder")
        defaults.set(["legacy-production"], forKey: "settings.sidebar.environmentsOrder")
        let relaunched = AppContainer(
            inMemory: true,
            defaults: defaults,
            keyStore: InMemoryVaultKeyStore(isBiometricHardwareAvailable: false),
            encryptedVaultStore: store
        )
        #expect(relaunched.sessionManager.lockState == .locked)
        #expect(relaunched.settings.sidebarTagsOrder.isEmpty)
        #expect(relaunched.settings.sidebarEnvironmentsOrder.isEmpty)

        #expect(relaunched.sessionManager.unlockWithPasswordSynchronously("test-password"))
        #expect(relaunched.settings.sidebarTagsOrder == ["legacy-client"])
        #expect(relaunched.settings.sidebarEnvironmentsOrder == ["legacy-production"])
        #expect(defaults.stringArray(forKey: "settings.sidebar.tagsOrder") == nil)
        #expect(defaults.stringArray(forKey: "settings.sidebar.environmentsOrder") == nil)

        relaunched.sessionManager.lock()
        #expect(relaunched.sessionManager.unlockWithPasswordSynchronously("test-password"))
        #expect(relaunched.settings.sidebarTagsOrder == ["legacy-client"])
        #expect(relaunched.settings.sidebarEnvironmentsOrder == ["legacy-production"])
    }

    @Test func eraseResetsSettingsAndOldUndoCannotPopulateANewVault() throws {
        let container = makeContainer("EraseLifecycle")
        let viewModel = VaultViewModel(container: container)
        let saved = try container.itemRepository.saveItem(itemDraft(title: "Old", value: "one"))
        _ = try container.itemRepository.saveItem(itemDraft(title: "Old", id: saved.id, value: "two"))
        viewModel.reload()
        viewModel.purgeAllValueHistory()
        container.settings.autoLockInterval = 17
        container.settings.keepsSecretValueHistory = false

        try container.sessionManager.resetVaultDestroyingAllData()

        #expect(container.sessionManager.lockState == .setupRequired)
        #expect(container.settings.autoLockInterval == 300)
        #expect(container.settings.keepsSecretValueHistory)
        #expect(viewModel.undoActionLabel == nil)

        container.sessionManager.createVaultSynchronously(password: "new-password")
        _ = try container.itemRepository.saveItem(itemDraft(title: "New"))
        viewModel.reload()
        viewModel.undoLastDestructiveAction()
        #expect(viewModel.items.map(\.title) == ["New"])
    }

    @Test func eraseReportsIncompleteKeychainCleanup() throws {
        let container = makeContainer("EraseFailure", keyStore: RejectingKeyStore())
        container.settings.autoLockInterval = 12
        var didThrow = false
        do {
            try container.sessionManager.resetVaultDestroyingAllData()
        } catch {
            didThrow = true
        }
        #expect(didThrow)
        #expect(container.settings.autoLockInterval == 300)
        #expect(container.sessionManager.lockState == .setupRequired)
    }

    @Test func fileVaultUsesOwnerOnlyPermissionsAndEraseRemovesEveryArtifact() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PassStore-Hardening-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileEncryptedVaultStore(baseDirectory: directory)
        let container = makeContainer("FileCleanup", vaultStore: store)
        container.settings.sidebarTagsOrder = ["confidential-client-codename"]
        try container.sessionManager.writeRollbackCopy()

        let mode: (URL) throws -> Int = { url in
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
        }
        #expect(try mode(directory) & 0o777 == 0o700)
        #expect(try mode(directory.appendingPathComponent("vault.enc")) & 0o777 == 0o600)
        #expect(try mode(directory.appendingPathComponent("vault.meta")) & 0o777 == 0o600)
        #expect(try mode(directory.appendingPathComponent("vault.package")) & 0o777 == 0o600)
        #expect(try mode(directory.appendingPathComponent("vault.rollback")) & 0o777 == 0o600)
        let rollbackData = try Data(contentsOf: directory.appendingPathComponent("vault.rollback"))
        #expect(!String(decoding: rollbackData, as: UTF8.self).contains("confidential-client-codename"))

        try container.sessionManager.resetVaultDestroyingAllData()
        let remaining = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(remaining.isEmpty)
    }

    @Test func authoritativePackageWinsOverCorruptLegacyMirrorFiles() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PassStore-Package-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let keyStore = InMemoryVaultKeyStore(isBiometricHardwareAvailable: true)
        let store = FileEncryptedVaultStore(baseDirectory: directory)
        let container = makeContainer("AuthoritativePackage", keyStore: keyStore, vaultStore: store)
        _ = try container.itemRepository.saveItem(itemDraft(title: "From Package", value: "kept"))

        try Data("corrupt metadata".utf8).write(
            to: directory.appendingPathComponent("vault.meta"),
            options: .atomic
        )
        try Data("corrupt envelope".utf8).write(
            to: directory.appendingPathComponent("vault.enc"),
            options: .atomic
        )

        let reopened = FileEncryptedVaultStore(baseDirectory: directory)
        // Exercise either read order: the first call populates the coherent package cache.
        let envelope = try reopened.loadEnvelope()
        let metadata = try reopened.loadMetadata()
        let crypto = VaultCryptoService(defaultIterations: 20_000, defaultOpsLimit: 1, defaultMemLimit: 8_192)
        var key = try crypto.unwrapVaultKey(metadata.wrappedVaultKey, password: "test-password")
        defer { VaultCryptoService.overwrite(&key) }
        let snapshot = try crypto.decryptVault(envelope, using: key)

        #expect(snapshot.items.map(\.title) == ["From Package"])
        #expect(snapshot.items.first?.fields.first?.plainValue == "kept")
    }

    @Test func corruptAuthoritativePackageNeverFallsBackToLegacyMirrors() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PassStore-Corrupt-Package-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileEncryptedVaultStore(baseDirectory: directory)
        _ = makeContainer("CorruptAuthoritativePackage", vaultStore: store)

        // The mirror pair is still valid here. Falling back to it would hide corruption and
        // could combine state from a different save after a crash or partial filesystem copy.
        try Data("not a vault package".utf8).write(
            to: directory.appendingPathComponent("vault.package"),
            options: .atomic
        )

        var metadataReadFailed = false
        do {
            _ = try FileEncryptedVaultStore(baseDirectory: directory).loadMetadata()
        } catch {
            metadataReadFailed = true
        }
        var envelopeReadFailed = false
        do {
            _ = try FileEncryptedVaultStore(baseDirectory: directory).loadEnvelope()
        } catch {
            envelopeReadFailed = true
        }

        #expect(metadataReadFailed)
        #expect(envelopeReadFailed)
    }

    @Test func failedVaultCreationRemovesKeyAndPartialFiles() {
        let defaults = UserDefaults(suiteName: "CreationCleanup-\(UUID().uuidString)")!
        let store = ToggleSaveStore()
        store.rejectsSaves = true
        let keyStore = InMemoryVaultKeyStore(isBiometricHardwareAvailable: true)
        let session = VaultSessionManager(
            defaults: defaults,
            settings: AppSettingsStore(defaults: defaults),
            cryptoService: VaultCryptoService(defaultIterations: 20_000, defaultOpsLimit: 1, defaultMemLimit: 8_192),
            vaultStore: store,
            keyStore: keyStore,
            memoryStore: VaultMemoryStore()
        )

        session.createVaultSynchronously(password: "test-password")

        #expect(session.lockState == .setupRequired)
        #expect(!store.hasVault())
        #expect(throws: VaultKeyStoreError.self) {
            _ = try keyStore.readVaultKey(prompt: "test")
        }
    }

    @Test func rollbackDiscardFailureIsReportedToTheViewModel() {
        let container = makeContainer("DiscardFailure", vaultStore: RejectingRollbackStore())
        let viewModel = VaultViewModel(container: container)
        viewModel.discardRollbackCopy()
        #expect(viewModel.alertMessage == HardeningTestFailure.rollbackUnavailable.localizedDescription)
    }

    // MARK: - Import safety and fidelity

    @Test func anImportIsNotAppliedWhenItsRollbackCopyCannotBeWritten() async throws {
        let source = makeContainer("RollbackRequiredSource")
        _ = try source.itemRepository.saveItem(itemDraft(title: "Incoming"))
        let data = try encryptedBackup(from: source)

        let target = makeContainer("RollbackRequiredTarget", vaultStore: RejectingRollbackStore())
        let viewModel = VaultViewModel(container: target)
        _ = try target.itemRepository.saveItem(itemDraft(title: "Local"))
        viewModel.reload()

        viewModel.stageImport(data: data, fileName: "backup.pstore")
        #expect(await viewModel.prepareImport(password: "backup-password"))
        let outcome = viewModel.applyStagedImport(mode: .replace)

        #expect(outcome == nil)
        #expect(viewModel.items.map(\.title) == ["Local"])
        #expect(viewModel.importPreview != nil)
    }

    @Test func choosingAnotherImportDiscardsThePreviouslyDecryptedPayload() async throws {
        let source = makeContainer("SupersededImportSource")
        _ = try source.itemRepository.saveItem(itemDraft(title: "Must Not Be Restored"))
        let firstData = try encryptedBackup(from: source)

        let target = makeContainer("SupersededImportTarget")
        let viewModel = VaultViewModel(container: target)
        viewModel.stageImport(data: firstData, fileName: "first.pstore")
        #expect(await viewModel.prepareImport(password: "backup-password"))
        #expect(viewModel.importPreview?.fileName == "first.pstore")

        // Selecting a replacement must make the first decrypted payload unreachable even if
        // the replacement later turns out to be malformed or cannot be decrypted.
        viewModel.stageImport(data: Data("not a backup".utf8), fileName: "second.pstore")

        #expect(viewModel.importPreview == nil)
        #expect(viewModel.applyStagedImport(mode: .merge) == nil)
        #expect(viewModel.items.isEmpty)
    }

    @Test func durableRollbackRestoresSettingsAndVaultContents() async throws {
        let source = makeContainer("RollbackSettingsSource")
        source.settings.autoLockInterval = 900
        source.settings.keepsSecretValueHistory = true
        _ = try source.itemRepository.saveItem(itemDraft(title: "Incoming"))
        let data = try encryptedBackup(from: source)

        let target = makeContainer("RollbackSettingsTarget")
        target.settings.autoLockInterval = 120
        target.settings.keepsSecretValueHistory = false
        let viewModel = VaultViewModel(container: target)
        _ = try target.itemRepository.saveItem(itemDraft(title: "Original"))
        viewModel.reload()

        viewModel.stageImport(data: data, fileName: "backup.pstore")
        #expect(await viewModel.prepareImport(password: "backup-password"))
        #expect(viewModel.applyStagedImport(mode: .replace) != nil)
        #expect(target.settings.autoLockInterval == 900)

        try target.sessionManager.restoreRollbackCopy()
        #expect(target.settings.autoLockInterval == 120)
        #expect(!target.settings.keepsSecretValueHistory)
        #expect(target.sessionManager.lockState == .locked)

        #expect(target.sessionManager.unlockWithPasswordSynchronously("test-password"))
        viewModel.reload()
        #expect(viewModel.items.map(\.title) == ["Original"])
    }

    @Test func conflictingMergeIsIdempotentAndKeepsLocalMasterPasswordHistory() async throws {
        let sharedID = UUID()
        let source = makeContainer("ConflictRepeatSource")
        _ = try source.itemRepository.saveItem(itemDraft(title: "Shared", id: sharedID, value: "remote"))
        source.memoryStore.recordMasterPasswordChange(.changed)
        try source.memoryStore.persist()
        let data = try encryptedBackup(from: source)

        let target = makeContainer("ConflictRepeatTarget")
        let viewModel = VaultViewModel(container: target)
        _ = try target.itemRepository.saveItem(itemDraft(title: "Shared", id: sharedID, value: "local"))
        viewModel.reload()
        let localPasswordHistory = target.memoryStore.masterPasswordHistory

        for pass in 0..<2 {
            viewModel.stageImport(data: data, fileName: "backup.pstore")
            #expect(await viewModel.prepareImport(password: "backup-password"))
            let outcome = try #require(viewModel.applyStagedImport(mode: .merge))
            #expect(outcome.addedItems == (pass == 0 ? 1 : 0))
        }

        #expect(viewModel.items.count == 2)
        #expect(viewModel.items.count { $0.title == "Shared (imported)" } == 1)
        #expect(target.memoryStore.masterPasswordHistory == localPasswordHistory)
    }

    @Test func mergeKeepsSemanticallyIdenticalRecordsWithDifferentStableIDs() async throws {
        let firstID = UUID()
        let secondID = UUID()
        let source = makeContainer("DistinctDuplicateSource")
        _ = try source.itemRepository.saveItem(itemDraft(title: "Intentional Duplicate", id: firstID))
        _ = try source.itemRepository.saveItem(itemDraft(title: "Intentional Duplicate", id: secondID))
        let data = try encryptedBackup(from: source)

        let target = makeContainer("DistinctDuplicateTarget")
        let viewModel = VaultViewModel(container: target)
        viewModel.stageImport(data: data, fileName: "backup.pstore")
        #expect(await viewModel.prepareImport(password: "backup-password"))
        #expect(viewModel.applyStagedImport(mode: .merge)?.addedItems == 2)

        #expect(Set(viewModel.items.map(\.id)) == [firstID, secondID])
    }

    @Test func conflictMergeDoesNotMistakeAnUnrelatedLookalikeForAPriorImport() async throws {
        let sharedID = UUID()
        let source = makeContainer("ConflictLookalikeSource")
        _ = try source.itemRepository.saveItem(
            itemDraft(title: "Shared", id: sharedID, value: "remote")
        )
        let data = try encryptedBackup(from: source)

        let target = makeContainer("ConflictLookalikeTarget")
        _ = try target.itemRepository.saveItem(
            itemDraft(title: "Shared", id: sharedID, value: "local")
        )
        _ = try target.itemRepository.saveItem(
            itemDraft(title: "Shared (imported)", id: UUID(), value: "remote")
        )
        let viewModel = VaultViewModel(container: target)
        viewModel.stageImport(data: data, fileName: "backup.pstore")
        #expect(await viewModel.prepareImport(password: "backup-password"))
        #expect(viewModel.applyStagedImport(mode: .merge)?.addedItems == 1)

        #expect(viewModel.items.count == 3)
        #expect(viewModel.items.count { $0.title == "Shared (imported)" } == 2)
    }

    @Test func mergePreservesDistinctSameNameWorkspacesAndTemplatesAcrossRepeatedImports() async throws {
        let source = makeContainer("SameNameRelationshipsSource")
        let firstWorkspace = try source.workspaceRepository.saveWorkspace(
            WorkspaceDraft(id: nil, name: "Shared Name", icon: "shippingbox", colorHex: "#111111", notes: "first")
        )
        let secondWorkspace = try source.workspaceRepository.saveWorkspace(
            WorkspaceDraft(id: nil, name: "Shared Name", icon: "shippingbox", colorHex: "#222222", notes: "second")
        )
        let firstTemplate = try source.templateRepository.saveTemplate(
            TemplateDraft(
                id: nil,
                name: "Shared Template",
                itemType: .generic,
                fieldDefinitions: [
                    TemplateFieldDraft(
                        key: "token",
                        label: "First",
                        kind: .secret,
                        isSensitive: true,
                        isCopyable: true,
                        isMaskedByDefault: true,
                        sortOrder: 0
                    )
                ]
            ),
            isBuiltIn: false
        )
        let secondTemplate = try source.templateRepository.saveTemplate(
            TemplateDraft(
                id: nil,
                name: "Shared Template",
                itemType: .generic,
                fieldDefinitions: [
                    TemplateFieldDraft(
                        key: "token",
                        label: "Second",
                        kind: .secret,
                        isSensitive: true,
                        isCopyable: true,
                        isMaskedByDefault: true,
                        sortOrder: 0
                    )
                ]
            ),
            isBuiltIn: false
        )
        var firstItem = itemDraft(title: "First relationship", templateID: firstTemplate.id)
        firstItem.workspaceID = firstWorkspace.id
        var secondItem = itemDraft(title: "Second relationship", templateID: secondTemplate.id)
        secondItem.workspaceID = secondWorkspace.id
        _ = try source.itemRepository.saveItem(firstItem)
        _ = try source.itemRepository.saveItem(secondItem)
        let data = try encryptedBackup(from: source)

        let target = makeContainer("SameNameRelationshipsTarget")
        let viewModel = VaultViewModel(container: target)
        for pass in 0..<2 {
            viewModel.stageImport(data: data, fileName: "backup.pstore")
            #expect(await viewModel.prepareImport(password: "backup-password"))
            let outcome = try #require(viewModel.applyStagedImport(mode: .merge))
            #expect(outcome.addedItems == (pass == 0 ? 2 : 0))
            #expect(outcome.addedWorkspaces == (pass == 0 ? 2 : 0))
        }

        #expect(target.memoryStore.workspaces.count == 2)
        #expect(target.memoryStore.customTemplates.count == 2)
        #expect(Set(viewModel.items.compactMap { $0.workspace?.id }).count == 2)
        #expect(Set(viewModel.items.compactMap { $0.template?.id }).count == 2)
    }

    @Test func legacyReplaceActuallyRemovesTheExistingVaultContents() async throws {
        let legacy = ExportedItemPayload(
            id: UUID(),
            workspaceName: "Legacy Workspace",
            title: "Legacy Only",
            type: SecretItemType.generic.title,
            environment: EnvironmentKind.dev.title,
            notes: "",
            tags: [],
            isFavorite: false,
            createdAt: .now,
            updatedAt: .now,
            fields: [
                ExportedFieldPayload(
                    key: "token",
                    label: "Token",
                    value: "legacy-secret",
                    kind: FieldKind.secret.rawValue,
                    isSensitive: true
                )
            ]
        )
        let data = try encryptedLegacyBackup(items: [legacy])
        let target = makeContainer("LegacyReplaceTarget")
        _ = try target.itemRepository.saveItem(itemDraft(title: "Must Disappear"))
        let viewModel = VaultViewModel(container: target)

        viewModel.stageImport(data: data, fileName: "legacy.pstore")
        #expect(await viewModel.prepareImport(password: "legacy-password"))
        #expect(viewModel.applyStagedImport(mode: .replace) != nil)

        #expect(viewModel.items.map(\.title) == ["Legacy Only"])
        #expect(viewModel.items.first?.fields.first?.plainValue == "legacy-secret")
    }

    @Test func failedImportIsRolledBackInMemoryIncludingSettings() async throws {
        let source = makeContainer("AtomicImportSource")
        source.settings.autoLockInterval = 900
        _ = try source.itemRepository.saveItem(itemDraft(title: "Incoming"))
        let data = try encryptedBackup(from: source)

        let store = OneShotSaveFailureStore()
        let target = makeContainer("AtomicImportTarget", vaultStore: store)
        target.settings.autoLockInterval = 120
        _ = try target.itemRepository.saveItem(itemDraft(title: "Original"))
        let viewModel = VaultViewModel(container: target)
        viewModel.stageImport(data: data, fileName: "backup.pstore")
        #expect(await viewModel.prepareImport(password: "backup-password"))

        // Replacement persists once, then biometric/settings reconciliation persists again.
        store.failOnSave(numberFromNow: 2)
        #expect(viewModel.applyStagedImport(mode: .replace) == nil)
        #expect(viewModel.items.map(\.title) == ["Original"])
        #expect(target.settings.autoLockInterval == 120)
        #expect(viewModel.importPreview != nil)
    }

    @Test func mergePreservesTemplatesAndAllItemMetadata() async throws {
        let source = makeContainer("MergeFidelitySource")
        let template = try source.templateRepository.saveTemplate(
            TemplateDraft(
                id: nil,
                name: "Imported Template",
                itemType: .generic,
                fieldDefinitions: [
                    TemplateFieldDraft(
                        key: "token",
                        label: "Deploy Token",
                        kind: .multiline,
                        isSensitive: true,
                        isCopyable: false,
                        isMaskedByDefault: true,
                        sortOrder: 0
                    )
                ]
            ),
            isBuiltIn: false
        )
        var draft = itemDraft(title: "Metadata", value: "current", templateID: template.id)
        draft.tags = ["one", "two"]
        draft.environment = .custom("QA West")
        draft.fieldDrafts[0].kind = .multiline
        draft.fieldDrafts[0].isCopyable = false
        let item = try source.itemRepository.saveItem(draft)
        let createdAt = Date(timeIntervalSince1970: 700_000_000)
        let updatedAt = Date(timeIntervalSince1970: 710_000_000)
        item.createdAt = createdAt
        item.updatedAt = updatedAt
        item.lastAccessedAt = Date(timeIntervalSince1970: 720_000_000)
        item.fields[0].previousValues = [SecretValueVersion(value: "previous", replacedAt: updatedAt)]
        item.changeHistory = [SecretItemChangeEntry(kind: .sensitiveValueChanged, changedAt: updatedAt, detail: "Deploy Token")]
        item.ignoredHealthIssues = [IgnoredHealthIssue(kindRawValue: "weak", fieldKey: "token", valueDigest: "digest")]
        item.linkedFile = LinkedFileReference(displayPath: "/tmp/imported.env", syncedDigest: "file", syncedVaultDigest: "vault")
        try source.memoryStore.persist()
        let data = try encryptedBackup(from: source)

        let target = makeContainer("MergeFidelityTarget")
        let viewModel = VaultViewModel(container: target)
        viewModel.stageImport(data: data, fileName: "backup.pstore")
        #expect(await viewModel.prepareImport(password: "backup-password"))
        #expect(viewModel.applyStagedImport(mode: .merge) != nil)

        let imported = try #require(viewModel.items.first { $0.title == "Metadata" })
        let importedTemplate = try #require(target.memoryStore.customTemplates.first { $0.name == "Imported Template" })
        #expect(imported.template?.id == importedTemplate.id)
        #expect(imported.createdAt == createdAt)
        #expect(imported.updatedAt == updatedAt)
        #expect(imported.environmentValue == .custom("QA West"))
        #expect(imported.tags == ["one", "two"])
        #expect(imported.fields[0].kind == .multiline)
        #expect(!imported.fields[0].isCopyable)
        #expect(imported.fields[0].previousValues.map(\.value) == ["previous"])
        #expect(imported.changeHistory.count == 1)
        #expect(imported.ignoredHealthIssues.count == 1)
        #expect(imported.linkedFile?.displayPath == "/tmp/imported.env")
    }

    // MARK: - History, timestamps and transactions

    @Test func nonSensitiveValuesNeverEnterSecretHistoryAndDeclassifyingPurgesIt() throws {
        let container = makeContainer("HistorySensitivity")
        let plain = try container.itemRepository.saveItem(itemDraft(title: "Plain", value: "first", isSensitive: false))
        let plainChanged = try container.itemRepository.saveItem(itemDraft(title: "Plain", id: plain.id, value: "second", isSensitive: false))
        #expect(plainChanged.fields[0].previousValues.isEmpty)

        let secret = try container.itemRepository.saveItem(itemDraft(title: "Secret", value: "one"))
        _ = try container.itemRepository.saveItem(itemDraft(title: "Secret", id: secret.id, value: "two"))
        #expect(!secret.fields[0].previousValues.isEmpty)
        let declassified = try container.itemRepository.saveItem(itemDraft(title: "Secret", id: secret.id, value: "public", isSensitive: false))
        #expect(declassified.fields[0].previousValues.isEmpty)
    }

    @Test func tagsAndFieldMetadataBumpUpdatedAt() throws {
        let container = makeContainer("UpdatedAtCoverage")
        let item = try container.itemRepository.saveItem(itemDraft(title: "Timestamp"))

        item.updatedAt = Date(timeIntervalSince1970: 1)
        var tags = itemDraft(title: "Timestamp", id: item.id)
        tags.tags = ["changed"]
        let tagged = try container.itemRepository.saveItem(tags)
        #expect(tagged.updatedAt > Date(timeIntervalSince1970: 1))

        tagged.updatedAt = Date(timeIntervalSince1970: 2)
        var metadata = itemDraft(title: "Timestamp", id: item.id)
        metadata.tags = ["changed"]
        metadata.fieldDrafts[0].isCopyable = false
        let changed = try container.itemRepository.saveItem(metadata)
        #expect(changed.updatedAt > Date(timeIntervalSince1970: 2))
    }

    @Test func failedTransactionRestoresTheOriginalMemorySnapshot() throws {
        let store = VaultMemoryStore()
        store.activate(snapshot: .empty) { throw HardeningTestFailure.expected }
        let repository = SecretItemRepository(store: store)

        var failed = false
        do {
            try store.performTransaction {
                _ = try repository.saveItem(itemDraft(title: "Must Roll Back"))
            }
        } catch {
            failed = true
        }

        #expect(failed)
        #expect(store.items.isEmpty)
    }

    @Test func failedSingleRepositorySaveRestoresTheDisplayedEntityGraph() throws {
        let store = ToggleSaveStore()
        let container = makeContainer("AtomicRepositorySave", vaultStore: store)
        let original = try container.itemRepository.saveItem(itemDraft(title: "Original", value: "old"))
        store.rejectsSaves = true

        #expect(throws: HardeningTestFailure.self) {
            _ = try container.itemRepository.saveItem(
                itemDraft(title: "Changed", id: original.id, value: "new")
            )
        }

        store.rejectsSaves = false
        let restored = try #require(container.memoryStore.items.first { $0.id == original.id })
        #expect(restored.title == "Original")
        #expect(restored.fields.first?.plainValue == "old")
    }

    @Test func failedViewModelSaveReloadsEntitiesSoTheNextEditTargetsTheLiveGraph() throws {
        let store = ToggleSaveStore()
        let container = makeContainer("AtomicSingleViewModel", vaultStore: store)
        let original = try container.itemRepository.saveItem(itemDraft(title: "Original", value: "old"))
        let viewModel = VaultViewModel(container: container)
        var failedDraft = viewModel.draft(forItemID: original.id)
        failedDraft.title = "Failed Edit"
        failedDraft.fieldDrafts[0].value = "failed"
        store.rejectsSaves = true

        viewModel.saveItem(failedDraft)

        #expect(viewModel.items.first?.title == "Original")
        #expect(viewModel.items.first?.fields.first?.plainValue == "old")
        let reloaded = try #require(viewModel.items.first)
        #expect(reloaded !== original)

        store.rejectsSaves = false
        var retry = viewModel.draft(forItemID: original.id)
        retry.title = "Successful Retry"
        retry.fieldDrafts[0].value = "new"
        viewModel.saveItem(retry)
        #expect(viewModel.items.first?.title == "Successful Retry")
        #expect(viewModel.items.first?.fields.first?.plainValue == "new")
    }

    @Test func failedBulkSaveReloadsRestoredEntitiesAndKeepsSelection() throws {
        let store = ToggleSaveStore()
        let container = makeContainer("AtomicBulkViewModel", vaultStore: store)
        let first = try container.itemRepository.saveItem(itemDraft(title: "One"))
        let second = try container.itemRepository.saveItem(itemDraft(title: "Two"))
        let viewModel = VaultViewModel(container: container)
        viewModel.multiSelectedIDs = [first.id, second.id]
        store.rejectsSaves = true

        viewModel.bulkAddFavorite()

        #expect(viewModel.items.allSatisfy { !$0.isFavorite })
        #expect(viewModel.multiSelectedIDs == [first.id, second.id])
        #expect(viewModel.alertMessage == HardeningTestFailure.expected.localizedDescription)
    }

    @Test func undoRecoversItsPreUndoStateWhenTheSecondPersistenceStepFails() throws {
        let store = OneShotSaveFailureStore()
        let container = makeContainer("AtomicUndo", vaultStore: store)
        let item = try container.itemRepository.saveItem(itemDraft(title: "History", value: "one"))
        _ = try container.itemRepository.saveItem(itemDraft(title: "History", id: item.id, value: "two"))
        let viewModel = VaultViewModel(container: container)
        viewModel.purgeAllValueHistory()
        #expect(viewModel.items.first?.fields.first?.previousValues.isEmpty == true)

        // Restoring the undo snapshot succeeds; preference reconciliation is the next save.
        store.failOnSave(numberFromNow: 2)
        viewModel.undoLastDestructiveAction()
        #expect(viewModel.items.first?.fields.first?.previousValues.isEmpty == true)
        #expect(viewModel.undoActionLabel != nil)

        viewModel.undoLastDestructiveAction()
        #expect(viewModel.items.first?.fields.first?.previousValues.map(\.value) == ["one"])
        #expect(viewModel.undoActionLabel == nil)
    }

    @Test func repeatedShiftClickKeepsTheOriginalRangeAnchor() throws {
        let container = makeContainer("StableShiftAnchor")
        let viewModel = VaultViewModel(container: container)
        for title in ["A", "B", "C", "D"] {
            _ = try container.itemRepository.saveItem(itemDraft(title: title))
        }
        viewModel.reload()
        viewModel.sortOrder = .title
        let rows = viewModel.filteredItems

        viewModel.select(rows[1])
        viewModel.extendSelection(to: rows[3])
        #expect(viewModel.multiSelectedItems.map(\.title) == ["B", "C", "D"])
        viewModel.extendSelection(to: rows[0])

        #expect(viewModel.multiSelectedItems.map(\.title) == ["A", "B"])
        #expect(viewModel.selectedItemID == rows[0].id)
    }

    @Test func reusedSecretFindingsWorkForItemsWithTheSameTitle() throws {
        let container = makeContainer("SameTitleReuse")
        _ = try container.itemRepository.saveItem(itemDraft(title: "Same", value: "a-stronger-shared-secret-42"))
        _ = try container.itemRepository.saveItem(itemDraft(title: "Same", value: "a-stronger-shared-secret-42"))
        let viewModel = VaultViewModel(container: container)

        let reused = viewModel.vaultHealthReport().findings.filter { $0.kind == .reused }
        #expect(reused.count == 2)
        #expect(Set(reused.map(\.id)).count == 2)
        #expect(reused.allSatisfy { $0.detail.contains("also used in Same") })
    }

    @Test func whitespaceOnlyFieldIsNotDiscardedByATypeChange() {
        let container = makeContainer("WhitespaceTypeChange")
        let viewModel = VaultViewModel(container: container)
        var draft = itemDraft(title: "Whitespace", value: "   ", isSensitive: false)
        let originalFieldID = draft.fieldDrafts[0].id

        viewModel.applyItemTypeChange(to: &draft, newType: .database)

        #expect(draft.type == .database)
        #expect(draft.fieldDrafts.count == 1)
        #expect(draft.fieldDrafts[0].id == originalFieldID)
        #expect(draft.fieldDrafts[0].value == "   ")
    }

    @Test func duplicateChildIDsAreNormalizedBeforePersistence() throws {
        let container = makeContainer("UniqueChildIDs")
        let sharedFieldID = UUID()
        var draft = itemDraft(title: "Fields")
        draft.fieldDrafts[0].id = sharedFieldID
        draft.fieldDrafts.append(FieldDraft(
            id: sharedFieldID,
            key: "second",
            label: "Second",
            value: "two",
            kind: .secret,
            isSensitive: true,
            sortOrder: 1
        ))
        let item = try container.itemRepository.saveItem(draft)
        #expect(Set(item.fields.map(\.id)).count == 2)

        let sharedDefinitionID = UUID()
        let template = try container.templateRepository.saveTemplate(
            TemplateDraft(
                name: "Unique Definitions",
                itemType: .customTemplate,
                fieldDefinitions: [
                    TemplateFieldDraft(id: sharedDefinitionID, key: "one", label: "One", kind: .text, isSensitive: false, isCopyable: true, isMaskedByDefault: false, sortOrder: 0),
                    TemplateFieldDraft(id: sharedDefinitionID, key: "two", label: "Two", kind: .text, isSensitive: false, isCopyable: true, isMaskedByDefault: false, sortOrder: 1)
                ]
            ),
            isBuiltIn: false
        )
        #expect(Set(template.fieldDefinitions.map(\.id)).count == 2)

        let duplicate = try container.itemRepository.duplicateItem(item)
        #expect(Set(item.fields.map(\.id)).isDisjoint(with: Set(duplicate.fields.map(\.id))))
    }

    @Test func malformedKeySizesAndOversizedSnapshotsAreRejected() throws {
        let keyStore = InMemoryVaultKeyStore(isBiometricHardwareAvailable: true)
        #expect(throws: VaultKeyStoreError.self) {
            try keyStore.saveVaultKey(Data(repeating: 1, count: 31), requireBiometrics: true)
        }

        let now = Date()
        let workspaces = (0...10_000).map { index in
            WorkspaceSnapshot(
                id: UUID(),
                name: "W\(index)",
                icon: "folder",
                colorHex: "#000000",
                notes: "",
                isArchived: false,
                createdAt: now,
                updatedAt: now,
                sortOrder: index
            )
        }
        let oversized = VaultSnapshot(workspaces: workspaces, items: [], customTemplates: [])
        #expect(throws: VaultCryptoError.vaultContentsTooLarge) {
            try oversized.validateResourceLimits()
        }
        let crypto = VaultCryptoService(defaultIterations: 20_000, defaultOpsLimit: 1, defaultMemLimit: 8_192)
        #expect(throws: VaultCryptoError.invalidWrappedKey) {
            _ = try crypto.wrapVaultKey(Data(repeating: 1, count: 31), password: "password")
        }
    }

    @Test func duplicateTopLevelIDsArePreservedAndNormalizedDeterministically() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let workspaceID = UUID()
        let itemID = UUID()
        let templateID = UUID()
        let snapshot = VaultSnapshot(
            workspaces: [
                WorkspaceSnapshot(id: workspaceID, name: "First", icon: "folder", colorHex: "#111111", notes: "", isArchived: false, createdAt: now, updatedAt: now, sortOrder: 0),
                WorkspaceSnapshot(id: workspaceID, name: "Second", icon: "folder", colorHex: "#222222", notes: "", isArchived: false, createdAt: now, updatedAt: now, sortOrder: 1)
            ],
            items: [
                duplicateIDItemSnapshot(id: itemID, title: "First item", workspaceID: workspaceID, templateID: templateID, now: now),
                duplicateIDItemSnapshot(id: itemID, title: "Second item", workspaceID: workspaceID, templateID: templateID, now: now)
            ],
            customTemplates: [
                TemplateSnapshot(id: templateID, itemTypeRawValue: SecretItemType.generic.rawValue, name: "First template", createdAt: now, updatedAt: now, fieldDefinitions: []),
                TemplateSnapshot(id: templateID, itemTypeRawValue: SecretItemType.generic.rawValue, name: "Second template", createdAt: now, updatedAt: now, fieldDefinitions: [])
            ]
        )

        let memory = VaultMemoryStore()
        let first = memory.normalizedSnapshotCopy(snapshot)
        let second = memory.normalizedSnapshotCopy(snapshot)
        let canonicalRoundTrip = memory.normalizedSnapshotCopy(first)

        #expect(first.workspaces.count == 2)
        #expect(first.items.count == 2)
        #expect(first.customTemplates.count == 2)
        #expect(Set(first.workspaces.map(\.id)).count == 2)
        #expect(Set(first.items.map(\.id)).count == 2)
        #expect(Set(first.customTemplates.map(\.id)).count == 2)
        #expect(first.workspaces.map(\.id) == second.workspaces.map(\.id))
        #expect(first.items.map(\.id) == second.items.map(\.id))
        #expect(first.customTemplates.map(\.id) == second.customTemplates.map(\.id))
        #expect(first.workspaces.map(\.id) == canonicalRoundTrip.workspaces.map(\.id))
        #expect(first.items.map(\.id) == canonicalRoundTrip.items.map(\.id))
        #expect(first.customTemplates.map(\.id) == canonicalRoundTrip.customTemplates.map(\.id))
    }

    private func duplicateIDItemSnapshot(
        id: UUID,
        title: String,
        workspaceID: UUID,
        templateID: UUID,
        now: Date
    ) -> SecretItemSnapshot {
        SecretItemSnapshot(
            id: id,
            title: title,
            typeRawValue: SecretItemType.generic.rawValue,
            environmentRawValue: EnvironmentKind.dev.rawValue,
            customEnvironmentName: nil,
            notes: "",
            tagsRawValue: "",
            isFavorite: false,
            isArchived: false,
            createdAt: now,
            updatedAt: now,
            lastAccessedAt: nil,
            workspaceID: workspaceID,
            templateID: templateID,
            fields: []
        )
    }

    // MARK: - Linked files and dotenv parsing

    @Test func linkingDifferentContentsRequiresAnExplicitFirstDirection() async throws {
        let container = makeContainer("InitialLinkConflict")
        let viewModel = VaultViewModel(container: container)
        let item = try container.itemRepository.saveItem(itemDraft(title: "Env", value: "vault"))
        viewModel.reload()

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("initial-link-\(UUID().uuidString).env")
        defer { try? FileManager.default.removeItem(at: url) }
        try "token=file\n".write(to: url, atomically: true, encoding: .utf8)

        await viewModel.linkFile(at: url, to: item, parsedIntoFields: true)
        let status = await viewModel.linkedFileStatus(for: item)
        #expect(status == .needsInitialSync)
    }

    @Test func linkedEnvSerializationKeepsEmptyAndWhitespaceValues() throws {
        let container = makeContainer("EnvExactValues")
        let viewModel = VaultViewModel(container: container)
        let item = try container.itemRepository.saveItem(SecretItemDraft(
            title: "Exact",
            type: .envGroup,
            workspaceID: nil,
            environment: .preset(.dev),
            notes: "",
            tags: [],
            isFavorite: false,
            fieldDrafts: [
                FieldDraft(key: "EMPTY", label: "EMPTY", value: "", kind: .text, isSensitive: false, sortOrder: 0),
                FieldDraft(key: "SPACED", label: "SPACED", value: "  x  ", kind: .text, isSensitive: false, sortOrder: 1)
            ]
        ))
        viewModel.reload()

        let contents = viewModel.envContents(for: item)
        #expect(contents.contains("EMPTY=\"\""))
        #expect(contents.contains("SPACED=\"  x  \""))
    }

    @Test func pickedEnvReadsAreBoundedAndLinkedWritesPreservePermissions() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PassStore-LinkedFile-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let oversizedURL = directory.appendingPathComponent("oversized.env")
        _ = FileManager.default.createFile(atPath: oversizedURL.path, contents: nil)
        let oversizedHandle = try FileHandle(forWritingTo: oversizedURL)
        try oversizedHandle.truncate(atOffset: UInt64(LinkedFileService.maximumReadableFileSize + 1))
        try oversizedHandle.close()
        #expect(throws: LinkedFileError.self) {
            _ = try LinkedFileService.readPickedFile(at: oversizedURL)
        }

        let writableURL = directory.appendingPathComponent("permissions.env")
        try "TOKEN=old\n".write(to: writableURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: writableURL.path)
        let service = LinkedFileService()
        let link = try service.makeLink(to: writableURL, parsedIntoFields: true)
        _ = try service.write("TOKEN=new\n", to: link)
        let attributes = try FileManager.default.attributesOfItem(atPath: writableURL.path)
        let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
        #expect(permissions & 0o777 == 0o640)
    }

    @Test func dotenvHashFragmentsAndFirstClosingQuoteArePreservedCorrectly() {
        let parsed = EnvImportService().parse("""
        COLOR=#fff
        URL=https://example.com/page#section
        COMMENTED=value # note
        QUOTED="first" trailing "second"
        """)
        let values = Dictionary(parsed.entries.map { ($0.key, $0.value) }, uniquingKeysWith: { first, _ in first })
        #expect(values["COLOR"] == "#fff")
        #expect(values["URL"] == "https://example.com/page#section")
        #expect(values["COMMENTED"] == "value")
        #expect(values["QUOTED"] == "first")
    }
}

nonisolated private final class RejectingKeyStore: VaultKeyStore, @unchecked Sendable {
    let isBiometricHardwareAvailable = true
    func saveVaultKey(_ key: Data, requireBiometrics: Bool) throws { throw VaultKeyStoreError.invalidData }
    func readVaultKey(prompt: String) throws -> Data { throw VaultKeyStoreError.itemNotFound }
    func deleteVaultKey() throws { throw VaultKeyStoreError.invalidData }
    func clearLegacySecrets() throws { throw VaultKeyStoreError.invalidData }
}

nonisolated private final class BlockingBiometricKeyStore: VaultKeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var key: Data?
    private var readCount = 0
    private let releases = [DispatchSemaphore(value: 0), DispatchSemaphore(value: 0)]

    let isBiometricHardwareAvailable = true

    var startedReadCount: Int { lock.withLock { readCount } }

    func saveVaultKey(_ key: Data, requireBiometrics: Bool) throws {
        guard requireBiometrics, key.count == 32 else { throw VaultKeyStoreError.invalidData }
        lock.withLock { self.key = key }
    }

    func readVaultKey(prompt: String) throws -> Data {
        let (index, storedKey): (Int, Data?) = lock.withLock {
            let index = readCount
            readCount += 1
            return (index, key)
        }
        guard index < releases.count else { throw VaultKeyStoreError.invalidData }
        releases[index].wait()
        guard let storedKey, storedKey.count == 32 else { throw VaultKeyStoreError.itemNotFound }
        return storedKey
    }

    func releaseRead(_ index: Int) {
        guard releases.indices.contains(index) else { return }
        releases[index].signal()
    }

    func releaseAllReads() {
        for semaphore in releases { semaphore.signal() }
    }

    func deleteVaultKey() throws {}
    func clearLegacySecrets() throws {}
}

@MainActor
private final class RejectingRollbackStore: EncryptedVaultStore {
    private let base = InMemoryEncryptedVaultStore()

    func hasVault() -> Bool { base.hasVault() }
    func loadMetadata() throws -> VaultMetadata { try base.loadMetadata() }
    func loadEnvelope() throws -> VaultEnvelope { try base.loadEnvelope() }
    func save(metadata: VaultMetadata, envelope: VaultEnvelope) throws { try base.save(metadata: metadata, envelope: envelope) }
    func resetSecureVault() throws { try base.resetSecureVault() }
    func resetLegacyArtifacts() throws { try base.resetLegacyArtifacts() }
    func writeRollbackCopy(settingsEnvelope: VaultEnvelope) throws { throw HardeningTestFailure.rollbackUnavailable }
    func rollbackCopyDate() -> Date? { nil }
    func restoreRollbackCopy() throws -> RollbackSettingsPayload? { throw HardeningTestFailure.rollbackUnavailable }
    func discardRollbackCopy() throws { throw HardeningTestFailure.rollbackUnavailable }
}

@MainActor
private final class ToggleSaveStore: EncryptedVaultStore {
    private let base = InMemoryEncryptedVaultStore()
    var rejectsSaves = false

    func hasVault() -> Bool { base.hasVault() }
    func loadMetadata() throws -> VaultMetadata { try base.loadMetadata() }
    func loadEnvelope() throws -> VaultEnvelope { try base.loadEnvelope() }
    func save(metadata: VaultMetadata, envelope: VaultEnvelope) throws {
        if rejectsSaves { throw HardeningTestFailure.expected }
        try base.save(metadata: metadata, envelope: envelope)
    }
    func resetSecureVault() throws { try base.resetSecureVault() }
    func resetLegacyArtifacts() throws { try base.resetLegacyArtifacts() }
    func writeRollbackCopy(settingsEnvelope: VaultEnvelope) throws {
        try base.writeRollbackCopy(settingsEnvelope: settingsEnvelope)
    }
    func rollbackCopyDate() -> Date? { base.rollbackCopyDate() }
    func restoreRollbackCopy() throws -> RollbackSettingsPayload? { try base.restoreRollbackCopy() }
    func discardRollbackCopy() throws { try base.discardRollbackCopy() }
}

@MainActor
private final class OneShotSaveFailureStore: EncryptedVaultStore {
    private let base = InMemoryEncryptedVaultStore()
    private var savesUntilFailure: Int?

    func failOnSave(numberFromNow: Int) {
        precondition(numberFromNow > 0)
        savesUntilFailure = numberFromNow
    }

    func hasVault() -> Bool { base.hasVault() }
    func loadMetadata() throws -> VaultMetadata { try base.loadMetadata() }
    func loadEnvelope() throws -> VaultEnvelope { try base.loadEnvelope() }
    func save(metadata: VaultMetadata, envelope: VaultEnvelope) throws {
        if let remaining = savesUntilFailure {
            if remaining == 1 {
                savesUntilFailure = nil
                throw HardeningTestFailure.expected
            }
            savesUntilFailure = remaining - 1
        }
        try base.save(metadata: metadata, envelope: envelope)
    }
    func resetSecureVault() throws { try base.resetSecureVault() }
    func resetLegacyArtifacts() throws { try base.resetLegacyArtifacts() }
    func writeRollbackCopy(settingsEnvelope: VaultEnvelope) throws {
        try base.writeRollbackCopy(settingsEnvelope: settingsEnvelope)
    }
    func rollbackCopyDate() -> Date? { base.rollbackCopyDate() }
    func restoreRollbackCopy() throws -> RollbackSettingsPayload? { try base.restoreRollbackCopy() }
    func discardRollbackCopy() throws { try base.discardRollbackCopy() }
}
