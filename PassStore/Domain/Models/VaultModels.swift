import Foundation
import Observation

@Observable
final class WorkspaceEntity: Identifiable, Hashable {
    let id: UUID
    var name: String
    var icon: String
    var colorHex: String
    var notes: String
    var isArchived: Bool
    var createdAt: Date
    var updatedAt: Date
    var sortOrder: Int
    var items: [SecretItemEntity]

    init(
        id: UUID = UUID(),
        name: String,
        icon: String = "shippingbox",
        colorHex: String = "#4A7AFF",
        notes: String = "",
        isArchived: Bool = false,
        createdAt: Date = .now,
        updatedAt: Date = .now,
        sortOrder: Int = 0,
        items: [SecretItemEntity] = []
    ) {
        self.id = id
        self.name = name
        self.icon = icon
        self.colorHex = colorHex
        self.notes = notes
        self.isArchived = isArchived
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.sortOrder = sortOrder
        self.items = items
    }

    static func == (lhs: WorkspaceEntity, rhs: WorkspaceEntity) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

@Observable
final class SecretItemEntity: Identifiable, Hashable {
    let id: UUID
    var title: String
    var typeRawValue: String
    var environmentRawValue: String
    var customEnvironmentName: String?
    var notes: String
    var tagsRawValue: String
    var isFavorite: Bool
    var isArchived: Bool
    var createdAt: Date
    var updatedAt: Date
    var lastAccessedAt: Date?
    weak var workspace: WorkspaceEntity?
    weak var template: SecretFieldTemplateEntity?
    var fields: [SecretFieldValueEntity]
    /// Newest-first audit trail. Never contains secret values — see `SecretItemChangeKind`.
    var changeHistory: [SecretItemChangeEntry]
    /// Health findings the owner chose to dismiss. Keyed to the value that produced them,
    /// so rotating a secret brings its finding back instead of hiding it forever.
    var ignoredHealthIssues: [IgnoredHealthIssue]
    /// The `.env` (or other text file) this item was imported from, if any.
    var linkedFile: LinkedFileReference?

    init(
        id: UUID = UUID(),
        title: String,
        type: SecretItemType,
        environment: EnvironmentValue = .preset(.dev),
        notes: String = "",
        tags: [String] = [],
        isFavorite: Bool = false,
        isArchived: Bool = false,
        createdAt: Date = .now,
        updatedAt: Date = .now,
        lastAccessedAt: Date? = nil,
        workspace: WorkspaceEntity? = nil,
        template: SecretFieldTemplateEntity? = nil,
        fields: [SecretFieldValueEntity] = [],
        changeHistory: [SecretItemChangeEntry] = [],
        ignoredHealthIssues: [IgnoredHealthIssue] = [],
        linkedFile: LinkedFileReference? = nil
    ) {
        self.id = id
        self.title = title
        self.typeRawValue = type.rawValue
        self.environmentRawValue = environment.kind.rawValue
        self.customEnvironmentName = environment.customName
        self.notes = notes
        self.tagsRawValue = tags.joined(separator: ",")
        self.isFavorite = isFavorite
        self.isArchived = isArchived
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastAccessedAt = lastAccessedAt
        self.workspace = workspace
        self.template = template
        self.fields = fields
        self.changeHistory = changeHistory
        self.ignoredHealthIssues = ignoredHealthIssues
        self.linkedFile = linkedFile
    }

    static func == (lhs: SecretItemEntity, rhs: SecretItemEntity) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

@Observable
final class SecretFieldValueEntity: Identifiable, Hashable {
    let id: UUID
    var fieldKey: String
    var labelSnapshot: String
    var kindRawValue: String
    var isSensitive: Bool
    var isCopyable: Bool
    var isMasked: Bool
    var sortOrder: Int
    var secretReference: String?
    var plainValue: String
    /// Newest-first previous values of this field.
    ///
    /// Unlike the 1.1.1 audit trail — which records only *that* a secret changed — this keeps
    /// the value itself, so a rotated password can be read back or restored. It rides inside
    /// the same encrypted envelope as everything else and is capped by
    /// `SecretItemRepository.valueHistoryLimit`; the owner can switch it off or purge it.
    var previousValues: [SecretValueVersion]
    weak var item: SecretItemEntity?

    init(
        id: UUID = UUID(),
        fieldKey: String,
        labelSnapshot: String,
        kind: FieldKind,
        isSensitive: Bool,
        isCopyable: Bool = true,
        isMasked: Bool = false,
        sortOrder: Int = 0,
        secretReference: String? = nil,
        plainValue: String = "",
        previousValues: [SecretValueVersion] = [],
        item: SecretItemEntity? = nil
    ) {
        self.id = id
        self.fieldKey = fieldKey
        self.labelSnapshot = labelSnapshot
        self.kindRawValue = kind.rawValue
        self.isSensitive = isSensitive
        self.isCopyable = isCopyable
        self.isMasked = isMasked
        self.sortOrder = sortOrder
        self.secretReference = secretReference
        self.plainValue = plainValue
        self.previousValues = previousValues
        self.item = item
    }

