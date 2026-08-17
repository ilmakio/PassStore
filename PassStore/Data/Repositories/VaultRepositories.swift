import CryptoKit
import Foundation

@MainActor
final class WorkspaceRepository: WorkspaceRepositoryProtocol {
    private let store: VaultMemoryStore

    init(store: VaultMemoryStore) {
        self.store = store
    }

    func fetchAll(includeArchived: Bool = false) throws -> [WorkspaceEntity] {
        let all = store.workspaces.sorted {
            if $0.sortOrder != $1.sortOrder { return $0.sortOrder < $1.sortOrder }
            if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
            return $0.id.uuidString < $1.id.uuidString
        }
        return includeArchived ? all : all.filter { !$0.isArchived }
    }

    @discardableResult
    func saveWorkspace(_ draft: WorkspaceDraft) throws -> WorkspaceEntity {
        try store.performTransaction {
            try saveWorkspaceMutation(draft)
        }
    }

    private func saveWorkspaceMutation(_ draft: WorkspaceDraft) throws -> WorkspaceEntity {
        try store.requireUnlocked()
        let workspace: WorkspaceEntity
        if let id = draft.id,
           let existing = store.workspaces.first(where: { $0.id == id }) {
            workspace = existing
        } else {
            workspace = WorkspaceEntity(
                id: draft.id ?? UUID(),
                name: draft.name,
                icon: draft.icon,
                colorHex: draft.colorHex,
                notes: draft.notes,
                sortOrder: store.workspaces.count
            )
            store.workspaces.append(workspace)
        }
        workspace.name = draft.name
        workspace.icon = draft.icon
        workspace.colorHex = draft.colorHex
        workspace.notes = draft.notes
        workspace.environments = WorkspaceEnvironment.sanitizedList(draft.environments)
        workspace.updatedAt = .now
        try store.persist()
        return workspace
    }

    /// Links, re-links or unlinks the folder this workspace belongs to.
    ///
    /// Separate from `saveWorkspace` because linking a folder is its own decision — and because
    /// unlinking has to be a single, obvious gesture: it is how the owner takes the folder
    /// permission back.
    func setLinkedFolder(_ folder: LinkedFolderReference?, onWorkspaceWithID id: UUID) throws {
        try store.performTransaction {
            try store.requireUnlocked()
            guard let workspace = store.workspaces.first(where: { $0.id == id }) else { return }
            workspace.linkedFolder = folder
            workspace.updatedAt = .now
            try store.persist()
        }
    }

    /// Replaces the declared environments without touching anything else on the workspace.
    ///
    /// The editor round-trips the whole draft, but adopting an environment, reordering the list
    /// or switching one off are single gestures made from the sidebar and the overview — they
    /// have no business rewriting the workspace's name and notes on the way.
    @discardableResult
    func setEnvironments(
        _ environments: [WorkspaceEnvironment],
        onWorkspaceWithID id: UUID
    ) throws -> [WorkspaceEnvironment] {
        try store.performTransaction {
            try store.requireUnlocked()
            guard let workspace = store.workspaces.first(where: { $0.id == id }) else {
                return []
            }
            let sanitized = WorkspaceEnvironment.sanitizedList(environments)
            workspace.environments = sanitized
            workspace.updatedAt = .now
            try store.persist()
            return sanitized
        }
    }

    func reorderWorkspaces(_ ids: [UUID]) throws {
        try store.performTransaction {
            try reorderWorkspacesMutation(ids)
        }
    }

    private func reorderWorkspacesMutation(_ ids: [UUID]) throws {
        try store.requireUnlocked()
        for (index, id) in ids.enumerated() {
            store.workspaces.first(where: { $0.id == id })?.sortOrder = index
        }
        try store.persist()
    }

    func deleteWorkspace(_ workspace: WorkspaceEntity) throws {
        try store.performTransaction {
            try deleteWorkspaceMutation(workspace)
        }
    }

    private func deleteWorkspaceMutation(_ workspace: WorkspaceEntity) throws {
        try store.requireUnlocked()
        for item in store.items where item.workspace?.id == workspace.id {
            item.workspace = nil
        }
        store.workspaces.removeAll { $0.id == workspace.id }
        try store.persist()
    }
}

@MainActor
final class TemplateRepository: TemplateRepositoryProtocol {
    private let store: VaultMemoryStore

    init(store: VaultMemoryStore) {
        self.store = store
    }

    func fetchAll() throws -> [SecretFieldTemplateEntity] {
        store.allTemplates.sorted(by: templateSortComparator)
    }

    func seedBuiltInsIfNeeded() throws {}

    @discardableResult
    func saveTemplate(_ draft: TemplateDraft, isBuiltIn: Bool = false) throws -> SecretFieldTemplateEntity {
        try store.performTransaction {
            try saveTemplateMutation(draft, isBuiltIn: isBuiltIn)
        }
    }

