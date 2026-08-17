import Foundation

enum LinkedFolderError: LocalizedError {
    case noFolder
    case unresolvable
    case bookmarkCreationFailed
    case bookmarkRefreshFailed
    case notReadable

    var errorDescription: String? {
        switch self {
        case .noFolder:
            "This workspace is not linked to a folder."
        case .unresolvable:
            "The linked folder could not be found. It may have been moved or renamed — link it again to continue."
        case .bookmarkCreationFailed:
            "PassStore could not save durable permission for that folder. Choose it again."
        case .bookmarkRefreshFailed:
            "Permission for the linked folder expired and could not be renewed. Choose it again."
        case .notReadable:
            "The linked folder could not be read."
        }
    }
}

/// Maps a `.env` file name to the environment it is likely to hold.
///
/// Conventions vary per project, so every result is a suggestion the owner can override in the
/// import sheet. The rules only look at the file's *name*: a classifier that had to read the
/// file would mean opening every candidate before being asked to.
nonisolated enum EnvFileClassifier: Sendable {
    /// Suffixes that mark a checked-in example rather than a place secrets live.
    static let templateSuffixes = ["example", "sample", "template", "dist", "defaults"]

    /// Names that are `.env` files without following the `.env.<name>` shape.
    private static let baseNames = [".env", "env", ".environment"]

    static func isEnvFileName(_ name: String) -> Bool {
        let lowered = name.lowercased()
        if baseNames.contains(lowered) { return true }
        // ".env.production", ".env.local", and also "production.env".
        return lowered.hasPrefix(".env.") || lowered.hasSuffix(".env")
    }

    static func isTemplate(_ name: String) -> Bool {
        let components = name.lowercased().split(separator: ".").map(String.init)
        return components.contains { templateSuffixes.contains($0) }
    }

    /// The environment a file name suggests.
    ///
    /// A bare `.env` is treated as Local: whatever a project's deployment pipeline does with it,
    /// the copy sitting in a working directory is the one the owner runs against.
    static func environment(forFileName name: String) -> EnvironmentValue {
        let token = descriptiveToken(in: name)
        guard let token else { return .preset(.local) }

        switch token {
        case "local", "localhost":
            return .preset(.local)
        case "dev", "development", "develop":
            return .preset(.dev)
        case "staging", "stage", "preprod", "preproduction", "uat":
            return .preset(.staging)
        case "prod", "production", "live":
            return .preset(.prod)
        default:
            return .custom(displayName(for: token))
        }
    }

    /// The part of the name that describes an environment: the last component that is neither
    /// "env" nor a template marker nor a bare "local" override.
    ///
    /// `.env.production.local` is a local override *of production*, so production is what
    /// matters; `.env.local` has nothing but the override, so the override is the answer.
    private static func descriptiveToken(in name: String) -> String? {
        var components = name.lowercased()
            .split(separator: ".", omittingEmptySubsequences: true)
            .map(String.init)
            .filter { $0 != "env" && !templateSuffixes.contains($0) }
        if components.count > 1, components.last == "local" {
            components.removeLast()
        }
        return components.last
    }

    private static func displayName(for token: String) -> String {
        token.prefix(1).uppercased() + token.dropFirst()
    }
}