    static func == (lhs: SecretFieldValueEntity, rhs: SecretFieldValueEntity) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

@Observable
final class SecretFieldTemplateEntity: Identifiable, Hashable {
    let id: UUID
    var itemTypeRawValue: String
    var name: String
    var isBuiltIn: Bool
    var createdAt: Date
    var updatedAt: Date
    var fieldDefinitions: [SecretFieldDefinitionEntity]

    init(
        id: UUID = UUID(),
        itemType: SecretItemType,
        name: String,
        isBuiltIn: Bool,
        createdAt: Date = .now,
        updatedAt: Date = .now,
        fieldDefinitions: [SecretFieldDefinitionEntity] = []
    ) {
        self.id = id
        self.itemTypeRawValue = itemType.rawValue
        self.name = name
        self.isBuiltIn = isBuiltIn
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.fieldDefinitions = fieldDefinitions
    }

    static func == (lhs: SecretFieldTemplateEntity, rhs: SecretFieldTemplateEntity) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

@Observable
final class SecretFieldDefinitionEntity: Identifiable, Hashable {
    let id: UUID
    var key: String
    var label: String
    var kindRawValue: String
    var isSensitive: Bool
    var isCopyable: Bool
    var isMaskedByDefault: Bool
    var sortOrder: Int
    weak var template: SecretFieldTemplateEntity?

    init(
        id: UUID = UUID(),
        key: String,
        label: String,
        kind: FieldKind,
        isSensitive: Bool,
        isCopyable: Bool = true,
        isMaskedByDefault: Bool = false,
        sortOrder: Int = 0,
        template: SecretFieldTemplateEntity? = nil
    ) {
        self.id = id
        self.key = key
        self.label = label
        self.kindRawValue = kind.rawValue
        self.isSensitive = isSensitive
        self.isCopyable = isCopyable
        self.isMaskedByDefault = isMaskedByDefault
        self.sortOrder = sortOrder
        self.template = template
    }

    static func == (lhs: SecretFieldDefinitionEntity, rhs: SecretFieldDefinitionEntity) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

struct EnvironmentValue: Codable, Hashable {
    let kind: EnvironmentKind
    let customName: String?

    static func preset(_ kind: EnvironmentKind) -> EnvironmentValue {
        EnvironmentValue(kind: kind, customName: nil)
    }

    static func custom(_ name: String) -> EnvironmentValue {
        EnvironmentValue(kind: .custom, customName: name)
    }

    var title: String {
        kind == .custom ? (customName?.isEmpty == false ? customName! : "Custom") : kind.title
    }
}

struct FieldDraft: Identifiable, Hashable {
    var id: UUID = UUID()
    var key: String
    var label: String
    var value: String
    var kind: FieldKind
    var isSensitive: Bool
    var isCopyable: Bool
    var isMasked: Bool
    var sortOrder: Int
    var secretReference: String?

    init(
        id: UUID = UUID(),
        key: String,
        label: String,
        value: String = "",
        kind: FieldKind,
        isSensitive: Bool,
        isCopyable: Bool = true,
        isMasked: Bool = false,
        sortOrder: Int = 0,
        secretReference: String? = nil
    ) {
        self.id = id
        self.key = key
        self.label = label
        self.value = value
        self.kind = kind
        self.isSensitive = isSensitive
        self.isCopyable = isCopyable
        self.isMasked = isMasked
        self.sortOrder = sortOrder
        self.secretReference = secretReference
    }
}

struct SecretItemDraft: Identifiable {
    var id: UUID?
    var title: String
    var type: SecretItemType
    var workspaceID: UUID?
    var environment: EnvironmentValue
    var notes: String
    var tags: [String]
    var isFavorite: Bool
    var isArchived: Bool = false
    var fieldDrafts: [FieldDraft]
    var templateID: UUID?
    /// Carried through the editor so saving does not drop an existing file link.
    var linkedFile: LinkedFileReference?

    static let empty = SecretItemDraft(
        title: "",
        type: .generic,
        workspaceID: nil,
        environment: .preset(.dev),
        notes: "",
        tags: [],
        isFavorite: false,
        fieldDrafts: []
    )
}

struct WorkspaceDraft {
    var id: UUID?
    var name: String
    var icon: String
    var colorHex: String
    var notes: String

    static let empty = WorkspaceDraft(name: "", icon: "shippingbox", colorHex: "#4A7AFF", notes: "")
}

struct TemplateFieldDraft: Identifiable, Hashable {
    var id: UUID = UUID()
    var key: String
    var label: String
    var kind: FieldKind
    var isSensitive: Bool
    var isCopyable: Bool
    var isMaskedByDefault: Bool
    var sortOrder: Int
}

struct TemplateDraft {
    var id: UUID?
    var name: String
    var itemType: SecretItemType
    var fieldDefinitions: [TemplateFieldDraft]
}

struct FieldResolvedValue: Identifiable, Hashable {
    let id: UUID
    let key: String
    let label: String
    let value: String
    let kind: FieldKind
    let isSensitive: Bool
    let isCopyable: Bool
    let isMasked: Bool
    let sortOrder: Int
    /// Newest-first previous values, empty when history is off or the field never changed.
    let previousValues: [SecretValueVersion]

