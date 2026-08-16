import CryptoKit
import Darwin
import Foundation

enum LinkedFileError: LocalizedError {
    case noLink
    case unresolvable
    case notReadable
    case notWritable
    case bookmarkCreationFailed
    case bookmarkRefreshFailed
    case fileChangedBeforeWrite
    case fileTooLarge

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
        case .bookmarkCreationFailed:
            "PassStore could not save durable permission for that file. Choose the file again."
        case .bookmarkRefreshFailed:
            "Permission for the linked file expired and could not be renewed. Choose the file again."
        case .fileChangedBeforeWrite:
            "The linked file changed again before it could be written. Review it and confirm the overwrite again."
        case .fileTooLarge:
            "The linked file is too large to load safely as a .env file."
        }
    }
}

/// Reads and writes the `.env` file an item mirrors.
///
/// The whole point is that a `.env` changes over time: a stored copy is stale the moment the
/// file is edited. This keeps a security-scoped bookmark so the same file can be reached
/// again after a relaunch — the sandbox forgets a plain path, which is why linking has to
/// store a bookmark rather than a string.
nonisolated struct LinkedFileService: Sendable {
    static let maximumReadableFileSize = 16 * 1_024 * 1_024

    /// Reads a user-picked file without first creating a bookmark. The bounded FileHandle
    /// path avoids both an unbounded allocation and the eager `String(contentsOf:)` read used
    /// by import previews.
    static func readPickedFile(at url: URL) throws -> String {
        let gotAccess = url.startAccessingSecurityScopedResource()
        defer { if gotAccess { url.stopAccessingSecurityScopedResource() } }
        var data: Data
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            data = try handle.read(upToCount: maximumReadableFileSize + 1) ?? Data()
        } catch {
            throw LinkedFileError.notReadable
        }
        defer { VaultCryptoService.overwrite(&data) }
        guard data.count <= maximumReadableFileSize else { throw LinkedFileError.fileTooLarge }
        guard let contents = String(data: data, encoding: .utf8) else { throw LinkedFileError.notReadable }
        return contents
    }

    struct ReadResult: Sendable {
        let contents: String
        let refreshedBookmark: Data?
        let resolvedPath: String
    }

    struct WriteResult: Sendable {
        let refreshedBookmark: Data?
        let resolvedPath: String
    }

    private struct Resolution {
        let url: URL
        let refreshedBookmark: Data?
    }

    /// Resolves the bookmark and reads the file, keeping the security-scoped access open only
    /// for the duration of the read.
    func read(_ link: LinkedFileReference) throws -> ReadResult {
        let resolution = try resolve(link)
        let gotAccess = resolution.url.startAccessingSecurityScopedResource()
        defer { if gotAccess { resolution.url.stopAccessingSecurityScopedResource() } }
        var data: Data
        do {
            let handle = try FileHandle(forReadingFrom: resolution.url)
            defer { try? handle.close() }
            data = try handle.read(upToCount: Self.maximumReadableFileSize + 1) ?? Data()
        } catch {
            throw LinkedFileError.notReadable
        }
        defer { VaultCryptoService.overwrite(&data) }
        guard data.count <= Self.maximumReadableFileSize else { throw LinkedFileError.fileTooLarge }
        guard let contents = String(data: data, encoding: .utf8) else { throw LinkedFileError.notReadable }
        return ReadResult(
            contents: contents,
            refreshedBookmark: resolution.refreshedBookmark,
            resolvedPath: resolution.url.path
        )
    }

    func write(
        _ contents: String,
        to link: LinkedFileReference,
        requiringCurrentDigest expectedDigest: String? = nil
    ) throws -> WriteResult {
        guard contents.utf8.count <= Self.maximumReadableFileSize else {
            throw LinkedFileError.fileTooLarge
        }
        let resolution = try resolve(link)
        let gotAccess = resolution.url.startAccessingSecurityScopedResource()
        defer { if gotAccess { resolution.url.stopAccessingSecurityScopedResource() } }
        var data = Data(contents.utf8)
        defer { VaultCryptoService.overwrite(&data) }

        let fileManager = FileManager.default
        let temporary = resolution.url.deletingLastPathComponent().appendingPathComponent(
            ".\(resolution.url.lastPathComponent).passstore-\(UUID().uuidString).tmp",
            isDirectory: false
        )

        // A security-scoped bookmark grants access to the *file*, not to the directory holding
        // it, so the temporary file needed for an atomic rename usually cannot be created at
        // all. Fall back to rewriting the file itself, which the bookmark does cover.
        guard fileManager.createFile(
            atPath: temporary.path,
            contents: nil,
            attributes: [.posixPermissions: 0o600]
        ) else {
            try writeInPlace(data, to: resolution.url, requiringCurrentDigest: expectedDigest)
            return WriteResult(
                refreshedBookmark: resolution.refreshedBookmark,
                resolvedPath: resolution.url.path
            )
        }
        try? fileManager.removeItem(at: temporary)

        do {
            let attributes = try fileManager.attributesOfItem(atPath: resolution.url.path)
            let originalPermissions = attributes[.posixPermissions] as? NSNumber ?? NSNumber(value: 0o600)
            guard fileManager.createFile(
                atPath: temporary.path,
                contents: nil,
                attributes: [.posixPermissions: originalPermissions]
            ) else {
                throw CocoaError(.fileWriteUnknown)
            }

            let handle = try FileHandle(forWritingTo: temporary)
            do {
                try handle.write(contentsOf: data)
                try handle.synchronize()
                try handle.close()
            } catch {
                try? handle.close()
                throw error
            }
            // Set the final mode before the rename. `String.write(.atomic)` briefly exposed
            // a newly-created file with default permissions and could leave it that way if
            // the post-write chmod failed.
            try fileManager.setAttributes(
                [.posixPermissions: originalPermissions],
                ofItemAtPath: temporary.path
            )

            // Write and flush the temporary file first, then compare as close to the atomic
            // rename as possible. This cannot make uncoordinated external writers impossible,
            // but it removes the much larger read/encode/write race from the UI layer.
            if let expectedDigest {
                var currentData = try readBoundedData(from: resolution.url)
                defer { VaultCryptoService.overwrite(&currentData) }
                guard Self.digest(currentData) == expectedDigest else {
                    throw LinkedFileError.fileChangedBeforeWrite
                }
            }

            let result = temporary.path.withCString { source in
                resolution.url.path.withCString { destination in
                    Darwin.rename(source, destination)
                }
            }
            guard result == 0 else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
        } catch let error as LinkedFileError {
            if fileManager.fileExists(atPath: temporary.path) {
                try? fileManager.removeItem(at: temporary)
            }
            throw error
        } catch {
            if fileManager.fileExists(atPath: temporary.path) {
                try? fileManager.removeItem(at: temporary)
            }
            throw LinkedFileError.notWritable
        }
        return WriteResult(
            refreshedBookmark: resolution.refreshedBookmark,
            resolvedPath: resolution.url.path
        )
    }

    /// Rewrites the file itself, for the common sandbox case where only the file — not its
    /// directory — is reachable.
    ///
    /// Truncating in place is not atomic: an interrupted write can leave the file short. The
    /// contents are a `.env` the owner asked to overwrite and PassStore still holds the full
    /// value, so that is a far better outcome than being unable to write at all.
    private func writeInPlace(
        _ data: Data,
        to url: URL,
        requiringCurrentDigest expectedDigest: String?
    ) throws {
        if let expectedDigest {
            var currentData = try readBoundedData(from: url)
            defer { VaultCryptoService.overwrite(&currentData) }
            guard Self.digest(currentData) == expectedDigest else {
                throw LinkedFileError.fileChangedBeforeWrite
            }
        }
        do {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.truncate(atOffset: 0)
            try handle.write(contentsOf: data)
            try handle.synchronize()
        } catch let error as LinkedFileError {
            throw error
        } catch {
            throw LinkedFileError.notWritable
        }
    }

    /// True when the bookmark still points at something readable.
    func isReachable(_ link: LinkedFileReference) -> Bool {
        (try? resolve(link)) != nil
    }

    func makeLink(to url: URL, parsedIntoFields: Bool) throws -> LinkedFileReference {
        let gotAccess = url.startAccessingSecurityScopedResource()
        defer { if gotAccess { url.stopAccessingSecurityScopedResource() } }
        let bookmark: Data
        do {
            bookmark = try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        } catch {
            throw LinkedFileError.bookmarkCreationFailed
        }
        return LinkedFileReference(
            bookmark: bookmark,
            displayPath: url.path,
            parsedIntoFields: parsedIntoFields
        )
    }

    private func resolve(_ link: LinkedFileReference) throws -> Resolution {
        if let bookmark = link.bookmark {
            var isStale = false
            if let url = try? URL(
                resolvingBookmarkData: bookmark,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ) {
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
                    throw LinkedFileError.bookmarkRefreshFailed
                }
            }
        }
        // `displayPath` is presentation metadata, not authority. A restored or malicious
        // backup must never gain file access merely by naming a readable path; only a valid
        // security-scoped bookmark created by the user's picker is accepted.
        guard !link.displayPath.isEmpty else { throw LinkedFileError.noLink }
        throw LinkedFileError.unresolvable
    }

    static func digest(_ contents: String) -> String {
        var data = Data(contents.utf8)
        defer { VaultCryptoService.overwrite(&data) }
        return digest(data)
    }

    private static func digest(_ data: Data) -> String {
        Data(SHA256.hash(data: data)).base64EncodedString()
    }

    private func readBoundedData(from url: URL) throws -> Data {
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let data = try handle.read(upToCount: Self.maximumReadableFileSize + 1) ?? Data()
            guard data.count <= Self.maximumReadableFileSize else {
                throw LinkedFileError.fileTooLarge
            }
            return data
        } catch let error as LinkedFileError {
            throw error
        } catch {
            throw LinkedFileError.notReadable
        }
    }
}
