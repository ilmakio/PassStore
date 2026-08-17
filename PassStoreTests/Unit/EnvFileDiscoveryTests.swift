import Foundation
import Testing
@testable import PassStore

/// Finding a project's `.env` files, and the limits that make handing a whole repository to a
/// password manager reasonable: no contents read, no symlinks followed, nothing unbounded.
struct EnvFileDiscoveryTests {
    private let service = EnvFileDiscoveryService()

    // MARK: - Classification

    @Test func fileNamesAreRecognisedByShapeNotByGuessing() {
        #expect(EnvFileClassifier.isEnvFileName(".env"))
        #expect(EnvFileClassifier.isEnvFileName(".env.production"))
        #expect(EnvFileClassifier.isEnvFileName("production.env"))
        #expect(EnvFileClassifier.isEnvFileName(".env.local"))
        #expect(!EnvFileClassifier.isEnvFileName("environment.swift"))
        #expect(!EnvFileClassifier.isEnvFileName(".envrc"))
        #expect(!EnvFileClassifier.isEnvFileName("README.md"))
    }

    @Test func theEnvironmentIsSuggestedFromTheFileName() {
        #expect(EnvFileClassifier.environment(forFileName: ".env").kind == .local)
        #expect(EnvFileClassifier.environment(forFileName: ".env.local").kind == .local)
        #expect(EnvFileClassifier.environment(forFileName: ".env.development").kind == .dev)
        #expect(EnvFileClassifier.environment(forFileName: ".env.staging").kind == .staging)
        #expect(EnvFileClassifier.environment(forFileName: ".env.production").kind == .prod)
        #expect(EnvFileClassifier.environment(forFileName: ".env.PROD").kind == .prod)
    }

    /// `.env.production.local` is a local override *of production*, which is where its secrets
    /// belong — not in Local with everything else that ends in `.local`.
    @Test func aLocalOverrideKeepsTheEnvironmentItOverrides() {
        #expect(EnvFileClassifier.environment(forFileName: ".env.production.local").kind == .prod)
        #expect(EnvFileClassifier.environment(forFileName: ".env.staging.local").kind == .staging)
    }

    @Test func anUnknownSuffixBecomesACustomEnvironment() {
        let environment = EnvFileClassifier.environment(forFileName: ".env.qa")
        #expect(environment.kind == .custom)
        #expect(environment.title == "Qa")
    }

    @Test func checkedInExamplesAreFlagged() {
        #expect(EnvFileClassifier.isTemplate(".env.example"))
        #expect(EnvFileClassifier.isTemplate(".env.production.sample"))
        #expect(EnvFileClassifier.isTemplate(".env.template"))
        #expect(!EnvFileClassifier.isTemplate(".env.production"))
    }

    // MARK: - Walking a folder

    private func makeTree(_ label: String, _ build: (URL) throws -> Void) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("EnvDiscovery-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try build(root)
        return root
    }

    private func write(_ contents: String, to path: String, in root: URL) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    @Test func theProjectsOwnFilesAreFoundAndItsDependenciesAreNot() throws {
        let root = try makeTree("Basics") { root in
            try write("A=1", to: ".env", in: root)
            try write("A=2", to: ".env.production", in: root)
            try write("A=3", to: "apps/api/.env.staging", in: root)
            try write("A=4", to: "node_modules/some-package/.env", in: root)
            try write("A=5", to: ".git/config/.env", in: root)
            try write("A=6", to: "README.md", in: root)
        }
        defer { try? FileManager.default.removeItem(at: root) }

        let found = service.walkForEnvFiles(in: root, alreadyLinkedPaths: []).files

        #expect(found.map(\.relativePath) == [".env", ".env.production", "apps/api/.env.staging"])
        #expect(found[2].suggestedEnvironment.kind == .staging)
    }

    @Test func theWalkStopsGoingDeeper() throws {
        let root = try makeTree("Depth") { root in
            try write("A=1", to: "one/two/three/.env", in: root)
            try write("A=2", to: "one/two/three/four/five/.env", in: root)
        }
        defer { try? FileManager.default.removeItem(at: root) }

        let found = service.walkForEnvFiles(in: root, alreadyLinkedPaths: []).files
        #expect(found.map(\.relativePath) == ["one/two/three/.env"])
    }

