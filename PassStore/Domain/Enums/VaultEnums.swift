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

/// How a value was quoted in a `.env` file.
///
/// Kept per assignment so writing a new value back can use the quoting the owner already had.
/// Double quotes are the safe default when a value needs escaping; they should not be imposed
/// on a file that did without them.
nonisolated enum EnvQuoteStyle: String, Codable, Hashable, Sendable {
    case none
    case single
    case double

    init(leadingCharacter: Character?) {
        switch leadingCharacter {
        case "\"": self = .double
        case "'": self = .single
        default: self = .none
        }
    }
}

/// The declared order is the lifecycle order — local, dev, staging, prod — and code relies on
/// it: `WorkspaceEnvironment.canonicalRank(of:)` orders a workspace's environments by it, so
/// reordering these cases reorders the UI.
nonisolated enum EnvironmentKind: String, CaseIterable, Codable, Identifiable {
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

    /// How an environment is told apart from its siblings.
    ///
    /// Deliberately a glyph rather than a colour: colour already means "which workspace this
    /// belongs to" everywhere else in the app, and giving environments their own palette made
    /// two different things compete for the same signal. Every environment of a project is
    /// drawn in the project's colour, and these tell them apart.
    var systemImage: String {
        switch self {
        case .local: "laptopcomputer"
        case .dev: "hammer.fill"
        case .staging: "testtube.2"
        case .prod: "globe.americas.fill"
        case .custom: "circle.hexagongrid"
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
    /// The file and vault differed when the link was created; the owner must pick a side.
    case needsInitialSync
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
        case .needsInitialSync, .fileChanged, .vaultChanged, .diverged: true
        }
    }
}

/// What happened to one variable since an item and its `.env` were last in sync.
///
/// `LinkedFileStatus` answers "has something changed?" for the whole file, which leaves the owner
/// with one decision covering everything in it. This answers "what changed" per variable, so a
/// value can be pulled or pushed on its own without touching anything else.
///
/// Deliberately carries no values: the state is cached per item while the vault is unlocked, and
/// a cache of every linked file's secrets is not something to keep around. The value is read from
/// the file at the moment it is applied.
nonisolated enum EnvFieldDrift: String, Equatable, Sendable {
    /// The file holds a different value; the item's has not moved since the last sync.
    case fileChanged
    /// The item's value has moved; the file's has not.
    case vaultChanged
    /// Both moved, or the link predates per-variable tracking and which side moved is unknown.
    case diverged
    /// The item has this variable and the file does not.
    case onlyInVault
    /// The file has this variable and the item does not.
    case onlyInFile

    /// Whether the file has a value that could be pulled in.
    var canPull: Bool {
        self != .onlyInVault
    }

    /// Whether the item has a value that could be written out.
    var canPush: Bool {
        self != .onlyInFile
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
    /// One environment of one workspace — "Acme API › Prod".
    ///
    /// Identified by environment *title* rather than by a declaration id, because an
    /// environment can be in use without ever having been declared: every vault written before
    /// 1.3 is in exactly that state, and navigation has to reach those items too.
    case workspaceEnvironment(UUID, String)
    case tag(String)
    /// The same environment across every workspace. Kept alongside the scoped case: "show me
    /// everything in production" is a different and still useful question.
    case environment(String)

    var workspaceID: UUID? {
        switch self {
        case let .workspace(id): id
        case let .workspaceEnvironment(id, _): id
        case .library, .tag, .environment: nil
        }
    }
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
    /// A whole workspace proposed from a folder the owner picked: its name, its environments and
    /// the `.env` files it will start with, all reviewable before anything is created.
    case newWorkspaceFromFolder
    /// The `.env` files found in a workspace's linked folder, before any of them is imported.
    case envDiscovery(UUID)
    /// Keys side by side across one workspace's environments.
    case environmentMatrix(UUID)
    /// Sending a secret into another environment, and choosing how much of it comes across.
    case copyToEnvironment

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
        case .newWorkspaceFromFolder: "new-workspace-from-folder"
        case let .envDiscovery(id): "env-discovery-\(id.uuidString)"
        case let .environmentMatrix(id): "environment-matrix-\(id.uuidString)"
        case .copyToEnvironment: "copy-to-environment"
        }
    }
}
