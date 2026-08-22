import Foundation
import Testing
@testable import PassStore

/// "Is a secret I am storing properly also sitting in my repository?" is a question only a password
/// manager can answer, because it is the only thing that knows both halves. Getting it wrong in
/// either direction is bad: a missed leak is the point of the feature, and a report full of noise is
/// one nobody reads.
struct SecretScanTests {

    // MARK: - Fixture

    private func makeTree(_ files: [String: String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("passstore-scan-\(UUID().uuidString)", isDirectory: true)
        for (path, contents) in files {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data(contents.utf8).write(to: url)
        }
        return root
    }

    private func candidate(
        _ value: String,
        title: String = "Production API",
        key: String = "api_key",
        isSensitive: Bool = true
    ) -> SecretScanCandidate {
        SecretScanCandidate(
            itemID: UUID(),
            itemTitle: title,
            fieldKey: key,
            fieldLabel: "API Key",
            value: value,
            isSensitive: isSensitive
        )
    }

    // MARK: - What is worth searching for

    @Test func onlyLongSensitiveValuesBecomeNeedles() {
        let needles = SecretScanner.needles(from: [
            candidate("a-genuinely-long-secret-value"),
            // Not sensitive: a hostname would match every file in the project.
            candidate("db.internal.example", key: "host", isSensitive: false),
            // Too short to mean anything; every hit would be noise.
            candidate("abc123"),
            // A multi-line value cannot be matched against a single line.
            candidate("-----BEGIN KEY-----\nabcdefghijkl\n-----END KEY-----")
        ])
        #expect(needles.count == 1)
        #expect(needles.first?.value == "a-genuinely-long-secret-value")
    }

    @Test func theSameValueIsNotSearchedForTwice() {
        let shared = UUID()
        let needles = SecretScanner.needles(from: [
            SecretScanCandidate(itemID: shared, itemTitle: "A", fieldKey: "k", fieldLabel: "K", value: "duplicated-secret-value", isSensitive: true),
            SecretScanCandidate(itemID: shared, itemTitle: "A", fieldKey: "k", fieldLabel: "K", value: "duplicated-secret-value", isSensitive: true)
        ])
        #expect(needles.count == 1)
    }

    // MARK: - Finding things

    @Test func findsASecretAndNamesTheFileAndLine() throws {
        let root = try makeTree([
            "src/config.ts": "const key = \"super-secret-token-value\";\n",
            "README.md": "Nothing to see here\n"
        ])
        let needles = SecretScanner.needles(from: [candidate("super-secret-token-value")])

        let report = SecretScanner.scan(root: root, needles: needles)
        #expect(report.findings.count == 1)
        let finding = try #require(report.findings.first)
        #expect(finding.relativePath == "src/config.ts")
        #expect(finding.line == 1)
        #expect(finding.itemTitle == "Production API")
        #expect(!report.isClean)
        #expect(report.affectedFileCount == 1)
        #expect(report.affectedSecretCount == 1)
    }

    @Test func reportsEveryLineAndEveryFileASecretAppearsIn() throws {
        let root = try makeTree([
            "a.env": "TOKEN=super-secret-token-value\n",
            "deploy/b.yaml": "one: x\ntwo: super-secret-token-value\nthree: super-secret-token-value\n"
        ])
        let needles = SecretScanner.needles(from: [candidate("super-secret-token-value")])
        let report = SecretScanner.scan(root: root, needles: needles)

        #expect(report.findings.count == 3)
        #expect(report.affectedFileCount == 2)
        // One secret, three sightings.
        #expect(report.affectedSecretCount == 1)
        #expect(report.findings.map(\.line).sorted() == [1, 2, 3])
    }

    /// A clean answer has to mean something, so a vault whose secrets are nowhere must come back
    /// clean rather than merely quiet.
    @Test func aFolderWithNoSecretsInItComesBackClean() throws {
        let root = try makeTree([
            "src/app.swift": "let greeting = \"hello\"\n",
            ".env.example": "TOKEN=replace-me\n"
        ])
        let report = SecretScanner.scan(
            root: root,
            needles: SecretScanner.needles(from: [candidate("super-secret-token-value")])
        )
        #expect(report.isClean)
        #expect(report.filesScanned == 2)
        #expect(report.secretsChecked == 1)
        #expect(!report.wasTruncated)
    }

    /// Hidden files are exactly where a leaked secret lives.
    @Test func hiddenFilesAreScanned() throws {
        let root = try makeTree([".env.local": "SECRET=super-secret-token-value\n"])
        let report = SecretScanner.scan(
            root: root,
            needles: SecretScanner.needles(from: [candidate("super-secret-token-value")])
        )
        #expect(report.findings.count == 1)
        #expect(report.findings.first?.relativePath == ".env.local")
    }

    /// `node_modules` and `.git` will happily hold thousands of copies of a secret that leaked
    /// once, and the report would be unreadable.
    @Test func noisyDirectoriesAreSkipped() throws {
        let root = try makeTree([
            "node_modules/pkg/index.js": "var k = \"super-secret-token-value\";\n",
            ".git/COMMIT_EDITMSG": "added super-secret-token-value\n",
            "build/output.txt": "super-secret-token-value\n",
            "src/real.js": "var k = \"super-secret-token-value\";\n"
        ])
        let report = SecretScanner.scan(
            root: root,
            needles: SecretScanner.needles(from: [candidate("super-secret-token-value")])
        )
        #expect(report.findings.count == 1)
        #expect(report.findings.first?.relativePath == "src/real.js")
    }

    /// A binary that happens to contain the bytes of a secret is not a leak anybody can act on.
    @Test func binaryFilesAreLeftAlone() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("passstore-scan-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        var binary = Data("super-secret-token-value".utf8)
        binary.append(0)
        binary.append(Data(repeating: 0xFF, count: 32))
        try binary.write(to: root.appendingPathComponent("blob.bin"))

        let report = SecretScanner.scan(
            root: root,
            needles: SecretScanner.needles(from: [candidate("super-secret-token-value")])
        )
        #expect(report.isClean)
    }

    @Test func aScanWithNothingToLookForDoesNoWork() throws {
        let root = try makeTree(["a.txt": "anything\n"])
        let report = SecretScanner.scan(root: root, needles: [])
        #expect(report.isClean)
        #expect(report.filesScanned == 0)
        #expect(report.secretsChecked == 0)
    }

    @Test func cancellingMarksTheReportIncompleteRatherThanClean() throws {
        let root = try makeTree([
            "one.txt": "super-secret-token-value\n",
            "two.txt": "super-secret-token-value\n"
        ])
        let report = SecretScanner.scan(
            root: root,
            needles: SecretScanner.needles(from: [candidate("super-secret-token-value")]),
            isCancelled: { true }
        )
        // A stopped scan must never read as "there is nothing here".
        #expect(report.wasTruncated)
    }

    @Test func findingsAreOrderedByFileThenLine() throws {
        let root = try makeTree([
            "z.txt": "super-secret-token-value\n",
            "a.txt": "x\nsuper-secret-token-value\n",
            "m.txt": "super-secret-token-value\n"
        ])
        let report = SecretScanner.scan(
            root: root,
            needles: SecretScanner.needles(from: [candidate("super-secret-token-value")])
        )
        #expect(report.findings.map(\.relativePath) == ["a.txt", "m.txt", "z.txt"])
    }

    /// The report is rendered, screenshotted and pasted into tickets. It must not contain the
    /// secret it is reporting.
    @Test func aFindingNeverCarriesTheValue() throws {
        let secret = "super-secret-token-value"
        let root = try makeTree(["config.json": "{\"k\":\"\(secret)\"}\n"])
        let report = SecretScanner.scan(
            root: root,
            needles: SecretScanner.needles(from: [candidate(secret)])
        )
        let finding = try #require(report.findings.first)
        #expect(!finding.id.contains(secret))
        #expect(!finding.relativePath.contains(secret))
        #expect(!finding.itemTitle.contains(secret))
        #expect(!finding.fieldLabel.contains(secret))
    }

    // MARK: - Drawing a large report

    /// A secret that leaked into a generated file can appear thousands of times. The report keeps
    /// every finding, and the grouping the interface draws is capped — otherwise the sheet spends its
    /// time building rows nobody will scroll to.
    @Test func theGroupingIsCappedForDrawingWhileTheFindingsAreKeptWhole() throws {
        let lines = Array(repeating: "TOKEN=super-secret-token-value", count: 60).joined(separator: "\n")
        let root = try makeTree(["big.env": lines + "\n"])
        let report = SecretScanner.scan(
            root: root,
            needles: SecretScanner.needles(from: [candidate("super-secret-token-value")])
        )

        #expect(report.findings.count == 60)
        let group = try #require(report.fileGroups.first)
        #expect(group.findings.count == SecretScanner.maximumRenderedFindingsPerFile)
        #expect(group.hiddenFindingCount == 60 - SecretScanner.maximumRenderedFindingsPerFile)
        #expect(report.isPartiallyRendered)
    }

    @Test func aSmallReportIsDrawnWhole() throws {
        let root = try makeTree([
            "a.env": "TOKEN=super-secret-token-value\n",
            "b.env": "TOKEN=super-secret-token-value\n"
        ])
        let report = SecretScanner.scan(
            root: root,
            needles: SecretScanner.needles(from: [candidate("super-secret-token-value")])
        )
        #expect(report.fileGroups.count == 2)
        #expect(report.hiddenFileCount == 0)
        #expect(!report.isPartiallyRendered)
        let allShown = report.fileGroups.allSatisfy { $0.hiddenFindingCount == 0 }
        #expect(allShown)
    }

    @Test func theGroupingKeepsTheFileOrderAndPaths() throws {
        let root = try makeTree([
            "z.txt": "super-secret-token-value\n",
            "a.txt": "super-secret-token-value\n"
        ])
        let report = SecretScanner.scan(
            root: root,
            needles: SecretScanner.needles(from: [candidate("super-secret-token-value")])
        )
        #expect(report.fileGroups.map(\.relativePath) == ["a.txt", "z.txt"])
        let group = try #require(report.fileGroups.first)
        #expect(group.absolutePath.hasSuffix("a.txt"))
        #expect(group.id == "a.txt")
    }

    @Test func relativePathsAreRelativeToWhatWasScanned() {
        let root = "/tmp/project"
        let url = URL(fileURLWithPath: "/tmp/project/src/deep/file.ts")
        #expect(SecretScanner.relativePath(of: url, under: root) == "src/deep/file.ts")
        // A path outside the root is reported as it is rather than mangled.
        #expect(SecretScanner.relativePath(of: URL(fileURLWithPath: "/elsewhere/x"), under: root) == "/elsewhere/x")
    }
}

@MainActor
struct SecretScanViewModelTests {

