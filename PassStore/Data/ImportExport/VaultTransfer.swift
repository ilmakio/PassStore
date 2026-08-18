import CryptoKit
import Darwin
import Foundation

enum TransferError: LocalizedError, Equatable {
    case invalidDatabaseItem
    case missingPassword
    case exportPasswordTooShort(Int)
    case exportPasswordMismatch
    case importFileMissing
    case invalidExportFile
    case wrongExportPassword
    case unsupportedExportVersion
    case exportFileTooLarge
    case importFileTooLarge
    case importFileUnreadable

    var errorDescription: String? {
        switch self {
        case .invalidDatabaseItem:
            "The selected item does not contain enough fields to build a connection string."
        case .missingPassword:
            "Provide an export password."
        case let .exportPasswordTooShort(minimum):
            "Backup password must be at least \(minimum) characters."
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
        case .exportFileTooLarge:
            "This vault is too large to export as a backup that PassStore can safely import."
        case .importFileTooLarge:
            "This backup is too large to import safely."
        case .importFileUnreadable:
            "The selected backup could not be read."
        }
    }
}

struct CopyFormatter {
    static func envString(for item: SecretItemEntity, fields: [FieldResolvedValue]) -> String {
        envTitleComment(item.title) + "\n" + envFileContents(fields: fields)
    }

    /// An item's title as a comment safe to put at the head of a `.env`.
    ///
    /// Titles are encrypted user/imported data too. Every physical line is prefixed, so a title
    /// containing a newline cannot escape the comment and inject a sourced assignment.
    static func envTitleComment(_ title: String) -> String {
        title
            .components(separatedBy: .newlines)
            .map { "# \($0)" }
            .joined(separator: "\n")
    }

    /// Serialises fields as `.env` text.
    ///
    /// Two long-standing round-trip bugs are fixed here. Keys were upper-cased, so importing
    /// `Api_Key=…` and copying it back produced `API_KEY=…` — a different variable. And values
    /// were never quoted, so anything containing a space, a newline, a quote or a `#` came
    /// back out as an invalid or truncated line.
    static func envFileContents(fields: [FieldResolvedValue]) -> String {
        let ordered = orderedForEnvOutput(fields)
        var usedKeys: Set<String> = []
        return ordered.map { field in
            let base = safeEnvKey(field.key)
            var key = base
            var suffix = 2
            while !usedKeys.insert(key).inserted {
                key = "\(base)_\(suffix)"
                suffix += 1
            }
            return "\(key)=\(envQuoted(field.value))"
        }.joined(separator: "\n")
    }

    /// Rewrites `original` so every known key carries its stored value, leaving everything
    /// else exactly as it was.
    ///
    /// Regenerating the file from the stored fields — which is what writing used to do —
    /// silently destroyed comments, blank lines, key order and any variable the item does not
    /// track. A `.env` is a file its owner maintains, not something PassStore owns, so an
    /// update only ever replaces the value on an assignment it recognises.
    ///
    /// Keys the item has and the file lacks are appended. Keys the file has and the item lacks
    /// are left alone: deleting somebody's line because a field was removed here would be the
    /// same mistake in a smaller form.
    static func envFileByUpdating(_ original: String, with fields: [FieldResolvedValue]) -> String {
        let assignments = EnvImportService.assignments(in: original)
        var pending = Dictionary(fields.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })

        var lines = original.components(separatedBy: "\n")
        // Rewrite back-to-front so earlier line indices stay valid as multi-line spans shrink.
        for assignment in assignments.reversed() {
            guard let field = pending.removeValue(forKey: assignment.key) else { continue }
            // A value the item did not change keeps the exact line the owner wrote. Rebuilding
            // every tracked assignment re-quoted the whole file — `LOG_LEVEL=info` came back as
            // `LOG_LEVEL="info"` — so one Write showed up as a diff on every line.
            guard assignment.currentValue != field.value else { continue }
            let literal = envValueLiteral(
                field.value,
                preferring: assignment.quote,
                allowingLiteralNewlines: assignment.lineRange.count > 1
            )
            let rebuilt = "\(assignment.prefix)\(assignment.key)=\(literal)\(assignment.trailingComment)"
            lines.replaceSubrange(assignment.lineRange, with: [rebuilt])
        }

