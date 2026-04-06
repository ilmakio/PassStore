import Foundation

@MainActor
enum PreviewSeeder {
    static func seedIfNeeded(_ container: AppContainer) {
        guard (try? container.workspaceRepository.fetchAll(includeArchived: true).isEmpty) == true else { return }
        let backend = try? container.workspaceRepository.saveWorkspace(.init(name: "Pokéos API", icon: "server.rack", colorHex: "#4A7AFF", notes: "Core API services"))
        let infra = try? container.workspaceRepository.saveWorkspace(.init(name: "Personal Infra", icon: "terminal", colorHex: "#2AA198", notes: "VPS, object storage, edge tooling"))
        let templates = (try? container.templateRepository.fetchAll()) ?? []

        let databaseTemplate = templates.first(where: { $0.itemType == .database })
        let s3Template = templates.first(where: { $0.itemType == .s3Compatible })
        let apiTemplate = templates.first(where: { $0.itemType == .apiCredential })
        let envTemplate = templates.first(where: { $0.itemType == .envGroup })
        let sshTemplate = templates.first(where: { $0.itemType == .serverSSH })

        _ = try? container.itemRepository.saveItem(.init(
            title: "Primary Postgres",
            type: .database,
            workspaceID: backend?.id,
            environment: .preset(.prod),
            notes: "Read/write database used by the API.",
            tags: ["database", "postgres"],
            isFavorite: true,
            fieldDrafts: [
                .init(key: "db_engine", label: "Database type", value: "postgresql", kind: .text, isSensitive: false, sortOrder: 0),
                .init(key: "host", label: "Host", value: "db.pokeos.internal", kind: .text, isSensitive: false, sortOrder: 1),
                .init(key: "port", label: "Port", value: "5432", kind: .number, isSensitive: false, sortOrder: 2),
                .init(key: "database", label: "Database", value: "pokeos", kind: .text, isSensitive: false, sortOrder: 3),
                .init(key: "username", label: "Username", value: "app_user", kind: .text, isSensitive: false, sortOrder: 4),
                .init(key: "password", label: "Password", value: "super-secret-password", kind: .secret, isSensitive: true, isMasked: true, sortOrder: 5)
            ],
            templateID: databaseTemplate?.id
        ))
        _ = try? container.itemRepository.saveItem(.init(
            title: "Edge Storage",
            type: .s3Compatible,
            workspaceID: infra?.id,
            environment: .preset(.staging),
            notes: "MinIO bucket for staging builds.",
            tags: ["minio", "assets"],
            isFavorite: false,
            fieldDrafts: [
                .init(key: "endpoint", label: "Endpoint", value: "https://minio.example.dev", kind: .url, isSensitive: false, sortOrder: 0),
                .init(key: "bucket", label: "Bucket", value: "build-artifacts", kind: .text, isSensitive: false, sortOrder: 1),
                .init(key: "region", label: "Region", value: "eu-central-1", kind: .text, isSensitive: false, sortOrder: 2),
                .init(key: "accessKey", label: "Access Key", value: "MINIOACCESS", kind: .secret, isSensitive: true, isMasked: true, sortOrder: 3),
                .init(key: "secretKey", label: "Secret Key", value: "MINIOSECRET", kind: .secret, isSensitive: true, isMasked: true, sortOrder: 4)
            ],
            templateID: s3Template?.id
        ))
        _ = try? container.itemRepository.saveItem(.init(
            title: "NovaDesk API",
            type: .apiCredential,
            workspaceID: backend?.id,
            environment: .preset(.dev),
            notes: "Third-party API used by the internal dashboard.",
            tags: ["api", "partner"],
            isFavorite: true,
            fieldDrafts: [
                .init(key: "baseUrl", label: "Base URL", value: "https://api.novadesk.io", kind: .url, isSensitive: false, sortOrder: 0),
                .init(key: "apiKey", label: "API Key", value: "pk_live_123456", kind: .secret, isSensitive: true, isMasked: true, sortOrder: 1),
                .init(key: "clientId", label: "Client ID", value: "devvault", kind: .text, isSensitive: false, sortOrder: 2),
                .init(key: "clientSecret", label: "Client Secret", value: "client-secret", kind: .secret, isSensitive: true, isMasked: true, sortOrder: 3)
            ],
            templateID: apiTemplate?.id
        ))
        _ = try? container.itemRepository.saveItem(.init(
            title: "Frontend .env",
            type: .envGroup,
            workspaceID: backend?.id,
            environment: .preset(.local),
            notes: "Preview env values for local dev.",
            tags: ["env", "frontend"],
            isFavorite: false,
            fieldDrafts: [
                .init(key: "env", label: ".env", value: "NEXT_PUBLIC_API_URL=http://localhost:8080\nSESSION_SECRET=local-dev-secret", kind: .multiline, isSensitive: true, isMasked: true, sortOrder: 0)
            ],
            templateID: envTemplate?.id
        ))
        _ = try? container.itemRepository.saveItem(.init(
            title: "SSH Bastion",
            type: .serverSSH,
            workspaceID: infra?.id,
            environment: .custom("Ops"),
            notes: "Primary bastion host.",
            tags: ["ssh", "infra"],
            isFavorite: false,
            fieldDrafts: [
                .init(key: "host", label: "Host", value: "bastion.example.dev", kind: .text, isSensitive: false, sortOrder: 0),
                .init(key: "port", label: "Port", value: "22", kind: .number, isSensitive: false, sortOrder: 1),
                .init(key: "username", label: "Username", value: "deploy", kind: .text, isSensitive: false, sortOrder: 2),
                .init(key: "password", label: "Password", value: "optional-password", kind: .secret, isSensitive: true, isMasked: true, sortOrder: 3),
                .init(key: "privateKey", label: "Private Key", value: "-----BEGIN OPENSSH PRIVATE KEY-----", kind: .multiline, isSensitive: true, isMasked: true, sortOrder: 4)
            ],
            templateID: sshTemplate?.id
        ))
    }
}