    /// Clicking through to a secret used to throw the report away, so getting back to the rest of
    /// the list meant walking the whole folder again.
    @Test func theReportSurvivesClosingTheSheetAndDiesWithTheSession() async throws {
        let container = AppContainer.preview()
        let viewModel = VaultViewModel(container: container)

        var draft = SecretItemDraft.empty
        draft.title = "Kept Report"
        draft.fieldDrafts = [
            FieldDraft(key: "api_key", label: "API Key", value: "kept-report-value-abcdef", kind: .secret, isSensitive: true, isMasked: true, sortOrder: 0)
        ]
        viewModel.saveItem(draft)

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("passstore-scan-keep-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("KEY=kept-report-value-abcdef\n".utf8).write(to: root.appendingPathComponent(".env"))

        viewModel.scanForLeakedSecrets(in: root)
        for _ in 0..<200 where viewModel.isScanningForSecrets {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(viewModel.hasSecretScanReport)

        // Closing the sheet keeps it, so Vault ▸ Last Scan Results can bring it straight back.
        viewModel.activeSheet = nil
        #expect(viewModel.hasSecretScanReport)
        viewModel.showLastSecretScanReport()
        #expect(viewModel.activeSheet?.id == VaultSheet.secretScan.id)

        // Locking is what ends it: it names items and files.
        viewModel.clearUnlockedState()
        #expect(!viewModel.hasSecretScanReport)
    }


    @Test func scanningAProjectFolderFindsTheVaultsOwnSecret() async throws {
        let container = AppContainer.preview()
        let viewModel = VaultViewModel(container: container)

        var draft = SecretItemDraft.empty
        draft.title = "Leaked Key"
        draft.fieldDrafts = [
            FieldDraft(key: "api_key", label: "API Key", value: "leaked-value-abcdefghijkl", kind: .secret, isSensitive: true, isMasked: true, sortOrder: 0)
        ]
        viewModel.saveItem(draft)

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("passstore-scan-vm-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("API_KEY=leaked-value-abcdefghijkl\n".utf8)
            .write(to: root.appendingPathComponent(".env"))

        viewModel.scanForLeakedSecrets(in: root)
        #expect(viewModel.isScanningForSecrets)

        // The scan runs off the main actor; wait for it to land.
        for _ in 0..<200 where viewModel.isScanningForSecrets {
            try await Task.sleep(for: .milliseconds(20))
        }

        let report = try #require(viewModel.secretScanReport)
        #expect(report.findings.contains { $0.itemTitle == "Leaked Key" && $0.relativePath == ".env" })

        // Closing the sheet must not leave a list naming which secret is in which file lying around.
        viewModel.clearSecretScanReport()
        #expect(viewModel.secretScanReport == nil)
    }
}
