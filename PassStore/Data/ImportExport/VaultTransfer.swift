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
        "# \(item.title)\n" + envFileContents(fields: fields)
    }

    /// Serialises fields as `.env` text.
    ///
    /// Two long-standing round-trip bugs are fixed here. Keys were upper-cased, so importing
    /// `Api_Key=…` and copying it back produced `API_KEY=…` — a different variable. And values
    /// were never quoted, so anything containing a space, a newline, a quote or a `#` came
    /// back out as an invalid or truncated line.
    static func envFileContents(fields: [FieldResolvedValue]) -> String {
        fields
            .sorted { $0.sortOrder < $1.sortOrder }
            .map { "\($0.key)=\(envQuoted($0.value))" }
            .joined(separator: "\n")
    }

    /// Quotes only when the bare form would not survive a re-read.
    static func envQuoted(_ value: String) -> String {
        let needsQuoting = value.isEmpty
            || value.contains(where: { $0 == " " || $0 == "\t" || $0.isNewline })
            || value.contains("#")
            || value.contains("\"")
            || value.contains("'")
            || value.contains("\\")
            || value.hasPrefix(" ")
            || value.hasSuffix(" ")
        guard needsQuoting else { return value }
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
        return "\"\(escaped)\""
    }

    static func jsonString(for item: SecretItemEntity, fields: [FieldResolvedValue]) throws -> String {
        let payload = keyedValues(fields)
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    /// Field keys should be unique, but a legacy or hand-edited vault can repeat one; keep the
    /// first occurrence rather than trapping the way `Dictionary(uniqueKeysWithValues:)` would.
    static func keyedValues(_ fields: [FieldResolvedValue]) -> [String: String] {
        Dictionary(fields.map { ($0.key, $0.value) }, uniquingKeysWith: { first, _ in first })
    }

    static func databaseConnectionString(for item: SecretItemEntity, fields: [FieldResolvedValue]) throws -> String {
        guard item.type == .database else { throw TransferError.invalidDatabaseItem }
        let map = keyedValues(fields)
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

struct EnvImportService: Sendable {
    /// Parses `.env` text.
    ///
    /// The original parser split on `=` and trimmed, which meant `KEY="hello world"` was
    /// stored *with* its quote characters, `export KEY=v` produced a key literally called
    /// `export KEY`, and a value spanning several quoted lines was truncated at the first
    /// newline. All three are common in real `.env` files.
    func parse(_ text: String) -> ParsedEnvDocument {
        var notes: [String] = []
        var entries: [ParsedEnvEntry] = []

        var lines = text.components(separatedBy: .newlines)[...]
        while let rawLine = lines.first {
            lines = lines.dropFirst()
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }

            if line.hasPrefix("#") {
                notes.append(String(line.dropFirst()).trimmingCharacters(in: .whitespaces))
                continue
            }

            guard let separator = line.firstIndex(of: "=") else { continue }
            var key = String(line[line.startIndex..<separator]).trimmingCharacters(in: .whitespaces)
            // `export FOO=bar` is valid in a sourced .env and must not become a key called
            // "export FOO".
            if key.hasPrefix("export "), key.count > "export ".count {
                key = String(key.dropFirst("export ".count)).trimmingCharacters(in: .whitespaces)
            }
            guard !key.isEmpty, key.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "." }) else { continue }

            var remainder = String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespaces)

            // A quoted value may continue on following lines until the quote closes.
            if let quote = remainder.first, quote == "\"" || quote == "'", !Self.isClosed(remainder, quote: quote) {
                while let next = lines.first {
                    lines = lines.dropFirst()
                    remainder += "\n" + next
                    if Self.isClosed(remainder, quote: quote) { break }
                }
            }

            let value = Self.unquote(remainder)
            entries.append(ParsedEnvEntry(key: key, value: value, isSensitive: Self.looksSensitive(key: key)))
        }

        return ParsedEnvDocument(notes: notes.joined(separator: "\n"), entries: entries)
    }

    /// True once the opening quote has a matching unescaped closing quote.
    private static func isClosed(_ text: String, quote: Character) -> Bool {
        var isEscaped = false
        for (index, character) in text.enumerated() {
            if index == 0 { continue }
            if isEscaped { isEscaped = false; continue }
            if character == "\\", quote == "\"" { isEscaped = true; continue }
            if character == quote { return true }
        }
        return false
    }

    /// Strips surrounding quotes, expands escapes inside double quotes, and drops a trailing
    /// comment from an unquoted value.
    static func unquote(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard let quote = trimmed.first, quote == "\"" || quote == "'" else {
            // `FOO=bar # note` — the comment is not part of the value.
            guard let hashIndex = trimmed.firstIndex(of: "#") else { return trimmed }
            return String(trimmed[trimmed.startIndex..<hashIndex]).trimmingCharacters(in: .whitespaces)
        }

        var body = String(trimmed.dropFirst())
        if let closing = body.lastIndex(of: quote) {
            body = String(body[body.startIndex..<closing])
        }
        // Single quotes are literal in shell semantics; only double quotes take escapes.
        guard quote == "\"" else { return body }
        var result = ""
        var isEscaped = false
        for character in body {
            if isEscaped {
                switch character {
                case "n": result.append("\n")
                case "r": result.append("\r")
                case "t": result.append("\t")
                case "\\": result.append("\\")
                case "\"": result.append("\"")
                default:
                    result.append("\\")
                    result.append(character)
                }
                isEscaped = false
                continue
            }
            if character == "\\" { isEscaped = true; continue }
            result.append(character)
        }
        if isEscaped { result.append("\\") }
        return result
    }

    /// Heuristic for pre-marking a variable as sensitive on import.
    ///
    /// `key` alone used to match, so `MONKEY_COUNT` and `KEYBOARD_LAYOUT` were imported as
    /// secrets. It now has to look like a credential rather than merely contain the letters.
    static func looksSensitive(key: String) -> Bool {
        let lower = key.lowercased()
        let strongMarkers = ["secret", "password", "passwd", "token", "credential", "private", "apikey", "auth"]
        if strongMarkers.contains(where: { lower.contains($0) }) { return true }
        // "key" only counts as its own word: API_KEY and KEY yes, MONKEY_COUNT no.
        let words = lower.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        return words.contains("key") || words.contains("keys") || words.contains("dsn") || words.contains("pwd")
    }
}

enum ImportedPayload {
    case legacyItems([ExportedItemPayload])
    case fullBackup(ExportedBackupPayload)
}

struct ExportService: Sendable {
    private let cryptoService: VaultCryptoService

    init(cryptoService: VaultCryptoService) {
        self.cryptoService = cryptoService
    }

    /// Exports a full vault backup (v3) including all vault data and app settings.
    ///
    /// Runs the Argon2id wrap off the main actor: it is the same ~1s cost as an unlock, and
    /// on the main actor it froze the export sheet with no spinner.
    func exportFullBackup(backup: ExportedBackupPayload, password: String) async throws -> Data {
        try await Task.detached(priority: .userInitiated) { [self] in
            try exportFullBackupSynchronously(backup: backup, password: password)
        }.value
    }

    func exportFullBackupSynchronously(backup: ExportedBackupPayload, password: String) throws -> Data {
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

    func importPayload(from fileData: Data, password: String) async throws -> ImportedPayload {
        try await Task.detached(priority: .userInitiated) { [self] in
            try importPayloadSynchronously(from: fileData, password: password)
        }.value
    }

    /// Decrypts a `.pstore` file and returns either a full backup (v3) or legacy items (v1/v2).
    func importPayloadSynchronously(from fileData: Data, password: String) throws -> ImportedPayload {
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
