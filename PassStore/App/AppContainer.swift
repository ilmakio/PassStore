import Foundation

@MainActor
final class AppContainer {
    let settings: AppSettingsStore
    let sessionManager: VaultSessionManager
    let clipboard: ClipboardService
    let envImport: EnvImportService
    let exportService: ExportService
    let memoryStore: VaultMemoryStore

    let workspaceRepository: WorkspaceRepository
    let itemRepository: SecretItemRepository
    let templateRepository: TemplateRepository

    init(
        inMemory: Bool = false,
        defaults: UserDefaults = .standard,
        keyStore: VaultKeyStore? = nil,
        encryptedVaultStore: EncryptedVaultStore? = nil
    ) {
        self.settings = AppSettingsStore(defaults: defaults)
        let cryptoService = VaultCryptoService(
            defaultIterations: inMemory ? 20_000 : 600_000,
            defaultOpsLimit: inMemory ? 1 : 3,
            defaultMemLimit: inMemory ? 8_192 : 268_435_456
        )
        self.memoryStore = VaultMemoryStore()
        let activeKeyStore = keyStore ?? (inMemory ? InMemoryVaultKeyStore() : KeychainVaultKeyStore())
        let activeVaultStore = encryptedVaultStore ?? (inMemory ? InMemoryEncryptedVaultStore() : FileEncryptedVaultStore())
        self.sessionManager = VaultSessionManager(
            defaults: defaults,
            settings: settings,
            cryptoService: cryptoService,
            vaultStore: activeVaultStore,
            keyStore: activeKeyStore,
            memoryStore: memoryStore
        )
        self.clipboard = ClipboardService(settings: settings)
        self.envImport = EnvImportService()
        self.exportService = ExportService(cryptoService: cryptoService)
        self.workspaceRepository = WorkspaceRepository(store: memoryStore)
        self.itemRepository = SecretItemRepository(store: memoryStore)
        self.templateRepository = TemplateRepository(store: memoryStore)

        sessionManager.onLock = { [clipboard] in
            clipboard.resetSessionState()
        }
    }

    static let live = AppContainer()

    static func preview() -> AppContainer {
        let defaults = UserDefaults(suiteName: "PassStorePreview-\(UUID().uuidString)")!
        let container = AppContainer(inMemory: true, defaults: defaults)
        container.sessionManager.createVault(password: "preview-ok")
        PreviewSeeder.seedIfNeeded(container)
        return container
    }

    static func uiTesting() -> AppContainer {
        let defaults = UserDefaults(suiteName: "PassStoreUITest-\(UUID().uuidString)")!
        let container = AppContainer(
            inMemory: true,
            defaults: defaults,
            keyStore: InMemoryVaultKeyStore(isBiometricHardwareAvailable: true),
            encryptedVaultStore: InMemoryEncryptedVaultStore()
        )
        container.sessionManager.createVault(password: "uitest-ok")
        PreviewSeeder.seedIfNeeded(container)

        let sshTemplate = (try? container.templateRepository.fetchAll())?.first(where: { $0.itemType == .serverSSH })
        let workspace = (try? container.workspaceRepository.fetchAll(includeArchived: false))?.first

        _ = try? container.itemRepository.saveItem(.init(
            title: "SSH Optional Empty",
            type: .serverSSH,
            workspaceID: workspace?.id,
            environment: .preset(.staging),
            notes: "",
            tags: ["ssh", "empty"],
            isFavorite: false,
            fieldDrafts: [
                .init(key: "smokeMarker", label: "Smoke Marker", value: "launch-readiness", kind: .text, isSensitive: false, sortOrder: 0),
                .init(key: "host", label: "Host", value: "empty.example.dev", kind: .text, isSensitive: false, sortOrder: 1),
                .init(key: "port", label: "Port", value: "22", kind: .number, isSensitive: false, sortOrder: 2),
                .init(key: "username", label: "Username", value: "deploy", kind: .text, isSensitive: false, sortOrder: 3),
                .init(key: "password", label: "Password", value: "", kind: .secret, isSensitive: true, isMasked: true, sortOrder: 4),
                .init(key: "privateKey", label: "Private Key", value: "", kind: .multiline, isSensitive: true, isMasked: true, sortOrder: 5)
            ],
            templateID: sshTemplate?.id
        ))

        return container
    }
}