    /// A symlink is the way a walk bounded to one folder ends up reading something outside it.
    @Test func symlinksAreSkippedRatherThanFollowed() throws {
        let outside = try makeTree("Outside") { root in
            try write("SECRET=leaked", to: ".env", in: root)
        }
        defer { try? FileManager.default.removeItem(at: outside) }

        let root = try makeTree("Symlink") { root in
            try write("A=1", to: ".env", in: root)
            try FileManager.default.createSymbolicLink(
                at: root.appendingPathComponent("elsewhere"),
                withDestinationURL: outside
            )
            try FileManager.default.createSymbolicLink(
                at: root.appendingPathComponent(".env.linked"),
                withDestinationURL: outside.appendingPathComponent(".env")
            )
        }
        defer { try? FileManager.default.removeItem(at: root) }

        let found = service.walkForEnvFiles(in: root, alreadyLinkedPaths: []).files
        #expect(found.map(\.relativePath) == [".env"])
    }

    @Test func theListIsCappedAndSaysSo() throws {
        let root = try makeTree("Cap") { root in
            for index in 0..<(EnvFileDiscoveryService.maximumResults + 10) {
                try write("A=\(index)", to: "package-\(index)/.env", in: root)
            }
        }
        defer { try? FileManager.default.removeItem(at: root) }

        let walk = service.walkForEnvFiles(in: root, alreadyLinkedPaths: [])
        #expect(walk.files.count == EnvFileDiscoveryService.maximumResults)
        #expect(walk.didReachLimit)
    }

    @Test func examplesSinkAndAlreadyLinkedFilesAreMarked() throws {
        let root = try makeTree("Marks") { root in
            try write("A=1", to: ".env.example", in: root)
            try write("A=2", to: ".env", in: root)
        }
        defer { try? FileManager.default.removeItem(at: root) }

        let linked = root.appendingPathComponent(".env").resolvingSymlinksInPath().path
        let found = service.walkForEnvFiles(in: root, alreadyLinkedPaths: [linked]).files

        // Real files first, examples last.
        #expect(found.map(\.relativePath) == [".env", ".env.example"])
        #expect(found[0].isAlreadyLinked)
        #expect(found[0].isTemplate == false)
        #expect(found[1].isTemplate)
        #expect(found[1].isAlreadyLinked == false)
    }

    @Test func discoveryReportsSizesWithoutReadingContents() throws {
        let root = try makeTree("Sizes") { root in
            try write("TOKEN=supersecret", to: ".env", in: root)
        }
        defer { try? FileManager.default.removeItem(at: root) }

        let found = try #require(service.walkForEnvFiles(in: root, alreadyLinkedPaths: []).files.first)
        #expect(found.byteCount == "TOKEN=supersecret".utf8.count)
    }

    // MARK: - Path handling

    /// A relative path from a scan rides along in the vault, so it is data — and data does not
    /// get to point outside the folder it was found in.
    @Test func aRelativePathCannotEscapeTheLinkedFolder() throws {
        let root = URL(fileURLWithPath: "/tmp/project", isDirectory: true)

        #expect(throws: LinkedFolderError.self) {
            try EnvFileDiscoveryService.fileURL(forRelativePath: "../secrets/.env", inResolvedFolder: root)
        }
        #expect(throws: LinkedFolderError.self) {
            try EnvFileDiscoveryService.fileURL(forRelativePath: "apps/../../.env", inResolvedFolder: root)
        }
        #expect(throws: LinkedFolderError.self) {
            try EnvFileDiscoveryService.fileURL(forRelativePath: "", inResolvedFolder: root)
        }

        let allowed = try EnvFileDiscoveryService.fileURL(
            forRelativePath: "apps/api/.env",
            inResolvedFolder: root
        )
        #expect(allowed.path == "/tmp/project/apps/api/.env")
    }

    /// Absolute paths never grant access on their own: only a bookmark the owner's own folder
    /// pick produced can be resolved.
    @Test func aFolderWithoutABookmarkCannotBeResolved() {
        let pathOnly = LinkedFolderReference(bookmark: nil, displayPath: "/Users/somebody/project")
        #expect(throws: LinkedFolderError.self) {
            _ = try service.resolve(pathOnly)
        }
        #expect(throws: LinkedFolderError.self) {
            _ = try service.discover(in: pathOnly, alreadyLinkedPaths: [])
        }
    }
}