    init(
        id: UUID,
        key: String,
        label: String,
        value: String,
        kind: FieldKind,
        isSensitive: Bool,
        isCopyable: Bool,
        isMasked: Bool,
        sortOrder: Int,
        previousValues: [SecretValueVersion] = []
    ) {
        self.id = id
        self.key = key
        self.label = label
        self.value = value
        self.kind = kind
        self.isSensitive = isSensitive
        self.isCopyable = isCopyable
        self.isMasked = isMasked
        self.sortOrder = sortOrder
        self.previousValues = previousValues
    }
}

/// Shared rules for reading meaning out of a field's key and label.
enum SecretFieldClassification {
    /// True for fields that hold a rotatable login password rather than some other secret.
    /// Used both to offer the generator and to date credentials in the health audit.
    static func isPasswordLike(key: String, label: String) -> Bool {
        let descriptor = "\(key) \(label)".lowercased()
        return descriptor.contains("password") || descriptor.contains("passphrase")
    }
}

// MARK: - Secret value history

/// A value a field used to hold, and when it stopped holding it.
///
/// This is the one structure in the vault that stores an *old* secret on purpose. That is a
/// real trade-off — a rotated password stays recoverable until the history is trimmed — so
/// it is capped, purgeable per item, and switchable off entirely in Settings.
struct SecretValueVersion: Identifiable, Codable, Hashable {
    let id: UUID
    let value: String
    /// When this value was replaced by a newer one.
    let replacedAt: Date

    init(id: UUID = UUID(), value: String, replacedAt: Date = .now) {
        self.id = id
        self.value = value
        self.replacedAt = replacedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        value = try container.decodeIfPresent(String.self, forKey: .value) ?? ""
        replacedAt = try container.decodeIfPresent(Date.self, forKey: .replacedAt) ?? .now
    }
}

// MARK: - Linked files

/// A file on disk this item mirrors — in practice the `.env` it was imported from.
///
/// The bookmark is what survives the sandbox across launches; `displayPath` exists so the UI
/// can name the file even when the bookmark no longer resolves.
struct LinkedFileReference: Codable, Hashable {
    /// Security-scoped bookmark. Nil when the link was restored from a backup taken on
    /// another Mac, in which case the file has to be re-picked.
    var bookmark: Data?
    var displayPath: String
    /// Digest of the file contents at the last successful sync, in either direction.
    var syncedDigest: String?
    var syncedAt: Date?
    /// Digest of what the vault held at the last sync, so local edits can be told apart
    /// from on-disk edits instead of guessing.
    var syncedVaultDigest: String?
    /// Whether the file was stored parsed into one field per key, or as one blob.
    var parsedIntoFields: Bool

    init(
        bookmark: Data? = nil,
        displayPath: String,
        syncedDigest: String? = nil,
        syncedAt: Date? = nil,
        syncedVaultDigest: String? = nil,
        parsedIntoFields: Bool = true
    ) {
        self.bookmark = bookmark
        self.displayPath = displayPath
        self.syncedDigest = syncedDigest
        self.syncedAt = syncedAt
        self.syncedVaultDigest = syncedVaultDigest
        self.parsedIntoFields = parsedIntoFields
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        bookmark = try container.decodeIfPresent(Data.self, forKey: .bookmark)
        displayPath = try container.decodeIfPresent(String.self, forKey: .displayPath) ?? ""
        syncedDigest = try container.decodeIfPresent(String.self, forKey: .syncedDigest)
        syncedAt = try container.decodeIfPresent(Date.self, forKey: .syncedAt)
        syncedVaultDigest = try container.decodeIfPresent(String.self, forKey: .syncedVaultDigest)
        parsedIntoFields = try container.decodeIfPresent(Bool.self, forKey: .parsedIntoFields) ?? true
    }

    var fileName: String {
        (displayPath as NSString).lastPathComponent
    }

    /// Path with the home directory abbreviated, which is what the UI should show.
    var abbreviatedPath: String {
        (displayPath as NSString).abbreviatingWithTildeInPath
    }
}

// MARK: - Backup import

/// What a `.pstore` contains, shown before anything is written.
///
/// Restoring used to replace the entire vault the instant the password was accepted, with no
/// preview and no way back. Now the contents are summarised first and the owner picks how to
/// apply them.
struct ImportPreview {
    enum Mode: String, CaseIterable, Identifiable {
        /// Discard the current vault and take the backup as-is.
        case replace
        /// Keep everything current and add what the backup has and the vault does not.
        case merge

        var id: String { rawValue }

        var title: String {
            switch self {
            case .replace: "Replace"
            case .merge: "Merge"
            }
        }

        var explanation: String {
            switch self {
            case .replace:
                "Everything currently in your vault is discarded and replaced by the backup."
            case .merge:
                "Your current items are kept. Anything the backup has and your vault does not is added; nothing is overwritten."
            }
        }
    }

    let itemCount: Int
    let workspaceCount: Int
    let templateCount: Int
    let createdAt: Date?
    let fileName: String
    /// Items whose id already exists locally with different contents. Merge imports these
    /// as separate copies rather than overwriting.
    let conflictingItemCount: Int
    /// Items the vault already has byte-for-byte; merge skips these entirely.
    let identicalItemCount: Int
    /// True for legacy v1/v2 exports, which carry items only — no settings, no workspaces.
    let isLegacyFormat: Bool

    var newItemCount: Int { max(0, itemCount - conflictingItemCount - identicalItemCount) }
}

/// Result of applying an import, for the confirmation message.
struct ImportOutcome {
    let mode: ImportPreview.Mode
    let addedItems: Int
    let addedWorkspaces: Int
    let skippedIdentical: Int

