import AppKit
import Darwin
import Foundation
import LocalAuthentication
import Observation
import Security

private struct BiometricPreferencePersistenceError: LocalizedError {
    let persistenceError: Error
    let recoveryFailures: [String]

    var errorDescription: String? {
        let base = "The Touch ID preference could not be saved: \(persistenceError.localizedDescription)"
        guard !recoveryFailures.isEmpty else { return base }
        return "\(base) PassStore also could not fully restore the prior state: \(recoveryFailures.joined(separator: "; "))"
    }
}

private struct VaultStateRecoveryError: LocalizedError {
    let operation: String
    let operationError: Error
    let recoveryFailures: [String]

    var errorDescription: String? {
        let recovery = recoveryFailures.joined(separator: "; ")
        return "\(operation) failed: \(operationError.localizedDescription) PassStore also could not fully restore the prior state: \(recovery) Lock and reopen the vault before making more changes."
    }
}

@Observable
final class AppSettingsStore {
    var autoLockInterval: TimeInterval {
        didSet { defaults.set(autoLockInterval, forKey: Keys.autoLockInterval) }
    }

    var clipboardClearInterval: TimeInterval {
        didSet { defaults.set(clipboardClearInterval, forKey: Keys.clipboardClearInterval) }
    }

    var biometricsEnabled: Bool {
        didSet { defaults.set(biometricsEnabled, forKey: Keys.biometricsEnabled) }
    }

    /// Raise the Touch ID prompt by itself when the app launches or comes back to the front.
    var unlocksWithBiometricsAutomatically: Bool {
        didSet { defaults.set(unlocksWithBiometricsAutomatically, forKey: Keys.unlocksWithBiometricsAutomatically) }
    }

    /// Lock when the Mac sleeps, the screen locks or the screensaver starts.
    var locksOnSystemLock: Bool {
        didSet { defaults.set(locksOnSystemLock, forKey: Keys.locksOnSystemLock) }
    }

    /// Keep previous values of secret fields so a rotated password can be looked up or restored.
    var keepsSecretValueHistory: Bool {
        didSet { defaults.set(keepsSecretValueHistory, forKey: Keys.keepsSecretValueHistory) }
    }

    /// Check linked `.env` files for on-disk changes when the window comes back to the front.
    var checksLinkedFilesOnFocus: Bool {
        didSet { defaults.set(checksLinkedFilesOnFocus, forKey: Keys.checksLinkedFilesOnFocus) }
    }

    /// Persisted item-list sort order (see `ItemSortOrder`).
    var itemSortOrderRawValue: String {
        didSet { defaults.set(itemSortOrderRawValue, forKey: Keys.itemSortOrder) }
    }

    /// When false, the global ⌘⌥P shortcut is not registered.
    var globalCommandPaletteHotkeyEnabled: Bool {
        didSet {
            defaults.set(globalCommandPaletteHotkeyEnabled, forKey: Keys.globalCommandPaletteHotkeyEnabled)
            NotificationCenter.default.post(name: .passStoreGlobalHotkeySettingsChanged, object: nil)
        }
    }

    private let defaults: UserDefaults

    var sidebarLibraryExpanded: Bool {
        didSet { defaults.set(sidebarLibraryExpanded, forKey: Keys.sidebarLibraryExpanded) }
    }

    var sidebarWorkspacesExpanded: Bool {
        didSet { defaults.set(sidebarWorkspacesExpanded, forKey: Keys.sidebarWorkspacesExpanded) }
    }

    var sidebarTypesExpanded: Bool {
        didSet { defaults.set(sidebarTypesExpanded, forKey: Keys.sidebarTypesExpanded) }
    }

    var sidebarTagsExpanded: Bool {
        didSet { defaults.set(sidebarTagsExpanded, forKey: Keys.sidebarTagsExpanded) }
    }

    var sidebarEnvironmentsExpanded: Bool {
        didSet { defaults.set(sidebarEnvironmentsExpanded, forKey: Keys.sidebarEnvironmentsExpanded) }
    }

    var sidebarTypesOrder: [String] {
        didSet { defaults.set(sidebarTypesOrder, forKey: Keys.sidebarTypesOrder) }
    }

    /// These two arrays may contain client, project or infrastructure names. They are kept in
    /// memory only while unlocked and injected into the encrypted VaultSnapshot on each save.
    var sidebarTagsOrder: [String]
    var sidebarEnvironmentsOrder: [String]

    var hasShownSensitiveCopyWarning: Bool {
        didSet { defaults.set(hasShownSensitiveCopyWarning, forKey: Keys.hasShownSensitiveCopyWarning) }
    }

    private enum Keys {
        static let autoLockInterval = "settings.autoLockInterval"
        static let clipboardClearInterval = "settings.clipboardClearInterval"
        static let biometricsEnabled = "settings.biometricsEnabled"
        static let globalCommandPaletteHotkeyEnabled = "settings.globalCommandPaletteHotkeyEnabled"
        static let sidebarLibraryExpanded = "settings.sidebar.libraryExpanded"
        static let sidebarWorkspacesExpanded = "settings.sidebar.workspacesExpanded"
        static let sidebarTypesExpanded = "settings.sidebar.typesExpanded"
        static let sidebarTagsExpanded = "settings.sidebar.tagsExpanded"
        static let sidebarEnvironmentsExpanded = "settings.sidebar.environmentsExpanded"
        static let sidebarTypesOrder = "settings.sidebar.typesOrder"
        static let sidebarTagsOrder = "settings.sidebar.tagsOrder"
        static let sidebarEnvironmentsOrder = "settings.sidebar.environmentsOrder"
        static let hasShownSensitiveCopyWarning = "settings.hasShownSensitiveCopyWarning"
        static let unlocksWithBiometricsAutomatically = "settings.unlocksWithBiometricsAutomatically"
        static let locksOnSystemLock = "settings.locksOnSystemLock"
        static let keepsSecretValueHistory = "settings.keepsSecretValueHistory"
        static let checksLinkedFilesOnFocus = "settings.checksLinkedFilesOnFocus"
        static let itemSortOrder = "settings.itemSortOrder"

