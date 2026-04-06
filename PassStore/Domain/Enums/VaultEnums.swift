import Foundation

enum SecretItemType: String, CaseIterable, Codable, Identifiable {
    case generic
    case envGroup
    case database
    case apiCredential
    case s3Compatible
    case serverSSH
    case websiteService
    case savedCommand
    case customTemplate

    var id: String { rawValue }

    var title: String {
        switch self {
        case .generic: "Generic Secret"
        case .envGroup: ".env File"
        case .database: "Database"
        case .apiCredential: "API Credential"
        case .s3Compatible: "MinIO / S3"
        case .serverSSH: "Server / SSH"
        case .websiteService: "Website / Service"
        case .savedCommand: "Saved Command"
        case .customTemplate: "Custom Template"
        }
    }

    var systemImage: String {
        switch self {
        case .generic: "lock.doc"
        case .envGroup: "curlybraces.square"
        case .database: "cylinder.split.1x2"
        case .apiCredential: "key.horizontal"
        case .s3Compatible: "shippingbox"
        case .serverSSH: "terminal"
        case .websiteService: "globe"
        case .savedCommand: "chevron.left.forwardslash.chevron.right"
        case .customTemplate: "square.on.square"
        }
    }
}

enum FieldKind: String, CaseIterable, Codable, Identifiable {
    case text
    case secret
    case url
    case number
    case multiline
    case json

    var id: String { rawValue }

    var title: String { rawValue.capitalized }
}

enum EnvironmentKind: String, CaseIterable, Codable, Identifiable {
    case local
    case dev
    case staging
    case prod
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .local: "Local"
        case .dev: "Dev"
        case .staging: "Staging"
        case .prod: "Prod"
        case .custom: "Custom"
        }
    }
}

enum LibrarySection: String, CaseIterable, Hashable, Identifiable {
    case allItems
    case favorites
    case recent
    case archived

    var id: String { rawValue }

    var title: String {
        switch self {
        case .allItems: "All Items"
        case .favorites: "Favorites"
        case .recent: "Recent"
        case .archived: "Archived"
        }
    }

    var systemImage: String {
        switch self {
        case .allItems: "square.stack.3d.up"
        case .favorites: "star"
        case .recent: "clock"
        case .archived: "archivebox"
        }
    }
}

enum VaultDestination: Hashable {
    case library(LibrarySection)
    case workspace(UUID)
    case tag(String)
    case environment(String)
}

enum VaultSheet: Identifiable {
    case newItemFlow
    case editItem(UUID)
    case newWorkspace
    case editWorkspace(UUID)
    case importEncryptedExport
    case export

    var id: String {
        switch self {
        case .newItemFlow: "new-item-flow"
        case let .editItem(id): "edit-item-\(id.uuidString)"
        case .newWorkspace: "new-workspace"
        case let .editWorkspace(id): "edit-workspace-\(id.uuidString)"
        case .importEncryptedExport: "import-encrypted-export"
        case .export: "export"
        }
    }
}
