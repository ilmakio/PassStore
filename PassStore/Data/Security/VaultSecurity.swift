import AppKit
import CryptoKit
import Darwin
import Foundation
import Observation

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

    var sidebarTagsOrder: [String] {
        didSet { defaults.set(sidebarTagsOrder, forKey: Keys.sidebarTagsOrder) }
    }

    var sidebarEnvironmentsOrder: [String] {
        didSet { defaults.set(sidebarEnvironmentsOrder, forKey: Keys.sidebarEnvironmentsOrder) }
    }

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
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.autoLockInterval = defaults.object(forKey: Keys.autoLockInterval) as? Double ?? 300
        self.clipboardClearInterval = defaults.object(forKey: Keys.clipboardClearInterval) as? Double ?? 10
        self.biometricsEnabled = defaults.object(forKey: Keys.biometricsEnabled) as? Bool ?? true
        self.globalCommandPaletteHotkeyEnabled = defaults.object(forKey: Keys.globalCommandPaletteHotkeyEnabled) as? Bool ?? true
        self.sidebarLibraryExpanded = defaults.object(forKey: Keys.sidebarLibraryExpanded) as? Bool ?? true
        self.sidebarWorkspacesExpanded = defaults.object(forKey: Keys.sidebarWorkspacesExpanded) as? Bool ?? true
        self.sidebarTypesExpanded = defaults.object(forKey: Keys.sidebarTypesExpanded) as? Bool ?? true
        self.sidebarTagsExpanded = defaults.object(forKey: Keys.sidebarTagsExpanded) as? Bool ?? true
        self.sidebarEnvironmentsExpanded = defaults.object(forKey: Keys.sidebarEnvironmentsExpanded) as? Bool ?? true
        self.sidebarTypesOrder = defaults.stringArray(forKey: Keys.sidebarTypesOrder) ?? []
        self.sidebarTagsOrder = defaults.stringArray(forKey: Keys.sidebarTagsOrder) ?? []
        self.sidebarEnvironmentsOrder = defaults.stringArray(forKey: Keys.sidebarEnvironmentsOrder) ?? []
        self.hasShownSensitiveCopyWarning = defaults.bool(forKey: Keys.hasShownSensitiveCopyWarning)
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
            sidebarEnvironmentsOrder: sidebarEnvironmentsOrder
        )
    }

    func applySettings(from payload: ExportedSettingsPayload) {
        autoLockInterval = payload.autoLockInterval
        clipboardClearInterval = payload.clipboardClearInterval
        biometricsEnabled = payload.biometricsEnabled
        globalCommandPaletteHotkeyEnabled = payload.globalCommandPaletteHotkeyEnabled
        sidebarLibraryExpanded = payload.sidebarLibraryExpanded
        sidebarWorkspacesExpanded = payload.sidebarWorkspacesExpanded
        sidebarTypesExpanded = payload.sidebarTypesExpanded
        sidebarTagsExpanded = payload.sidebarTagsExpanded
        sidebarEnvironmentsExpanded = payload.sidebarEnvironmentsExpanded
        sidebarTypesOrder = payload.sidebarTypesOrder
        sidebarTagsOrder = payload.sidebarTagsOrder
        sidebarEnvironmentsOrder = payload.sidebarEnvironmentsOrder
    }
}