    var summary: String {
        switch mode {
        case .replace:
            return "Vault replaced with \(addedItems) \(addedItems == 1 ? "item" : "items")."
        case .merge:
            var parts = ["\(addedItems) \(addedItems == 1 ? "item" : "items") added"]
            if addedWorkspaces > 0 {
                parts.append("\(addedWorkspaces) \(addedWorkspaces == 1 ? "workspace" : "workspaces") added")
            }
            if skippedIdentical > 0 {
                parts.append("\(skippedIdentical) already present")
            }
            return parts.joined(separator: ", ") + "."
        }
    }
}

// MARK: - Audit history

/// One recorded change to an item.
///
/// `detail` carries a field *label* at most. Storing a value here — even a redacted one —
/// would put plaintext secrets in a structure the UI renders unmasked, so it never happens.
struct SecretItemChangeEntry: Identifiable, Codable, Hashable {
    let id: UUID
    let kindRawValue: String
    let changedAt: Date
    let detail: String?

    var kind: SecretItemChangeKind {
        SecretItemChangeKind(rawValue: kindRawValue) ?? .detailsUpdated
    }

    init(id: UUID = UUID(), kind: SecretItemChangeKind, changedAt: Date = .now, detail: String? = nil) {
        self.id = id
        self.kindRawValue = kind.rawValue
        self.changedAt = changedAt
        self.detail = detail
    }

    /// Older vaults never wrote history, so every field tolerates absence rather than
    /// failing the whole vault decode.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        kindRawValue = try container.decodeIfPresent(String.self, forKey: .kindRawValue) ?? SecretItemChangeKind.detailsUpdated.rawValue
        changedAt = try container.decodeIfPresent(Date.self, forKey: .changedAt) ?? .now
        detail = try container.decodeIfPresent(String.self, forKey: .detail)
    }
}

/// A vault-health finding the owner dismissed.
///
/// The identity includes a digest of the offending value, so an ignore silently stops
/// applying the moment that value changes — dismissing a weak password hides today's
/// warning, not tomorrow's.
struct IgnoredHealthIssue: Identifiable, Codable, Hashable {
    let kindRawValue: String
    let fieldKey: String
    let valueDigest: String
    let ignoredAt: Date

    var id: String { "\(kindRawValue)|\(fieldKey)|\(valueDigest)" }

    init(kindRawValue: String, fieldKey: String, valueDigest: String, ignoredAt: Date = .now) {
        self.kindRawValue = kindRawValue
        self.fieldKey = fieldKey
        self.valueDigest = valueDigest
        self.ignoredAt = ignoredAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kindRawValue = try container.decodeIfPresent(String.self, forKey: .kindRawValue) ?? ""
        fieldKey = try container.decodeIfPresent(String.self, forKey: .fieldKey) ?? ""
        valueDigest = try container.decodeIfPresent(String.self, forKey: .valueDigest) ?? ""
        ignoredAt = try container.decodeIfPresent(Date.self, forKey: .ignoredAt) ?? .now
    }
}

/// When the master password was set or rotated.
///
/// Lives inside the encrypted vault payload, not in `vault.meta`: the metadata file is
/// plaintext on disk, and when someone changes their master password is nobody's business.
struct MasterPasswordChangeEntry: Identifiable, Codable, Hashable {
    let id: UUID
    let kindRawValue: String
    let changedAt: Date

    var kind: MasterPasswordChangeKind {
        MasterPasswordChangeKind(rawValue: kindRawValue) ?? .changed
    }

    init(id: UUID = UUID(), kind: MasterPasswordChangeKind, changedAt: Date = .now) {
        self.id = id
        self.kindRawValue = kind.rawValue
        self.changedAt = changedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        kindRawValue = try container.decodeIfPresent(String.self, forKey: .kindRawValue) ?? MasterPasswordChangeKind.changed.rawValue
        changedAt = try container.decodeIfPresent(Date.self, forKey: .changedAt) ?? .now
    }
}

// MARK: - Bulk edit

/// Edits applied across a multi-selection. Every action defaults to "leave it alone",
/// so an empty draft is a no-op and the sheet can only ever do what was explicitly asked.
struct BulkEditDraft {
    var tagsToAdd: [String] = []
    var tagsToRemove: [String] = []
    var workspaceAction: BulkEditWorkspaceAction = .keep
    var environmentAction: BulkEditEnvironmentAction = .keep
    var favoriteAction: BulkEditBooleanAction = .keep
    var archiveAction: BulkEditBooleanAction = .keep

    static let empty = BulkEditDraft()

    var hasChanges: Bool {
        !tagsToAdd.isEmpty
            || !tagsToRemove.isEmpty
            || workspaceAction != .keep
            || environmentAction != .keep
            || favoriteAction != .keep
            || archiveAction != .keep
    }

