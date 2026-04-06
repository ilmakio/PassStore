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
            return $0.updatedAt > $1.updatedAt
        }
        return includeArchived ? all : all.filter { !$0.isArchived }
    }

    @discardableResult
    func saveWorkspace(_ draft: WorkspaceDraft) throws -> WorkspaceEntity {
        try store.requireUnlocked()
        let workspace: WorkspaceEntity
        if let id = draft.id,
           let existing = store.workspaces.first(where: { $0.id == id }) {
            workspace = existing
        } else {
            workspace = WorkspaceEntity(name: draft.name, icon: draft.icon, colorHex: draft.colorHex, notes: draft.notes, sortOrder: store.workspaces.count)
            store.workspaces.append(workspace)
        }
        workspace.name = draft.name
        workspace.icon = draft.icon
        workspace.colorHex = draft.colorHex
        workspace.notes = draft.notes
        workspace.updatedAt = .now
        try store.persist()
        return workspace
    }

    func reorderWorkspaces(_ ids: [UUID]) throws {
        try store.requireUnlocked()
        for (index, id) in ids.enumerated() {
            store.workspaces.first(where: { $0.id == id })?.sortOrder = index
        }
        try store.persist()
    }

    func deleteWorkspace(_ workspace: WorkspaceEntity) throws {
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
        try store.requireUnlocked()
        let existingCustom = draft.id.flatMap { id in store.customTemplates.first(where: { $0.id == id }) }
        let template = existingCustom ?? SecretFieldTemplateEntity(
            id: draft.id ?? UUID(),
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

        let existingDefinitions = Dictionary(uniqueKeysWithValues: template.fieldDefinitions.map { ($0.id, $0) })
        template.fieldDefinitions = draft.fieldDefinitions.map { fieldDraft in
            let definition = existingDefinitions[fieldDraft.id] ?? SecretFieldDefinitionEntity(
                id: fieldDraft.id,
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
        }.sorted { $0.sortOrder < $1.sortOrder }

        try store.persist()
        return template
    }

    func deleteTemplate(_ template: SecretFieldTemplateEntity) throws {
        guard !template.isBuiltIn else { return }
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
        return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
    }
}

@MainActor
final class SecretItemRepository: SecretItemRepositoryProtocol {
    private let store: VaultMemoryStore

    init(store: VaultMemoryStore) {
        self.store = store
    }

    func fetchAll(includeArchived: Bool = false) throws -> [SecretItemEntity] {
        let items = store.items.sorted { $0.updatedAt > $1.updatedAt }
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
                sortOrder: $0.sortOrder
            )
        }.sorted { $0.sortOrder < $1.sortOrder }
    }

    @discardableResult
    func saveItem(_ draft: SecretItemDraft) throws -> SecretItemEntity {
        try store.requireUnlocked()
        let item: SecretItemEntity
        if let id = draft.id,
           let existing = store.items.first(where: { $0.id == id }) {
            item = existing
        } else {
            item = SecretItemEntity(title: draft.title, type: draft.type, environment: draft.environment)
            store.items.append(item)
        }

        item.title = draft.title
        item.type = draft.type
        item.environmentValue = draft.environment
        item.notes = draft.notes
        item.tags = draft.tags
        item.isFavorite = draft.isFavorite
        item.isArchived = draft.isArchived
        item.updatedAt = .now
        item.workspace = workspace(for: draft.workspaceID)
        item.template = template(for: draft.templateID)

        let existingFields = Dictionary(uniqueKeysWithValues: item.fields.map { ($0.fieldKey, $0) })
        item.fields = draft.fieldDrafts.map { fieldDraft in
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
            field.fieldKey = fieldDraft.key
            field.labelSnapshot = fieldDraft.label
            field.kind = fieldDraft.kind
            field.isSensitive = fieldDraft.isSensitive
            field.isCopyable = fieldDraft.isCopyable
            field.isMasked = fieldDraft.isMasked
            field.sortOrder = fieldDraft.sortOrder
            field.plainValue = fieldDraft.value
            field.item = item
            return field
        }.sorted { $0.sortOrder < $1.sortOrder }

        rebuildWorkspaceItems()
        try store.persist()
        return item
    }

    func recordItemAccess(_ item: SecretItemEntity) throws {
        try store.requireUnlocked()
        guard store.items.contains(where: { $0.id == item.id }) else { return }
        item.lastAccessedAt = .now
        try store.persist()
    }

    @discardableResult
    func duplicateItem(_ item: SecretItemEntity) throws -> SecretItemEntity {
        let resolved = try resolveFields(for: item)
        let duplicateDraft = SecretItemDraft(
            id: nil,
            title: "\(item.title) Copy",
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
            templateID: item.template?.id
        )
        return try saveItem(duplicateDraft)
    }

    func deleteItem(_ item: SecretItemEntity) throws {
        try store.requireUnlocked()
        store.items.removeAll { $0.id == item.id }
        rebuildWorkspaceItems()
        try store.persist()
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
        }.sorted { $0.sortOrder < $1.sortOrder }
        return template
    }
}