enum VaultLockState: Equatable {
    case setupRequired
    case locked
    case unlocked
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
        refreshBiometricAvailability()
        startMonitoring()
    }

    func createVault(password: String) {
        guard password.count >= 8 else {
            lastErrorMessage = password.isEmpty
                ? "Password cannot be empty."
                : "Password must be at least 8 characters."
            return
        }
        isBusy = true
        defer { isBusy = false }

        do {
            try performResetCleanup()
            let vaultKey = cryptoService.generateVaultKey()
            let wrappedKey = try cryptoService.wrapVaultKey(vaultKey, password: password)
            var metadata = VaultMetadata(
                version: 1,
                wrappedVaultKey: wrappedKey,
                biometricUnlockEnabled: false,
                updatedAt: .now
            )
            let envelope = try cryptoService.encryptVault(.empty, using: vaultKey)
            _ = syncBiometricState(using: vaultKey, metadata: &metadata)
            try vaultStore.save(metadata: metadata, envelope: envelope)
            activate(snapshot: .empty, key: vaultKey, metadata: metadata)
            lastErrorMessage = nil
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    func unlockWithPassword(_ password: String) -> Bool {
        // Progressive delay: reject early if still in lockout window.
        if let lastFailed = lastFailedAttemptAt, failedPasswordAttempts > 0 {
            let required = Self.lockoutDelays.first { failedPasswordAttempts >= $0.threshold }?.delay ?? 0
            let elapsed = Date().timeIntervalSince(lastFailed)
            if elapsed < required {
                let remaining = Int((required - elapsed).rounded(.up))
                lastErrorMessage = "Too many failed attempts. Please wait \(remaining)s."
                return false
            }
        }

        isBusy = true
        defer { isBusy = false }

        do {
            let metadata = try vaultStore.loadMetadata()
            let vaultKey = try cryptoService.unwrapVaultKey(metadata.wrappedVaultKey, password: password)
            var updatedMetadata = metadata

            // Migrate legacy PBKDF2 vaults to Argon2id on first successful unlock.
            let isLegacyKDF = metadata.wrappedVaultKey.kdfAlgorithm == nil
                || metadata.wrappedVaultKey.kdfAlgorithm == "pbkdf2-sha256"
            if isLegacyKDF {
                updatedMetadata.wrappedVaultKey = try cryptoService.wrapVaultKey(vaultKey, password: password)
            }

            _ = syncBiometricState(using: vaultKey, metadata: &updatedMetadata)
            let envelope = try vaultStore.loadEnvelope()
            let snapshot = try cryptoService.decryptVault(envelope, using: vaultKey)
            activate(snapshot: snapshot, key: vaultKey, metadata: updatedMetadata)
            if updatedMetadata.updatedAt != metadata.updatedAt
                || updatedMetadata.biometricUnlockEnabled != metadata.biometricUnlockEnabled
                || isLegacyKDF {
                try saveCurrentVault(metadataOverride: updatedMetadata)
            }
            failedPasswordAttempts = 0
            lastFailedAttemptAt = nil
            lastErrorMessage = nil
            return true
        } catch {
            failedPasswordAttempts += 1
            lastFailedAttemptAt = Date()
            lastErrorMessage = "Incorrect password or corrupted vault."
            return false
        }
    }

    func unlockWithBiometrics() async -> Bool {
        guard settings.biometricsEnabled else {
            lastErrorMessage = "Biometric unlock is disabled."
            return false
        }

        isBusy = true
        defer { isBusy = false }

        do {
            let metadata = try vaultStore.loadMetadata()
            guard metadata.biometricUnlockEnabled else {
                lastErrorMessage = "Biometric unlock is not configured."
                return false
            }
            let vaultKey = try keyStore.readVaultKey(prompt: "Unlock PassStore")
            let envelope = try vaultStore.loadEnvelope()
            let snapshot = try cryptoService.decryptVault(envelope, using: vaultKey)
            activate(snapshot: snapshot, key: vaultKey, metadata: metadata)
            lastErrorMessage = nil
            return true
        } catch {
            lastErrorMessage = error.localizedDescription
            return false
        }
    }

    func changeMasterPassword(to password: String) throws {
        guard !password.isEmpty else { throw VaultCryptoError.emptyPassword }
        guard let activeVaultKey, var metadata else { throw VaultCryptoError.vaultLocked }
        metadata.wrappedVaultKey = try cryptoService.wrapVaultKey(activeVaultKey, password: password)
        metadata.updatedAt = .now
        self.metadata = metadata
        try saveCurrentVault()
    }

    func syncBiometricPreferenceIfUnlocked() {
        guard lockState == .unlocked, let activeVaultKey, var metadata else {
            refreshBiometricAvailability()
            return
        }
        let biometricWarning = syncBiometricState(using: activeVaultKey, metadata: &metadata)
        self.metadata = metadata
        do {
            try saveCurrentVault()
            lastErrorMessage = biometricWarning
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    func lock() {
        // Overwrite key bytes before releasing the reference so the material
        // doesn't linger in freed memory pages.
        if activeVaultKey != nil {
            activeVaultKey!.withUnsafeMutableBytes { buffer in
                guard let base = buffer.baseAddress else { return }
                memset(base, 0, buffer.count)
            }
            activeVaultKey = nil
        }
        metadata = nil
        memoryStore.clear()
        failedPasswordAttempts = 0
        lastFailedAttemptAt = nil
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
        let envelope = try cryptoService.encryptVault(memoryStore.makeSnapshot(), using: activeVaultKey)
        try vaultStore.save(metadata: metadata, envelope: envelope)
        self.metadata = metadata
    }

    private func activate(snapshot: VaultSnapshot, key: Data, metadata: VaultMetadata) {
        activeVaultKey = key
        self.metadata = metadata
        memoryStore.activate(snapshot: snapshot) { [weak self] in
            try self?.saveCurrentVault()
        }
        lockState = .unlocked
        touchInteraction()
        refreshBiometricAvailability()
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
            try? keyStore.deleteVaultKey()
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

    private func performResetCleanup() throws {
        try? keyStore.deleteVaultKey()
        try? keyStore.clearLegacySecrets()
        try vaultStore.resetSecureVault()
        try vaultStore.resetLegacyArtifacts()
        defaults.removeObject(forKey: LegacyKeys.salt)
        defaults.removeObject(forKey: LegacyKeys.verifier)
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
    }
}

@Observable
final class ClipboardService {
    var lastCopiedDescription = ""

    private let settings: AppSettingsStore
    private var timer: Timer?
    private var fingerprint: String?
    init(settings: AppSettingsStore) {
        self.settings = settings
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
        fingerprint = Self.hash(string)
        lastCopiedDescription = label
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: settings.clipboardClearInterval, repeats: false) { [weak self] _ in
            self?.clearIfOwned()
        }
    }

    func clearIfOwned() {
        let pasteboard = NSPasteboard.general
        let current = pasteboard.string(forType: .string) ?? ""
        guard Self.hash(current) == fingerprint else { return }
        pasteboard.clearContents()
        fingerprint = nil
        lastCopiedDescription = ""
    }

    func resetSessionState() {
        clearIfOwned()
        timer?.invalidate()
        fingerprint = nil
        lastCopiedDescription = ""
    }

    private static func hash(_ string: String) -> String {
        Data(SHA256.hash(data: Data(string.utf8))).base64EncodedString()
    }
}