        let additions = fields
            .filter { pending[$0.key] != nil }
            .map { "\(safeEnvKey($0.key))=\(envQuoted($0.value))" }
        guard !additions.isEmpty else { return lines.joined(separator: "\n") }

        if lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true {
            lines.removeLast()
        }
        return (lines + additions).joined(separator: "\n") + "\n"
    }

    /// Renders the item's fields back into the layout of the file they came from.
    ///
    /// This is what makes "copy my `.env`" mean the file the owner wrote — comments, section
    /// banners, blank lines, ordering, `export` prefixes and quoting included — rather than a
    /// document regenerated from a list of keys. It needs no access to the file, so it works
    /// from a backup, on another Mac, and when the original is nowhere to be found.
    static func envFileFromLayout(_ layout: EnvDocumentLayout, with fields: [FieldResolvedValue]) -> String {
        let byKey = Dictionary(fields.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        var rendered: [String] = []

        for line in layout.lines {
            switch line {
            case let .text(text):
                rendered.append(text)
            case let .assignment(assignment):
                // A variable the item no longer holds has no value to write, and the layout
                // deliberately does not remember what it used to be. Leaving the line out is the
                // only truthful option; inventing `KEY=` would read as "deliberately empty".
                guard let field = byKey[assignment.key] else { continue }
                let literal = envValueLiteral(
                    field.value,
                    preferring: assignment.quote,
                    allowingLiteralNewlines: assignment.wraps
                )
                rendered.append("\(assignment.prefix)\(assignment.key)=\(literal)\(assignment.trailingComment)")
            }
        }

        // A variable added in PassStore after the layout was captured still belongs in the copy.
        let known = Set(layout.keys)
        let additions = orderedForEnvOutput(fields.filter { !known.contains($0.key) })
            .map { "\(safeEnvKey($0.key))=\(envQuoted($0.value))" }
        guard !additions.isEmpty else { return rendered.joined(separator: "\n") }

        if rendered.last?.trimmingCharacters(in: .whitespaces).isEmpty == true {
            rendered.removeLast()
        }
        return (rendered + additions).joined(separator: "\n") + "\n"
    }

    /// Writes a value using the quoting the file already used, when that quoting is still safe
    /// for the new value.
    ///
    /// Double quotes remain the fallback and the default for generated output. They are just
    /// not something to impose on a file somebody else maintains: turning `PORT=5432` into
    /// `PORT="5432"` is a change to their repository for a value that did not change.
    /// `allowingLiteralNewlines` covers the value that was written across several lines inside
    /// its quotes — a PEM key, almost always. Escaping it onto one line parses back to the same
    /// value, but it is not the file the owner had.
    static func envValueLiteral(
        _ value: String,
        preferring style: EnvQuoteStyle,
        allowingLiteralNewlines: Bool = false
    ) -> String {
        switch style {
        // `KEY=` is how a file that does without quotes writes an empty value, and it reads back
        // as empty everywhere. Quoting it would be a change to a line for no reason.
        case .none where value.isEmpty || isSafeUnquoted(value):
            return value
        case .single where isSafeSingleQuoted(value, allowingLineBreaks: allowingLiteralNewlines):
            return "'\(value)'"
        case .double where allowingLiteralNewlines && value.contains("\n"):
            return envQuotedKeepingLineBreaks(value)
        default:
            return envQuoted(value)
        }
    }

    /// Deliberately conservative: anything a shell or a dotenv reader could interpret —
    /// whitespace, quotes, `#`, `$`, backticks, escapes, globs, line breaks — falls through to
    /// the quoted form. Only characters that mean themselves in every reader stay bare.
    private static func isSafeUnquoted(_ value: String) -> Bool {
        guard !value.isEmpty else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            CharacterSet.alphanumerics.contains(scalar) && scalar.isASCII
                || unquotedSafePunctuation.contains(Character(scalar))
        }
    }

    private static let unquotedSafePunctuation: Set<Character> = ["_", ".", "-", "/", ":", "@", "%", "+", ",", "="]

    /// Single quotes are literal in shell semantics, so they carry `$`, backticks and `#`
    /// safely. They cannot carry a single quote — there is no escape for one inside them.
    private static func isSafeSingleQuoted(_ value: String, allowingLineBreaks: Bool) -> Bool {
        guard !value.contains("'"), !value.contains("\r") else { return false }
        return allowingLineBreaks || !value.contains("\n")
    }

    /// Double quotes, escaped as usual, except that line breaks stay line breaks. `$` and
    /// backticks are still escaped: the value has to be safe to `source` however it is laid out.
    private static func envQuotedKeepingLineBreaks(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "$", with: "\\$")
            .replacingOccurrences(of: "`", with: "\\`")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
        return "\"\(escaped)\""
    }

    /// Always quoting makes the output safe both for dotenv readers and for developers who
    /// load the file with `source`. Dollar signs and backticks must be escaped as well as
    /// ordinary string escapes; otherwise a value restored from a backup could trigger shell
    /// expansion or command substitution when the linked file is sourced.
    static func envQuoted(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "$", with: "\\$")
            .replacingOccurrences(of: "`", with: "\\`")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
        return "\"\(escaped)\""
    }

    /// The item's own order, made total so the same fields always serialise the same way.
    private static func orderedForEnvOutput(_ fields: [FieldResolvedValue]) -> [FieldResolvedValue] {
        fields.sorted {
            if $0.sortOrder != $1.sortOrder { return $0.sortOrder < $1.sortOrder }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    /// Field keys are user-editable and can arrive from an imported backup. Keep normal
    /// dotenv identifiers unchanged, but replace line breaks, `=` and other syntax so a field
    /// key can never inject an additional assignment or shell statement into a linked file.
    private static func safeEnvKey(_ raw: String) -> String {
        let scalars = raw.unicodeScalars.map { scalar -> Character in
            if CharacterSet.alphanumerics.contains(scalar) || scalar == "_" || scalar == "." {
                return Character(String(scalar))
            }
            return "_"
        }
        let key = String(scalars).trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return key.isEmpty ? "FIELD" : key
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

nonisolated struct EnvImportService: Sendable {
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

    /// Where each assignment lives in the original text, so a value can be replaced without
    /// disturbing the lines around it.
    struct Assignment {
        /// Whitespace and any `export ` that preceded the key, reproduced verbatim.
        let prefix: String
        let key: String
        /// The value exactly as the file writes it — quotes included, spanning every physical
        /// line it occupies — so an update can tell "same value" from "same text" and can put a
        /// new value back in the same shape.
        let rawValue: String
        let quote: EnvQuoteStyle
        /// A trailing `# comment` on a single-line unquoted value, kept so updating a value
        /// does not throw away the note explaining it.
        let trailingComment: String
        /// The physical lines this assignment occupies — more than one for a quoted value
        /// that wraps.
        let lineRange: Range<Int>

        /// The value the file currently holds, decoded exactly as `parse` decodes it.
        var currentValue: String { EnvImportService.unquote(rawValue) }
    }

    /// Compares the file with the item one variable at a time.
    ///
    /// Only variables that actually differ are reported. `baseline` is the digest of each value at
    /// the last sync: without it there is no way to tell an on-disk edit from a local one, and the
    /// honest answer for a variable that differs is `.diverged` rather than a guess.
    static func drift(
        between fileContents: String,
        and fields: [FieldResolvedValue],
        baseline: [String: String]?
    ) -> [String: EnvFieldDrift] {
        // Last occurrence wins, which is how dotenv readers resolve a repeated variable.
        let fileValues = Dictionary(
            EnvImportService().parse(fileContents).entries.map { ($0.key, $0.value) },
            uniquingKeysWith: { _, last in last }
        )
        let vaultValues = Dictionary(
            fields.map { ($0.key, $0.value) },
            uniquingKeysWith: { first, _ in first }
        )

        var result: [String: EnvFieldDrift] = [:]
        for (key, vaultValue) in vaultValues {
            guard let fileValue = fileValues[key] else {
                result[key] = .onlyInVault
                continue
            }
            guard fileValue != vaultValue else { continue }
            guard let synced = baseline?[key] else {
                result[key] = .diverged
                continue
            }
            let fileMoved = synced != LinkedFileService.digest(fileValue)
            let vaultMoved = synced != LinkedFileService.digest(vaultValue)
            switch (fileMoved, vaultMoved) {
            case (true, false): result[key] = .fileChanged
            case (false, true): result[key] = .vaultChanged
            // Both, or a baseline that matches neither: either way the owner has to pick a side.
            default: result[key] = .diverged
            }
        }
        for (key, _) in fileValues where vaultValues[key] == nil {
            result[key] = .onlyInFile
        }
        return result
    }

    /// The per-variable baseline to store when the item and the file are in sync.
    static func fieldDigests(of fields: [FieldResolvedValue]) -> [String: String] {
        Dictionary(
            fields.map { ($0.key, LinkedFileService.digest($0.value)) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    /// The value the file currently gives a variable, or nil when it does not have it.
    static func value(forKey key: String, in fileContents: String) -> String? {
        EnvImportService().parse(fileContents).entries.last { $0.key == key }?.value
    }

    /// Captures the file's shape — everything about it the item's fields cannot carry.
    ///
    /// Values are not part of it: see `EnvDocumentLayout`.
    static func layout(of text: String) -> EnvDocumentLayout {
        let lines = text.components(separatedBy: "\n")
        let byStartLine = Dictionary(
            assignments(in: text).map { ($0.lineRange.lowerBound, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        var result: [EnvDocumentLayout.Line] = []
        var index = 0
        while index < lines.count {
            if let assignment = byStartLine[index] {
                result.append(.assignment(EnvAssignmentLayout(
                    prefix: assignment.prefix,
                    key: assignment.key,
                    quote: assignment.quote,
                    wraps: assignment.lineRange.count > 1,
                    trailingComment: assignment.trailingComment
                )))
                index = assignment.lineRange.upperBound
            } else {
                result.append(.text(lines[index]))
                index += 1
            }
        }
        return EnvDocumentLayout(lines: result)
    }

    /// Locates every assignment, using the same rules as `parse`.
    static func assignments(in text: String) -> [Assignment] {
        let lines = text.components(separatedBy: "\n")
        var result: [Assignment] = []
        var index = 0

        while index < lines.count {
            let start = index
            let rawLine = lines[index]
            index += 1

            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"), let separator = line.firstIndex(of: "=") else { continue }

            let head = String(line[line.startIndex..<separator])
            var key = head.trimmingCharacters(in: .whitespaces)
            var prefix = String(rawLine.prefix(while: { $0 == " " || $0 == "\t" }))
            if key.hasPrefix("export "), key.count > "export ".count {
                key = String(key.dropFirst("export ".count)).trimmingCharacters(in: .whitespaces)
                prefix += "export "
            }
            guard !key.isEmpty, key.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "." }) else { continue }

            var remainder = String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
            var trailingComment = ""

            if let quote = remainder.first, quote == "\"" || quote == "'" {
                while !isClosed(remainder, quote: quote), index < lines.count {
                    remainder += "\n" + lines[index]
                    index += 1
                }
            } else if let hash = remainder.range(of: " #") {
                trailingComment = String(remainder[hash.lowerBound...])
                remainder = String(remainder[..<hash.lowerBound])
            }

            result.append(
                Assignment(
                    prefix: prefix,
                    key: key,
                    rawValue: remainder,
                    quote: EnvQuoteStyle(leadingCharacter: remainder.first),
                    trailingComment: trailingComment,
                    lineRange: start..<index
                )
            )
        }
        return result
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
            // `FOO=bar # note` has a comment, while `COLOR=#fff` and URL fragments do not.
            var previousWasWhitespace = false
            for index in trimmed.indices {
                let character = trimmed[index]
                if character == "#", previousWasWhitespace {
                    return String(trimmed[..<index]).trimmingCharacters(in: .whitespaces)
                }
                previousWasWhitespace = character.isWhitespace
            }
            return trimmed
        }

        var body = String(trimmed.dropFirst())
        var isEscaped = false
        var closing: String.Index?
        for index in body.indices {
            let character = body[index]
            if isEscaped {
                isEscaped = false
                continue
            }
            if quote == "\"", character == "\\" {
                isEscaped = true
                continue
            }
            if character == quote {
                closing = index
                break
            }
        }
        if let closing {
            body = String(body[..<closing])
        }
        // Single quotes are literal in shell semantics; only double quotes take escapes.
        guard quote == "\"" else { return body }
        var result = ""
        var isEscapePending = false
        for character in body {
            if isEscapePending {
                switch character {
                case "n": result.append("\n")
                case "r": result.append("\r")
                case "t": result.append("\t")
                case "\\": result.append("\\")
                case "\"": result.append("\"")
                case "$": result.append("$")
                case "`": result.append("`")
                default:
                    result.append("\\")
                    result.append(character)
                }
                isEscapePending = false
                continue
            }
            if character == "\\" { isEscapePending = true; continue }
            result.append(character)
        }
        if isEscapePending { result.append("\\") }
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

nonisolated enum ImportedPayload: Sendable {
    case legacyItems([ExportedItemPayload])
    case fullBackup(ExportedBackupPayload)
}

nonisolated struct ExportKeyMaterial: Sendable {
    fileprivate var vaultKey: Data
    fileprivate let wrappedKey: WrappedVaultKey

    mutating func securelyClear() {
        Self.overwrite(&vaultKey)
    }

    fileprivate static func overwrite(_ data: inout Data) {
        data.withUnsafeMutableBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            memset(base, 0, buffer.count)
        }
        data.removeAll(keepingCapacity: false)
    }
}

nonisolated struct ExportService: Sendable {
    static let maximumImportFileSize = 128 * 1_024 * 1_024

    private let cryptoService: VaultCryptoService

    init(cryptoService: VaultCryptoService) {
        self.cryptoService = cryptoService
    }

    static func readImportFile(at url: URL) throws -> Data {
        let gotAccess = url.startAccessingSecurityScopedResource()
        defer { if gotAccess { url.stopAccessingSecurityScopedResource() } }
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let data = try handle.read(upToCount: maximumImportFileSize + 1) ?? Data()
            guard data.count <= maximumImportFileSize else {
                throw TransferError.importFileTooLarge
            }
            return data
        } catch let error as TransferError {
            throw error
        } catch {
            throw TransferError.importFileUnreadable
        }
    }

    /// Performs only the expensive password wrapping off-main. The caller intentionally does
    /// not capture a plaintext vault snapshot until this finishes, so locking during Argon2id
    /// cannot leave the whole vault retained by a background task.
    func prepareFullBackup(password: String) async throws -> ExportKeyMaterial {
        try await Task.detached(priority: .userInitiated) { [self] in
            try makeKeyMaterialSynchronously(password: password)
        }.value
    }

    func exportFullBackupSynchronously(backup: ExportedBackupPayload, password: String) throws -> Data {
        var material = try makeKeyMaterialSynchronously(password: password)
        defer { material.securelyClear() }
        return try finishFullBackupSynchronously(backup: backup, material: material)
    }

    /// Returns the sole live owner of the generated export key. Keeping construction in a
    /// helper avoids retaining a second copy while the outer synchronous path clears it.
    private func makeKeyMaterialSynchronously(password: String) throws -> ExportKeyMaterial {
        guard password.count >= VaultSessionManager.minimumPasswordLength else {
            throw TransferError.exportPasswordTooShort(VaultSessionManager.minimumPasswordLength)
        }
        var vaultKey = cryptoService.generateVaultKey()
        do {
            let wrappedKey = try cryptoService.wrapVaultKey(vaultKey, password: password)
            return ExportKeyMaterial(vaultKey: vaultKey, wrappedKey: wrappedKey)
        } catch {
            ExportKeyMaterial.overwrite(&vaultKey)
            throw error
        }
    }

    /// Encodes and encrypts after the KDF has completed. This portion is intentionally
    /// synchronous and contains no suspension point at which a lock could interleave.
    func finishFullBackupSynchronously(backup: ExportedBackupPayload, material: ExportKeyMaterial) throws -> Data {
        do {
            try backup.vault.validateResourceLimits()
        } catch VaultCryptoError.vaultContentsTooLarge {
            throw TransferError.exportFileTooLarge
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var payload = try encoder.encode(backup)
        defer { ExportKeyMaterial.overwrite(&payload) }
        let envelope = try encryptPayload(payload, using: material.vaultKey)
        let exportEnvelope = EncryptedExportEnvelope(
            version: 3,
            kdf: material.wrappedKey,
            payload: envelope,
            createdAt: .now
        )
        let result = try encoder.encode(exportEnvelope)
        guard result.count <= Self.maximumImportFileSize else {
            throw TransferError.exportFileTooLarge
        }
        return result
    }

    func importPayload(from fileData: Data, password: String) async throws -> ImportedPayload {
        try await Task.detached(priority: .userInitiated) { [self] in
            try importPayloadSynchronously(from: fileData, password: password)
        }.value
    }

    /// Decrypts a `.pstore` file and returns either a full backup (v3) or legacy items (v1/v2).
    func importPayloadSynchronously(from fileData: Data, password: String) throws -> ImportedPayload {
        guard fileData.count <= Self.maximumImportFileSize else {
            throw TransferError.importFileTooLarge
        }
        let decoder = JSONDecoder()
        let envelope: EncryptedExportEnvelope
        do {
            envelope = try decoder.decode(EncryptedExportEnvelope.self, from: fileData)
        } catch {
            throw TransferError.invalidExportFile
        }
        guard (1...3).contains(envelope.version) else { throw TransferError.unsupportedExportVersion }
        guard envelope.payload.version == 1 else { throw TransferError.unsupportedExportVersion }
        var vaultKey: Data
        do {
            vaultKey = try cryptoService.unwrapVaultKey(envelope.kdf, password: password)
        } catch {
            throw TransferError.wrongExportPassword
        }
        defer { ExportKeyMaterial.overwrite(&vaultKey) }
        var plaintext: Data
        do {
            plaintext = try cryptoService.decryptEnvelopePayload(envelope.payload, using: vaultKey)
        } catch {
            throw TransferError.wrongExportPassword
        }
        defer { ExportKeyMaterial.overwrite(&plaintext) }
        if envelope.version >= 3 {
            do {
                let backup = try decoder.decode(ExportedBackupPayload.self, from: plaintext)
                try backup.vault.validateResourceLimits()
                return .fullBackup(backup)
            } catch VaultCryptoError.vaultContentsTooLarge {
                throw TransferError.importFileTooLarge
            } catch {
                throw TransferError.invalidExportFile
            }
        } else {
            do {
                let items = try decoder.decode([ExportedItemPayload].self, from: plaintext)
                try Self.validateLegacyItems(items)
                return .legacyItems(items)
            } catch VaultCryptoError.vaultContentsTooLarge {
                throw TransferError.importFileTooLarge
            } catch {
                throw TransferError.invalidExportFile
            }
        }
    }

    private func encryptPayload(_ payload: Data, using vaultKey: Data) throws -> VaultEnvelope {
        guard vaultKey.count == 32 else { throw VaultCryptoError.invalidEnvelope }
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

    private static func validateLegacyItems(_ items: [ExportedItemPayload]) throws {
        guard items.count <= 100_000 else { throw VaultCryptoError.vaultContentsTooLarge }
        var totalFields = 0
        for item in items {
            guard item.fields.count <= 2_000,
                  item.fields.count <= 1_000_000 - totalFields else {
                throw VaultCryptoError.vaultContentsTooLarge
            }
            totalFields += item.fields.count
        }
    }
}
