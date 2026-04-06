import CryptoKit
import Foundation

enum TransferError: LocalizedError {
    case invalidDatabaseItem
    case missingPassword
    case exportPasswordMismatch
    case importFileMissing
    case invalidExportFile
    case wrongExportPassword
    case unsupportedExportVersion

    var errorDescription: String? {
        switch self {
        case .invalidDatabaseItem:
            "The selected item does not contain enough fields to build a connection string."
        case .missingPassword:
            "Provide an export password."
        case .exportPasswordMismatch:
            "The export passwords do not match."
        case .importFileMissing:
            "Choose a PassStore backup (.pstore) first."
        case .invalidExportFile:
            "This file is not a valid PassStore export."
        case .wrongExportPassword:
            "The export password is incorrect or the file is corrupted."
        case .unsupportedExportVersion:
            "This export was created with a newer PassStore version."
        }
    }
}

struct CopyFormatter {
    static func envString(for item: SecretItemEntity, fields: [FieldResolvedValue]) -> String {
        let header = "# \(item.title)"
        let pairs = fields.sorted { $0.sortOrder < $1.sortOrder }.map { "\($0.key.uppercased())=\($0.value)" }
        return ([header] + pairs).joined(separator: "\n")
    }

    static func jsonString(for item: SecretItemEntity, fields: [FieldResolvedValue]) throws -> String {
        let payload = Dictionary(uniqueKeysWithValues: fields.map { ($0.key, $0.value) })
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    static func databaseConnectionString(for item: SecretItemEntity, fields: [FieldResolvedValue]) throws -> String {
        guard item.type == .database else { throw TransferError.invalidDatabaseItem }
        let map = Dictionary(uniqueKeysWithValues: fields.map { ($0.key, $0.value) })
        let engineRaw = (map["db_engine"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let engine = engineRaw.isEmpty ? "postgresql" : engineRaw
        return try buildDatabaseConnectionString(engine: engine, map: map)
    }

    private static func buildDatabaseConnectionString(engine: String, map: [String: String]) throws -> String {
        switch engine {
        case "sqlite":
            let path = map["database"] ?? ""
            guard !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw TransferError.invalidDatabaseItem
            }
            let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
            return "sqlite:///\(encoded)"
        case "redis":
            guard let host = map["host"]?.trimmingCharacters(in: .whitespacesAndNewlines), !host.isEmpty,
                  let port = map["port"]?.trimmingCharacters(in: .whitespacesAndNewlines), !port.isEmpty else {
                throw TransferError.invalidDatabaseItem
            }
            let password = map["password"] ?? ""
            let dbIndex = (map["database"] ?? "0").trimmingCharacters(in: .whitespacesAndNewlines)
            if password.isEmpty {
                return "redis://\(host):\(port)/\(dbIndex)"
            }
            return "redis://:\(encodeUserInfo(password))@\(host):\(port)/\(dbIndex)"
        case "elasticsearch":
            guard let host = map["host"]?.trimmingCharacters(in: .whitespacesAndNewlines), !host.isEmpty else {
                throw TransferError.invalidDatabaseItem
            }
            let port = (map["port"] ?? "9200").trimmingCharacters(in: .whitespacesAndNewlines)
            let useTLS = (map["database"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "https"
            let scheme = useTLS ? "https" : "http"
            return "\(scheme)://\(host):\(port)"
        case "mssql":
            guard let host = map["host"]?.trimmingCharacters(in: .whitespacesAndNewlines), !host.isEmpty,
                  let port = map["port"]?.trimmingCharacters(in: .whitespacesAndNewlines), !port.isEmpty,
                  let database = map["database"]?.trimmingCharacters(in: .whitespacesAndNewlines), !database.isEmpty else {
                throw TransferError.invalidDatabaseItem
            }
            let user = map["username"] ?? ""
            let password = map["password"] ?? ""
            let u = encodeJdbcComponent(user)
            let p = encodeJdbcComponent(password)
            return "jdbc:sqlserver://\(host):\(port);databaseName=\(encodeJdbcComponent(database));user=\(u);password=\(p)"
        case "other":
            return try formatGenericDatabaseSummary(map: map)
        case "cassandra":
            guard let host = map["host"]?.trimmingCharacters(in: .whitespacesAndNewlines), !host.isEmpty,
                  let port = map["port"]?.trimmingCharacters(in: .whitespacesAndNewlines), !port.isEmpty,
                  let keyspace = map["database"]?.trimmingCharacters(in: .whitespacesAndNewlines), !keyspace.isEmpty else {
                throw TransferError.invalidDatabaseItem
            }
            let user = map["username"] ?? ""
            let password = map["password"] ?? ""
            if user.isEmpty, password.isEmpty {
                return "cassandra://\(host):\(port)/\(keyspace)"
            }
            return "cassandra://\(encodeUserInfo(user)):\(encodeUserInfo(password))@\(host):\(port)/\(keyspace)"
        case "postgresql", "mysql", "mariadb", "mongodb":
            guard let host = map["host"]?.trimmingCharacters(in: .whitespacesAndNewlines), !host.isEmpty,
                  let port = map["port"]?.trimmingCharacters(in: .whitespacesAndNewlines), !port.isEmpty,
                  let database = map["database"]?.trimmingCharacters(in: .whitespacesAndNewlines), !database.isEmpty else {
                throw TransferError.invalidDatabaseItem
            }
            let username = map["username"] ?? ""
            let password = map["password"] ?? ""
            let scheme: String = {
                switch engine {
                case "mysql", "mariadb": "mysql"
                case "mongodb": "mongodb"
                default: "postgresql"
                }
            }()
            return sqlStyleURL(scheme: scheme, username: username, password: password, host: host, port: port, database: database)
        default:
            return try formatGenericDatabaseSummary(map: map)
        }
    }

    private static func sqlStyleURL(scheme: String, username: String, password: String, host: String, port: String, database: String) -> String {
        let u = encodeUserInfo(username)
        let p = encodeUserInfo(password)
        let db = encodePathSegment(database)
        let auth: String
        if username.isEmpty, password.isEmpty {
            auth = ""
        } else if password.isEmpty {
            auth = "\(u)@"
        } else {
            auth = "\(u):\(p)@"
        }
        return "\(scheme)://\(auth)\(host):\(port)/\(db)"
    }

    private static func encodeUserInfo(_ value: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private static func encodePathSegment(_ value: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private static func encodeJdbcComponent(_ value: String) -> String {
        value.replacingOccurrences(of: ";", with: "\\;")
    }

    private static func formatGenericDatabaseSummary(map: [String: String]) throws -> String {
        let keys = ["db_engine", "host", "port", "database", "username", "password"]
        let lines = keys.compactMap { key -> String? in
            guard let v = map[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty else { return nil }
            if key == "password" { return "\(key)=***" }
            return "\(key)=\(v)"
        }
        guard !lines.isEmpty else { throw TransferError.invalidDatabaseItem }
        return lines.joined(separator: "\n")
    }
}

struct EnvImportService {
    func parse(_ text: String) -> ParsedEnvDocument {
        var notes: [String] = []
        var entries: [ParsedEnvEntry] = []
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            if line.hasPrefix("#") {
                notes.append(String(line.dropFirst()).trimmingCharacters(in: .whitespaces))
                continue
            }
            let pieces = line.split(separator: "=", maxSplits: 1).map(String.init)
            guard pieces.count == 2 else { continue }
            let key = pieces[0].trimmingCharacters(in: .whitespacesAndNewlines)
            let value = pieces[1].trimmingCharacters(in: .whitespacesAndNewlines)
            let sensitive = key.lowercased().contains("secret")
                || key.lowercased().contains("token")
                || key.lowercased().contains("password")
                || key.lowercased().contains("key")
            entries.append(ParsedEnvEntry(key: key, value: value, isSensitive: sensitive))
        }
        return ParsedEnvDocument(notes: notes.joined(separator: "\n"), entries: entries)
    }
}

enum ImportedPayload {
    case legacyItems([ExportedItemPayload])
    case fullBackup(ExportedBackupPayload)
}

struct ExportService {
    private let cryptoService: VaultCryptoService

    init(cryptoService: VaultCryptoService) {
        self.cryptoService = cryptoService
    }

    /// Exports a full vault backup (v3) including all vault data and app settings.
    func exportFullBackup(backup: ExportedBackupPayload, password: String) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let payload = try encoder.encode(backup)
        let vaultKey = cryptoService.generateVaultKey()
        let wrappedKey = try cryptoService.wrapVaultKey(vaultKey, password: password)
        let envelope = try encryptPayload(payload, using: vaultKey)
        let exportEnvelope = EncryptedExportEnvelope(
            version: 3,
            kdf: wrappedKey,
            payload: envelope,
            createdAt: .now
        )
        return try encoder.encode(exportEnvelope)
    }

    /// Decrypts a `.pstore` file and returns either a full backup (v3) or legacy items (v1/v2).
    func importPayload(from fileData: Data, password: String) throws -> ImportedPayload {
        let decoder = JSONDecoder()
        let envelope: EncryptedExportEnvelope
        do {
            envelope = try decoder.decode(EncryptedExportEnvelope.self, from: fileData)
        } catch {
            throw TransferError.invalidExportFile
        }
        guard envelope.version <= 3 else { throw TransferError.unsupportedExportVersion }
        let vaultKey: Data
        do {
            vaultKey = try cryptoService.unwrapVaultKey(envelope.kdf, password: password)
        } catch {
            throw TransferError.wrongExportPassword
        }
        let plaintext: Data
        do {
            plaintext = try cryptoService.decryptEnvelopePayload(envelope.payload, using: vaultKey)
        } catch {
            throw TransferError.wrongExportPassword
        }
        if envelope.version >= 3 {
            do {
                let backup = try decoder.decode(ExportedBackupPayload.self, from: plaintext)
                return .fullBackup(backup)
            } catch {
                throw TransferError.invalidExportFile
            }
        } else {
            do {
                let items = try decoder.decode([ExportedItemPayload].self, from: plaintext)
                return .legacyItems(items)
            } catch {
                throw TransferError.invalidExportFile
            }
        }
    }

    private func encryptPayload(_ payload: Data, using vaultKey: Data) throws -> VaultEnvelope {
        let key = SymmetricKey(data: vaultKey)
        let sealed = try AES.GCM.seal(payload, using: key)
        return VaultEnvelope(
            version: 1,
            nonce: Data(sealed.nonce).base64EncodedString(),
            ciphertext: sealed.ciphertext.base64EncodedString(),
            tag: sealed.tag.base64EncodedString(),
            createdAt: .now
        )
    }
}
