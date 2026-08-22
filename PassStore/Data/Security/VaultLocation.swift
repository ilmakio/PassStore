import Foundation
import Observation

/// Why a chosen vault folder could not be used this launch.
nonisolated enum VaultLocationProblem: Equatable, Sendable {
    /// The bookmark no longer resolves — the folder was renamed, deleted, or is on a volume
    /// that is not mounted.
    case unresolvable
    /// It resolved, but the folder is not there.
    case missing
    /// It resolved and exists, but cannot be written to.
    case notWritable

    var message: String {
        switch self {
        case .unresolvable:
            "PassStore could not find the folder your vault was moved to. It is using the default location until you point it at the folder again."
        case .missing:
            "The folder your vault was moved to is not there. If it is on a drive or a cloud folder, make sure it is available, then choose it again."
        case .notWritable:
            "The folder your vault was moved to cannot be written to. PassStore is using the default location until you choose another folder."
        }
    }
}

/// Where the encrypted vault package lives on disk.
///
/// PassStore does not sync anything, and it is not going to. But refusing to say *where* the file
/// goes turned that into "you cannot have this vault on two Macs at all", which is a different and
/// much worse promise. Pointing it at a folder somebody already syncs — iCloud Drive, Dropbox, a
/// git-crypt repository, a USB stick — costs nothing here and hands the choice back to its owner.
///
/// The safety half of that story is not in this file: see `VaultMetadata.writeCounter`, which is
/// what stops two Macs from silently overwriting one another.
@MainActor
@Observable
final class VaultLocationStore {
    private enum Keys {
        static let bookmark = "vault.location.bookmark"
        static let displayPath = "vault.location.displayPath"
        static let installID = "vault.install.identifier"
    }

    private let defaults: UserDefaults
    private let fileManager: FileManager
    private let bundleIdentifier: String

    // Security-scoped bookmarks are the only way a sandboxed app keeps access to a folder its
    // owner chose, and they are also untestable: they require a real user selection. Injecting the
    // four operations keeps the resolution logic — which folder wins, what happens when it is gone
    // — under test, which is the part that can lose somebody's vault.
    private let makeBookmark: (URL) throws -> Data
    private let resolveBookmark: (Data) throws -> (url: URL, isStale: Bool)
    private let beginAccess: (URL) -> Bool
    private let endAccess: (URL) -> Void

    /// The folder the app would use with no choice recorded.
    let defaultDirectory: URL

    /// The resolved chosen folder, when there is one and it works.
    private(set) var customDirectory: URL?

    /// Set when a folder was chosen but cannot be used right now, so the UI can explain itself
    /// rather than silently reverting to the default and looking like it lost the vault.
    private(set) var problem: VaultLocationProblem?

    /// Path of the chosen folder as last recorded, kept so the UI can name it even when the
    /// bookmark no longer resolves.
    private(set) var recordedDisplayPath: String?

    /// Held for as long as the app uses the folder. A sandboxed app loses access the moment this
    /// is balanced, and the vault is written for the whole session, so it is never balanced
    /// except when the folder changes.
    private var accessedURL: URL?