    /// Human summary for the confirm button, e.g. "2 tags added, moved to workspace".
    var summary: String {
        var parts: [String] = []
        if !tagsToAdd.isEmpty { parts.append("\(tagsToAdd.count) \(tagsToAdd.count == 1 ? "tag" : "tags") added") }
        if !tagsToRemove.isEmpty { parts.append("\(tagsToRemove.count) \(tagsToRemove.count == 1 ? "tag" : "tags") removed") }
        switch workspaceAction {
        case .keep: break
        case .move: parts.append("moved to workspace")
        case .clear: parts.append("workspace cleared")
        }
        if case .set = environmentAction { parts.append("environment set") }
        switch favoriteAction {
        case .keep: break
        case .enable: parts.append("favorited")
        case .disable: parts.append("unfavorited")
        }
        switch archiveAction {
        case .keep: break
        case .enable: parts.append("archived")
        case .disable: parts.append("restored")
        }
        return parts.isEmpty ? "No changes" : parts.joined(separator: ", ")
    }
}

struct ExportedItemPayload: Codable {
    let id: UUID
    let workspaceName: String?
    let title: String
    let type: String
    let environment: String
    let notes: String
    let tags: [String]
    let isFavorite: Bool
    let createdAt: Date
    let updatedAt: Date
    let fields: [ExportedFieldPayload]
}

struct ExportedFieldPayload: Codable {
    let key: String
    let label: String
    let value: String
    let kind: String
    let isSensitive: Bool
}

// MARK: - Full Backup Payload (v3)

struct ExportedSettingsPayload: Codable {
    let autoLockInterval: TimeInterval
    let clipboardClearInterval: TimeInterval
    let biometricsEnabled: Bool
    let globalCommandPaletteHotkeyEnabled: Bool
    let sidebarLibraryExpanded: Bool
    let sidebarWorkspacesExpanded: Bool
    let sidebarTypesExpanded: Bool
    let sidebarTagsExpanded: Bool
    let sidebarEnvironmentsExpanded: Bool
    let sidebarTypesOrder: [String]
    let sidebarTagsOrder: [String]
    let sidebarEnvironmentsOrder: [String]
    /// Added in 1.2.0. Backups written earlier decode these to their defaults.
    let unlocksWithBiometricsAutomatically: Bool
    let locksOnSystemLock: Bool
    let keepsSecretValueHistory: Bool
    let checksLinkedFilesOnFocus: Bool
    let itemSortOrderRawValue: String

    init(
        autoLockInterval: TimeInterval,
        clipboardClearInterval: TimeInterval,
        biometricsEnabled: Bool,
        globalCommandPaletteHotkeyEnabled: Bool,
        sidebarLibraryExpanded: Bool,
        sidebarWorkspacesExpanded: Bool,
        sidebarTypesExpanded: Bool,
        sidebarTagsExpanded: Bool,
        sidebarEnvironmentsExpanded: Bool,
        sidebarTypesOrder: [String],
        sidebarTagsOrder: [String],
        sidebarEnvironmentsOrder: [String],
        unlocksWithBiometricsAutomatically: Bool = true,
        locksOnSystemLock: Bool = true,
        keepsSecretValueHistory: Bool = true,
        checksLinkedFilesOnFocus: Bool = true,
        itemSortOrderRawValue: String = ItemSortOrder.title.rawValue
    ) {
        self.autoLockInterval = autoLockInterval
        self.clipboardClearInterval = clipboardClearInterval
        self.biometricsEnabled = biometricsEnabled
        self.globalCommandPaletteHotkeyEnabled = globalCommandPaletteHotkeyEnabled
        self.sidebarLibraryExpanded = sidebarLibraryExpanded
        self.sidebarWorkspacesExpanded = sidebarWorkspacesExpanded
        self.sidebarTypesExpanded = sidebarTypesExpanded
        self.sidebarTagsExpanded = sidebarTagsExpanded
        self.sidebarEnvironmentsExpanded = sidebarEnvironmentsExpanded
        self.sidebarTypesOrder = sidebarTypesOrder
        self.sidebarTagsOrder = sidebarTagsOrder
        self.sidebarEnvironmentsOrder = sidebarEnvironmentsOrder
        self.unlocksWithBiometricsAutomatically = unlocksWithBiometricsAutomatically
        self.locksOnSystemLock = locksOnSystemLock
        self.keepsSecretValueHistory = keepsSecretValueHistory
        self.checksLinkedFilesOnFocus = checksLinkedFilesOnFocus
        self.itemSortOrderRawValue = itemSortOrderRawValue
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        autoLockInterval = try container.decode(TimeInterval.self, forKey: .autoLockInterval)
        clipboardClearInterval = try container.decode(TimeInterval.self, forKey: .clipboardClearInterval)
        biometricsEnabled = try container.decode(Bool.self, forKey: .biometricsEnabled)
        globalCommandPaletteHotkeyEnabled = try container.decode(Bool.self, forKey: .globalCommandPaletteHotkeyEnabled)
        sidebarLibraryExpanded = try container.decode(Bool.self, forKey: .sidebarLibraryExpanded)
        sidebarWorkspacesExpanded = try container.decode(Bool.self, forKey: .sidebarWorkspacesExpanded)
        sidebarTypesExpanded = try container.decode(Bool.self, forKey: .sidebarTypesExpanded)
        sidebarTagsExpanded = try container.decode(Bool.self, forKey: .sidebarTagsExpanded)
        sidebarEnvironmentsExpanded = try container.decode(Bool.self, forKey: .sidebarEnvironmentsExpanded)
        sidebarTypesOrder = try container.decode([String].self, forKey: .sidebarTypesOrder)
        sidebarTagsOrder = try container.decode([String].self, forKey: .sidebarTagsOrder)
        sidebarEnvironmentsOrder = try container.decode([String].self, forKey: .sidebarEnvironmentsOrder)
        unlocksWithBiometricsAutomatically = try container.decodeIfPresent(Bool.self, forKey: .unlocksWithBiometricsAutomatically) ?? true
        locksOnSystemLock = try container.decodeIfPresent(Bool.self, forKey: .locksOnSystemLock) ?? true
        keepsSecretValueHistory = try container.decodeIfPresent(Bool.self, forKey: .keepsSecretValueHistory) ?? true
        checksLinkedFilesOnFocus = try container.decodeIfPresent(Bool.self, forKey: .checksLinkedFilesOnFocus) ?? true
        itemSortOrderRawValue = try container.decodeIfPresent(String.self, forKey: .itemSortOrderRawValue) ?? ItemSortOrder.title.rawValue
    }
}

struct ExportedBackupPayload: Codable {
    let vault: VaultSnapshot
    let settings: ExportedSettingsPayload
}

struct WrappedVaultKey: Codable {
    /// KDF algorithm. Nil or "pbkdf2-sha256" = legacy PBKDF2; "argon2id" = Argon2id.
    let kdfAlgorithm: String?
    let salt: String
    /// PBKDF2: iteration count. Argon2id: opslimit (number of passes).
    let iterations: Int
    /// Argon2id only: memory limit in bytes (e.g. 268_435_456 = 256 MB). Nil for PBKDF2.
    let memoryLimit: Int?
    let nonce: String
    let ciphertext: String
    let tag: String
}

struct VaultMetadata: Codable {
    let version: Int
    var wrappedVaultKey: WrappedVaultKey
    var biometricUnlockEnabled: Bool
    var updatedAt: Date
}

struct VaultEnvelope: Codable {
    let version: Int
    let nonce: String
    let ciphertext: String
    let tag: String
    let createdAt: Date
}

struct EncryptedExportEnvelope: Codable {
    let version: Int
    let kdf: WrappedVaultKey
    let payload: VaultEnvelope
    let createdAt: Date
}

struct VaultSnapshot: Codable {
    var workspaces: [WorkspaceSnapshot]
    var items: [SecretItemSnapshot]
    var customTemplates: [TemplateSnapshot]
    /// Newest-first. Added in 1.1.1; vaults written before that decode to an empty trail.
    var masterPasswordHistory: [MasterPasswordChangeEntry]