        static let all: [String] = [
            autoLockInterval,
            clipboardClearInterval,
            biometricsEnabled,
            globalCommandPaletteHotkeyEnabled,
            sidebarLibraryExpanded,
            sidebarWorkspacesExpanded,
            sidebarTypesExpanded,
            sidebarTagsExpanded,
            sidebarEnvironmentsExpanded,
            sidebarTypesOrder,
            sidebarTagsOrder,
            sidebarEnvironmentsOrder,
            hasShownSensitiveCopyWarning,
            unlocksWithBiometricsAutomatically,
            locksOnSystemLock,
            keepsSecretValueHistory,
            checksLinkedFilesOnFocus,
            itemSortOrder
        ]
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.autoLockInterval = Self.nearestAllowedInterval(
            defaults.object(forKey: Keys.autoLockInterval) as? Double ?? 300,
            allowed: Self.allowedAutoLockIntervals
        )
        self.clipboardClearInterval = Self.nearestAllowedInterval(
            defaults.object(forKey: Keys.clipboardClearInterval) as? Double ?? 10,
            allowed: Self.allowedClipboardIntervals
        )
        self.biometricsEnabled = defaults.object(forKey: Keys.biometricsEnabled) as? Bool ?? true
        self.globalCommandPaletteHotkeyEnabled = defaults.object(forKey: Keys.globalCommandPaletteHotkeyEnabled) as? Bool ?? true
        self.sidebarLibraryExpanded = defaults.object(forKey: Keys.sidebarLibraryExpanded) as? Bool ?? true
        self.sidebarWorkspacesExpanded = defaults.object(forKey: Keys.sidebarWorkspacesExpanded) as? Bool ?? true
        self.sidebarTypesExpanded = defaults.object(forKey: Keys.sidebarTypesExpanded) as? Bool ?? true
        self.sidebarTagsExpanded = defaults.object(forKey: Keys.sidebarTagsExpanded) as? Bool ?? true
        self.sidebarEnvironmentsExpanded = defaults.object(forKey: Keys.sidebarEnvironmentsExpanded) as? Bool ?? true
        let validTypes = Set(SecretItemType.allCases.map(\.rawValue))
        self.sidebarTypesOrder = Self.sanitizedOrder(
            defaults.stringArray(forKey: Keys.sidebarTypesOrder) ?? []
        ).filter { validTypes.contains($0) }
        // Early 1.2 builds persisted these potentially identifying labels in plaintext.
        // Do not materialize them while the vault is locked; `activate` reads them only after
        // successful authentication and immediately migrates them into the encrypted snapshot.
        self.sidebarTagsOrder = []
        self.sidebarEnvironmentsOrder = []
        self.hasShownSensitiveCopyWarning = defaults.bool(forKey: Keys.hasShownSensitiveCopyWarning)
        self.unlocksWithBiometricsAutomatically = defaults.object(forKey: Keys.unlocksWithBiometricsAutomatically) as? Bool ?? true
        self.locksOnSystemLock = defaults.object(forKey: Keys.locksOnSystemLock) as? Bool ?? true
        self.keepsSecretValueHistory = defaults.object(forKey: Keys.keepsSecretValueHistory) as? Bool ?? true
        self.checksLinkedFilesOnFocus = defaults.object(forKey: Keys.checksLinkedFilesOnFocus) as? Bool ?? true
        self.itemSortOrderRawValue = ItemSortOrder(
            rawValue: defaults.string(forKey: Keys.itemSortOrder) ?? ""
        )?.rawValue ?? ItemSortOrder.title.rawValue
    }

    var itemSortOrder: ItemSortOrder {
        get { ItemSortOrder(rawValue: itemSortOrderRawValue) ?? .title }
        set { itemSortOrderRawValue = newValue.rawValue }
    }

    func makeSettingsSnapshot() -> ExportedSettingsPayload {
        ExportedSettingsPayload(
            autoLockInterval: autoLockInterval,
            clipboardClearInterval: clipboardClearInterval,
            biometricsEnabled: biometricsEnabled,
            globalCommandPaletteHotkeyEnabled: globalCommandPaletteHotkeyEnabled,
            sidebarLibraryExpanded: sidebarLibraryExpanded,
            sidebarWorkspacesExpanded: sidebarWorkspacesExpanded,
            sidebarTypesExpanded: sidebarTypesExpanded,
            sidebarTagsExpanded: sidebarTagsExpanded,
            sidebarEnvironmentsExpanded: sidebarEnvironmentsExpanded,
            sidebarTypesOrder: sidebarTypesOrder,
            sidebarTagsOrder: sidebarTagsOrder,
            sidebarEnvironmentsOrder: sidebarEnvironmentsOrder,
            unlocksWithBiometricsAutomatically: unlocksWithBiometricsAutomatically,
            locksOnSystemLock: locksOnSystemLock,
            keepsSecretValueHistory: keepsSecretValueHistory,
            checksLinkedFilesOnFocus: checksLinkedFilesOnFocus,
            itemSortOrderRawValue: itemSortOrderRawValue
        )
    }

    func applySettings(from payload: ExportedSettingsPayload) {
        // Backup files are untrusted input even after their password is correct. Keep timer
        // values finite/supported and bound arbitrary order arrays before persisting them.
        autoLockInterval = Self.nearestAllowedInterval(
            payload.autoLockInterval,
            allowed: Self.allowedAutoLockIntervals
        )
        clipboardClearInterval = Self.nearestAllowedInterval(
            payload.clipboardClearInterval,
            allowed: Self.allowedClipboardIntervals
        )
        biometricsEnabled = payload.biometricsEnabled
        globalCommandPaletteHotkeyEnabled = payload.globalCommandPaletteHotkeyEnabled
        sidebarLibraryExpanded = payload.sidebarLibraryExpanded
        sidebarWorkspacesExpanded = payload.sidebarWorkspacesExpanded
        sidebarTypesExpanded = payload.sidebarTypesExpanded
        sidebarTagsExpanded = payload.sidebarTagsExpanded
        sidebarEnvironmentsExpanded = payload.sidebarEnvironmentsExpanded
        let validTypes = Set(SecretItemType.allCases.map(\.rawValue))
        sidebarTypesOrder = Self.sanitizedOrder(payload.sidebarTypesOrder)
            .filter { validTypes.contains($0) }
        sidebarTagsOrder = Self.sanitizedOrder(payload.sidebarTagsOrder)
        sidebarEnvironmentsOrder = Self.sanitizedOrder(payload.sidebarEnvironmentsOrder)
        unlocksWithBiometricsAutomatically = payload.unlocksWithBiometricsAutomatically
        locksOnSystemLock = payload.locksOnSystemLock
        keepsSecretValueHistory = payload.keepsSecretValueHistory
        checksLinkedFilesOnFocus = payload.checksLinkedFilesOnFocus
        itemSortOrderRawValue = ItemSortOrder(rawValue: payload.itemSortOrderRawValue)?.rawValue
            ?? ItemSortOrder.title.rawValue
    }

    func applyPrivateSidebarOrders(tags: [String], environments: [String]) {
        sidebarTagsOrder = Self.sanitizedOrder(tags)
        sidebarEnvironmentsOrder = Self.sanitizedOrder(environments)
    }

    /// Reads the plaintext keys written by early 1.2 builds exactly long enough to migrate
    /// them into the encrypted vault. New assignments never write these keys.
    func persistedLegacyPrivateSidebarOrders() -> (tags: [String], environments: [String]) {
        (
            Self.sanitizedOrder(defaults.stringArray(forKey: Keys.sidebarTagsOrder) ?? []),
            Self.sanitizedOrder(defaults.stringArray(forKey: Keys.sidebarEnvironmentsOrder) ?? [])
        )
    }

    func removePersistedPrivateSidebarOrders() {
        defaults.removeObject(forKey: Keys.sidebarTagsOrder)
        defaults.removeObject(forKey: Keys.sidebarEnvironmentsOrder)
    }

