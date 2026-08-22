import Foundation

/// One place a stored secret was found sitting in a file.
///
/// Carries the identity of the secret and where it was seen — never the value. A report about
/// secrets leaking into files must not itself be a file full of secrets, and this one is rendered,
/// screenshotted and pasted into tickets.
nonisolated struct SecretScanFinding: Identifiable, Hashable, Sendable {
    let id: String
    let itemID: UUID
    let itemTitle: String
    let fieldKey: String
    let fieldLabel: String
    /// Path relative to the folder that was scanned, which is what somebody wants to read.
    let relativePath: String
    /// Absolute path, so the finding can be revealed in the Finder.
    let absolutePath: String
    /// 1-based.
    let line: Int

    init(
        itemID: UUID,
        itemTitle: String,
        fieldKey: String,
        fieldLabel: String,
        relativePath: String,
        absolutePath: String,
        line: Int
    ) {
        self.id = "\(itemID.uuidString)|\(fieldKey)|\(relativePath)|\(line)"
        self.itemID = itemID
        self.itemTitle = itemTitle
        self.fieldKey = fieldKey
        self.fieldLabel = fieldLabel
        self.relativePath = relativePath
        self.absolutePath = absolutePath
        self.line = line
    }
}

/// What to look for. Built from the vault, used once, and dropped.
nonisolated struct SecretScanNeedle: Sendable {
    let itemID: UUID
    let itemTitle: String
    let fieldKey: String
    let fieldLabel: String
    let value: String
}

/// The findings in one file, ready to draw.
///
/// Grouped by the scanner rather than by the view: a large repository can produce thousands of
/// findings, and regrouping them on every render is work done once per frame to produce the same
/// answer. `hiddenFindingCount` is what the cap left out of this file.
nonisolated struct SecretScanFileGroup: Identifiable, Sendable {
    var id: String { relativePath }
    let relativePath: String
    let absolutePath: String
    let findings: [SecretScanFinding]
    let hiddenFindingCount: Int
}

nonisolated struct SecretScanReport: Sendable {
    let root: String
    /// Every finding, in order. This is what Copy List writes; the interface draws `fileGroups`.
    let findings: [SecretScanFinding]
    /// The findings grouped by file and capped for drawing.
    let fileGroups: [SecretScanFileGroup]
    /// Files a secret was found in that the cap left out of `fileGroups`.
    let hiddenFileCount: Int
    let filesScanned: Int
    let secretsChecked: Int
    /// True when the walk hit its own limits and stopped early, so a clean result cannot be read as
    /// "there is nothing here".
    let wasTruncated: Bool
    /// Distinct files a secret was found in, before the drawing cap.
    let affectedFileCount: Int
    /// Distinct secrets that leaked.
    let affectedSecretCount: Int

    init(
        root: String,
        findings: [SecretScanFinding],
        filesScanned: Int,
        secretsChecked: Int,
        wasTruncated: Bool
    ) {
        self.root = root
        self.findings = findings
        self.filesScanned = filesScanned
        self.secretsChecked = secretsChecked
        self.wasTruncated = wasTruncated
        self.affectedFileCount = Set(findings.map(\.relativePath)).count
        self.affectedSecretCount = Set(findings.map { "\($0.itemID)|\($0.fieldKey)" }).count

        let grouped = Self.group(findings)
        self.fileGroups = Array(grouped.prefix(SecretScanner.maximumRenderedFiles))
        self.hiddenFileCount = max(0, grouped.count - SecretScanner.maximumRenderedFiles)
    }

    var isClean: Bool { findings.isEmpty }

    /// True when the interface is showing less than everything, so it can say so.
    var isPartiallyRendered: Bool {
        hiddenFileCount > 0 || fileGroups.contains { $0.hiddenFindingCount > 0 }
    }

    /// Findings by file, in the order they were reported, each capped.
    private static func group(_ findings: [SecretScanFinding]) -> [SecretScanFileGroup] {
        var order: [String] = []
        var byPath: [String: [SecretScanFinding]] = [:]
        for finding in findings {
            if byPath[finding.relativePath] == nil { order.append(finding.relativePath) }
            byPath[finding.relativePath, default: []].append(finding)
        }
        return order.map { path in
            let all = byPath[path] ?? []
            let shown = Array(all.prefix(SecretScanner.maximumRenderedFindingsPerFile))
            return SecretScanFileGroup(
                relativePath: path,
                absolutePath: all.first?.absolutePath ?? path,
                findings: shown,
                hiddenFindingCount: all.count - shown.count
            )
        }
    }
}

