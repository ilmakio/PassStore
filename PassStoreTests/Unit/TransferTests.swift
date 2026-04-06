import Foundation
import Testing
@testable import PassStore

struct TransferTests {
    @Test func envParserExtractsEntriesAndComments() {
        let parser = EnvImportService()
        let document = parser.parse("""
        # local config
        API_URL=https://example.com
        SESSION_SECRET=abc123
        """)

        #expect(document.notes == "local config")
        #expect(document.entries.count == 2)
        #expect(document.entries[1].isSensitive)
    }

    @Test func databaseFormatterBuildsConnectionString() throws {
        let item = SecretItemEntity(title: "DB", type: .database)
        let fields = [
            FieldResolvedValue(id: UUID(), key: "host", label: "Host", value: "localhost", kind: .text, isSensitive: false, isCopyable: true, isMasked: false, sortOrder: 0),
            FieldResolvedValue(id: UUID(), key: "port", label: "Port", value: "5432", kind: .number, isSensitive: false, isCopyable: true, isMasked: false, sortOrder: 1),
            FieldResolvedValue(id: UUID(), key: "database", label: "Database", value: "devvault", kind: .text, isSensitive: false, isCopyable: true, isMasked: false, sortOrder: 2),
            FieldResolvedValue(id: UUID(), key: "username", label: "Username", value: "postgres", kind: .text, isSensitive: false, isCopyable: true, isMasked: false, sortOrder: 3),
            FieldResolvedValue(id: UUID(), key: "password", label: "Password", value: "secret", kind: .secret, isSensitive: true, isCopyable: true, isMasked: true, sortOrder: 4)
        ]

        let connection = try CopyFormatter.databaseConnectionString(for: item, fields: fields)
        #expect(connection == "postgresql://postgres:secret@localhost:5432/devvault")
    }

    @Test func databaseFormatterUsesEngineForMySQL() throws {
        let item = SecretItemEntity(title: "DB", type: .database)
        let fields = [
            FieldResolvedValue(id: UUID(), key: "db_engine", label: "Database type", value: "mysql", kind: .text, isSensitive: false, isCopyable: true, isMasked: false, sortOrder: 0),
            FieldResolvedValue(id: UUID(), key: "host", label: "Host", value: "127.0.0.1", kind: .text, isSensitive: false, isCopyable: true, isMasked: false, sortOrder: 1),
            FieldResolvedValue(id: UUID(), key: "port", label: "Port", value: "3306", kind: .number, isSensitive: false, isCopyable: true, isMasked: false, sortOrder: 2),
            FieldResolvedValue(id: UUID(), key: "database", label: "Database", value: "app", kind: .text, isSensitive: false, isCopyable: true, isMasked: false, sortOrder: 3),
            FieldResolvedValue(id: UUID(), key: "username", label: "Username", value: "root", kind: .text, isSensitive: false, isCopyable: true, isMasked: false, sortOrder: 4),
            FieldResolvedValue(id: UUID(), key: "password", label: "Password", value: "x", kind: .secret, isSensitive: true, isCopyable: true, isMasked: true, sortOrder: 5)
        ]
        let connection = try CopyFormatter.databaseConnectionString(for: item, fields: fields)
        #expect(connection == "mysql://root:x@127.0.0.1:3306/app")
    }

    @Test func exportServiceEncryptsPayloadWithoutPlaintextLeak() throws {
        let service = ExportService(cryptoService: VaultCryptoService(defaultIterations: 2_000, defaultOpsLimit: 1, defaultMemLimit: 8_192))
        let backup = makeBackupPayload()

        let exported = try service.exportFullBackup(backup: backup, password: "export-pass")
        let string = String(decoding: exported, as: UTF8.self)

        #expect(!string.contains("Primary Postgres"))
        #expect(!string.contains("super-secret"))
        #expect(!string.contains("Sensitive note"))
    }