    /// Locking releases even this metadata; custom tag and environment names can be as
    /// revealing as item titles. Overwriting Swift strings remains best-effort due to COW.
    func securelyClearPrivateSidebarOrders() {
        for index in sidebarTagsOrder.indices {
            Self.clearString(&sidebarTagsOrder[index])
        }
        for index in sidebarEnvironmentsOrder.indices {
            Self.clearString(&sidebarEnvironmentsOrder[index])
        }
        sidebarTagsOrder.removeAll(keepingCapacity: false)
        sidebarEnvironmentsOrder.removeAll(keepingCapacity: false)
    }

    private static let allowedAutoLockIntervals: [TimeInterval] = [60, 120, 300, 900, 1_800, 3_600]
    private static let allowedClipboardIntervals: [TimeInterval] = [10, 30, 60, 120, 300]

    private static func nearestAllowedInterval(
        _ value: TimeInterval,
        allowed: [TimeInterval]
    ) -> TimeInterval {
        guard value.isFinite else { return allowed[0] }
        return allowed.min { abs($0 - value) < abs($1 - value) } ?? allowed[0]
    }

    private static func sanitizedOrder(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for rawValue in values.prefix(500) {
            let value = String(rawValue.prefix(256)).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, seen.insert(value).inserted else { continue }
            result.append(value)
        }
        return result
    }

    private static func clearString(_ value: inout String) {
        guard !value.isEmpty else { return }
        value = String(repeating: "\0", count: value.utf8.count)
        value.removeAll(keepingCapacity: false)
    }

    /// Restores the in-memory defaults and removes every persisted preference.
    ///
    /// Assigning first keeps live views and services in sync. Removing the keys afterwards
    /// means a subsequent launch starts from defaults rather than from a second persisted copy.
    func resetToDefaults() {
        autoLockInterval = 300
        clipboardClearInterval = 10
        biometricsEnabled = true
        globalCommandPaletteHotkeyEnabled = true
        sidebarLibraryExpanded = true
        sidebarWorkspacesExpanded = true
        sidebarTypesExpanded = true
        sidebarTagsExpanded = true
        sidebarEnvironmentsExpanded = true
        sidebarTypesOrder = []
        sidebarTagsOrder = []
        sidebarEnvironmentsOrder = []
        hasShownSensitiveCopyWarning = false
        unlocksWithBiometricsAutomatically = true
        locksOnSystemLock = true
        keepsSecretValueHistory = true
        checksLinkedFilesOnFocus = true
        itemSortOrderRawValue = ItemSortOrder.title.rawValue

        for key in Keys.all {
            defaults.removeObject(forKey: key)
        }
    }
}

enum VaultLockState: Equatable {
    case setupRequired
    case locked
    case unlocked
}

private struct VaultResetCleanupError: LocalizedError {
    let failures: [String]

    var errorDescription: String? {
        let detail = failures.joined(separator: " ")
        return "PassStore could not remove every vault artefact. \(detail) Try Erase Vault again before creating a new vault."
    }
}

@MainActor
@Observable
final class VaultSessionManager {
    private enum LegacyKeys {
        static let salt = "vault.password.salt"
        static let verifier = "vault.password.verifier"
    }

    var lockState: VaultLockState
    var lastErrorMessage: String?
    var isBiometricAvailable = false
    var isBusy = false
    var onLock: (() -> Void)?

    private let defaults: UserDefaults
    private let settings: AppSettingsStore
    private let cryptoService: VaultCryptoService
    private let vaultStore: EncryptedVaultStore
    private let keyStore: VaultKeyStore
    private let memoryStore: VaultMemoryStore
    private var activeVaultKey: Data?
    private var metadata: VaultMetadata?
    private var lastInteractionAt = Date()
    private var timer: Timer?
    private var eventMonitor: Any?
    /// Sleep / screen-lock observers, kept so they can be torn down together.
    private var systemLockObservers: [(center: NotificationCenter, token: NSObjectProtocol)] = []
    /// Invalidates work that crossed an `await` whenever a lock, reset or newer unlock occurs.
    private var securityGeneration: UInt64 = 0

    // Brute-force protection: progressive delay after failed password attempts.
    private var failedPasswordAttempts = 0
    private var lastFailedAttemptAt: Date?

    private static let lockoutDelays: [(threshold: Int, delay: TimeInterval)] = [
        (5, 30), (4, 10), (3, 5), (2, 2), (1, 1)
    ]

    init(
        defaults: UserDefaults = .standard,
        settings: AppSettingsStore,
        cryptoService: VaultCryptoService,
        vaultStore: EncryptedVaultStore,
        keyStore: VaultKeyStore,
        memoryStore: VaultMemoryStore
    ) {
        self.defaults = defaults
        self.settings = settings
        self.cryptoService = cryptoService
        self.vaultStore = vaultStore
        self.keyStore = keyStore
        self.memoryStore = memoryStore
        self.lockState = vaultStore.hasVault() ? .locked : .setupRequired
        restoreLockoutState()
        refreshBiometricAvailability()
        startMonitoring()
    }

