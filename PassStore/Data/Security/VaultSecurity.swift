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

    /// When false, no global shortcut is registered at all.
    var globalCommandPaletteHotkeyEnabled: Bool {
        didSet {
            defaults.set(globalCommandPaletteHotkeyEnabled, forKey: Keys.globalCommandPaletteHotkeyEnabled)
            NotificationCenter.default.post(name: .passStoreGlobalHotkeySettingsChanged, object: nil)
        }
    }

    /// Virtual key code of the global shortcut. ⌘⌥P was hard-wired until 1.4, which meant an app
    /// that already owned that chord left PassStore with no shortcut and no way to move it.
    var globalHotkeyKeyCode: Int {
        didSet {
            defaults.set(globalHotkeyKeyCode, forKey: Keys.globalHotkeyKeyCode)
            NotificationCenter.default.post(name: .passStoreGlobalHotkeySettingsChanged, object: nil)
        }
    }

    /// Carbon modifier mask (`cmdKey`, `optionKey`, `controlKey`, `shiftKey`).
    var globalHotkeyModifiers: Int {
        didSet {
            defaults.set(globalHotkeyModifiers, forKey: Keys.globalHotkeyModifiers)
            NotificationCenter.default.post(name: .passStoreGlobalHotkeySettingsChanged, object: nil)
        }
    }

    /// How the chord is written on screen, captured when it was recorded.
    ///
    /// Stored rather than derived: turning a virtual key code back into the character printed on
    /// the key means consulting the active keyboard layout, and the layout that recorded it is the
    /// one that got it right.
    var globalHotkeyDisplay: String {
        didSet { defaults.set(globalHotkeyDisplay, forKey: Keys.globalHotkeyDisplay) }
    }

    /// Start PassStore when you log in. Managed by the system, not by a login item we install.
    var launchesAtLogin: Bool {
        didSet { defaults.set(launchesAtLogin, forKey: Keys.launchesAtLogin) }
    }

    /// Live in the menu bar with no Dock icon.
    var showsInMenuBarOnly: Bool {
        didSet {
            defaults.set(showsInMenuBarOnly, forKey: Keys.showsInMenuBarOnly)
            NotificationCenter.default.post(name: .passStoreActivationPolicyChanged, object: nil)
        }
    }

    /// The chord PassStore ships with.
    nonisolated static let defaultHotkeyKeyCode = 35 // kVK_ANSI_P
    nonisolated static let defaultHotkeyModifiers = 0x0100 | 0x0800 // cmdKey | optionKey
    nonisolated static let defaultHotkeyDisplay = "⌘⌥P"

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

    /// Workspaces whose environments are showing in the sidebar.
    ///
    /// Unlike tag and environment *names*, an id names nothing: it is safe in plain
    /// `UserDefaults` alongside the rest of the sidebar's layout state. It is deliberately not
    /// part of a backup either — it points at ids that a restored vault may not even contain.
    var expandedWorkspaceIDs: Set<UUID> {
        didSet {
            defaults.set(expandedWorkspaceIDs.map(\.uuidString), forKey: Keys.expandedWorkspaceIDs)
        }
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
        static let expandedWorkspaceIDs = "settings.sidebar.expandedWorkspaceIDs"
        static let sidebarTagsOrder = "settings.sidebar.tagsOrder"
        static let sidebarEnvironmentsOrder = "settings.sidebar.environmentsOrder"
        static let hasShownSensitiveCopyWarning = "settings.hasShownSensitiveCopyWarning"
        static let unlocksWithBiometricsAutomatically = "settings.unlocksWithBiometricsAutomatically"
        static let locksOnSystemLock = "settings.locksOnSystemLock"
        static let keepsSecretValueHistory = "settings.keepsSecretValueHistory"
        static let checksLinkedFilesOnFocus = "settings.checksLinkedFilesOnFocus"
        static let itemSortOrder = "settings.itemSortOrder"
        static let globalHotkeyKeyCode = "settings.globalHotkeyKeyCode"
        static let globalHotkeyModifiers = "settings.globalHotkeyModifiers"
        static let globalHotkeyDisplay = "settings.globalHotkeyDisplay"
        static let launchesAtLogin = "settings.launchesAtLogin"
        static let showsInMenuBarOnly = "settings.showsInMenuBarOnly"

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
            expandedWorkspaceIDs,
            sidebarTagsOrder,
            sidebarEnvironmentsOrder,
            hasShownSensitiveCopyWarning,
            unlocksWithBiometricsAutomatically,
            locksOnSystemLock,
            keepsSecretValueHistory,
            checksLinkedFilesOnFocus,
            itemSortOrder,
            globalHotkeyKeyCode,
            globalHotkeyModifiers,
            globalHotkeyDisplay,
            launchesAtLogin,
            showsInMenuBarOnly
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
        self.expandedWorkspaceIDs = Set(
            (defaults.stringArray(forKey: Keys.expandedWorkspaceIDs) ?? [])
                .prefix(500)
                .compactMap(UUID.init(uuidString:))
        )
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
        self.globalHotkeyKeyCode = defaults.object(forKey: Keys.globalHotkeyKeyCode) as? Int
            ?? Self.defaultHotkeyKeyCode
        self.globalHotkeyModifiers = Self.sanitizedHotkeyModifiers(
            defaults.object(forKey: Keys.globalHotkeyModifiers) as? Int ?? Self.defaultHotkeyModifiers
        )
        self.globalHotkeyDisplay = defaults.string(forKey: Keys.globalHotkeyDisplay)?.nilIfEmptyValue
            ?? Self.defaultHotkeyDisplay
        self.launchesAtLogin = defaults.bool(forKey: Keys.launchesAtLogin)
        self.showsInMenuBarOnly = defaults.bool(forKey: Keys.showsInMenuBarOnly)
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

    /// Keeps a recorded chord to something that can be a global shortcut.
    ///
    /// At least one of Command, Option or Control has to be in it. A bare letter — or one with only
    /// Shift — registered system-wide would intercept that key in every application, which for a
    /// password manager is indistinguishable from a keylogger by anybody watching.
    nonisolated static func sanitizedHotkeyModifiers(_ raw: Int) -> Int {
        let allowed = raw & (cmdKeyMask | optionKeyMask | controlKeyMask | shiftKeyMask)
        guard allowed & (cmdKeyMask | optionKeyMask | controlKeyMask) != 0 else {
            return defaultHotkeyModifiers
        }
        return allowed
    }

    /// Carbon modifier bits, spelled out so this file does not have to import Carbon.
    nonisolated static let cmdKeyMask = 0x0100
    nonisolated static let shiftKeyMask = 0x0200
    nonisolated static let optionKeyMask = 0x0800
    nonisolated static let controlKeyMask = 0x1000

    var isUsingDefaultHotkey: Bool {
        globalHotkeyKeyCode == Self.defaultHotkeyKeyCode
            && globalHotkeyModifiers == Self.defaultHotkeyModifiers
    }

    func resetHotkeyToDefault() {
        globalHotkeyKeyCode = Self.defaultHotkeyKeyCode
        globalHotkeyModifiers = Self.defaultHotkeyModifiers
        globalHotkeyDisplay = Self.defaultHotkeyDisplay
    }

    /// Records a chord, rejecting one with no usable modifier.
    @discardableResult
    func setHotkey(keyCode: Int, modifiers: Int, display: String) -> Bool {
        let sanitized = Self.sanitizedHotkeyModifiers(modifiers)
        guard sanitized == modifiers & (Self.cmdKeyMask | Self.optionKeyMask | Self.controlKeyMask | Self.shiftKeyMask),
              !display.isEmpty else {
            return false
        }
        globalHotkeyKeyCode = keyCode
        globalHotkeyModifiers = sanitized
        globalHotkeyDisplay = display
        return true
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
        expandedWorkspaceIDs = []
        sidebarTagsOrder = []
        sidebarEnvironmentsOrder = []
        hasShownSensitiveCopyWarning = false
        unlocksWithBiometricsAutomatically = true
        locksOnSystemLock = true
        keepsSecretValueHistory = true
        checksLinkedFilesOnFocus = true
        itemSortOrderRawValue = ItemSortOrder.title.rawValue
        globalHotkeyKeyCode = Self.defaultHotkeyKeyCode
        globalHotkeyModifiers = Self.defaultHotkeyModifiers
        globalHotkeyDisplay = Self.defaultHotkeyDisplay
        launchesAtLogin = false
        showsInMenuBarOnly = false

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
    /// Identifies this install in the metadata it writes. See `VaultMetadata.lastWriterID`.
    private let installIdentifier: String
    /// The write counter this session last read or wrote. Anything else on disk means another
    /// copy of PassStore wrote the vault while this one had it open.
    private var loadedWriteCounter = 0
    /// Set when a save was refused because the vault moved underneath us, so the UI can offer the
    /// two ways out instead of only reporting a failure.
    private(set) var hasForeignChange = false
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
        memoryStore: VaultMemoryStore,
        installIdentifier: String = UUID().uuidString
    ) {
        self.installIdentifier = installIdentifier
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
            metadata = try writeVault(metadata: metadata, envelope: envelope)
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
            // Read the file rather than the cache. A vault in a synced folder can have been
            // rewritten since this process last looked, and unlocking a stale copy would show the
            // wrong contents and then refuse to save them.
            let metadata = try vaultStore.loadMetadataFromStorage()
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
            let metadata = try vaultStore.loadMetadataFromStorage()
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
        // Adopt the version that was just read before anything is written from it. The migration
        // write below is based on this metadata, and comparing it against a counter left over from
        // before the last lock would report a conflict with nobody.
        loadedWriteCounter = metadata.writeCounter
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
                updatedMetadata = try writeVault(metadata: updatedMetadata, envelope: envelope)
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
            let metadata = try vaultStore.loadMetadataFromStorage()
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
        // Deliberately replaces whatever is on disk — that is the whole point of a rollback — so
        // the foreign-write check is skipped rather than blocking the way out of a bad import.
        try writeVault(metadata: restoredMetadata, envelope: securedEnvelope, checkingForForeignWrite: false)
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
    /// Whether erasing has to be authorised first.
    ///
    /// Wiping a vault is destructive and, from the lock screen, reachable by anyone sitting at
    /// an unattended Mac. Where Touch ID is configured there is no reason to allow it
    /// unauthenticated: someone who can pass Touch ID can simply unlock instead, so gating it
    /// costs the owner nothing and removes the "walk up and destroy" case entirely.
    ///
    /// Without Touch ID the gate cannot exist — the whole point of this escape hatch is that
    /// the master password is gone — so the typed confirmation stands on its own. That is no
    /// weaker than the alternative already available to anyone at the machine: deleting the
    /// vault files in Finder.
    var requiresBiometricAuthorisationToErase: Bool {
        settings.biometricsEnabled && isBiometricAvailable && keyStore.isBiometricHardwareAvailable
    }

    /// Confirms the owner's identity before an erase, when that is possible.
    func authoriseErase() async -> Bool {
        guard requiresBiometricAuthorisationToErase else { return true }
        let context = LAContext()
        context.localizedReason = "Erase the PassStore vault"
        do {
            return try await context.evaluatePolicy(
                .deviceOwnerAuthenticationWithBiometrics,
                localizedReason: "Erase the PassStore vault"
            )
        } catch {
            lastErrorMessage = Self.isUserCancelledBiometrics(error)
                ? nil
                : "Erase was not authorised: \(error.localizedDescription)"
            return false
        }
    }

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
        loadedWriteCounter = 0
        hasForeignChange = false
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
                    // A repair write putting back the state that was already there.
                    try writeVault(metadata: previousMetadata, envelope: previousEnvelope, checkingForForeignWrite: false)
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
                // A repair write putting back the state that was already there.
                try writeVault(metadata: previousMetadata, envelope: previousEnvelope, checkingForForeignWrite: false)
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
        // Forget which version was held. The next unlock adopts whatever is on disk then — without
        // this, unlocking a vault a sync client had rolled back would look like a conflict.
        loadedWriteCounter = 0
        hasForeignChange = false
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

    /// Writes out anything this session still owes before the vault file is copied or moved.
    func flushPendingWrites() {
        memoryStore.flushPendingPersist()
    }

    /// Re-reads the situation after the store has been pointed at a different vault file.
    ///
    /// The biometric Keychain entry is dropped on purpose: it holds the key to the vault being
    /// left behind, and offering Touch ID for a vault it cannot open produces a decryption failure
    /// that looks like corruption. One password unlock re-establishes it.
    func refreshAfterVaultFileChange() {
        try? keyStore.deleteVaultKey()
        loadedWriteCounter = 0
        hasForeignChange = false
        lastErrorMessage = nil
        clearLockout()
        lockState = vaultStore.hasVault() ? .locked : .setupRequired
        refreshBiometricAvailability()
    }

    // MARK: - Writing, and who wrote last
    //
    // A vault in a synced folder can be open on two Macs at once. Neither of them can see the
    // other, so the only thing that stops the second save from throwing away the first is a
    // marker in the file itself. Every write this session performs goes through `writeVault`, so
    // the counter can never be skipped — a skipped bump makes the *next* save look like somebody
    // else's work and reports a conflict that never happened.

    /// Stamps this install's marker on the metadata and writes it.
    ///
    /// The counter only ever goes up, including when adopting a file that came back from a sync
    /// conflict with a lower one: a counter that can go backwards cannot be compared.
    @discardableResult
    private func writeVault(
        metadata: VaultMetadata,
        envelope: VaultEnvelope,
        checkingForForeignWrite: Bool = true
    ) throws -> VaultMetadata {
        if checkingForForeignWrite {
            try requireNoForeignWrite()
        }
        var stamped = metadata
        stamped.writeCounter = max(loadedWriteCounter, onDiskWriteCounter ?? 0) + 1
        stamped.lastWriterID = installIdentifier
        try vaultStore.save(metadata: stamped, envelope: envelope)
        loadedWriteCounter = stamped.writeCounter
        hasForeignChange = false
        return stamped
    }

    /// Puts the notice away without choosing. The conflict itself is unresolved, so the next save
    /// raises it again — which is better than pretending it went away.
    func dismissForeignChangeNotice() {
        hasForeignChange = false
    }

    private var onDiskWriteCounter: Int? {
        (try? vaultStore.loadMetadataFromStorage())?.writeCounter
    }

    /// Throws when the vault on disk is not the one this session read.
    private func requireNoForeignWrite() throws {
        // No file yet means this is the creating write, which cannot conflict with anything.
        guard let onDisk = try? vaultStore.loadMetadataFromStorage() else { return }
        guard onDisk.writeCounter != loadedWriteCounter else { return }
        hasForeignChange = true
        throw VaultCryptoError.vaultChangedElsewhere
    }

    /// Confirms the vault sitting on disk right now opens with the key this session holds.
    ///
    /// Used after copying a vault to a new folder, so nothing is deleted from the old one until
    /// the copy has been proven to work.
    func verifyOnDiskVaultReadable() throws {
        guard let activeVaultKey else { throw VaultCryptoError.vaultLocked }
        let metadata = try vaultStore.loadMetadataFromStorage()
        guard metadata.version == 1 else { throw VaultCryptoError.unsupportedVaultVersion }
        let envelope = try vaultStore.loadEnvelope()
        _ = try cryptoService.decryptVault(envelope, using: activeVaultKey)
    }

    /// Takes what is on disk and discards what this session holds in memory.
    ///
    /// The way out of a conflict for somebody who would rather keep the other Mac's work. It does
    /// not need the master password again, because the vault key is unchanged unless the password
    /// itself was rotated elsewhere — and that case locks instead of guessing.
    func reloadFromDisk() throws {
        guard let activeVaultKey else { throw VaultCryptoError.vaultLocked }
        let metadata = try vaultStore.loadMetadataFromStorage()
        guard metadata.version == 1 else { throw VaultCryptoError.unsupportedVaultVersion }
        let envelope = try vaultStore.loadEnvelope()

        let snapshot: VaultSnapshot
        do {
            snapshot = try cryptoService.decryptVault(envelope, using: activeVaultKey)
        } catch {
            // Whatever is on disk was wrapped under a different password. Nothing this session
            // holds can open it, so the honest outcome is to lock and let them unlock it.
            memoryStore.discardPendingPersist()
            lock()
            throw VaultCryptoError.vaultChangedElsewhereAndRelocked
        }

        // The in-memory graph is about to be replaced; a queued write from it must not land.
        memoryStore.discardPendingPersist()
        hasForeignChange = false
        loadedWriteCounter = metadata.writeCounter
        let warning = activate(snapshot: snapshot, key: activeVaultKey, metadata: metadata)
        lastErrorMessage = warning
    }

    /// Keeps this session's version and writes over the other one.
    func overwriteForeignChange() throws {
        guard activeVaultKey != nil else { throw VaultCryptoError.vaultLocked }
        // Adopt whatever is on disk as the floor, so the write lands above it and the other Mac
        // sees a conflict in turn rather than silently losing this one too.
        loadedWriteCounter = max(loadedWriteCounter, onDiskWriteCounter ?? 0)
        hasForeignChange = false
        try saveCurrentVault()
    }

    func saveCurrentVault(metadataOverride: VaultMetadata? = nil) throws {
        guard let activeVaultKey else { throw VaultCryptoError.vaultLocked }
        let metadata = metadataOverride ?? self.metadata
        guard var metadata else { throw VaultCryptoError.metadataMissing }
        metadata.updatedAt = .now
        let snapshot = currentSnapshotIncludingPrivateSettings()
        let envelope = try cryptoService.encryptVault(snapshot, using: activeVaultKey)
        metadata = try writeVault(metadata: metadata, envelope: envelope)
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
        // `max` rather than assignment: a creating or migrating write has already stamped a higher
        // counter than the metadata this was called with, and the copy that came back from a sync
        // conflict may carry a lower one. Either way the counter must not go backwards.
        loadedWriteCounter = max(loadedWriteCounter, metadata.writeCounter)
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
        // Never a hard failure: this clears secrets belonging to a former app identity that a
        // sandboxed build may not be able to address at all. Erasing the current vault is what
        // the owner asked for, and that is covered by the checks around it.
        try? keyStore.clearLegacySecrets()
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


private nonisolated extension String {
    /// Nil for an empty string, so a blank recorded shortcut falls back to the default rather than
    /// showing nothing.
    var nilIfEmptyValue: String? { isEmpty ? nil : self }
}
