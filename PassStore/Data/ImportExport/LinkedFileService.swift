import CryptoKit
import Foundation

enum LinkedFileError: LocalizedError {
    case noLink
    case unresolvable
    case notReadable
    case notWritable

    var errorDescription: String? {
        switch self {
        case .noLink:
            "This item is not linked to a file."
        case .unresolvable:
            "The linked file could not be found. It may have been moved, renamed or deleted — link it again to continue."
        case .notReadable:
            "The linked file could not be read as UTF-8 text."
        case .notWritable:
            "The linked file could not be written. Check that you still have permission to edit it."
        }
    }
}

/// Reads and writes the `.env` file an item mirrors.
///
/// The whole point is that a `.env` changes over time: a stored copy is stale the moment the
/// file is edited. This keeps a security-scoped bookmark so the same file can be reached
/// again after a relaunch — the sandbox forgets a plain path, which is why linking has to
/// store a bookmark rather than a string.
@MainActor
struct LinkedFileService {
    /// Resolves the bookmark and reads the file, keeping the security-scoped access open only
    /// for the duration of the read.
    func read(_ link: LinkedFileReference) throws -> String {
        let url = try resolve(link)
        let gotAccess = url.startAccessingSecurityScopedResource()
        defer { if gotAccess { url.stopAccessingSecurityScopedResource() } }
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else {
            throw LinkedFileError.notReadable
        }
        return contents
    }

    func write(_ contents: String, to link: LinkedFileReference) throws {
        let url = try resolve(link)
        let gotAccess = url.startAccessingSecurityScopedResource()
        defer { if gotAccess { url.stopAccessingSecurityScopedResource() } }
        do {
            try contents.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            throw LinkedFileError.notWritable
        }
    }

    /// True when the bookmark still points at something readable.
    func isReachable(_ link: LinkedFileReference) -> Bool {
        (try? resolve(link)) != nil
    }

    func makeLink(to url: URL, parsedIntoFields: Bool) -> LinkedFileReference {
        let bookmark = try? url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        return LinkedFileReference(
            bookmark: bookmark,
            displayPath: url.path,
            parsedIntoFields: parsedIntoFields
        )
    }

    private func resolve(_ link: LinkedFileReference) throws -> URL {
        if let bookmark = link.bookmark {
            var isStale = false
            if let url = try? URL(
                resolvingBookmarkData: bookmark,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ) {
                return url
            }
        }
        // A backup restored on another Mac carries the path but no usable bookmark. If the
        // path happens to exist and be readable without the sandbox exception, use it;
        // otherwise the owner has to re-pick the file.
        guard !link.displayPath.isEmpty else { throw LinkedFileError.noLink }
        let url = URL(fileURLWithPath: link.displayPath)
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            throw LinkedFileError.unresolvable
        }
        return url
    }

    static func digest(_ contents: String) -> String {
        Data(SHA256.hash(data: Data(contents.utf8))).base64EncodedString()
    }
}
