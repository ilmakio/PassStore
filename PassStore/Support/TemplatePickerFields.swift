import Foundation

/// Storage keys for built-in template fields rendered as pickers in the item editor.
enum VaultFormFieldKeys {
    static let databaseEngine = "db_engine"
    static let savedCommandKind = "command_kind"
}

// MARK: - Database engine (SQL / NoSQL)

struct DatabaseEngineOption: Identifiable, Hashable {
    let id: String
    let title: String

    static let all: [DatabaseEngineOption] = [
        .init(id: "postgresql", title: "PostgreSQL"),
        .init(id: "mysql", title: "MySQL"),
        .init(id: "mariadb", title: "MariaDB"),
        .init(id: "mssql", title: "Microsoft SQL Server"),
        .init(id: "sqlite", title: "SQLite"),
        .init(id: "mongodb", title: "MongoDB"),
        .init(id: "redis", title: "Redis"),
        .init(id: "cassandra", title: "Cassandra"),
        .init(id: "elasticsearch", title: "Elasticsearch"),
        .init(id: "other", title: "Other / custom")
    ]

    static func title(forStored raw: String) -> String {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !key.isEmpty else { return all.first!.title }
        return all.first(where: { $0.id == key })?.title ?? raw
    }

    static var defaultStoredID: String { all.first!.id }
}

// MARK: - Saved command kind

struct SavedCommandKindOption: Identifiable, Hashable {
    let id: String
    let title: String

    static let all: [SavedCommandKindOption] = [
        .init(id: "shell", title: "Shell / Terminal"),
        .init(id: "sql", title: "SQL"),
        .init(id: "other", title: "Other")
    ]

    static func title(forStored raw: String) -> String {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !key.isEmpty else { return all.first!.title }
        return all.first(where: { $0.id == key })?.title ?? raw
    }

    static var defaultStoredID: String { all.first!.id }
}

enum TemplatePickerFieldDisplay {
    static func presentationValue(fieldKey: String, stored: String) -> String {
        switch fieldKey {
        case VaultFormFieldKeys.databaseEngine:
            DatabaseEngineOption.title(forStored: stored)
        case VaultFormFieldKeys.savedCommandKind:
            SavedCommandKindOption.title(forStored: stored)
        default:
            stored
        }
    }
}