/// Looks for the vault's own secrets sitting in plaintext inside a folder.
///
/// The question this answers — "is a secret I am storing properly also committed in my repository?"
/// — is one only a password manager can answer, because it is the only thing that knows both
/// halves. Everything here is local, reads only what it is pointed at, and writes nothing.
nonisolated enum SecretScanner {
    /// Directories never worth walking into. Skipping them is not an optimisation: `node_modules`
    /// and `.git` will happily contain thousands of matches for a secret that leaked once, and the
    /// report would be unreadable.
    static let skippedDirectories: Set<String> = [
        ".git", ".svn", ".hg", "node_modules", ".build", "build", "DerivedData",
        "Pods", "Carthage", ".venv", "venv", "__pycache__", ".next", ".nuxt",
        "dist", "out", "target", ".gradle", ".terraform", ".mypy_cache",
        ".pytest_cache", ".swiftpm", ".yarn", "vendor", ".cache", ".idea",
        ".DS_Store", ".Trash"
    ]

    /// A value shorter than this is not worth searching for: it matches everywhere and every hit is
    /// noise. Short secrets are the health report's problem, not this one's.
    static let minimumNeedleLength = 8

    /// Bigger than this and a text file is a data file.
    static let maximumFileBytes = 4 * 1_024 * 1_024

    /// A ceiling so pointing this at a home directory ends rather than never finishing.
    static let maximumFilesScanned = 40_000

    /// How much of a report is drawn.
    ///
    /// A secret that leaked into a generated file can appear thousands of times, and a scrolling
    /// view of ten thousand rows is slow to build and useless to read. The report keeps every
    /// finding — Copy List writes all of them — and the interface draws this much and says so.
    static let maximumRenderedFiles = 200
    static let maximumRenderedFindingsPerFile = 20

    /// Which of the vault's values are worth looking for.
    ///
    /// Sensitive values only, and only ones long enough to mean something. Searching for a hostname
    /// or a port number would report every file in the project and say nothing at all.
    static func needles(from candidates: [SecretScanCandidate]) -> [SecretScanNeedle] {
        var seen: Set<String> = []
        var result: [SecretScanNeedle] = []
        for candidate in candidates {
            let value = candidate.value
            guard candidate.isSensitive,
                  value.count >= minimumNeedleLength,
                  !value.contains(where: \.isNewline),
                  seen.insert("\(candidate.itemID)|\(candidate.fieldKey)|\(value)").inserted else {
                continue
            }
            result.append(
                SecretScanNeedle(
                    itemID: candidate.itemID,
                    itemTitle: candidate.itemTitle,
                    fieldKey: candidate.fieldKey,
                    fieldLabel: candidate.fieldLabel,
                    value: value
                )
            )
        }
        return result
    }

    /// Walks `root` and reports every line that contains one of `needles`.
    ///
    /// Synchronous and deliberately dumb: one pass per file, a substring check per needle. A folder
    /// of source code and a handful of secrets is small enough that cleverness would only be a
    /// place for bugs to live.
    static func scan(
        root: URL,
        needles: [SecretScanNeedle],
        fileManager: FileManager = .default,
        isCancelled: () -> Bool = { false }
    ) -> SecretScanReport {
        let rootPath = root.standardizedFileURL.path
        guard !needles.isEmpty else {
            return SecretScanReport(
                root: rootPath,
                findings: [],
                filesScanned: 0,
                secretsChecked: 0,
                wasTruncated: false
            )
        }

        var findings: [SecretScanFinding] = []
        var filesScanned = 0
        var truncated = false

        // `skipsHiddenFiles` is deliberately off: a leaked secret is far more likely to be in
        // `.env.local` than anywhere visible.
        let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey],
            options: [.skipsPackageDescendants]
        )

        while let url = enumerator?.nextObject() as? URL {
            if isCancelled() { truncated = true; break }
            guard let values = try? url.resourceValues(
                forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey]
            ) else { continue }

            if values.isDirectory == true {
                if skippedDirectories.contains(url.lastPathComponent) {
                    enumerator?.skipDescendants()
                }
                continue
            }
            // Symlinks are not followed: a link out of the folder is not part of what was scanned,
            // and a loop would never end.
            guard values.isSymbolicLink != true, values.isRegularFile == true else { continue }
            if let size = values.fileSize, size > maximumFileBytes { continue }

            guard filesScanned < maximumFilesScanned else { truncated = true; break }
            filesScanned += 1

            guard let contents = readTextFile(at: url) else { continue }
            let relativePath = Self.relativePath(of: url, under: rootPath)

            for (index, line) in contents.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                guard line.count >= minimumNeedleLength else { continue }
                let haystack = String(line)
                for needle in needles where haystack.contains(needle.value) {
                    findings.append(
                        SecretScanFinding(
                            itemID: needle.itemID,
                            itemTitle: needle.itemTitle,
                            fieldKey: needle.fieldKey,
                            fieldLabel: needle.fieldLabel,
                            relativePath: relativePath,
                            absolutePath: url.standardizedFileURL.path,
                            line: index + 1
                        )
                    )
                }
            }
        }

        return SecretScanReport(
            root: rootPath,
            findings: findings.sorted {
                if $0.relativePath != $1.relativePath { return $0.relativePath < $1.relativePath }
                if $0.line != $1.line { return $0.line < $1.line }
                return $0.itemTitle < $1.itemTitle
            },
            filesScanned: filesScanned,
            secretsChecked: needles.count,
            wasTruncated: truncated
        )
    }

    /// Text, or nil when the file is binary or not decodable.
    ///
    /// A NUL byte in the first block is the same test `grep` uses, and for the same reason: a
    /// binary that happens to contain the bytes of a secret is not a leak anybody can act on.
    static func readTextFile(at url: URL) -> String? {
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else { return nil }
        guard !data.prefix(8_000).contains(0) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func relativePath(of url: URL, under rootPath: String) -> String {
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(rootPath) else { return path }
        let trimmed = path.dropFirst(rootPath.count)
        return trimmed.hasPrefix("/") ? String(trimmed.dropFirst()) : String(trimmed)
    }
}

/// One field of one item, flattened.
///
/// A plain value type rather than the entity graph: the scan runs off the main actor, and the graph
/// is neither `Sendable` nor safe to touch from there. Flattening at the boundary also means the
/// scanner can be tested without a vault at all.
nonisolated struct SecretScanCandidate: Sendable {
    let itemID: UUID
    let itemTitle: String
    let fieldKey: String
    let fieldLabel: String
    let value: String
    let isSensitive: Bool

    init(
        itemID: UUID,
        itemTitle: String,
        fieldKey: String,
        fieldLabel: String,
        value: String,
        isSensitive: Bool
    ) {
        self.itemID = itemID
        self.itemTitle = itemTitle
        self.fieldKey = fieldKey
        self.fieldLabel = fieldLabel
        self.value = value
        self.isSensitive = isSensitive
    }
}
