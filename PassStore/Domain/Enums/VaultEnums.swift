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

/// What happened to an item, as recorded in its audit history.
///
/// Entries describe *that* something changed, never *what it changed to*: a history entry
/// must stay safe to render next to a locked field, so no case ever carries a secret value.
enum SecretItemChangeKind: String, Codable, CaseIterable {
    case created
    case detailsUpdated
    case typeChanged
    case environmentChanged
    case workspaceChanged
    case fieldAdded
    case fieldRemoved
    case fieldValueChanged
    case sensitiveValueChanged
    case passwordRotated
    case favoriteEnabled
    case favoriteDisabled
    case archived
    case restored

    var title: String {
        switch self {
        case .created: "Created"
        case .detailsUpdated: "Details updated"
        case .typeChanged: "Type changed"
        case .environmentChanged: "Environment changed"
        case .workspaceChanged: "Workspace changed"
        case .fieldAdded: "Field added"
        case .fieldRemoved: "Field removed"
        case .fieldValueChanged: "Value changed"
        case .sensitiveValueChanged: "Secret changed"
        case .passwordRotated: "Password rotated"
        case .favoriteEnabled: "Added to favorites"
        case .favoriteDisabled: "Removed from favorites"
        case .archived: "Archived"
        case .restored: "Restored"
        }
    }

    var systemImage: String {
        switch self {
        case .created: "plus.circle"
        case .detailsUpdated: "pencil"
        case .typeChanged: "square.on.square"
        case .environmentChanged: "circle.hexagongrid"
        case .workspaceChanged: "shippingbox"
        case .fieldAdded: "plus.square"
        case .fieldRemoved: "minus.square"
        case .fieldValueChanged: "pencil.line"
        case .sensitiveValueChanged: "lock.rotation"
        case .passwordRotated: "key.horizontal"
        case .favoriteEnabled: "star.fill"
        case .favoriteDisabled: "star.slash"
        case .archived: "archivebox"
        case .restored: "tray.and.arrow.up"
        }
    }

    /// Rotating a password is what "when did this secret last change?" actually means;
    /// the vault health audit reads only these entries when dating a credential.
    var isPasswordRotation: Bool {
        self == .passwordRotated
    }
}

/// Why the master password entry was written.
enum MasterPasswordChangeKind: String, Codable {
    case vaultCreated
    case changed

    var title: String {
        switch self {
        case .vaultCreated: "Vault created"
        case .changed: "Password changed"
        }
    }
}

/// Tri-state toggle for bulk edits: leave every item alone, or force one value across all of them.
enum BulkEditBooleanAction: String, CaseIterable, Identifiable {
    case keep
    case enable
    case disable

    var id: String { rawValue }
}

/// Bulk workspace reassignment. `.clear` un-assigns without deleting anything.
enum BulkEditWorkspaceAction: Hashable {
    case keep
    case move(UUID)
    case clear
}

enum BulkEditEnvironmentAction: Hashable {
    case keep
    case set(EnvironmentValue)
}

/// How the item list is ordered. Persisted in settings.
///
/// Before 1.2.0 the order was hard-coded to title-ascending everywhere except "Recent",
/// so there was no way to ask "what did I touch last?" from any other destination.
enum ItemSortOrder: String, CaseIterable, Identifiable {
    case title
    case recentlyUsed
    case recentlyUpdated
    case newestFirst

    var id: String { rawValue }

    var title: String {
        switch self {
        case .title: "Name"
        case .recentlyUsed: "Last used"
        case .recentlyUpdated: "Last modified"
        case .newestFirst: "Date created"
        }
    }

    var systemImage: String {
        switch self {
        case .title: "textformat.abc"
        case .recentlyUsed: "clock.arrow.circlepath"
        case .recentlyUpdated: "pencil.circle"
        case .newestFirst: "calendar.badge.plus"
        }
    }
}

/// State of the `.env` file a record was imported from, relative to what is stored.
enum LinkedFileStatus: Equatable {
    /// No file is linked to this item.
    case unlinked
    /// The file is reachable and matches what the vault holds.
    case upToDate
    /// The file on disk has changed since the last sync.
    case fileChanged
    /// The vault has changed since the last sync, so writing back would push local edits out.
    case vaultChanged
    /// Both sides moved since the last sync.
    case diverged
    /// The bookmark no longer resolves — file moved, renamed or deleted.
    case unavailable

    var isActionable: Bool {
        switch self {
        case .unlinked, .upToDate, .unavailable: false
        case .fileChanged, .vaultChanged, .diverged: true
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
    case passwordGenerator
    case vaultHealth
    case bulkEdit
    /// Preview of a backup before it is applied, with the replace / merge choice.
    case importPreview
    /// Full audit trail and previous values for one item.
    case itemHistory(UUID)

    var id: String {
        switch self {
        case .newItemFlow: "new-item-flow"
        case let .editItem(id): "edit-item-\(id.uuidString)"
        case .newWorkspace: "new-workspace"
        case let .editWorkspace(id): "edit-workspace-\(id.uuidString)"
        case .importEncryptedExport: "import-encrypted-export"
        case .export: "export"
        case .passwordGenerator: "password-generator"
        case .vaultHealth: "vault-health"
        case .bulkEdit: "bulk-edit"
        case .importPreview: "import-preview"
        case let .itemHistory(id): "item-history-\(id.uuidString)"
        }
    }
}
