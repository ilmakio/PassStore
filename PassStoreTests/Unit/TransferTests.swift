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
        let payload = [
            ExportedItemPayload(
                id: UUID(),
                workspaceName: "Backend",
                title: "Primary Postgres",
                type: "Database",
                environment: "Prod",
                notes: "Sensitive note",
                tags: ["db"],
                isFavorite: true,
                createdAt: .now,
                updatedAt: .now,
                fields: [
                    ExportedFieldPayload(key: "password", label: "Password", value: "super-secret", kind: "secret", isSensitive: true)
                ]
            )
        ]

        let exported = try service.export(items: payload, password: "export-pass")
        let string = String(decoding: exported, as: UTF8.self)

        #expect(!string.contains("Primary Postgres"))
        #expect(!string.contains("super-secret"))
        #expect(!string.contains("Sensitive note"))
    }

    @Test func exportImportRoundTripRestoresPayload() throws {
        let service = ExportService(cryptoService: VaultCryptoService(defaultIterations: 2_000, defaultOpsLimit: 1, defaultMemLimit: 8_192))
        let payload = [
            ExportedItemPayload(
                id: UUID(),
                workspaceName: "Backend",
                title: "Primary Postgres",
                type: SecretItemType.database.title,
                environment: EnvironmentKind.prod.title,
                notes: "Note",
                tags: ["db"],
                isFavorite: true,
                createdAt: .now,
                updatedAt: .now,
                fields: [
                    ExportedFieldPayload(key: "password", label: "Password", value: "super-secret", kind: "secret", isSensitive: true)
                ]
            )
        ]
        let fileData = try service.export(items: payload, password: "export-pass")
        let imported = try service.importDecryptedItems(from: fileData, password: "export-pass")
        #expect(imported.count == 1)
        #expect(imported[0].title == "Primary Postgres")
        #expect(imported[0].fields.first?.value == "super-secret")
        #expect(imported[0].workspaceName == "Backend")
    }

    @Test func exportImportRoundTripWithUnicodePassword() throws {
        let crypto = VaultCryptoService(defaultIterations: 2_000, defaultOpsLimit: 1, defaultMemLimit: 8_192)
        let service = ExportService(cryptoService: crypto)
        let unicodePassword = "🔐päss_字"
        let vaultKey = crypto.generateVaultKey()
        let wrapped = try crypto.wrapVaultKey(vaultKey, password: unicodePassword)
        let unwrapped = try crypto.unwrapVaultKey(wrapped, password: unicodePassword)
        #expect(unwrapped == vaultKey)

        let payload = [
            ExportedItemPayload(
                id: UUID(),
                workspaceName: nil,
                title: "Unicode",
                type: SecretItemType.generic.title,
                environment: EnvironmentKind.dev.title,
                notes: "ñ",
                tags: [],
                isFavorite: false,
                createdAt: .now,
                updatedAt: .now,
                fields: []
            )
        ]
        let fileData = try service.export(items: payload, password: unicodePassword)
        let imported = try service.importDecryptedItems(from: fileData, password: unicodePassword)
        #expect(imported.count == 1)
        #expect(imported[0].title == "Unicode")
    }

    @Test func exportImportFailsWithWrongPassword() throws {
        let service = ExportService(cryptoService: VaultCryptoService(defaultIterations: 2_000, defaultOpsLimit: 1, defaultMemLimit: 8_192))
        let payload = [
            ExportedItemPayload(
                id: UUID(),
                workspaceName: nil,
                title: "Item",
                type: SecretItemType.generic.title,
                environment: EnvironmentKind.dev.title,
                notes: "",
                tags: [],
                isFavorite: false,
                createdAt: .now,
                updatedAt: .now,
                fields: []
            )
        ]
        let fileData = try service.export(items: payload, password: "good")
        #expect(throws: TransferError.wrongExportPassword) {
            try service.importDecryptedItems(from: fileData, password: "wrong")
        }
    }
}