    isolated deinit {
        timer?.invalidate()
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
        }
        for observer in systemLockObservers {
            observer.center.removeObserver(observer.token)
        }
    }

    // MARK: - Vault creation

    /// Creates a vault, deriving the wrapping key off the main actor so the window stays live.
    func createVault(password: String) async {
        guard !isBusy, lockState == .setupRequired, validateNewVaultPassword(password) else { return }
        let operation = beginExclusiveSecurityOperation()
        isBusy = true
        defer { finishExclusiveSecurityOperation(operation) }
        do {
            try performResetCleanup()
            var vaultKey = cryptoService.generateVaultKey()
            defer { Self.overwrite(&vaultKey) }
            let wrappedKey = try await cryptoService.wrapVaultKeyOffMain(vaultKey, password: password)
            try requireCurrentSecurityOperation(operation, expectedState: .setupRequired)
            try finishVaultCreation(vaultKey: vaultKey, wrappedKey: wrappedKey)
        } catch is CancellationError {
            // A system lock or a newer operation superseded this creation attempt.
        } catch {
            guard isSecurityGenerationCurrent(operation, requiring: .setupRequired) else { return }
            lastErrorMessage = error.localizedDescription
        }
    }

    /// Blocking variant. Only for previews, UI-test fixtures and unit tests, which configure a
    /// deliberately cheap KDF; production paths use the `async` version.
    func createVaultSynchronously(password: String) {
        guard !isBusy, lockState == .setupRequired, validateNewVaultPassword(password) else { return }
        _ = beginExclusiveSecurityOperation()
        do {
            try performResetCleanup()
            var vaultKey = cryptoService.generateVaultKey()
            defer { Self.overwrite(&vaultKey) }
            let wrappedKey = try cryptoService.wrapVaultKey(vaultKey, password: password)
            try finishVaultCreation(vaultKey: vaultKey, wrappedKey: wrappedKey)
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    private func validateNewVaultPassword(_ password: String) -> Bool {
        guard password.count >= Self.minimumPasswordLength else {
            lastErrorMessage = password.isEmpty
                ? "Password cannot be empty."
                : "Password must be at least \(Self.minimumPasswordLength) characters."
            return false
        }
        return true
    }

    private func finishVaultCreation(vaultKey: Data, wrappedKey: WrappedVaultKey) throws {
        var metadata = VaultMetadata(
            version: 1,
            wrappedVaultKey: wrappedKey,
            biometricUnlockEnabled: false,
            updatedAt: .now
        )
        // The vault starts with one audit entry so "last changed" has an answer from day one.
        let initialSnapshot = VaultSnapshot(
            workspaces: [],
            items: [],
            customTemplates: [],
            masterPasswordHistory: [MasterPasswordChangeEntry(kind: .vaultCreated)]
        )
        let envelope = try cryptoService.encryptVault(initialSnapshot, using: vaultKey)
        _ = syncBiometricState(using: vaultKey, metadata: &metadata)
        do {
            try vaultStore.save(metadata: metadata, envelope: envelope)
        } catch {
            let operationError = error
            var recoveryFailures: [String] = []
            do { try keyStore.deleteVaultKey() } catch {
                recoveryFailures.append("Keychain: \(error.localizedDescription)")
            }
            do { try vaultStore.resetSecureVault() } catch {
                recoveryFailures.append("encrypted vault: \(error.localizedDescription)")
            }
            guard recoveryFailures.isEmpty else {
                throw VaultStateRecoveryError(
                    operation: "Vault creation",
                    operationError: operationError,
                    recoveryFailures: recoveryFailures
                )
            }
            throw operationError
        }
        let activationWarning = activate(snapshot: initialSnapshot, key: vaultKey, metadata: metadata)
        clearLockout()
        lastErrorMessage = activationWarning
    }

    // MARK: - Unlock

    /// Unlocks with the master password. Argon2id runs off the main actor, so `isBusy` is
    /// actually observable for the duration and the window keeps drawing.
    @discardableResult
    func unlockWithPassword(_ password: String) async -> Bool {
        if let message = lockoutMessage() {
            lastErrorMessage = message
            return false
        }
        guard !isBusy, lockState == .locked else { return false }
        let operation = beginExclusiveSecurityOperation()
        isBusy = true
        defer { finishExclusiveSecurityOperation(operation) }
        do {
            let metadata = try vaultStore.loadMetadata()
            guard metadata.version == 1 else { throw VaultCryptoError.unsupportedVaultVersion }
            let envelope = try vaultStore.loadEnvelope()
            var opened = try await cryptoService.openVaultOffMain(
                metadata: metadata,
                envelope: envelope,
                password: password
            )
            defer { Self.overwrite(&opened.vaultKey) }
            var rewrapped: WrappedVaultKey?
            if Self.isLegacyKDF(metadata) {
                rewrapped = try await cryptoService.wrapVaultKeyOffMain(opened.vaultKey, password: password)
            }
            try requireCurrentSecurityOperation(operation, expectedState: .locked)
            try applyUnlock(
                metadata: metadata,
                envelope: envelope,
                vaultKey: opened.vaultKey,
                snapshot: opened.snapshot,
                rewrappedKey: rewrapped
            )
            return true
        } catch is CancellationError {
            return false
        } catch {
            guard isSecurityGenerationCurrent(operation, requiring: .locked) else { return false }
            handlePasswordUnlockFailure(error)
            return false
        }
    }

    /// Blocking variant, for tests and previews. See `createVaultSynchronously`.
    @discardableResult
    func unlockWithPasswordSynchronously(_ password: String) -> Bool {
        if let message = lockoutMessage() {
            lastErrorMessage = message
            return false
        }
        guard !isBusy, lockState == .locked else { return false }
        _ = beginExclusiveSecurityOperation()
        do {
            let metadata = try vaultStore.loadMetadata()
            guard metadata.version == 1 else { throw VaultCryptoError.unsupportedVaultVersion }
            let envelope = try vaultStore.loadEnvelope()
            var vaultKey = try cryptoService.unwrapVaultKey(metadata.wrappedVaultKey, password: password)
            defer { Self.overwrite(&vaultKey) }
            let snapshot = try cryptoService.decryptVault(envelope, using: vaultKey)
            let rewrapped = Self.isLegacyKDF(metadata)
                ? try cryptoService.wrapVaultKey(vaultKey, password: password)
                : nil
            try applyUnlock(
                metadata: metadata,
                envelope: envelope,
                vaultKey: vaultKey,
                snapshot: snapshot,
                rewrappedKey: rewrapped
            )
            return true
        } catch {
            handlePasswordUnlockFailure(error)
            return false
        }
    }

    /// Legacy PBKDF2 vaults are re-wrapped with Argon2id on the first successful unlock.
    private static func isLegacyKDF(_ metadata: VaultMetadata) -> Bool {
        metadata.wrappedVaultKey.kdfAlgorithm == nil || metadata.wrappedVaultKey.kdfAlgorithm == "pbkdf2-sha256"
    }

    private func applyUnlock(
        metadata: VaultMetadata,
        envelope: VaultEnvelope,
        vaultKey: Data,
        snapshot: VaultSnapshot,
        rewrappedKey: WrappedVaultKey?
    ) throws {
        var updatedMetadata = metadata
        if let rewrappedKey {
            updatedMetadata.wrappedVaultKey = rewrappedKey
        }
        _ = syncBiometricState(using: vaultKey, metadata: &updatedMetadata)
        if updatedMetadata.biometricUnlockEnabled != metadata.biometricUnlockEnabled
            || rewrappedKey != nil {
            // Persist metadata before exposing plaintext. If this write fails the caller stays
            // fully locked instead of returning `false` with an activated memory store.
            updatedMetadata.updatedAt = .now
            do {
                try vaultStore.save(metadata: updatedMetadata, envelope: envelope)
            } catch {
                let operationError = error
                var recoveryFailures: [String] = []
                do {
                    if metadata.biometricUnlockEnabled {
                        try keyStore.saveVaultKey(vaultKey, requireBiometrics: true)
                        settings.biometricsEnabled = true
                    } else {
                        try keyStore.deleteVaultKey()
                        settings.biometricsEnabled = false
                    }
                } catch {
                    recoveryFailures.append("Keychain: \(error.localizedDescription)")
                    settings.biometricsEnabled = false
                    try? keyStore.deleteVaultKey()
                }
                guard recoveryFailures.isEmpty else {
                    throw VaultStateRecoveryError(
                        operation: "Unlock migration",
                        operationError: operationError,
                        recoveryFailures: recoveryFailures
                    )
                }
                throw operationError
            }
        }
        let activationWarning = activate(snapshot: snapshot, key: vaultKey, metadata: updatedMetadata)
        clearLockout()
        lastErrorMessage = activationWarning
    }

    /// True when a Touch ID prompt would succeed right now. Governs the manual "Use Touch ID"
    /// button, which must stay available even when the automatic prompt is suppressed.
    var canAttemptBiometricUnlock: Bool {
        lockState == .locked
            && settings.biometricsEnabled
            && isBiometricAvailable
            && !isBusy
            && !isPresentingBiometricPrompt
    }

    /// True when PassStore should raise the prompt by itself.
    var shouldOfferAutomaticUnlock: Bool {
        canAttemptBiometricUnlock && !suppressesAutomaticUnlock
    }

    /// Set whenever the vault locks, and cleared when the app next goes to the background.
    ///
    /// Locking is a deliberate act. Prompting for Touch ID a moment later — while the owner
    /// is still sitting in front of the window they just locked — undoes it and makes the
    /// lock command look broken. Leaving the app and coming back is a different intent, and
    /// that does prompt again.
    private(set) var suppressesAutomaticUnlock = false

    /// Called when PassStore resigns active, so returning to it prompts normally again.
    func allowAutomaticUnlockOnNextActivation() {
        suppressesAutomaticUnlock = false
    }

    /// Guards against stacking prompts when several triggers fire at once (launch + focus,
    /// or focus bouncing as the Touch ID sheet takes and returns key window status).
    private(set) var isPresentingBiometricPrompt = false

    @discardableResult
    func unlockWithBiometrics() async -> Bool {
        guard settings.biometricsEnabled else {
            lastErrorMessage = "Biometric unlock is disabled."
            return false
        }
        guard !isBusy, !isPresentingBiometricPrompt else { return false }

        guard lockState == .locked else { return false }
        let operation = beginExclusiveSecurityOperation()
        isPresentingBiometricPrompt = true
        isBusy = true
        defer { finishExclusiveSecurityOperation(operation, clearsBiometricPrompt: true) }

        do {
            let metadata = try vaultStore.loadMetadata()
            guard metadata.version == 1 else { throw VaultCryptoError.unsupportedVaultVersion }
            guard metadata.biometricUnlockEnabled else {
                lastErrorMessage = "Biometric unlock is not configured."
                return false
            }
            let envelope = try vaultStore.loadEnvelope()
            // `SecItemCopyMatching` blocks its thread for as long as the Touch ID sheet is up,
            // so it cannot run on the main actor without freezing the window behind the sheet.
            let keyStore = self.keyStore
            let cryptoService = self.cryptoService
            var opened = try await Task.detached(priority: .userInitiated) { () -> (Data, VaultSnapshot) in
                var vaultKey = try keyStore.readVaultKey(prompt: "Unlock PassStore")
                do {
                    return (vaultKey, try cryptoService.decryptVault(envelope, using: vaultKey))
                } catch {
                    VaultCryptoService.overwrite(&vaultKey)
                    throw error
                }
            }.value
            defer { Self.overwrite(&opened.0) }
            try requireCurrentSecurityOperation(operation, expectedState: .locked)
            let activationWarning = activate(snapshot: opened.1, key: opened.0, metadata: metadata)
            clearLockout()
            lastErrorMessage = activationWarning
            return true
        } catch is CancellationError {
            return false
        } catch {
            guard isSecurityGenerationCurrent(operation, requiring: .locked) else { return false }
            // A cancelled prompt is a normal outcome, not an error worth shouting about.
            lastErrorMessage = Self.isUserCancelledBiometrics(error) ? nil : error.localizedDescription
            return false
        }
    }

    /// `errSecUserCanceled` / `LAError.userCancel` mean "I'll type it instead", so the lock
    /// screen should stay quiet rather than showing a scary red line.
    private static func isUserCancelledBiometrics(_ error: Error) -> Bool {
        if case let VaultKeyStoreError.unexpectedStatus(status) = error {
            return status == errSecUserCanceled || status == errSecAuthFailed
        }
        let nsError = error as NSError
        return nsError.domain == LAErrorDomain
            && [LAError.userCancel.rawValue, LAError.appCancel.rawValue, LAError.systemCancel.rawValue].contains(nsError.code)
    }

    // MARK: - Rollback copy

    /// Copies the encrypted vault aside before a destructive operation.
    func writeRollbackCopy() throws {
        guard let activeVaultKey else { throw VaultCryptoError.vaultLocked }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var settingsData = try encoder.encode(settings.makeSettingsSnapshot())
        defer { Self.overwrite(&settingsData) }
        let settingsEnvelope = try cryptoService.encryptEnvelopePayload(
            settingsData,
            using: activeVaultKey
        )
        try vaultStore.writeRollbackCopy(settingsEnvelope: settingsEnvelope)
    }

    func rollbackCopyDate() -> Date? {
        vaultStore.rollbackCopyDate()
    }

    /// Restores the pre-operation vault and locks, so the next unlock reads the restored
    /// files rather than whatever is still in memory.
    func restoreRollbackCopy() throws {
        guard let activeVaultKey else { throw VaultCryptoError.vaultLocked }
        defer {
            // The live graph still represents the imported vault. It must never be flushed
            // over the restored package while the deferred lock tears plaintext down.
            memoryStore.discardPendingPersist()
            lock()
        }
        let restoredSettings = try vaultStore.restoreRollbackCopy()

        // Import can change the biometric preference and therefore the Keychain. Reconcile
        // it against the restored metadata without persisting the still-imported memory store.
        if let restoredSettings {
            let payload: ExportedSettingsPayload
            switch restoredSettings {
            case let .encrypted(envelope):
                var data = try cryptoService.decryptEnvelopePayload(envelope, using: activeVaultKey)
                defer { Self.overwrite(&data) }
                payload = try JSONDecoder().decode(ExportedSettingsPayload.self, from: data)
            case let .legacyPlaintext(legacyPayload):
                payload = legacyPayload
            }
            settings.applySettings(from: payload)
        }
        var restoredMetadata = try vaultStore.loadMetadata()
        guard restoredMetadata.version == 1 else { throw VaultCryptoError.unsupportedVaultVersion }
        let biometricWarning = syncBiometricState(using: activeVaultKey, metadata: &restoredMetadata)
        let restoredEnvelope = try vaultStore.loadEnvelope()
        guard restoredEnvelope.version == 1 else { throw VaultCryptoError.unsupportedVaultVersion }
        var restoredSnapshot = try cryptoService.decryptVault(restoredEnvelope, using: activeVaultKey)
        restoredSnapshot.privateSidebarTagsOrder = settings.sidebarTagsOrder
        restoredSnapshot.privateSidebarEnvironmentsOrder = settings.sidebarEnvironmentsOrder
        let securedEnvelope = try cryptoService.encryptVault(restoredSnapshot, using: activeVaultKey)
        try vaultStore.save(metadata: restoredMetadata, envelope: securedEnvelope)
        try vaultStore.discardRollbackCopy()
        lastErrorMessage = biometricWarning
    }

    func discardRollbackCopy() throws {
        try vaultStore.discardRollbackCopy()
    }

    // MARK: - Reset

    /// Destroys the vault and every derived artefact so the owner can start over.
    ///
    /// There is deliberately no recovery path for a forgotten master password — the whole
    /// design depends on that — but "start over" is not the same as "recover", and without
    /// it a forgotten password left the app permanently stuck at the lock screen with the
    /// only fix being to delete files in `~/Library` by hand.
    func resetVaultDestroyingAllData() throws {
        invalidateSecurityOperations()
        isBusy = false
        isPresentingBiometricPrompt = false
        if let window = NSApp?.keyWindow,
           let textView = window.firstResponder as? NSTextView {
            textView.undoManager?.removeAllActions()
            window.makeFirstResponder(nil)
        }
        memoryStore.clear()
        if activeVaultKey != nil {
            activeVaultKey!.withUnsafeMutableBytes { buffer in
                guard let base = buffer.baseAddress else { return }
                memset(base, 0, buffer.count)
            }
        }
        activeVaultKey = nil
        metadata = nil
        let cleanupError: Error?
        do {
            try performResetCleanup(requiringCompleteKeychainCleanup: true)
            cleanupError = nil
        } catch {
            cleanupError = error
        }
        settings.resetToDefaults()
        clearLockout()
        lockState = vaultStore.hasVault() ? .locked : .setupRequired
        refreshBiometricAvailability()
        lastErrorMessage = cleanupError?.localizedDescription
        onLock?()
        if let cleanupError { throw cleanupError }
    }

    // MARK: - Brute-force lockout
    //
    // Persisted rather than held in memory: an in-memory counter is reset by quitting the
    // app, which makes the delay trivial to skip. The real defence against an attacker with
    // the file is Argon2id, but the on-screen delay should still mean something.

    private enum LockoutKeys {
        static let attempts = "security.failedPasswordAttempts"
        static let lastAttempt = "security.lastFailedAttemptAt"
    }

    /// Nil when a password attempt is allowed, otherwise the message to show.
    private func lockoutMessage() -> String? {
        guard failedPasswordAttempts > 0, let lastFailed = lastFailedAttemptAt else { return nil }
        let required = Self.lockoutDelays.first { failedPasswordAttempts >= $0.threshold }?.delay ?? 0
        let elapsed = Date().timeIntervalSince(lastFailed)
        // A clock moved backwards would otherwise lock the owner out indefinitely.
        guard elapsed >= 0, elapsed < required else { return nil }
        let remaining = Int((required - elapsed).rounded(.up))
        return "Too many failed attempts. Try again in \(remaining)s."
    }

    private func registerFailedAttempt() {
        failedPasswordAttempts = min(failedPasswordAttempts + 1, 5)
        lastFailedAttemptAt = Date()
        defaults.set(failedPasswordAttempts, forKey: LockoutKeys.attempts)
        defaults.set(lastFailedAttemptAt, forKey: LockoutKeys.lastAttempt)
        lastErrorMessage = "Incorrect password or corrupted vault."
    }

    /// Disk/permission failures are operational errors, not guesses at the password. Counting
    /// them towards the brute-force delay can lock the owner out while the correct password is
    /// being used (for example when metadata cannot be rewritten during KDF migration).
    private func handlePasswordUnlockFailure(_ error: Error) {
        // The crypto service maps only wrapped-key authentication failure to this case. A
        // later AES-GCM failure belongs to the vault payload and indicates corruption, not a
        // password guess; retrying the correct password must not create an artificial lockout.
        if error as? VaultCryptoError == .incorrectPassword {
            registerFailedAttempt()
            return
        }
        lastErrorMessage = error.localizedDescription
    }

    private func clearLockout() {
        failedPasswordAttempts = 0
        lastFailedAttemptAt = nil
        defaults.removeObject(forKey: LockoutKeys.attempts)
        defaults.removeObject(forKey: LockoutKeys.lastAttempt)
    }

    private func restoreLockoutState() {
        failedPasswordAttempts = min(max(defaults.integer(forKey: LockoutKeys.attempts), 0), 5)
        lastFailedAttemptAt = defaults.object(forKey: LockoutKeys.lastAttempt) as? Date
    }

    // MARK: - Master password

    /// Re-wraps the existing vault key under a new password. The vault key itself is unchanged, so
    /// stored data needs no re-encryption and the biometric Keychain entry stays valid.
    /// Requires the current password: an unlocked window should not be enough to lock the owner out.
    ///
    /// Both derivations run off the main actor — this is the slowest operation in the app
    /// (two full Argon2id passes) and it used to freeze the settings sheet solid.
    func changeMasterPassword(current: String, to newPassword: String) async throws {
        guard !isBusy, lockState == .unlocked, var metadata, let activeVaultKey else {
            throw VaultCryptoError.vaultLocked
        }
        guard !newPassword.isEmpty else { throw VaultCryptoError.emptyPassword }
        guard newPassword.count >= Self.minimumPasswordLength else {
            throw VaultCryptoError.passwordTooShort(Self.minimumPasswordLength)
        }

        let operation = beginExclusiveSecurityOperation()
        isBusy = true
        defer { finishExclusiveSecurityOperation(operation) }

        // The AES-GCM auth tag makes a successful unwrap proof that `current` is right. Keep
        // malformed metadata distinguishable from a wrong password, and verify the unwrapped
        // key still matches the live session before persisting a new wrapper around it.
        var currentKey: Data
        do {
            currentKey = try await cryptoService.unwrapVaultKeyOffMain(
                metadata.wrappedVaultKey,
                password: current
            )
        } catch VaultCryptoError.incorrectPassword {
            throw VaultCryptoError.incorrectCurrentPassword
        }
        defer { Self.overwrite(&currentKey) }
        try requireCurrentSecurityOperation(operation, expectedState: .unlocked)
        guard currentKey == activeVaultKey else { throw VaultCryptoError.invalidWrappedKey }
        guard newPassword != current else { throw VaultCryptoError.newPasswordMustDiffer }

        metadata.wrappedVaultKey = try await cryptoService.wrapVaultKeyOffMain(currentKey, password: newPassword)
        try requireCurrentSecurityOperation(operation, expectedState: .unlocked)
        metadata.updatedAt = .now
        let previousMetadata = self.metadata
        let previousHistory = memoryStore.masterPasswordHistory
        // Recorded before the save so the new entry rides along in the same encrypted write.
        memoryStore.recordMasterPasswordChange(.changed)
        do {
            try saveCurrentVault(metadataOverride: metadata)
        } catch {
            let operationError = error
            // Keep the running session and the on-disk password in agreement. A store may
            // throw after touching a file, so retry the exact prior state as a repair.
            memoryStore.masterPasswordHistory = previousHistory
            self.metadata = previousMetadata
            var recoveryFailures: [String] = []
            if let previousMetadata {
                do {
                    let previousEnvelope = try cryptoService.encryptVault(
                        currentSnapshotIncludingPrivateSettings(),
                        using: currentKey
                    )
                    try vaultStore.save(metadata: previousMetadata, envelope: previousEnvelope)
                } catch {
                    recoveryFailures.append("encrypted vault: \(error.localizedDescription)")
                }
            }
            if !recoveryFailures.isEmpty {
                lock()
                throw VaultStateRecoveryError(
                    operation: "Master password change",
                    operationError: operationError,
                    recoveryFailures: recoveryFailures
                )
            }
            throw operationError
        }
    }

    /// Newest-first record of master password events, or empty while locked.
    var masterPasswordHistory: [MasterPasswordChangeEntry] {
        guard lockState == .unlocked else { return [] }
        return memoryStore.masterPasswordHistory
    }

    /// When the master password was last rotated. Nil if it has never been changed since
    /// the vault was created, or if the vault predates 1.1.1.
    var masterPasswordLastChangedAt: Date? {
        masterPasswordHistory
            .filter { $0.kind == .changed }
            .map(\.changedAt)
            .max()
    }

    nonisolated static let minimumPasswordLength = 8

    func syncBiometricPreferenceIfUnlocked() throws {
        guard lockState == .unlocked, let activeVaultKey, var metadata else {
            refreshBiometricAvailability()
            return
        }
        // The setting's didSet fires before this method. If a master-password operation owns
        // the metadata, revert the toggle to its committed value instead of racing and later
        // having one operation silently overwrite the other.
        if isBusy {
            guard settings.biometricsEnabled == metadata.biometricUnlockEnabled else {
                settings.biometricsEnabled = metadata.biometricUnlockEnabled
                throw VaultCryptoError.securityOperationInProgress
            }
            refreshBiometricAvailability()
            return
        }
        let previousMetadata = metadata
        let biometricWarning = syncBiometricState(using: activeVaultKey, metadata: &metadata)
        do {
            try saveCurrentVault(metadataOverride: metadata)
            lastErrorMessage = biometricWarning
        } catch {
            let persistenceError = error
            self.metadata = previousMetadata

            // The Keychain was changed before the encrypted metadata write. If that write
            // fails, put both the preference and the key back exactly as they were so the
            // running session, on-disk metadata and next lock screen cannot disagree.
            var recoveryFailures: [String] = []
            do {
                if previousMetadata.biometricUnlockEnabled {
                    try keyStore.saveVaultKey(activeVaultKey, requireBiometrics: true)
                    settings.biometricsEnabled = true
                } else {
                    try keyStore.deleteVaultKey()
                    settings.biometricsEnabled = false
                }
            } catch {
                recoveryFailures.append("Keychain: \(error.localizedDescription)")
                // Fail closed: even if an old Keychain item could not be removed, the app
                // must not offer or attempt biometric unlock with inconsistent metadata.
                settings.biometricsEnabled = false
                try? keyStore.deleteVaultKey()
            }

            // A file-backed store may throw after replacing one of its two files. Repair the
            // complete old pair as well; otherwise the next launch could observe the failed
            // preference even though this session reverted it.
            do {
                let previousEnvelope = try cryptoService.encryptVault(
                    currentSnapshotIncludingPrivateSettings(),
                    using: activeVaultKey
                )
                try vaultStore.save(metadata: previousMetadata, envelope: previousEnvelope)
            } catch {
                recoveryFailures.append("encrypted vault: \(error.localizedDescription)")
                settings.biometricsEnabled = false
            }
            refreshBiometricAvailability()
            let surfaced = BiometricPreferencePersistenceError(
                persistenceError: persistenceError,
                recoveryFailures: recoveryFailures
            )
            lastErrorMessage = surfaced.localizedDescription
            throw surfaced
        }
    }

    func lock() {
        invalidateSecurityOperations()
        isBusy = false
        isPresentingBiometricPrompt = false
        // AppKit's field editor can retain typed values in its undo stack after SwiftUI has
        // removed the editor. Locking is a hard plaintext boundary, so drop that history and
        // end editing before the bound view state is cleared.
        if let window = NSApp?.keyWindow,
           let textView = window.firstResponder as? NSTextView {
            textView.undoManager?.removeAllActions()
            window.makeFirstResponder(nil)
        }
        // Persist coalesced last-access timestamps while the encryption key and metadata are
        // still available. Clearing them first made every immediate lock silently lose this
        // final write.
        memoryStore.flushPendingPersist()
        // Overwrite key bytes before releasing the reference so the material
        // doesn't linger in freed memory pages.
        if activeVaultKey != nil {
            activeVaultKey!.withUnsafeMutableBytes { buffer in
                guard let base = buffer.baseAddress else { return }
                memset(base, 0, buffer.count)
            }
        }
        activeVaultKey = nil
        metadata = nil
        memoryStore.clear()
        settings.securelyClearPrivateSidebarOrders()
        // The failed-attempt penalty is deliberately left alone: a successful unlock clears
        // it, and locking must not become a way to shrug one off.
        // Do not immediately offer to undo what was just asked for.
        suppressesAutomaticUnlock = true
        lockState = vaultStore.hasVault() ? .locked : .setupRequired
        refreshBiometricAvailability()
        onLock?()
    }

    func touchInteraction() {
        // Avoid mutating observable state on every keypress while locked (password field); not needed for auto-lock anyway.
        guard lockState == .unlocked else { return }
        lastInteractionAt = .now
    }

    func saveCurrentVault(metadataOverride: VaultMetadata? = nil) throws {
        guard let activeVaultKey else { throw VaultCryptoError.vaultLocked }
        let metadata = metadataOverride ?? self.metadata
        guard var metadata else { throw VaultCryptoError.metadataMissing }
        metadata.updatedAt = .now
        let snapshot = currentSnapshotIncludingPrivateSettings()
        let envelope = try cryptoService.encryptVault(snapshot, using: activeVaultKey)
        try vaultStore.save(metadata: metadata, envelope: envelope)
        self.metadata = metadata
        // Early 1.2 builds wrote user-defined tag/environment labels to UserDefaults. Once
        // any encrypted save succeeds, the migrated values are durable and the plaintext
        // compatibility copy should not remain until a later lock/unlock cycle.
        settings.removePersistedPrivateSidebarOrders()
    }

    private func currentSnapshotIncludingPrivateSettings() -> VaultSnapshot {
        var snapshot = memoryStore.makeSnapshot()
        snapshot.privateSidebarTagsOrder = settings.sidebarTagsOrder
        snapshot.privateSidebarEnvironmentsOrder = settings.sidebarEnvironmentsOrder
        return snapshot
    }

    @discardableResult
    private func activate(snapshot: VaultSnapshot, key: Data, metadata: VaultMetadata) -> String? {
        let legacyOrders = settings.persistedLegacyPrivateSidebarOrders()
        let needsPrivateMetadataMigration = snapshot.privateSidebarTagsOrder == nil
            || snapshot.privateSidebarEnvironmentsOrder == nil
        settings.applyPrivateSidebarOrders(
            tags: snapshot.privateSidebarTagsOrder ?? legacyOrders.tags,
            environments: snapshot.privateSidebarEnvironmentsOrder ?? legacyOrders.environments
        )
        activeVaultKey = key
        self.metadata = metadata
        memoryStore.activate(snapshot: snapshot) { [weak self] in
            try self?.saveCurrentVault()
        }
        lockState = .unlocked
        touchInteraction()
        refreshBiometricAvailability()
        guard needsPrivateMetadataMigration else {
            settings.removePersistedPrivateSidebarOrders()
            return nil
        }
        do {
            try saveCurrentVault()
            settings.removePersistedPrivateSidebarOrders()
            return nil
        } catch {
            return "The vault unlocked, but PassStore could not move private sidebar metadata into the encrypted vault (\(error.localizedDescription)). It will retry on the next unlock."
        }
    }

    private func syncBiometricState(using vaultKey: Data, metadata: inout VaultMetadata) -> String? {
        if settings.biometricsEnabled && keyStore.isBiometricHardwareAvailable {
            do {
                try keyStore.saveVaultKey(vaultKey, requireBiometrics: true)
                metadata.biometricUnlockEnabled = true
                return nil
            } catch {
                try? keyStore.deleteVaultKey()
                metadata.biometricUnlockEnabled = false
                settings.biometricsEnabled = false
                return error.localizedDescription
            }
        } else {
            do {
                try keyStore.deleteVaultKey()
            } catch {
                metadata.biometricUnlockEnabled = false
                return "Touch ID is disabled, but its old Keychain item could not be removed: \(error.localizedDescription)"
            }
            metadata.biometricUnlockEnabled = false
            return nil
        }
    }

    private func refreshBiometricAvailability() {
        let metadata = try? vaultStore.loadMetadata()
        isBiometricAvailable = settings.biometricsEnabled
            && keyStore.isBiometricHardwareAvailable
            && (metadata?.biometricUnlockEnabled ?? false)
    }

    private func performResetCleanup(requiringCompleteKeychainCleanup: Bool = false) throws {
        var failures: [String] = []
        do { try keyStore.deleteVaultKey() } catch {
            if requiringCompleteKeychainCleanup {
                failures.append("Keychain key: \(error.localizedDescription)")
            }
        }
        do { try keyStore.clearLegacySecrets() } catch {
            if requiringCompleteKeychainCleanup {
                failures.append("Legacy Keychain data: \(error.localizedDescription)")
            }
        }
        do { try vaultStore.resetSecureVault() } catch {
            failures.append("Encrypted vault files: \(error.localizedDescription)")
        }
        do { try vaultStore.resetLegacyArtifacts() } catch {
            failures.append("Legacy vault files: \(error.localizedDescription)")
        }
        defaults.removeObject(forKey: LegacyKeys.salt)
        defaults.removeObject(forKey: LegacyKeys.verifier)
        guard failures.isEmpty else { throw VaultResetCleanupError(failures: failures) }
    }

    /// Token used by view-model operations that must not install results after a lock.
    func captureSecurityGeneration() -> UInt64 {
        securityGeneration
    }

    func isSecurityGenerationCurrent(_ generation: UInt64, requiring state: VaultLockState = .unlocked) -> Bool {
        securityGeneration == generation && lockState == state
    }

    private func beginExclusiveSecurityOperation() -> UInt64 {
        securityGeneration &+= 1
        return securityGeneration
    }

    private func invalidateSecurityOperations() {
        securityGeneration &+= 1
    }

    /// An invalidated operation may finish after a newer unlock has already started. Only the
    /// operation that still owns the generation may clear shared progress/prompt state;
    /// otherwise the older task makes the UI accept a third expensive KDF concurrently.
    private func finishExclusiveSecurityOperation(
        _ generation: UInt64,
        clearsBiometricPrompt: Bool = false
    ) {
        guard securityGeneration == generation else { return }
        isBusy = false
        if clearsBiometricPrompt {
            isPresentingBiometricPrompt = false
        }
    }

    private func requireCurrentSecurityOperation(_ generation: UInt64, expectedState: VaultLockState) throws {
        guard isSecurityGenerationCurrent(generation, requiring: expectedState), !Task.isCancelled else {
            throw CancellationError()
        }
    }

    private static func overwrite(_ data: inout Data) {
        data.withUnsafeMutableBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            memset(base, 0, buffer.count)
        }
        data.removeAll(keepingCapacity: false)
    }

    private func startMonitoring() {
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard self.lockState == .unlocked else { return }
                if Date().timeIntervalSince(self.lastInteractionAt) >= self.settings.autoLockInterval {
                    self.lock()
                }
            }
        }
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .scrollWheel]) { [weak self] event in
            self?.touchInteraction()
            return event
        }
        installSystemLockTriggers()
    }

    /// Locks when the Mac itself becomes unattended.
    ///
    /// The inactivity timer alone was not enough: closing the lid or hitting the screensaver
    /// hotkey left the vault unlocked in memory for as long as the auto-lock interval, which
    /// is exactly the moment it should have been sealed.
    private func installSystemLockTriggers() {
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        let distributedCenter = DistributedNotificationCenter.default()

        let workspaceTriggers: [Notification.Name] = [
            NSWorkspace.willSleepNotification,
            NSWorkspace.screensDidSleepNotification,
            NSWorkspace.sessionDidResignActiveNotification
        ]
        for name in workspaceTriggers {
            let token = workspaceCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.lockForSystemEvent() }
            }
            systemLockObservers.append((center: workspaceCenter, token: token))
        }

        // Screen lock / screensaver start are only published on the distributed centre.
        for name in ["com.apple.screenIsLocked", "com.apple.screensaver.didstart"] {
            let token = distributedCenter.addObserver(
                forName: Notification.Name(name),
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in self?.lockForSystemEvent() }
            }
            systemLockObservers.append((center: distributedCenter, token: token))
        }
    }

    /// Internal so the race between a system lock and an in-flight unlock can be covered by
    /// a deterministic regression test without synthesising global macOS notifications.
    func lockForSystemEvent() {
        guard settings.locksOnSystemLock else { return }
        // Calling `lock()` while an unlock/create task is in flight invalidates its token even
        // though the visible state is already `.locked`/`.setupRequired`.
        lock()
    }
}

