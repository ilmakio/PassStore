import Foundation

/// A credential found in a developer tool's own config file, ready to become an item.
///
/// Deliberately not a `SecretItemDraft`: parsing is pure, testable and knows nothing about
/// workspaces, environments or templates. The view model decides what to do with these.
nonisolated struct ImportedCredential: Identifiable, Sendable {
    struct Field: Sendable {
        let key: String
        let label: String
        let value: String
        let isSensitive: Bool
        let kind: FieldKind
    }

    let id: UUID
    let title: String
    let type: SecretItemType
    /// Where it came from, for the preview: "aws profile", "registry", "machine".
    let sourceDescription: String
    let fields: [Field]
    let notes: String

    init(
        id: UUID = UUID(),
        title: String,
        type: SecretItemType,
        sourceDescription: String,
        fields: [Field],
        notes: String = ""
    ) {
        self.id = id
        self.title = title
        self.type = type
        self.sourceDescription = sourceDescription
        self.fields = fields
        self.notes = notes
    }

    var sensitiveFieldCount: Int { fields.count(where: \.isSensitive) }
}

/// The formats PassStore can read.
nonisolated enum DeveloperCredentialFormat: String, CaseIterable, Sendable {
    case awsCredentials
    case netrc
    case dockerConfig
    case bitwardenExport
    /// Any file of `KEY=value` lines. The catch-all that stops a plain env-shaped file being a
    /// dead end here.
    case dotenv
    /// A JSON object whose values are all plain — `{"API_KEY": "…"}`. Config files everywhere.
    case flatJSON

    var title: String {
        switch self {
        case .awsCredentials: "AWS credentials"
        case .netrc: ".netrc"
        case .dockerConfig: "Docker config"
        case .bitwardenExport: "Bitwarden export"
        case .dotenv: "environment file"
        case .flatJSON: "JSON key/value file"
        }
    }

    /// What to say when nothing recognisable was found.
    var expectation: String {
        switch self {
        case .awsCredentials: "an ~/.aws/credentials file with [profile] sections"
        case .netrc: "a .netrc file with machine / login / password lines"
        case .dockerConfig: "a Docker config.json with an \"auths\" object"
        case .bitwardenExport: "an unencrypted Bitwarden .json export"
        case .dotenv: "lines of KEY=value"
        case .flatJSON: "a JSON object of names and values"
        }
    }

    var systemImage: String {
        switch self {
        case .awsCredentials: "cloud"
        case .netrc: "network"
        case .dockerConfig: "shippingbox"
        case .bitwardenExport: "lock.rectangle.stack"
        case .dotenv: "curlybraces.square"
        case .flatJSON: "curlybraces"
        }
    }

    /// What this format gives you, in the interface's own words.
    var importDescription: String {
        switch self {
        case .awsCredentials: "~/.aws/credentials or ~/.aws/config — one item per profile"
        case .netrc: "~/.netrc — one item per machine"
        case .dockerConfig: "~/.docker/config.json — one item per registry"
        case .bitwardenExport: "An unencrypted .json export — logins and custom fields"
        case .dotenv: "Any file of KEY=value lines — one item holding the variables"
        case .flatJSON: "A JSON object of names and values, if one of them looks like a credential"
        }
    }

    /// One line each, for the interface. Listing what is accepted beats reporting what was not.
    static var supportedSummary: [String] {
        [
            "AWS — ~/.aws/credentials or ~/.aws/config, one item per profile",
            ".netrc — one item per machine",
            "Docker — ~/.docker/config.json, one item per registry",
            "Bitwarden — an unencrypted .json export",
            "Environment files — any file of KEY=value lines",
            "JSON — an object of names and values, like {\"API_KEY\": \"…\"}"
        ]
    }
}