    static let empty = VaultSnapshot(workspaces: [], items: [], customTemplates: [], masterPasswordHistory: [])

    init(
        workspaces: [WorkspaceSnapshot],
        items: [SecretItemSnapshot],
        customTemplates: [TemplateSnapshot],
        masterPasswordHistory: [MasterPasswordChangeEntry] = []
    ) {
        self.workspaces = workspaces
        self.items = items
        self.customTemplates = customTemplates
        self.masterPasswordHistory = masterPasswordHistory
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        workspaces = try container.decode([WorkspaceSnapshot].self, forKey: .workspaces)
        items = try container.decode([SecretItemSnapshot].self, forKey: .items)
        customTemplates = try container.decode([TemplateSnapshot].self, forKey: .customTemplates)
        masterPasswordHistory = try container.decodeIfPresent([MasterPasswordChangeEntry].self, forKey: .masterPasswordHistory) ?? []
    }
}

struct WorkspaceSnapshot: Codable {
    let id: UUID
    let name: String
    let icon: String
    let colorHex: String
    let notes: String
    let isArchived: Bool
    let createdAt: Date
    let updatedAt: Date
    let sortOrder: Int

    init(id: UUID, name: String, icon: String, colorHex: String, notes: String, isArchived: Bool, createdAt: Date, updatedAt: Date, sortOrder: Int = 0) {
        self.id = id
        self.name = name
        self.icon = icon
        self.colorHex = colorHex
        self.notes = notes
        self.isArchived = isArchived
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.sortOrder = sortOrder
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        icon = try container.decode(String.self, forKey: .icon)
        colorHex = try container.decode(String.self, forKey: .colorHex)
        notes = try container.decode(String.self, forKey: .notes)
        isArchived = try container.decode(Bool.self, forKey: .isArchived)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        sortOrder = try container.decodeIfPresent(Int.self, forKey: .sortOrder) ?? 0
    }
}

struct SecretItemSnapshot: Codable {
    let id: UUID
    let title: String
    let typeRawValue: String
    let environmentRawValue: String
    let customEnvironmentName: String?
    let notes: String
    let tagsRawValue: String
    let isFavorite: Bool
    let isArchived: Bool
    let createdAt: Date
    let updatedAt: Date
    let lastAccessedAt: Date?
    let workspaceID: UUID?
    let templateID: UUID?
    let fields: [FieldValueSnapshot]
    /// Added in 1.1.1. Absent in vaults written by 1.1.0 and earlier.
    let changeHistory: [SecretItemChangeEntry]
    let ignoredHealthIssues: [IgnoredHealthIssue]
    /// Added in 1.2.0.
    let linkedFile: LinkedFileReference?