    @Test func exportImportRoundTripRestoresFullBackupAndSettings() throws {
        let service = ExportService(cryptoService: VaultCryptoService(defaultIterations: 2_000, defaultOpsLimit: 1, defaultMemLimit: 8_192))
        let backup = makeBackupPayload(settings: ExportedSettingsPayload(
            autoLockInterval: 120,
            clipboardClearInterval: 5,
            biometricsEnabled: false,
            globalCommandPaletteHotkeyEnabled: false,
            sidebarLibraryExpanded: true,
            sidebarWorkspacesExpanded: false,
            sidebarTypesExpanded: true,
            sidebarTagsExpanded: false,
            sidebarEnvironmentsExpanded: true,
            sidebarTypesOrder: ["database", "generic"],
            sidebarTagsOrder: ["backend"],
            sidebarEnvironmentsOrder: ["Prod", "Staging"]
        ))

        let fileData = try service.exportFullBackup(backup: backup, password: "export-pass")
        let imported = try service.importPayload(from: fileData, password: "export-pass")

        guard case let .fullBackup(restored) = imported else {
            Issue.record("Expected a v3 full backup payload.")
            return
        }

        #expect(restored.vault.workspaces.count == 1)
        #expect(restored.vault.workspaces[0].name == "Backend")
        #expect(restored.vault.items.count == 1)
        #expect(restored.vault.items[0].title == "Primary Postgres")
        #expect(restored.vault.items[0].notes == "Sensitive note")
        #expect(restored.vault.items[0].fields.first?.plainValue == "super-secret")
        #expect(restored.settings.autoLockInterval == 120)
        #expect(restored.settings.clipboardClearInterval == 5)
        #expect(restored.settings.biometricsEnabled == false)
        #expect(restored.settings.globalCommandPaletteHotkeyEnabled == false)
        #expect(restored.settings.sidebarWorkspacesExpanded == false)
        #expect(restored.settings.sidebarTagsOrder == ["backend"])
    }

    @Test func exportImportRoundTripWithUnicodePassword() throws {
        let crypto = VaultCryptoService(defaultIterations: 2_000, defaultOpsLimit: 1, defaultMemLimit: 8_192)
        let service = ExportService(cryptoService: crypto)
        let unicodePassword = "🔐päss_字"
        let vaultKey = crypto.generateVaultKey()
        let wrapped = try crypto.wrapVaultKey(vaultKey, password: unicodePassword)
        let unwrapped = try crypto.unwrapVaultKey(wrapped, password: unicodePassword)
        #expect(unwrapped == vaultKey)

        let backup = makeBackupPayload(
            title: "Unicode",
            notes: "ñ",
            secretValue: "🔐"
        )
        let fileData = try service.exportFullBackup(backup: backup, password: unicodePassword)
        let imported = try service.importPayload(from: fileData, password: unicodePassword)

        guard case let .fullBackup(restored) = imported else {
            Issue.record("Expected a v3 full backup payload.")
            return
        }

        #expect(restored.vault.items.count == 1)
        #expect(restored.vault.items[0].title == "Unicode")
        #expect(restored.vault.items[0].notes == "ñ")
        #expect(restored.vault.items[0].fields.first?.plainValue == "🔐")
    }

    @Test func exportImportFailsWithWrongPassword() throws {
        let service = ExportService(cryptoService: VaultCryptoService(defaultIterations: 2_000, defaultOpsLimit: 1, defaultMemLimit: 8_192))
        let fileData = try service.exportFullBackup(backup: makeBackupPayload(title: "Item"), password: "good")
        #expect(throws: TransferError.wrongExportPassword) {
            try service.importPayload(from: fileData, password: "wrong")
        }
    }
}

private func makeBackupPayload(
    title: String = "Primary Postgres",
    notes: String = "Sensitive note",
    secretValue: String = "super-secret",
    settings: ExportedSettingsPayload = ExportedSettingsPayload(
        autoLockInterval: 300,
        clipboardClearInterval: 10,
        biometricsEnabled: true,
        globalCommandPaletteHotkeyEnabled: true,
        sidebarLibraryExpanded: true,
        sidebarWorkspacesExpanded: true,
        sidebarTypesExpanded: true,
        sidebarTagsExpanded: true,
        sidebarEnvironmentsExpanded: true,
        sidebarTypesOrder: [],
        sidebarTagsOrder: [],
        sidebarEnvironmentsOrder: []
    )
) -> ExportedBackupPayload {
    let workspaceID = UUID()
    let workspace = WorkspaceSnapshot(
        id: workspaceID,
        name: "Backend",
        icon: "shippingbox",
        colorHex: "#4A7AFF",
        notes: "Primary backend services",
        isArchived: false,
        createdAt: .now,
        updatedAt: .now,
        sortOrder: 0
    )
    let item = SecretItemSnapshot(
        id: UUID(),
        title: title,
        typeRawValue: SecretItemType.database.rawValue,
        environmentRawValue: EnvironmentKind.prod.rawValue,
        customEnvironmentName: nil,
        notes: notes,
        tagsRawValue: "db,prod",
        isFavorite: true,
        isArchived: false,
        createdAt: .now,
        updatedAt: .now,
        lastAccessedAt: nil,
        workspaceID: workspaceID,
        templateID: nil,
        fields: [
            FieldValueSnapshot(
                id: UUID(),
                fieldKey: "password",
                labelSnapshot: "Password",
                kindRawValue: FieldKind.secret.rawValue,
                isSensitive: true,
                isCopyable: true,
                isMasked: true,
                sortOrder: 0,
                plainValue: secretValue
            )
        ]
    )

    return ExportedBackupPayload(
        vault: VaultSnapshot(workspaces: [workspace], items: [item], customTemplates: []),
        settings: settings
    )
}