@Observable
final class ClipboardService {
    var lastCopiedDescription = ""

    private let settings: AppSettingsStore
    private var timer: Timer?
    private var ownedChangeCount: Int?
    init(settings: AppSettingsStore) {
        self.settings = settings
    }

    isolated deinit {
        timer?.invalidate()
    }

    var shouldWarnAboutSensitiveCopy: Bool {
        !settings.hasShownSensitiveCopyWarning
    }

    func markSensitiveCopyWarningShown() {
        settings.hasShownSensitiveCopyWarning = true
    }

    func copy(_ string: String, label: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        // Signal clipboard managers (and macOS Handoff/Universal Clipboard) to skip this item.
        // This is the de-facto convention used by 1Password, Safari, and other security apps.
        pasteboard.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        pasteboard.setString(string, forType: .string)
        ownedChangeCount = pasteboard.changeCount
        lastCopiedDescription = label
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: settings.clipboardClearInterval, repeats: false) { [weak self] _ in
            self?.clearIfOwned()
        }
    }

    func clearIfOwned() {
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount == ownedChangeCount else {
            // Another app now owns the clipboard. Leave its data alone but retire our stale
            // status so the UI no longer claims a PassStore value is pending. The pasteboard
            // change counter already identifies ownership, so retaining a dictionary-attackable
            // hash of the copied secret (and reading the plaintext back) is unnecessary.
            ownedChangeCount = nil
            lastCopiedDescription = ""
            return
        }
        pasteboard.clearContents()
        ownedChangeCount = nil
        lastCopiedDescription = ""
    }

    func resetSessionState() {
        clearIfOwned()
        timer?.invalidate()
        ownedChangeCount = nil
        lastCopiedDescription = ""
    }
}