    init(
        id: UUID,
        title: String,
        typeRawValue: String,
        environmentRawValue: String,
        customEnvironmentName: String?,
        notes: String,
        tagsRawValue: String,
        isFavorite: Bool,
        isArchived: Bool,
        createdAt: Date,
        updatedAt: Date,
        lastAccessedAt: Date?,
        workspaceID: UUID?,
        templateID: UUID?,
        fields: [FieldValueSnapshot],
        changeHistory: [SecretItemChangeEntry] = [],
        ignoredHealthIssues: [IgnoredHealthIssue] = [],
        linkedFile: LinkedFileReference? = nil
    ) {
        self.id = id
        self.title = title
        self.typeRawValue = typeRawValue
        self.environmentRawValue = environmentRawValue
        self.customEnvironmentName = customEnvironmentName
        self.notes = notes
        self.tagsRawValue = tagsRawValue
        self.isFavorite = isFavorite
        self.isArchived = isArchived
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastAccessedAt = lastAccessedAt
        self.workspaceID = workspaceID
        self.templateID = templateID
        self.fields = fields
        self.changeHistory = changeHistory
        self.ignoredHealthIssues = ignoredHealthIssues
        self.linkedFile = linkedFile
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        typeRawValue = try container.decode(String.self, forKey: .typeRawValue)
        environmentRawValue = try container.decode(String.self, forKey: .environmentRawValue)
        customEnvironmentName = try container.decodeIfPresent(String.self, forKey: .customEnvironmentName)
        notes = try container.decode(String.self, forKey: .notes)
        tagsRawValue = try container.decode(String.self, forKey: .tagsRawValue)
        isFavorite = try container.decode(Bool.self, forKey: .isFavorite)
        isArchived = try container.decode(Bool.self, forKey: .isArchived)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        lastAccessedAt = try container.decodeIfPresent(Date.self, forKey: .lastAccessedAt)
        workspaceID = try container.decodeIfPresent(UUID.self, forKey: .workspaceID)
        templateID = try container.decodeIfPresent(UUID.self, forKey: .templateID)
        fields = try container.decode([FieldValueSnapshot].self, forKey: .fields)
        changeHistory = try container.decodeIfPresent([SecretItemChangeEntry].self, forKey: .changeHistory) ?? []
        ignoredHealthIssues = try container.decodeIfPresent([IgnoredHealthIssue].self, forKey: .ignoredHealthIssues) ?? []
        linkedFile = try container.decodeIfPresent(LinkedFileReference.self, forKey: .linkedFile)
    }
}

struct FieldValueSnapshot: Codable {
    let id: UUID
    let fieldKey: String
    let labelSnapshot: String
    let kindRawValue: String
    let isSensitive: Bool
    let isCopyable: Bool
    let isMasked: Bool
    let sortOrder: Int
    let plainValue: String
    /// Added in 1.2.0. Absent in vaults written earlier.
    let previousValues: [SecretValueVersion]

    init(
        id: UUID,
        fieldKey: String,
        labelSnapshot: String,
        kindRawValue: String,
        isSensitive: Bool,
        isCopyable: Bool,
        isMasked: Bool,
        sortOrder: Int,
        plainValue: String,
        previousValues: [SecretValueVersion] = []
    ) {
        self.id = id
        self.fieldKey = fieldKey
        self.labelSnapshot = labelSnapshot
        self.kindRawValue = kindRawValue
        self.isSensitive = isSensitive
        self.isCopyable = isCopyable
        self.isMasked = isMasked
        self.sortOrder = sortOrder
        self.plainValue = plainValue
        self.previousValues = previousValues
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        fieldKey = try container.decode(String.self, forKey: .fieldKey)
        labelSnapshot = try container.decode(String.self, forKey: .labelSnapshot)
        kindRawValue = try container.decode(String.self, forKey: .kindRawValue)
        isSensitive = try container.decode(Bool.self, forKey: .isSensitive)
        isCopyable = try container.decode(Bool.self, forKey: .isCopyable)
        isMasked = try container.decode(Bool.self, forKey: .isMasked)
        sortOrder = try container.decode(Int.self, forKey: .sortOrder)
        plainValue = try container.decode(String.self, forKey: .plainValue)
        previousValues = try container.decodeIfPresent([SecretValueVersion].self, forKey: .previousValues) ?? []
    }
}

struct TemplateSnapshot: Codable {
    let id: UUID
    let itemTypeRawValue: String
    let name: String
    let createdAt: Date
    let updatedAt: Date
    let fieldDefinitions: [TemplateFieldSnapshot]
}

struct TemplateFieldSnapshot: Codable {
    let id: UUID
    let key: String
    let label: String
    let kindRawValue: String
    let isSensitive: Bool
    let isCopyable: Bool
    let isMaskedByDefault: Bool
    let sortOrder: Int
}

// MARK: - Vault health audit

struct VaultHealthFinding: Identifiable, Hashable {
    enum Kind: String, Hashable {
        case reused
        case weak
        case stale

        /// Lower sorts first: reuse is the most actionable problem in a secret vault.
        var severity: Int {
            switch self {
            case .reused: 0
            case .weak: 1
            case .stale: 2
            }
        }

        var title: String {
            switch self {
            case .reused: "Reused"
            case .weak: "Weak"
            case .stale: "Stale"
            }
        }

