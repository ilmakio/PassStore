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
        fields: [SecretFieldValueEntity] = []
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

    static let empty = VaultSnapshot(workspaces: [], items: [], customTemplates: [])
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