    init(
        defaults: UserDefaults = .standard,
        fileManager: FileManager = .default,
        bundleIdentifier: String = Bundle.main.bundleIdentifier ?? "app.makio.PassStore",
        defaultDirectory: URL? = nil,
        makeBookmark: @escaping (URL) throws -> Data = {
            try $0.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        },
        resolveBookmark: @escaping (Data) throws -> (url: URL, isStale: Bool) = { data in
            var isStale = false
            let url = try URL(
                resolvingBookmarkData: data,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            return (url, isStale)
        },
        beginAccess: @escaping (URL) -> Bool = { $0.startAccessingSecurityScopedResource() },
        endAccess: @escaping (URL) -> Void = { $0.stopAccessingSecurityScopedResource() }
    ) {
        self.defaults = defaults
        self.fileManager = fileManager
        self.bundleIdentifier = bundleIdentifier
        self.makeBookmark = makeBookmark
        self.resolveBookmark = resolveBookmark
        self.beginAccess = beginAccess
        self.endAccess = endAccess
        self.defaultDirectory = defaultDirectory
            ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                .appendingPathComponent(bundleIdentifier, isDirectory: true)
        self.recordedDisplayPath = defaults.string(forKey: Keys.displayPath)
        resolveStoredBookmark()
    }

    // MARK: - Current location

    /// The folder the vault store should use.
    var activeDirectory: URL { customDirectory ?? defaultDirectory }

    var isUsingCustomDirectory: Bool { customDirectory != nil }

    /// What to show in Settings: the resolved folder, or the recorded path when it is unavailable.
    var displayPath: String {
        let path = customDirectory?.path ?? recordedDisplayPath ?? defaultDirectory.path
        return (path as NSString).abbreviatingWithTildeInPath
    }

    /// Stable identifier for this install, minted on first use.
    ///
    /// Recorded in `UserDefaults` rather than derived from the hardware: it must survive a
    /// restart, and it must not be anything that identifies the machine to somebody reading the
    /// plaintext metadata file.
    var installIdentifier: String {
        if let existing = defaults.string(forKey: Keys.installID), !existing.isEmpty {
            return existing
        }
        let minted = UUID().uuidString
        defaults.set(minted, forKey: Keys.installID)
        return minted
    }

    // MARK: - Changing location

    /// Records a folder as the vault's home. Does not move anything — that is
    /// `VaultRelocationService`'s job, which calls this only once the copy is verified.
    func adoptCustomDirectory(_ url: URL) throws {
        let bookmark = try makeBookmark(url)
        releaseAccess()
        defaults.set(bookmark, forKey: Keys.bookmark)
        defaults.set(url.path, forKey: Keys.displayPath)
        recordedDisplayPath = url.path
        customDirectory = url
        problem = nil
        // Access for a directory the user just picked is already granted; take the scoped hold so
        // it survives the next launch through the bookmark.
        if beginAccess(url) {
            accessedURL = url
        }
    }

    /// Forgets the chosen folder and goes back to Application Support. Leaves files alone.
    func forgetCustomDirectory() {
        releaseAccess()
        defaults.removeObject(forKey: Keys.bookmark)
        defaults.removeObject(forKey: Keys.displayPath)
        recordedDisplayPath = nil
        customDirectory = nil
        problem = nil
    }

    /// Called when the app is going away. Not strictly required — the process is ending — but it
    /// keeps the scoped access balanced, which is what the API asks for.
    func releaseAccess() {
        if let accessedURL {
            endAccess(accessedURL)
            self.accessedURL = nil
        }
    }

    // MARK: - Resolution

    private func resolveStoredBookmark() {
        guard let bookmark = defaults.data(forKey: Keys.bookmark) else {
            customDirectory = nil
            problem = nil
            return
        }

        guard let resolved = try? resolveBookmark(bookmark) else {
            customDirectory = nil
            problem = .unresolvable
            return
        }
        let url = resolved.url
        let isStale = resolved.isStale

        guard beginAccess(url) else {
            customDirectory = nil
            problem = .unresolvable
            return
        }
        accessedURL = url

        // A folder inside a cloud provider can resolve while being absent locally, so existence
        // and writability are checked rather than assumed from a successful resolve.
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            releaseAccess()
            customDirectory = nil
            problem = .missing
            return
        }
        guard fileManager.isWritableFile(atPath: url.path) else {
            releaseAccess()
            customDirectory = nil
            problem = .notWritable
            return
        }

        customDirectory = url
        problem = nil
        recordedDisplayPath = url.path
        defaults.set(url.path, forKey: Keys.displayPath)

        // A stale bookmark still resolved, so refresh it before it stops resolving.
        if isStale, let refreshed = try? makeBookmark(url) {
            defaults.set(refreshed, forKey: Keys.bookmark)
        }
    }
}