        var systemImage: String {
            switch self {
            case .reused: "arrow.triangle.2.circlepath"
            case .weak: "exclamationmark.shield"
            case .stale: "clock.badge.exclamationmark"
            }
        }
    }

    let id: String
    let kind: Kind
    let itemID: UUID
    let itemTitle: String
    /// Human-readable explanation. Never contains a secret value.
    let detail: String
    /// Field this finding is about; empty for item-level findings such as `.stale`.
    let fieldKey: String
    /// Digest of the offending value, so an ignore expires when the value is rotated.
    /// Empty for `.stale`, which is dated rather than valued.
    let valueDigest: String
    /// For `.stale`: the date the finding is measured against. An ignore recorded before
    /// this date is out of date and stops applying.
    let referenceDate: Date?

    init(
        id: String,
        kind: Kind,
        itemID: UUID,
        itemTitle: String,
        detail: String,
        fieldKey: String = "",
        valueDigest: String = "",
        referenceDate: Date? = nil
    ) {
        self.id = id
        self.kind = kind
        self.itemID = itemID
        self.itemTitle = itemTitle
        self.detail = detail
        self.fieldKey = fieldKey
        self.valueDigest = valueDigest
        self.referenceDate = referenceDate
    }

    /// The dismissal record this finding would produce.
    var ignoreRecord: IgnoredHealthIssue {
        IgnoredHealthIssue(kindRawValue: kind.rawValue, fieldKey: fieldKey, valueDigest: valueDigest)
    }

    /// True when `ignored` still describes this exact finding.
    ///
    /// Value-based findings match on the digest, so changing the secret invalidates the
    /// dismissal. `.stale` has no value to key on, so it matches only while the item has
    /// not been touched since the dismissal.
    func isSilenced(by ignored: IgnoredHealthIssue) -> Bool {
        guard ignored.kindRawValue == kind.rawValue, ignored.fieldKey == fieldKey else { return false }
        guard kind == .stale else { return ignored.valueDigest == valueDigest }
        guard let referenceDate else { return true }
        return ignored.ignoredAt >= referenceDate
    }
}

struct VaultHealthReport {
    let auditedItemCount: Int
    let findings: [VaultHealthFinding]
    /// Findings that were produced but suppressed by an explicit dismissal.
    let ignoredFindings: [VaultHealthFinding]

    init(auditedItemCount: Int, findings: [VaultHealthFinding], ignoredFindings: [VaultHealthFinding] = []) {
        self.auditedItemCount = auditedItemCount
        self.findings = findings
        self.ignoredFindings = ignoredFindings
    }

    func count(of kind: VaultHealthFinding.Kind) -> Int {
        findings.filter { $0.kind == kind }.count
    }

    var isClean: Bool { findings.isEmpty }

    var ignoredCount: Int { ignoredFindings.count }
}

struct ParsedEnvDocument {
    var notes: String
    var entries: [ParsedEnvEntry]
}

enum EnvImportSource {
    case file(URL)
    case pastedText(String)
}

struct ParsedEnvEntry: Identifiable, Hashable {
    var id: UUID = UUID()
    var key: String
    var value: String
    var isSensitive: Bool
}

extension SecretItemEntity {
    var type: SecretItemType {
        get { SecretItemType(rawValue: typeRawValue) ?? .generic }
        set { typeRawValue = newValue.rawValue }
    }

    var environmentValue: EnvironmentValue {
        get {
            let kind = EnvironmentKind(rawValue: environmentRawValue) ?? .dev
            return kind == .custom ? .custom(customEnvironmentName ?? "Custom") : .preset(kind)
        }
        set {
            environmentRawValue = newValue.kind.rawValue
            customEnvironmentName = newValue.customName
        }
    }

    var tags: [String] {
        get {
            tagsRawValue
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }
        set {
            tagsRawValue = newValue
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: ",")
        }
    }
}

extension SecretItemEntity {
    /// When a password field on this item was last rotated, as recorded in the audit trail.
    ///
    /// Nil for items that predate history or have never had a password changed — callers
    /// fall back to `updatedAt`, which is what the audit did before 1.1.1.
    var passwordLastChangedAt: Date? {
        changeHistory
            .filter { $0.kind.isPasswordRotation }
            .map(\.changedAt)
            .max()
    }

    /// The date the staleness audit measures against: a password's own rotation date when
    /// known, otherwise the item's last edit. Renaming an item no longer makes its
    /// two-year-old password look fresh.
    var healthReferenceDate: Date {
        passwordLastChangedAt ?? updatedAt
    }

    var orderedChangeHistory: [SecretItemChangeEntry] {
        changeHistory.sorted { $0.changedAt > $1.changedAt }
    }
}

extension SecretFieldValueEntity {
    var kind: FieldKind {
        get { FieldKind(rawValue: kindRawValue) ?? .text }
        set { kindRawValue = newValue.rawValue }
    }
}

extension SecretFieldTemplateEntity {
    var itemType: SecretItemType {
        get { SecretItemType(rawValue: itemTypeRawValue) ?? .generic }
        set { itemTypeRawValue = newValue.rawValue }
    }
}

extension SecretFieldDefinitionEntity {
    var kind: FieldKind {
        get { FieldKind(rawValue: kindRawValue) ?? .text }
        set { kindRawValue = newValue.rawValue }
    }
}
