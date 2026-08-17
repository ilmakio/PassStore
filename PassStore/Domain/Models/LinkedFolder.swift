import Foundation

/// A folder on disk a workspace is associated with — in practice the repository the project
/// lives in.
///
/// A folder bookmark is a broader grant than the per-file bookmarks the rest of the app uses:
/// it reaches everything inside that directory. So it is only ever created from a folder the
/// owner picked explicitly, it is stored per workspace, it is revocable in one click, and
/// nothing ever walks it on its own — discovery runs when it is asked to and not at unlock.
nonisolated struct LinkedFolderReference: Codable, Hashable, Sendable {
    /// Security-scoped bookmark. Nil when the reference came from a backup taken on another
    /// Mac, in which case the folder has to be picked again before anything can be read.
    var bookmark: Data?
    var displayPath: String
    /// When the folder was last scanned for `.env` files. Nil means "never".
    var lastScannedAt: Date?

    init(bookmark: Data? = nil, displayPath: String, lastScannedAt: Date? = nil) {
        self.bookmark = bookmark
        self.displayPath = displayPath
        self.lastScannedAt = lastScannedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        bookmark = try container.decodeIfPresent(Data.self, forKey: .bookmark)
        displayPath = try container.decodeIfPresent(String.self, forKey: .displayPath) ?? ""
        lastScannedAt = try container.decodeIfPresent(Date.self, forKey: .lastScannedAt)
    }

    var folderName: String {
        (displayPath as NSString).lastPathComponent
    }

    /// Path with the home directory abbreviated, which is what the UI should show.
    var abbreviatedPath: String {
        (displayPath as NSString).abbreviatingWithTildeInPath
    }
}

/// One `.env`-shaped file found inside a linked project folder.
///
/// Discovery reports names, not contents: nothing in here is read from a file's body, and no
/// file is opened until the owner has said which ones to import.
nonisolated struct DiscoveredEnvFile: Identifiable, Hashable, Sendable {
    let id: String
    let fileName: String
    /// Path relative to the linked folder, for telling `apps/api/.env` from `apps/web/.env`.
    let relativePath: String
    let byteCount: Int
    /// The environment the file name suggests. A suggestion the owner can change, never a
    /// decision: file naming conventions vary per project.
    let suggestedEnvironment: EnvironmentValue
    /// True for `.env.example` and friends — checked in on purpose, and not where secrets live.
    let isTemplate: Bool
    /// True when a secret in this vault already mirrors this exact path.
    let isAlreadyLinked: Bool

    init(
        fileName: String,
        relativePath: String,
        byteCount: Int,
        suggestedEnvironment: EnvironmentValue,
        isTemplate: Bool,
        isAlreadyLinked: Bool
    ) {
        self.id = relativePath
        self.fileName = fileName
        self.relativePath = relativePath
        self.byteCount = byteCount
        self.suggestedEnvironment = suggestedEnvironment
        self.isTemplate = isTemplate
        self.isAlreadyLinked = isAlreadyLinked
    }
}

/// What the discovery sheet is about to do with one found file.
struct EnvFileImportPlan: Identifiable {
    let file: DiscoveredEnvFile
    var isSelected: Bool
    var environment: EnvironmentValue
    /// Parse into one field per key, rather than keeping the file as a single blob.
    var parsesIntoFields: Bool

    var id: String { file.id }
}