    private func saveTemplateMutation(_ draft: TemplateDraft, isBuiltIn: Bool) throws -> SecretFieldTemplateEntity {
        try store.requireUnlocked()
        let existingCustom = draft.id.flatMap { id in store.customTemplates.first(where: { $0.id == id }) }
        let requestedID = draft.id ?? UUID()
        let templateID = existingCustom == nil
            && store.allTemplates.contains(where: { $0.id == requestedID })
            ? UUID()
            : requestedID
        let template = existingCustom ?? SecretFieldTemplateEntity(
            id: templateID,
            itemType: draft.itemType,
            name: draft.name,
            isBuiltIn: false
        )

        if existingCustom == nil {
            store.customTemplates.append(template)
        }

        template.name = draft.name
        template.itemType = draft.itemType
        template.updatedAt = .now
        template.isBuiltIn = false

        let existingDefinitions = Dictionary(
            template.fieldDefinitions.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var seenDefinitionIDs: Set<UUID> = []
        template.fieldDefinitions = draft.fieldDefinitions.map { fieldDraft in
            let definitionID = seenDefinitionIDs.insert(fieldDraft.id).inserted
                ? fieldDraft.id
                : UUID()
            let definition = existingDefinitions[definitionID] ?? SecretFieldDefinitionEntity(
                id: definitionID,
                key: fieldDraft.key,
                label: fieldDraft.label,
                kind: fieldDraft.kind,
                isSensitive: fieldDraft.isSensitive,
                isCopyable: fieldDraft.isCopyable,
                isMaskedByDefault: fieldDraft.isMaskedByDefault,
                sortOrder: fieldDraft.sortOrder,
                template: template
            )
            definition.key = fieldDraft.key
            definition.label = fieldDraft.label
            definition.kind = fieldDraft.kind
            definition.isSensitive = fieldDraft.isSensitive
            definition.isCopyable = fieldDraft.isCopyable
            definition.isMaskedByDefault = fieldDraft.isMaskedByDefault
            definition.sortOrder = fieldDraft.sortOrder
            definition.template = template
            return definition
        }.sorted {
            if $0.sortOrder != $1.sortOrder { return $0.sortOrder < $1.sortOrder }
            return $0.id.uuidString < $1.id.uuidString
        }

        try store.persist()
        return template
    }

    func deleteTemplate(_ template: SecretFieldTemplateEntity) throws {
        // Resolve against the live custom collection. A stale/fabricated object carrying a
        // built-in id must not detach items from that built-in template.
        guard let storedTemplate = store.customTemplates.first(where: { $0.id == template.id }) else { return }
        try store.performTransaction {
            try deleteTemplateMutation(storedTemplate)
        }
    }

    private func deleteTemplateMutation(_ template: SecretFieldTemplateEntity) throws {
        try store.requireUnlocked()
        for item in store.items where item.template?.id == template.id {
            item.template = nil
        }
        store.customTemplates.removeAll { $0.id == template.id }
        try store.persist()
    }

    private func templateSortComparator(lhs: SecretFieldTemplateEntity, rhs: SecretFieldTemplateEntity) -> Bool {
        if lhs.isBuiltIn != rhs.isBuiltIn {
            return lhs.isBuiltIn && !rhs.isBuiltIn
        }
        let comparison = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
        if comparison != .orderedSame { return comparison == .orderedAscending }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}

@MainActor
final class SecretItemRepository: SecretItemRepositoryProtocol {
    private let store: VaultMemoryStore
    private let settings: AppSettingsStore?

    init(store: VaultMemoryStore, settings: AppSettingsStore? = nil) {
        self.store = store
        self.settings = settings
    }

    func fetchAll(includeArchived: Bool = false) throws -> [SecretItemEntity] {
        let items = store.items.sorted {
            if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
            return $0.id.uuidString < $1.id.uuidString
        }
        return includeArchived ? items : items.filter { !$0.isArchived }
    }

    func resolveFields(for item: SecretItemEntity) throws -> [FieldResolvedValue] {
        item.fields.map {
            FieldResolvedValue(
                id: $0.id,
                key: $0.fieldKey,
                label: $0.labelSnapshot,
                value: $0.plainValue,
                kind: $0.kind,
                isSensitive: $0.isSensitive,
                isCopyable: $0.isCopyable,
                isMasked: $0.isMasked,
                sortOrder: $0.sortOrder,
                previousValues: $0.previousValues.sorted { $0.replacedAt > $1.replacedAt }
            )
        }.sorted {
            if $0.sortOrder != $1.sortOrder { return $0.sortOrder < $1.sortOrder }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    // MARK: - Value history

    /// Whether previous values are kept when a field changes. Off means no new versions are
    /// written; it does not retroactively purge what is already stored (`purgeValueHistory`
    /// does that).
    ///
    /// Read straight from settings so the switch takes effect on the next save with no
    /// separate copy of the flag to keep in sync.
    var keepsValueHistory: Bool {
        settings?.keepsSecretValueHistory ?? true
    }

    /// Bounded per field: an actively rotated credential should not grow the vault forever.
    static let valueHistoryLimit = 10

    /// Drops every stored previous value in the vault.
    func purgeAllValueHistory() throws {
        try store.performTransaction {
            try purgeAllValueHistoryMutation()
        }
    }

    private func purgeAllValueHistoryMutation() throws {
        try store.requireUnlocked()
        for item in store.items {
            for field in item.fields where !field.previousValues.isEmpty {
                Self.securelyClearValueHistory(on: field)
            }
        }
        try store.persist()
    }

    /// Drops stored previous values for one item.
    func purgeValueHistory(for item: SecretItemEntity) throws {
        try store.performTransaction {
            try purgeValueHistoryMutation(for: item)
        }
    }

    private func purgeValueHistoryMutation(for item: SecretItemEntity) throws {
        try store.requireUnlocked()
        guard let storedItem = store.items.first(where: { $0.id == item.id }) else { return }
        for field in storedItem.fields where !field.previousValues.isEmpty {
            Self.securelyClearValueHistory(on: field)
        }
        try store.persist()
    }

    @discardableResult
    func saveItem(_ draft: SecretItemDraft) throws -> SecretItemEntity {
        try store.performTransaction {
            try saveItemMutation(draft)
        }
    }

    private func saveItemMutation(_ draft: SecretItemDraft) throws -> SecretItemEntity {
        try store.requireUnlocked()
        let draft = Self.normalized(draft)
        let item: SecretItemEntity
        let isNewItem: Bool
        if let id = draft.id,
           let existing = store.items.first(where: { $0.id == id }) {
            item = existing
            isNewItem = false
        } else {
            // Honour an explicit id when creating. It used to be discarded, so restoring an
            // item from a backup produced a brand-new id — which meant importing the same
            // backup twice duplicated everything, and nothing could be matched against what
            // the vault already held.
            item = SecretItemEntity(
                id: draft.id ?? UUID(),
                title: draft.title,
                type: draft.type,
                environment: draft.environment
            )
            // Creating something counts as using it. Without this a brand-new item — the
            // `.env` you just imported, say — had no "last used" date at all and so did not
            // appear in Recent, which is exactly where you would go looking for it.
            item.lastAccessedAt = .now
            store.items.append(item)
            isNewItem = true
        }

        // Snapshot before mutating: the diff is what becomes the audit trail.
        let previous = isNewItem ? nil : ItemStateSnapshot(item: item)

        item.title = draft.title
        item.type = draft.type
        item.environmentValue = draft.environment
        item.notes = draft.notes
        item.tags = draft.tags
        item.isFavorite = draft.isFavorite
        item.isArchived = draft.isArchived
        // Bumped only for changes the owner would call an edit. Starring an item or archiving
        // it used to move `updatedAt`, which pushed it to the top of "Recent" and reset the
        // staleness clock the health audit reads.
        if Self.isContentChange(draft: draft, previous: previous) {
            item.updatedAt = .now
        }
        item.workspace = workspace(for: draft.workspaceID)
        item.template = template(for: draft.templateID)
        item.linkedFile = draft.linkedFile
        item.envLayout = draft.envLayout

        // Field keys are the merge identity, so collisions must be resolved before mapping:
        // `Dictionary(uniqueKeysWithValues:)` traps on duplicates, and the editor lets two
        // fields end up with the same slug (e.g. renaming a field to match an existing one).
        let oldFields = item.fields
        let existingFields = Dictionary(oldFields.map { ($0.fieldKey, $0) }, uniquingKeysWith: { first, _ in first })
        let uniqueDrafts = Self.withUniqueKeys(draft.fieldDrafts)
        let replacementFields = uniqueDrafts.map { fieldDraft in
            let field = existingFields[fieldDraft.key] ?? SecretFieldValueEntity(
                id: fieldDraft.id,
                fieldKey: fieldDraft.key,
                labelSnapshot: fieldDraft.label,
                kind: fieldDraft.kind,
                isSensitive: fieldDraft.isSensitive,
                isCopyable: fieldDraft.isCopyable,
                isMasked: fieldDraft.isMasked,
                sortOrder: fieldDraft.sortOrder,
                plainValue: fieldDraft.value,
                item: item
            )
            let oldValue = field.plainValue
            let oldWasSensitive = field.isSensitive
            field.fieldKey = fieldDraft.key
            field.labelSnapshot = fieldDraft.label
            field.kind = fieldDraft.kind
            field.isSensitive = fieldDraft.isSensitive
            field.isCopyable = fieldDraft.isCopyable
            field.isMasked = fieldDraft.isMasked
            field.sortOrder = fieldDraft.sortOrder
            // Keep the outgoing value before overwriting it, so a rotated secret can be read
            // back or restored later.
            recordValueVersion(
                on: field,
                replacing: oldValue,
                oldWasSensitive: oldWasSensitive,
                with: fieldDraft.value,
                newIsSensitive: fieldDraft.isSensitive
            )
            field.plainValue = fieldDraft.value
            field.item = item
            return field
        }.sorted {
            if $0.sortOrder != $1.sortOrder { return $0.sortOrder < $1.sortOrder }
            return $0.id.uuidString < $1.id.uuidString
        }
        let retainedObjects = Set(replacementFields.map(ObjectIdentifier.init))
        for removed in oldFields where !retainedObjects.contains(ObjectIdentifier(removed)) {
            Self.securelyClear(field: removed)
            removed.item = nil
        }
        item.fields = replacementFields

        recordHistory(for: item, previous: previous)
        pruneStaleIgnores(on: item)
        rebuildWorkspaceItems()
        try store.persist()
        return item
    }

    /// Pushes the outgoing value onto the field's history.
    ///
    /// Only real replacements are recorded: filling a blank field for the first time, or
    /// saving without touching the value, adds nothing.
    private func recordValueVersion(
        on field: SecretFieldValueEntity,
        replacing oldValue: String,
        oldWasSensitive: Bool,
        with newValue: String,
        newIsSensitive: Bool
    ) {
        // History is exclusively for secrets. Turning sensitivity off must remove any old
        // secret versions immediately; otherwise they remain recoverable through a field the
        // UI now treats as ordinary text.
        guard newIsSensitive else {
            Self.securelyClearValueHistory(on: field)
            return
        }
        guard keepsValueHistory else { return }
        guard oldWasSensitive, oldValue != newValue, !oldValue.isEmpty else { return }
        let version = SecretValueVersion(value: oldValue)
        var versions = [version] + field.previousValues
        if versions.count > Self.valueHistoryLimit {
            for index in Self.valueHistoryLimit..<versions.count {
                versions[index].securelyClear()
            }
            versions.removeSubrange(Self.valueHistoryLimit...)
        }
        field.previousValues = versions
    }

    private static func securelyClearValueHistory(on field: SecretFieldValueEntity) {
        for index in field.previousValues.indices {
            field.previousValues[index].securelyClear()
        }
        field.previousValues.removeAll(keepingCapacity: false)
    }

    private static func securelyClear(field: SecretFieldValueEntity) {
        if !field.plainValue.isEmpty {
            field.plainValue = String(repeating: "\0", count: field.plainValue.utf8.count)
            field.plainValue.removeAll(keepingCapacity: false)
        }
        securelyClearValueHistory(on: field)
    }

    /// True when the draft changes something the owner would describe as editing the item.
    ///
    /// Favourite and archive flags are state, not content: they get their own audit entries
    /// but must not touch `updatedAt`.
    private static func isContentChange(draft: SecretItemDraft, previous: ItemStateSnapshot?) -> Bool {
        guard let previous else { return true }
        if previous.title != draft.title { return true }
        if previous.notes != draft.notes { return true }
        if previous.type != draft.type { return true }
        if previous.environment != draft.environment { return true }
        if previous.workspaceID != draft.workspaceID { return true }
        if previous.templateID != draft.templateID { return true }
        if previous.tags != draft.tags { return true }
        if previous.linkedFile != draft.linkedFile { return true }

        let incoming = Dictionary(
            withUniqueKeys(draft.fieldDrafts).map { ($0.key, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        if Set(incoming.keys) != Set(previous.fields.keys) { return true }
        return incoming.contains { key, fieldDraft in
            guard let old = previous.fields[key] else { return true }
            return old.value != fieldDraft.value
                || old.label != fieldDraft.label
                || old.kind != fieldDraft.kind
                || old.isSensitive != fieldDraft.isSensitive
                || old.isCopyable != fieldDraft.isCopyable
                || old.isMasked != fieldDraft.isMasked
                || old.sortOrder != fieldDraft.sortOrder
        }
    }

    /// Drops dismissals that can no longer match anything.
    ///
    /// A dismissal is pinned to the value that caused the finding, so once that value is
    /// rotated the record is dead weight. Without this, every dismiss-then-rotate cycle
    /// would leave a permanent orphan in the vault.
    private func pruneStaleIgnores(on item: SecretItemEntity) {
        guard !item.ignoredHealthIssues.isEmpty else { return }
        let liveDigests = Set(
            item.fields
                .filter(\.isSensitive)
                .map { "\($0.fieldKey)|\(Self.digest($0.plainValue))" }
        )
        item.ignoredHealthIssues.removeAll { ignored in
            // An item-level dismissal is measured against the item's own timeline, and this
            // save just moved it — so the dismissal is out of date by definition.
            guard ignored.kindRawValue != VaultHealthFinding.Kind.stale.rawValue else { return true }
            return !liveDigests.contains("\(ignored.fieldKey)|\(ignored.valueDigest)")
        }
    }

    static func digest(_ value: String) -> String {
        Data(SHA256.hash(data: Data(value.utf8))).base64EncodedString()
    }

    // MARK: - Audit history

    /// The subset of item state the audit trail compares. Captured before the entity is
    /// mutated, since the entity is a reference type and the draft overwrites it in place.
    private struct ItemStateSnapshot {
        let title: String
        let notes: String
        let type: SecretItemType
        let environment: EnvironmentValue
        let workspaceID: UUID?
        let templateID: UUID?
        let tags: [String]
        let linkedFile: LinkedFileReference?
        let isFavorite: Bool
        let isArchived: Bool
        let fields: [String: FieldState]

        struct FieldState {
            let label: String
            let value: String
            let kind: FieldKind
            let isSensitive: Bool
            let isCopyable: Bool
            let isMasked: Bool
            let sortOrder: Int
        }

        init(item: SecretItemEntity) {
            title = item.title
            notes = item.notes
            type = item.type
            environment = item.environmentValue
            workspaceID = item.workspace?.id
            templateID = item.template?.id
            tags = item.tags
            linkedFile = item.linkedFile
            isFavorite = item.isFavorite
            isArchived = item.isArchived
            fields = Dictionary(
                item.fields.map {
                    ($0.fieldKey, FieldState(
                        label: $0.labelSnapshot,
                        value: $0.plainValue,
                        kind: $0.kind,
                        isSensitive: $0.isSensitive,
                        isCopyable: $0.isCopyable,
                        isMasked: $0.isMasked,
                        sortOrder: $0.sortOrder
                    ))
                },
                uniquingKeysWith: { first, _ in first }
            )
        }
    }

    /// Appends entries describing how `item` just changed.
    ///
    /// Entries record the *kind* of change and, at most, a field label. Values — especially
    /// sensitive ones — are compared here but never written into the trail.
    private func recordHistory(for item: SecretItemEntity, previous: ItemStateSnapshot?) {
        let entries = Self.historyEntries(for: item, previous: previous)
        guard !entries.isEmpty else { return }
        item.changeHistory = Array((entries + item.changeHistory).prefix(Self.historyLimit))
    }

    /// Bounded per item so a heavily edited secret can't grow the vault without limit.
    static let historyLimit = 60

    private static func historyEntries(for item: SecretItemEntity, previous: ItemStateSnapshot?) -> [SecretItemChangeEntry] {
        guard let previous else { return [SecretItemChangeEntry(kind: .created)] }
        var entries: [SecretItemChangeEntry] = []

        // Keep the audit trail aligned with every item detail that can bump `updatedAt`.
        // Values have their own redacted entries below; labels and behavioural field flags do
        // not, so represent those as a generic details update without recording secret data.
        let fieldMetadataChanged = item.fields.contains { field in
            guard let old = previous.fields[field.fieldKey] else { return false }
            return old.label != field.labelSnapshot
                || old.kind != field.kind
                || old.isSensitive != field.isSensitive
                || old.isCopyable != field.isCopyable
                || old.isMasked != field.isMasked
                || old.sortOrder != field.sortOrder
        }
        if previous.title != item.title
            || previous.notes != item.notes
            || previous.templateID != item.template?.id
            || previous.tags != item.tags
            || previous.linkedFile != item.linkedFile
            || fieldMetadataChanged {
            entries.append(SecretItemChangeEntry(kind: .detailsUpdated))
        }
        if previous.type != item.type {
            entries.append(SecretItemChangeEntry(kind: .typeChanged, detail: item.type.title))
        }
        if previous.environment != item.environmentValue {
            entries.append(SecretItemChangeEntry(kind: .environmentChanged, detail: item.environmentValue.title))
        }
        if previous.workspaceID != item.workspace?.id {
            entries.append(SecretItemChangeEntry(kind: .workspaceChanged, detail: item.workspace?.name))
        }
        if previous.isFavorite != item.isFavorite {
            entries.append(SecretItemChangeEntry(kind: item.isFavorite ? .favoriteEnabled : .favoriteDisabled))
        }
        if previous.isArchived != item.isArchived {
            entries.append(SecretItemChangeEntry(kind: item.isArchived ? .archived : .restored))
        }

        let currentKeys = Set(item.fields.map(\.fieldKey))
        for (key, old) in previous.fields where !currentKeys.contains(key) {
            entries.append(SecretItemChangeEntry(kind: .fieldRemoved, detail: old.label))
        }

        for field in item.fields {
            guard let old = previous.fields[field.fieldKey] else {
                entries.append(SecretItemChangeEntry(kind: .fieldAdded, detail: field.labelSnapshot))
                continue
            }
            guard old.value != field.plainValue else { continue }
            if field.isSensitive || old.isSensitive {
                let isPassword = SecretFieldClassification.isPasswordLike(key: field.fieldKey, label: field.labelSnapshot)
                entries.append(
                    SecretItemChangeEntry(
                        kind: isPassword ? .passwordRotated : .sensitiveValueChanged,
                        detail: field.labelSnapshot
                    )
                )
            } else {
                entries.append(SecretItemChangeEntry(kind: .fieldValueChanged, detail: field.labelSnapshot))
            }
        }

        return entries
    }

    // MARK: - Draft normalization

    /// Cleans a draft at the repository boundary so the same hygiene applies no matter which
    /// caller produced it — editor, bulk edit, `.env` import or a restored backup.
    ///
    /// Field *values* are deliberately left untouched: trimming a password would silently
    /// corrupt a stored secret.
    static func normalized(_ draft: SecretItemDraft) -> SecretItemDraft {
        var draft = draft
        draft.title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        draft.notes = draft.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        draft.tags = normalizedTags(draft.tags)
        draft.environment = normalizedEnvironment(draft.environment)
        draft.fieldDrafts = draft.fieldDrafts.map { field in
            var field = field
            field.key = field.key.trimmingCharacters(in: .whitespacesAndNewlines)
            field.label = field.label.trimmingCharacters(in: .whitespacesAndNewlines)
            return field
        }
        return draft
    }

    /// Tags are persisted as one comma-joined string, so a tag containing a comma would
    /// silently split into two on the next load. Commas are stripped rather than escaped.
    static func normalizedTags(_ tags: [String]) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for tag in tags {
            let cleaned = tag
                .replacingOccurrences(of: ",", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty else { continue }
            let fingerprint = cleaned.lowercased()
            guard seen.insert(fingerprint).inserted else { continue }
            result.append(cleaned)
        }
        return result
    }

    private static func normalizedEnvironment(_ environment: EnvironmentValue) -> EnvironmentValue {
        guard environment.kind == .custom else { return environment }
        let trimmed = (environment.customName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? .preset(.dev) : .custom(trimmed)
    }

    /// Stamps "last used" and schedules a coalesced write.
    ///
    /// This runs on every row selection. Writing synchronously meant re-encrypting and
    /// rewriting the entire vault once per click — and once per keypress when walking the
    /// list with ⌥↓. The timestamp is worth keeping, but not at that price.
    func recordItemAccess(_ item: SecretItemEntity) throws {
        try store.requireUnlocked()
        guard let storedItem = store.items.first(where: { $0.id == item.id }) else { return }
        storedItem.lastAccessedAt = .now
        store.persistSoon()
    }

    /// "X Copy", then "X Copy 2", "X Copy 3"… Duplicating twice used to produce two items
    /// with byte-identical titles.
    func uniqueDuplicateTitle(basedOn title: String) -> String {
        let existing = Set(store.items.map(\.title))
        let base = "\(title) Copy"
        guard existing.contains(base) else { return base }
        var suffix = 2
        while existing.contains("\(base) \(suffix)") { suffix += 1 }
        return "\(base) \(suffix)"
    }

    @discardableResult
    func duplicateItem(_ item: SecretItemEntity) throws -> SecretItemEntity {
        let resolved = try resolveFields(for: item)
        let duplicateDraft = SecretItemDraft(
            id: nil,
            title: uniqueDuplicateTitle(basedOn: item.title),
            type: item.type,
            workspaceID: item.workspace?.id,
            environment: item.environmentValue,
            notes: item.notes,
            tags: item.tags,
            isFavorite: false,
            fieldDrafts: resolved.enumerated().map { index, field in
                FieldDraft(
                    key: field.key,
                    label: field.label,
                    value: field.value,
                    kind: field.kind,
                    isSensitive: field.isSensitive,
                    isCopyable: field.isCopyable,
                    isMasked: field.isMasked,
                    sortOrder: index
                )
            },
            templateID: item.template?.id,
            // A duplicate is deliberately not linked to the same file, but it is still the same
            // `.env`: it should copy out looking like one.
            envLayout: item.envLayout
        )
        return try saveItem(duplicateDraft)
    }

    func deleteItem(_ item: SecretItemEntity) throws {
        try store.performTransaction {
            try deleteItemMutation(item)
        }
    }

    private func deleteItemMutation(_ item: SecretItemEntity) throws {
        try store.requireUnlocked()
        guard let storedItem = store.items.first(where: { $0.id == item.id }) else { return }
        for field in storedItem.fields {
            Self.securelyClear(field: field)
            field.item = nil
        }
        storedItem.fields = []
        storedItem.workspace = nil
        storedItem.template = nil
        store.items.removeAll { $0 === storedItem }
        rebuildWorkspaceItems()
        try store.persist()
    }

    /// Renames duplicate storage keys (`host`, `host_2`, …) so every field survives the save
    /// instead of one silently overwriting the other.
    static func withUniqueKeys(_ drafts: [FieldDraft]) -> [FieldDraft] {
        var seen: Set<String> = []
        var seenIDs: Set<UUID> = []
        return drafts.map { draft in
            var normalized = draft
            if !seenIDs.insert(normalized.id).inserted {
                normalized.id = UUID()
                seenIDs.insert(normalized.id)
            }
            let base = draft.key.trimmingCharacters(in: .whitespacesAndNewlines)
            var candidate = base.isEmpty ? "field" : base
            if seen.contains(candidate) {
                var suffix = 2
                while seen.contains("\(candidate)_\(suffix)") { suffix += 1 }
                candidate = "\(candidate)_\(suffix)"
            }
            seen.insert(candidate)
            normalized.key = candidate
            return normalized
        }
    }

    private func workspace(for id: UUID?) -> WorkspaceEntity? {
        guard let id else { return nil }
        return store.workspaces.first(where: { $0.id == id })
    }

    private func template(for id: UUID?) -> SecretFieldTemplateEntity? {
        guard let id else { return nil }
        return store.allTemplates.first(where: { $0.id == id })
    }

    private func rebuildWorkspaceItems() {
        for workspace in store.workspaces {
            workspace.items = store.items
                .filter { $0.workspace?.id == workspace.id }
                .sorted { $0.updatedAt > $1.updatedAt }
        }
    }
}

enum BuiltInTemplates {
    @MainActor
    static func entities() -> [SecretFieldTemplateEntity] {
        defaultTemplates.map(makeTemplateEntity)
    }

    static let defaultTemplates: [TemplateDraft] = [
        TemplateDraft(
            id: UUID(uuidString: "F7A69C58-7590-4B2F-B80A-6D8516F42D01"),
            name: "Generic Secret",
            itemType: .generic,
            fieldDefinitions: [
                .init(id: UUID(uuidString: "F7A69C58-7590-4B2F-B80A-6D8516F42001")!, key: "secret", label: "Secret", kind: .secret, isSensitive: true, isCopyable: true, isMaskedByDefault: true, sortOrder: 0)
            ]
        ),
        TemplateDraft(
            id: UUID(uuidString: "6BFB66E4-6AA7-49DA-A935-F7967C42D002"),
            name: "Database",
            itemType: .database,
            fieldDefinitions: [
                .init(id: UUID(uuidString: "6BFB66E4-6AA7-49DA-A935-F7967C420020")!, key: "db_engine", label: "Database type", kind: .text, isSensitive: false, isCopyable: true, isMaskedByDefault: false, sortOrder: 0),
                .init(id: UUID(uuidString: "6BFB66E4-6AA7-49DA-A935-F7967C420021")!, key: "host", label: "Host", kind: .text, isSensitive: false, isCopyable: true, isMaskedByDefault: false, sortOrder: 1),
                .init(id: UUID(uuidString: "6BFB66E4-6AA7-49DA-A935-F7967C420022")!, key: "port", label: "Port", kind: .number, isSensitive: false, isCopyable: true, isMaskedByDefault: false, sortOrder: 2),
                .init(id: UUID(uuidString: "6BFB66E4-6AA7-49DA-A935-F7967C420023")!, key: "database", label: "Database", kind: .text, isSensitive: false, isCopyable: true, isMaskedByDefault: false, sortOrder: 3),
                .init(id: UUID(uuidString: "6BFB66E4-6AA7-49DA-A935-F7967C420024")!, key: "username", label: "Username", kind: .text, isSensitive: false, isCopyable: true, isMaskedByDefault: false, sortOrder: 4),
                .init(id: UUID(uuidString: "6BFB66E4-6AA7-49DA-A935-F7967C420025")!, key: "password", label: "Password", kind: .secret, isSensitive: true, isCopyable: true, isMaskedByDefault: true, sortOrder: 5)
            ]
        ),
        TemplateDraft(
            id: UUID(uuidString: "26B5E81A-4C9F-488C-B4A9-80E648D1F003"),
            name: "MinIO / S3",
            itemType: .s3Compatible,
            fieldDefinitions: [
                .init(id: UUID(uuidString: "26B5E81A-4C9F-488C-B4A9-80E648D1F031")!, key: "endpoint", label: "Endpoint", kind: .url, isSensitive: false, isCopyable: true, isMaskedByDefault: false, sortOrder: 0),
                .init(id: UUID(uuidString: "26B5E81A-4C9F-488C-B4A9-80E648D1F032")!, key: "bucket", label: "Bucket", kind: .text, isSensitive: false, isCopyable: true, isMaskedByDefault: false, sortOrder: 1),
                .init(id: UUID(uuidString: "26B5E81A-4C9F-488C-B4A9-80E648D1F033")!, key: "region", label: "Region", kind: .text, isSensitive: false, isCopyable: true, isMaskedByDefault: false, sortOrder: 2),
                .init(id: UUID(uuidString: "26B5E81A-4C9F-488C-B4A9-80E648D1F034")!, key: "accessKey", label: "Access Key", kind: .text, isSensitive: true, isCopyable: true, isMaskedByDefault: true, sortOrder: 3),
                .init(id: UUID(uuidString: "26B5E81A-4C9F-488C-B4A9-80E648D1F035")!, key: "secretKey", label: "Secret Key", kind: .secret, isSensitive: true, isCopyable: true, isMaskedByDefault: true, sortOrder: 4)
            ]
        ),
        TemplateDraft(
            id: UUID(uuidString: "F6ACB57B-4B71-4B8A-B9B5-9C2771775004"),
            name: "API Credential",
            itemType: .apiCredential,
            fieldDefinitions: [
                .init(id: UUID(uuidString: "F6ACB57B-4B71-4B8A-B9B5-9C2771775041")!, key: "baseUrl", label: "Base URL", kind: .url, isSensitive: false, isCopyable: true, isMaskedByDefault: false, sortOrder: 0),
                .init(id: UUID(uuidString: "F6ACB57B-4B71-4B8A-B9B5-9C2771775042")!, key: "apiKey", label: "API Key", kind: .secret, isSensitive: true, isCopyable: true, isMaskedByDefault: true, sortOrder: 1),
                .init(id: UUID(uuidString: "F6ACB57B-4B71-4B8A-B9B5-9C2771775043")!, key: "clientId", label: "Client ID", kind: .text, isSensitive: false, isCopyable: true, isMaskedByDefault: false, sortOrder: 2),
                .init(id: UUID(uuidString: "F6ACB57B-4B71-4B8A-B9B5-9C2771775044")!, key: "clientSecret", label: "Client Secret", kind: .secret, isSensitive: true, isCopyable: true, isMaskedByDefault: true, sortOrder: 3)
            ]
        ),
        TemplateDraft(
            id: UUID(uuidString: "8E5DA7EC-75D1-4CB2-B684-E17E11261005"),
            name: ".env File",
            itemType: .envGroup,
            fieldDefinitions: [
                .init(id: UUID(uuidString: "8E5DA7EC-75D1-4CB2-B684-E17E11261051")!, key: "env", label: ".env", kind: .multiline, isSensitive: true, isCopyable: true, isMaskedByDefault: true, sortOrder: 0)
            ]
        ),
        TemplateDraft(
            id: UUID(uuidString: "56EFB0B7-7B13-4354-BB3D-4A9269416006"),
            name: "Website / Service",
            itemType: .websiteService,
            fieldDefinitions: [
                .init(id: UUID(uuidString: "56EFB0B7-7B13-4354-BB3D-4A9269416061")!, key: "url", label: "URL", kind: .url, isSensitive: false, isCopyable: true, isMaskedByDefault: false, sortOrder: 0),
                .init(id: UUID(uuidString: "56EFB0B7-7B13-4354-BB3D-4A9269416062")!, key: "username", label: "Username", kind: .text, isSensitive: false, isCopyable: true, isMaskedByDefault: false, sortOrder: 1),
                .init(id: UUID(uuidString: "56EFB0B7-7B13-4354-BB3D-4A9269416063")!, key: "password", label: "Password", kind: .secret, isSensitive: true, isCopyable: true, isMaskedByDefault: true, sortOrder: 2)
            ]
        ),
        TemplateDraft(
            id: UUID(uuidString: "62BFC934-6D62-4990-8A5A-A2DF2D5D1007"),
            name: "Server / SSH",
            itemType: .serverSSH,
            fieldDefinitions: [
                .init(id: UUID(uuidString: "62BFC934-6D62-4990-8A5A-A2DF2D5D1071")!, key: "host", label: "Host", kind: .text, isSensitive: false, isCopyable: true, isMaskedByDefault: false, sortOrder: 0),
                .init(id: UUID(uuidString: "62BFC934-6D62-4990-8A5A-A2DF2D5D1072")!, key: "port", label: "Port", kind: .number, isSensitive: false, isCopyable: true, isMaskedByDefault: false, sortOrder: 1),
                .init(id: UUID(uuidString: "62BFC934-6D62-4990-8A5A-A2DF2D5D1073")!, key: "username", label: "Username", kind: .text, isSensitive: false, isCopyable: true, isMaskedByDefault: false, sortOrder: 2),
                .init(id: UUID(uuidString: "62BFC934-6D62-4990-8A5A-A2DF2D5D1074")!, key: "password", label: "Password", kind: .secret, isSensitive: true, isCopyable: true, isMaskedByDefault: true, sortOrder: 3),
                .init(id: UUID(uuidString: "62BFC934-6D62-4990-8A5A-A2DF2D5D1075")!, key: "privateKey", label: "Private Key", kind: .multiline, isSensitive: true, isCopyable: true, isMaskedByDefault: true, sortOrder: 4)
            ]
        ),
        TemplateDraft(
            id: UUID(uuidString: "D2E4F6A8-B0C1-2345-CDEF-6789ABCDEF01"),
            name: "Saved Command",
            itemType: .savedCommand,
            fieldDefinitions: [
                .init(id: UUID(uuidString: "D2E4F6A8-B0C1-2345-CDEF-6789ABCDEF02")!, key: "command_kind", label: "Command type", kind: .text, isSensitive: false, isCopyable: true, isMaskedByDefault: false, sortOrder: 0),
                .init(id: UUID(uuidString: "D2E4F6A8-B0C1-2345-CDEF-6789ABCDEF03")!, key: "execution_context", label: "Where to run", kind: .text, isSensitive: false, isCopyable: true, isMaskedByDefault: false, sortOrder: 1),
                .init(id: UUID(uuidString: "D2E4F6A8-B0C1-2345-CDEF-6789ABCDEF04")!, key: "working_directory", label: "Working directory", kind: .text, isSensitive: false, isCopyable: true, isMaskedByDefault: false, sortOrder: 2),
                .init(id: UUID(uuidString: "D2E4F6A8-B0C1-2345-CDEF-6789ABCDEF05")!, key: "command_body", label: "Command or query", kind: .multiline, isSensitive: false, isCopyable: true, isMaskedByDefault: false, sortOrder: 3),
                .init(id: UUID(uuidString: "D2E4F6A8-B0C1-2345-CDEF-6789ABCDEF06")!, key: "short_description", label: "What it does", kind: .text, isSensitive: false, isCopyable: true, isMaskedByDefault: false, sortOrder: 4)
            ]
        )
    ]

    @MainActor
    private static func makeTemplateEntity(from draft: TemplateDraft) -> SecretFieldTemplateEntity {
        let template = SecretFieldTemplateEntity(
            id: draft.id ?? UUID(),
            itemType: draft.itemType,
            name: draft.name,
            isBuiltIn: true
        )
        template.fieldDefinitions = draft.fieldDefinitions.map {
            SecretFieldDefinitionEntity(
                id: $0.id,
                key: $0.key,
                label: $0.label,
                kind: $0.kind,
                isSensitive: $0.isSensitive,
                isCopyable: $0.isCopyable,
                isMaskedByDefault: $0.isMaskedByDefault,
                sortOrder: $0.sortOrder,
                template: template
            )
        }.sorted {
            if $0.sortOrder != $1.sortOrder { return $0.sortOrder < $1.sortOrder }
            return $0.id.uuidString < $1.id.uuidString
        }
        return template
    }
}