nonisolated enum DeveloperCredentialImportError: LocalizedError, Equatable, Sendable {
    case unrecognisedFormat
    case nothingToImport(DeveloperCredentialFormat)
    case encryptedExport

    var errorDescription: String? {
        switch self {
        case .unrecognisedFormat:
            "PassStore could not read that file. It understands AWS credentials, .netrc, Docker config.json, unencrypted Bitwarden exports, files of KEY=value lines, and JSON objects of names and values."
        case let .nothingToImport(format):
            "That looks like \(format.title), but there was nothing in it to import — expected \(format.expectation)."
        case .encryptedExport:
            "That Bitwarden export is password-protected. Export again without encryption, import it, then delete the file."
        }
    }
}

/// Reads credentials out of the files developer tools keep them in.
///
/// These are the migrations nobody offers, and they are the ones that matter here: an `~/.aws/`
/// directory and a `.netrc` are plaintext credential stores that everybody has and nobody thinks
/// about. Importing them is the first step to being able to delete them.
nonisolated enum DeveloperCredentialImporter {
    static let maximumFileBytes = 8 * 1_024 * 1_024

    /// Works out what the file is and parses it.
    static func parse(contents: String, fileName: String) throws -> (format: DeveloperCredentialFormat, credentials: [ImportedCredential]) {
        guard let format = detectFormat(contents: contents, fileName: fileName) else {
            throw DeveloperCredentialImportError.unrecognisedFormat
        }
        let credentials = switch format {
        case .awsCredentials: parseAWSCredentials(contents)
        case .netrc: parseNetrc(contents)
        case .dockerConfig: parseDockerConfig(contents)
        case .bitwardenExport: try parseBitwardenExport(contents)
        case .dotenv: parseDotenv(contents, fileName: fileName)
        case .flatJSON: parseFlatJSON(contents, fileName: fileName)
        }
        guard !credentials.isEmpty else { throw DeveloperCredentialImportError.nothingToImport(format) }
        return (format, credentials)
    }

    /// Contents first, filename second.
    ///
    /// A file called `credentials` may be anything, and `config.json` is the most reused filename in
    /// software. What is inside it is the better evidence.
    static func detectFormat(contents: String, fileName: String) -> DeveloperCredentialFormat? {
        let lowercasedName = fileName.lowercased()
        let trimmed = contents.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmed.hasPrefix("{") {
            if trimmed.contains("\"auths\"") { return .dockerConfig }
            if trimmed.contains("\"items\"") || trimmed.contains("\"encrypted\"") { return .bitwardenExport }
            // Anything else has to look like it holds a credential. Shape alone is not enough: a
            // package.json is also an object of names and values, and offering to import its
            // version number as a secret would be worse than declining.
            let values = flatJSONValues(trimmed)
            guard values.contains(where: { EnvImportService.looksSensitive(key: $0.key) }) else { return nil }
            return .flatJSON
        }
        if contents.contains("aws_access_key_id") || contents.contains("aws_secret_access_key") {
            return .awsCredentials
        }
        if contents.range(of: #"(?m)^\s*machine\s+\S+"#, options: .regularExpression) != nil {
            return .netrc
        }
        // Then the name, for an AWS file whose keys are all in a profile we did not match on.
        if lowercasedName.contains("netrc") { return .netrc }
        if lowercasedName == "credentials" || lowercasedName == "config" { return .awsCredentials }
        // Last: any file of assignments. Deliberately the fallback rather than an early match, so a
        // recognisable format is never read as a generic one.
        if !EnvImportService().parse(contents).entries.isEmpty { return .dotenv }
        return nil
    }

    // MARK: - Environment files

    /// One item holding every variable in the file.
    ///
    /// Reuses the `.env` parser and its sensitivity rules rather than growing a second opinion about
    /// which names look like credentials.
    static func parseDotenv(_ contents: String, fileName: String) -> [ImportedCredential] {
        let document = EnvImportService().parse(contents)
        guard !document.entries.isEmpty else { return [] }
        return [
            ImportedCredential(
                title: Self.titleFromFileName(fileName, fallback: "Environment file"),
                type: .envGroup,
                sourceDescription: "\(document.entries.count) variables",
                fields: document.entries.map { entry in
                    ImportedCredential.Field(
                        key: entry.key,
                        label: entry.key,
                        value: entry.value,
                        isSensitive: entry.isSensitive,
                        kind: entry.isSensitive ? .secret : .text
                    )
                },
                notes: document.notes
            )
        ]
    }

    // MARK: - Flat JSON

    /// A JSON object of names and plain values, as one item.
    static func parseFlatJSON(_ contents: String, fileName: String) -> [ImportedCredential] {
        let values = flatJSONValues(contents)
        guard !values.isEmpty else { return [] }
        return [
            ImportedCredential(
                title: Self.titleFromFileName(fileName, fallback: "JSON credentials"),
                type: .generic,
                sourceDescription: "\(values.count) values",
                fields: values.map { pair in
                    let sensitive = EnvImportService.looksSensitive(key: pair.key)
                    return ImportedCredential.Field(
                        key: Self.slug(pair.key),
                        label: pair.key,
                        value: pair.value,
                        isSensitive: sensitive,
                        kind: sensitive ? .secret : .text
                    )
                }
            )
        ]
    }

    /// Top-level names and values, when every value is a string, number or boolean.
    ///
    /// Nested objects and arrays are refused rather than flattened: a guess about how to name
    /// `a.b[2].c` would be wrong often enough to be worse than saying no.
    static func flatJSONValues(_ contents: String) -> [(key: String, value: String)] {
        guard let data = contents.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }
        var result: [(key: String, value: String)] = []
        for key in object.keys.sorted() {
            switch object[key] {
            case let text as String where !text.isEmpty:
                result.append((key, text))
            case let number as NSNumber:
                result.append((key, number.stringValue))
            default:
                // One unusable value does not disqualify the file; it is simply not imported.
                continue
            }
        }
        return result
    }

    /// A readable item name from the file it came from.
    static func titleFromFileName(_ fileName: String, fallback: String) -> String {
        let name = (fileName as NSString).lastPathComponent
        let trimmed = name.hasPrefix(".") ? String(name.dropFirst()) : name
        let withoutExtension = (trimmed as NSString).deletingPathExtension
        let candidate = withoutExtension.isEmpty ? trimmed : withoutExtension
        return candidate.isEmpty ? fallback : candidate
    }

    // MARK: - AWS

    /// One item per profile.
    ///
    /// `~/.aws/credentials` is an INI file: `[profile]` headings and `key = value` under them. The
    /// default profile is called `default`, which makes a poor item name, so it is spelled out.
    static func parseAWSCredentials(_ contents: String) -> [ImportedCredential] {
        var result: [ImportedCredential] = []
        var profile: String?
        var values: [(key: String, value: String)] = []

        func flush() {
            guard let name = profile, !values.isEmpty else { return }
            let fields = values.compactMap { pair -> ImportedCredential.Field? in
                guard let descriptor = Self.awsFieldDescriptors[pair.key] else {
                    // An unknown key is still worth keeping; guessing it is not a secret would be
                    // the more dangerous mistake, so anything unrecognised is treated as one.
                    return ImportedCredential.Field(
                        key: pair.key,
                        label: pair.key.replacingOccurrences(of: "_", with: " ").capitalized,
                        value: pair.value,
                        isSensitive: true,
                        kind: .secret
                    )
                }
                return ImportedCredential.Field(
                    key: pair.key,
                    label: descriptor.label,
                    value: pair.value,
                    isSensitive: descriptor.isSensitive,
                    kind: descriptor.isSensitive ? .secret : .text
                )
            }
            result.append(
                ImportedCredential(
                    title: name == "default" ? "AWS (default profile)" : "AWS (\(name))",
                    type: .apiCredential,
                    sourceDescription: "profile \(name)",
                    fields: fields
                )
            )
            values = []
        }

        for rawLine in contents.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix(";") { continue }
            if line.hasPrefix("["), line.hasSuffix("]") {
                flush()
                // `[profile name]` is the form used in ~/.aws/config; the prefix is not part of the
                // name.
                var name = String(line.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
                if name.hasPrefix("profile ") { name = String(name.dropFirst("profile ".count)) }
                profile = name.isEmpty ? nil : name
                continue
            }
            guard let separator = line.firstIndex(of: "=") else { continue }
            let key = String(line[line.startIndex..<separator]).trimmingCharacters(in: .whitespaces).lowercased()
            let value = String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty, !value.isEmpty else { continue }
            values.append((key, value))
        }
        flush()
        return result
    }

    private static let awsFieldDescriptors: [String: (label: String, isSensitive: Bool)] = [
        "aws_access_key_id": ("Access Key ID", true),
        "aws_secret_access_key": ("Secret Access Key", true),
        "aws_session_token": ("Session Token", true),
        "region": ("Region", false),
        "output": ("Output Format", false)
    ]

    // MARK: - .netrc

    /// One item per machine.
    ///
    /// `.netrc` is whitespace-delimited tokens, not lines: `machine x login y password z` is
    /// commonly written across several lines, and `default` is a machine entry with no name.
    static func parseNetrc(_ contents: String) -> [ImportedCredential] {
        var result: [ImportedCredential] = []
        var machine: String?
        var login: String?
        var password: String?
        var account: String?

        func flush() {
            guard let host = machine else { return }
            var fields: [ImportedCredential.Field] = []
            if let login {
                fields.append(.init(key: "username", label: "Login", value: login, isSensitive: false, kind: .text))
            }
            if let account {
                fields.append(.init(key: "account", label: "Account", value: account, isSensitive: false, kind: .text))
            }
            if let password {
                fields.append(.init(key: "password", label: "Password", value: password, isSensitive: true, kind: .secret))
            }
            guard !fields.isEmpty else { return }
            result.append(
                ImportedCredential(
                    title: host,
                    type: .websiteService,
                    sourceDescription: "machine \(host)",
                    fields: fields
                )
            )
            login = nil
            password = nil
            account = nil
        }

        // `macdef` introduces a macro body that runs to a blank line and is not a credential.
        var tokens = contents
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
            .makeIterator()

        var pending: [String] = []
        while let token = tokens.next() { pending.append(token) }

        var index = 0
        while index < pending.count {
            let token = pending[index]
            index += 1
            switch token {
            case "machine":
                flush()
                machine = index < pending.count ? pending[index] : nil
                if machine != nil { index += 1 }
            case "default":
                flush()
                machine = "default"
            case "login":
                if index < pending.count { login = pending[index]; index += 1 }
            case "password":
                if index < pending.count { password = pending[index]; index += 1 }
            case "account":
                if index < pending.count { account = pending[index]; index += 1 }
            case "macdef":
                // Skip the macro name; its body has no tokens we care about.
                if index < pending.count { index += 1 }
            default:
                continue
            }
        }
        flush()
        return result
    }

    // MARK: - Docker

    /// One item per registry.
    ///
    /// Docker stores `auth` as base64 of `user:password`, which is not encryption and is worth
    /// saying out loud: anybody with the file has the password.
    static func parseDockerConfig(_ contents: String) -> [ImportedCredential] {
        guard let data = contents.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let auths = root["auths"] as? [String: Any] else {
            return []
        }

        var result: [ImportedCredential] = []
        for registry in auths.keys.sorted() {
            guard let entry = auths[registry] as? [String: Any] else { continue }
            var fields: [ImportedCredential.Field] = [
                .init(key: "registry", label: "Registry", value: registry, isSensitive: false, kind: .text)
            ]

            var username = entry["username"] as? String
            var password = entry["password"] as? String

            if let encoded = entry["auth"] as? String,
               let decoded = Data(base64Encoded: encoded).flatMap({ String(data: $0, encoding: .utf8) }),
               let separator = decoded.firstIndex(of: ":") {
                username = username ?? String(decoded[decoded.startIndex..<separator])
                password = password ?? String(decoded[decoded.index(after: separator)...])
            }

            if let username, !username.isEmpty {
                fields.append(.init(key: "username", label: "Username", value: username, isSensitive: false, kind: .text))
            }
            if let password, !password.isEmpty {
                fields.append(.init(key: "password", label: "Password", value: password, isSensitive: true, kind: .secret))
            }
            if let email = entry["email"] as? String, !email.isEmpty {
                fields.append(.init(key: "email", label: "Email", value: email, isSensitive: false, kind: .text))
            }

            guard fields.contains(where: \.isSensitive) else { continue }
            result.append(
                ImportedCredential(
                    title: "Docker — \(registry)",
                    type: .apiCredential,
                    sourceDescription: "registry \(registry)",
                    fields: fields,
                    notes: "Imported from a Docker config.json, where this password was stored as base64 — which is not encryption."
                )
            )
        }
        return result
    }

    // MARK: - Bitwarden

    /// Logins and secure notes out of an unencrypted Bitwarden export.
    static func parseBitwardenExport(_ contents: String) throws -> [ImportedCredential] {
        guard let data = contents.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }
        if root["encrypted"] as? Bool == true { throw DeveloperCredentialImportError.encryptedExport }
        guard let items = root["items"] as? [[String: Any]] else { return [] }

        var result: [ImportedCredential] = []
        for item in items {
            let name = (item["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !name.isEmpty else { continue }

            var fields: [ImportedCredential.Field] = []
            if let login = item["login"] as? [String: Any] {
                if let username = login["username"] as? String, !username.isEmpty {
                    fields.append(.init(key: "username", label: "Username", value: username, isSensitive: false, kind: .text))
                }
                if let password = login["password"] as? String, !password.isEmpty {
                    fields.append(.init(key: "password", label: "Password", value: password, isSensitive: true, kind: .secret))
                }
                if let totp = login["totp"] as? String, !totp.isEmpty {
                    fields.append(.init(key: "twofactor", label: "One-time code", value: totp, isSensitive: true, kind: .secret))
                }
                if let uris = login["uris"] as? [[String: Any]],
                   let first = uris.compactMap({ $0["uri"] as? String }).first(where: { !$0.isEmpty }) {
                    fields.append(.init(key: "url", label: "URL", value: first, isSensitive: false, kind: .url))
                }
            }
            for custom in (item["fields"] as? [[String: Any]]) ?? [] {
                guard let label = custom["name"] as? String, !label.isEmpty,
                      let value = custom["value"] as? String, !value.isEmpty else { continue }
                // Bitwarden field type 1 is "hidden".
                let hidden = (custom["type"] as? Int) == 1
                fields.append(
                    .init(
                        key: Self.slug(label),
                        label: label,
                        value: value,
                        isSensitive: hidden,
                        kind: hidden ? .secret : .text
                    )
                )
            }

            guard !fields.isEmpty else { continue }
            result.append(
                ImportedCredential(
                    title: name,
                    type: fields.contains(where: { $0.key == "url" }) ? .websiteService : .generic,
                    sourceDescription: "Bitwarden item",
                    fields: fields,
                    notes: (item["notes"] as? String) ?? ""
                )
            )
        }
        return result
    }

    static func slug(_ label: String) -> String {
        let mapped = label.lowercased().map { character -> Character in
            character.isLetter || character.isNumber ? character : "_"
        }
        let collapsed = String(mapped)
            .split(separator: "_", omittingEmptySubsequences: true)
            .joined(separator: "_")
        return collapsed.isEmpty ? "field" : collapsed
    }
}