/// Finds the `.env` files inside a folder a workspace is linked to.
///
/// Three rules make this safe enough to hand a whole repository to:
/// nothing is opened (names and sizes only), nothing is followed (symlinks are skipped rather
/// than resolved, so a link cannot walk out of the folder), and nothing is unbounded (depth,
/// count and the usual dependency directories are all capped or excluded).
nonisolated struct EnvFileDiscoveryService: Sendable {
    /// How far below the linked folder to look. Enough for `apps/api/.env` in a monorepo,
    /// not enough to crawl a home directory someone linked by mistake.
    static let maximumDepth = 4
    static let maximumResults = 60
    /// Directories that never hold a project's own secrets and always hold thousands of files.
    static let excludedDirectoryNames: Set<String> = [
        ".git", ".hg", ".svn", "node_modules", "vendor", "Pods", "Carthage",
        ".build", ".swiftpm", "DerivedData", "build", "dist", ".next", ".nuxt",
        ".venv", "venv", "__pycache__", ".gradle", "target", ".terraform",
        ".cache", ".turbo", ".yarn", "bower_components", ".tox", ".mypy_cache"
    ]

    /// Creates the durable, security-scoped reference to a folder the owner picked.
    func makeLink(to url: URL) throws -> LinkedFolderReference {
        let gotAccess = url.startAccessingSecurityScopedResource()
        defer { if gotAccess { url.stopAccessingSecurityScopedResource() } }
        do {
            let bookmark = try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            return LinkedFolderReference(bookmark: bookmark, displayPath: url.path)
        } catch {
            throw LinkedFolderError.bookmarkCreationFailed
        }
    }

    struct Resolution: Sendable {
        let url: URL
        let refreshedBookmark: Data?
    }

    /// Resolves the bookmark, renewing it if the folder moved.
    ///
    /// `displayPath` is presentation metadata, never authority: a restored or hand-edited backup
    /// must not gain access to a directory merely by naming one.
    func resolve(_ folder: LinkedFolderReference) throws -> Resolution {
        guard let bookmark = folder.bookmark else {
            throw folder.displayPath.isEmpty ? LinkedFolderError.noFolder : LinkedFolderError.unresolvable
        }
        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: bookmark,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else {
            throw LinkedFolderError.unresolvable
        }
        guard isStale else { return Resolution(url: url, refreshedBookmark: nil) }

        let gotAccess = url.startAccessingSecurityScopedResource()
        defer { if gotAccess { url.stopAccessingSecurityScopedResource() } }
        do {
            let refreshed = try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            return Resolution(url: url, refreshedBookmark: refreshed)
        } catch {
            throw LinkedFolderError.bookmarkRefreshFailed
        }
    }

    struct DiscoveryResult: Sendable {
        let files: [DiscoveredEnvFile]
        let refreshedBookmark: Data?
        let resolvedPath: String
        /// True when the walk stopped at `maximumResults`, so the UI can say so rather than
        /// implying the list is everything.
        let didReachLimit: Bool
    }

    /// Walks the folder and reports the `.env` files in it.
    ///
    /// `alreadyLinkedPaths` are absolute paths the vault already mirrors, so the sheet can mark
    /// them instead of offering to import the same file twice.
    func discover(
        in folder: LinkedFolderReference,
        alreadyLinkedPaths: Set<String>
    ) throws -> DiscoveryResult {
        let resolution = try resolve(folder)
        let gotAccess = resolution.url.startAccessingSecurityScopedResource()
        defer { if gotAccess { resolution.url.stopAccessingSecurityScopedResource() } }
        let walk = walkForEnvFiles(in: resolution.url, alreadyLinkedPaths: alreadyLinkedPaths)

        return DiscoveryResult(
            files: walk.files,
            refreshedBookmark: resolution.refreshedBookmark,
            resolvedPath: resolution.url.path,
            didReachLimit: walk.didReachLimit
        )
    }

    /// The walk itself, on a directory that is already reachable.
    ///
    /// Split out from `discover(in:alreadyLinkedPaths:)` so the rules — depth, exclusions,
    /// symlinks, the cap — can be tested against a real directory tree without a
    /// security-scoped bookmark, which only a user's own folder pick can produce.
    func walkForEnvFiles(
        in directory: URL,
        alreadyLinkedPaths: Set<String>
    ) -> (files: [DiscoveredEnvFile], didReachLimit: Bool) {
        let root = directory.resolvingSymlinksInPath()
        let keys: [URLResourceKey] = [
            .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .nameKey
        ]
        // Walked from the resolved root, not from what was handed in: a folder that is itself a
        // symlink — `~/code` pointing at a volume — makes the enumerator yield nothing at all,
        // and the walk would report an empty project rather than the files in it.
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            // Hidden files are the whole point: `.env` is hidden. Packages are not walked into,
            // and errors on one entry must not abort the walk.
            options: [.skipsPackageDescendants],
            errorHandler: { _, _ in true }
        ) else {
            return ([], false)
        }

        let rootDepth = root.standardizedFileURL.pathComponents.count
        var files: [DiscoveredEnvFile] = []
        var didReachLimit = false

        for case let url as URL in enumerator {
            if files.count >= Self.maximumResults {
                didReachLimit = true
                break
            }
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            let name = values.name ?? url.lastPathComponent

            // Symlinks are skipped, not resolved: following one is how a walk bounded to a
            // folder ends up reading something outside it.
            if values.isSymbolicLink == true {
                if values.isDirectory == true { enumerator.skipDescendants() }
                continue
            }

            if values.isDirectory == true {
                let depth = url.standardizedFileURL.pathComponents.count - rootDepth
                if depth >= Self.maximumDepth || Self.excludedDirectoryNames.contains(name) {
                    enumerator.skipDescendants()
                }
                continue
            }

            guard values.isRegularFile == true, EnvFileClassifier.isEnvFileName(name) else { continue }
            let byteCount = values.fileSize ?? 0
            guard byteCount <= LinkedFileService.maximumReadableFileSize else { continue }

            files.append(
                DiscoveredEnvFile(
                    fileName: name,
                    relativePath: Self.relativePath(of: url, from: root),
                    byteCount: byteCount,
                    suggestedEnvironment: EnvFileClassifier.environment(forFileName: name),
                    isTemplate: EnvFileClassifier.isTemplate(name),
                    isAlreadyLinked: alreadyLinkedPaths.contains(url.resolvingSymlinksInPath().path)
                )
            )
        }

        return (files.sorted(by: Self.presentationOrder), didReachLimit)
    }

    /// A discovered file, read and given a durable reference of its own.
    nonisolated struct PreparedEnvFile: Sendable {
        let fileName: String
        let contents: String
        /// A per-file security-scoped bookmark, so the resulting secret keeps working after the
        /// folder is unlinked — and so the existing linked-file machinery needs no folder at all.
        let fileLink: LinkedFileReference
    }

    /// Reads one discovered file and mints a per-file bookmark for it.
    ///
    /// Both happen inside a single window where the folder's security scope is held open, which
    /// is the only time a file inside it is reachable. This is also the first moment any file
    /// body is read: discovery itself only ever looked at names.
    func prepare(
        relativePath: String,
        in folder: LinkedFolderReference,
        parsedIntoFields: Bool
    ) throws -> PreparedEnvFile {
        let resolution = try resolve(folder)
        let gotAccess = resolution.url.startAccessingSecurityScopedResource()
        defer { if gotAccess { resolution.url.stopAccessingSecurityScopedResource() } }

        let url = try Self.fileURL(forRelativePath: relativePath, inResolvedFolder: resolution.url)
        let contents = try LinkedFileService.readPickedFile(at: url)
        // Not `try?`. A file whose bookmark could not be minted has no durable access, so the
        // secret made from it would be linked to a path it can never open again — and the import
        // would report it as in sync. Failing here loses one file from the batch and says so.
        let bookmark: Data
        do {
            bookmark = try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        } catch {
            throw LinkedFolderError.bookmarkCreationFailed
        }
        return PreparedEnvFile(
            fileName: url.lastPathComponent,
            contents: contents,
            fileLink: LinkedFileReference(
                bookmark: bookmark,
                displayPath: url.path,
                parsedIntoFields: parsedIntoFields
            )
        )
    }

    /// Turns a stored relative path back into a URL inside the linked folder.
    ///
    /// A relative path is data — it came out of a scan and rode along in the vault — so it does
    /// not get to point wherever it likes: no traversal components, and the result has to still
    /// be under the folder or it is refused.
    static func fileURL(forRelativePath relativePath: String, inResolvedFolder folder: URL) throws -> URL {
        let root = folder.resolvingSymlinksInPath().standardizedFileURL
        var candidate = root
        for component in relativePath.split(separator: "/").map(String.init) {
            guard component != "..", component != "." else { throw LinkedFolderError.unresolvable }
            candidate.appendPathComponent(component)
        }
        let standardized = candidate.standardizedFileURL
        guard standardized.path.hasPrefix(root.path + "/") else { throw LinkedFolderError.unresolvable }
        return standardized
    }

    private static func relativePath(of url: URL, from root: URL) -> String {
        let rootComponents = root.standardizedFileURL.pathComponents
        let components = url.standardizedFileURL.pathComponents
        guard components.count > rootComponents.count,
              Array(components.prefix(rootComponents.count)) == rootComponents else {
            return url.lastPathComponent
        }
        return components.dropFirst(rootComponents.count).joined(separator: "/")
    }

    /// Shallowest first, then by name: the repository's own `.env` before the ones belonging to
    /// packages inside it. Templates sink to the bottom — they are the least likely to be wanted.
    private static func presentationOrder(_ lhs: DiscoveredEnvFile, _ rhs: DiscoveredEnvFile) -> Bool {
        if lhs.isTemplate != rhs.isTemplate { return !lhs.isTemplate }
        let lhsDepth = lhs.relativePath.split(separator: "/").count
        let rhsDepth = rhs.relativePath.split(separator: "/").count
        if lhsDepth != rhsDepth { return lhsDepth < rhsDepth }
        return lhs.relativePath.localizedCaseInsensitiveCompare(rhs.relativePath) == .orderedAscending
    }
}
