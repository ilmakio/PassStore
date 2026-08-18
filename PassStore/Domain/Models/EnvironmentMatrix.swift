import Foundation

/// Keys across a workspace's environments: what each one defines, what it is missing, and where
/// the same secret has been used twice.
///
/// The matrix holds **no values**. Every cell carries presence and a digest, never the thing it
/// digests, so comparing environments does not create a second place where secrets are rendered.
/// Reading one still means opening the secret it belongs to.
nonisolated struct EnvironmentMatrix: Sendable {
    struct Column: Identifiable, Sendable {
        let matchKey: String
        let title: String
        let systemImage: String
        let itemCount: Int

        var id: String { matchKey }
    }

    enum Presence: Sendable {
        /// The environment defines this key.
        case set
        /// The environment defines it, with nothing in it. Meaningful in a `.env`: an empty
        /// value is a decision, an absent line is an omission.
        case blank
        case missing
    }

    struct Cell: Identifiable, Sendable {
        let columnKey: String
        let presence: Presence
        /// The secret that defines it, for jumping straight there.
        let itemID: UUID?
        /// More than one secret in the same environment defines this key — the two can disagree,
        /// and one of them is being ignored by whatever reads the file.
        let sourceCount: Int
        /// Digest of the value, used only to tell two environments apart. Never displayed.
        let valueDigest: String?

        var id: String { columnKey }
    }

    struct Row: Identifiable, Sendable {
        let key: String
        let isSensitive: Bool
        let cells: [Cell]
        /// Columns that hold something while this one does not.
        let missingCount: Int
        /// Match keys of the environments that share this key's value with another environment.
        /// Only ever populated for sensitive fields: `PORT=3000` being the same everywhere is
        /// how ports work, whereas one API key in local and production is a finding.
        let sharedSecretColumnKeys: [String]

        var id: String { key }
        var hasSharedSecret: Bool { !sharedSecretColumnKeys.isEmpty }
        var isDefinedTwiceSomewhere: Bool { cells.contains { $0.sourceCount > 1 } }
    }

    let columns: [Column]
    let rows: [Row]

    var keyCount: Int { rows.count }
    var missingCount: Int { rows.reduce(0) { $0 + $1.missingCount } }
    var sharedSecretCount: Int { rows.count(where: \.hasSharedSecret) }
    var isEmpty: Bool { rows.isEmpty || columns.count < 2 }

    /// Rows worth acting on: something is missing somewhere, a secret is shared, or a key is
    /// defined twice in one environment.
    var rowsNeedingAttention: [Row] {
        rows.filter { $0.missingCount > 0 || $0.hasSharedSecret || $0.isDefinedTwiceSomewhere }
    }

    /// One environment and how many keys it is missing that a sibling defines.
    struct MissingEnvironment: Identifiable, Sendable {
        let title: String
        let count: Int

        var id: String { title }
    }

    /// What the comparison amounts to, in the terms a person would use.
    ///
    /// Exists so a surface can *state the finding* — "Staging is missing 3 keys" — instead of
    /// offering a button called "Compare" and leaving the reader to go and look.
    struct Summary: Sendable {
        let keyCount: Int
        let environmentCount: Int
        /// Environments short of at least one key, emptiest first.
        let missing: [MissingEnvironment]
        let sharedSecretCount: Int
        /// Keys that two secrets in the same environment both define.
        let definedTwiceCount: Int

        var hasFindings: Bool {
            !missing.isEmpty || sharedSecretCount > 0 || definedTwiceCount > 0
        }

        /// True when there is not yet enough in the workspace for a comparison to mean anything.
        var isInconclusive: Bool { keyCount == 0 || environmentCount < 2 }
    }

    var summary: Summary {
        var missingByColumn: [String: Int] = [:]
        for row in rows {
            for cell in row.cells where cell.presence == .missing {
                // Only counts where the row itself counted it, so an environment nobody has put
                // anything in yet is not reported as missing every key in the project.
                guard row.missingCount > 0 else { continue }
                missingByColumn[cell.columnKey, default: 0] += 1
            }
        }

        let titlesByKey = Dictionary(columns.map { ($0.matchKey, $0.title) }, uniquingKeysWith: { first, _ in first })
        let missing = missingByColumn
            .compactMap { key, count -> MissingEnvironment? in
                guard let title = titlesByKey[key], count > 0 else { return nil }
                return MissingEnvironment(title: title, count: count)
            }
            .sorted {
                if $0.count != $1.count { return $0.count > $1.count }
                return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
            }

        return Summary(
            keyCount: rows.count,
            environmentCount: columns.count,
            missing: missing,
            sharedSecretCount: sharedSecretCount,
            definedTwiceCount: rows.count(where: \.isDefinedTwiceSomewhere)
        )
    }
}

/// What the matrix is built from: one environment per column, and per column the field keys its
/// secrets define — as digests, never as values.
nonisolated struct EnvironmentMatrixInput: Sendable {
    struct Entry: Sendable {
        let key: String
        let valueDigest: String
        let isBlank: Bool
        let isSensitive: Bool
        let itemID: UUID

        init(key: String, valueDigest: String, isBlank: Bool, isSensitive: Bool, itemID: UUID) {
            self.key = key
            self.valueDigest = valueDigest
            self.isBlank = isBlank
            self.isSensitive = isSensitive
            self.itemID = itemID
        }
    }

    struct Column: Sendable {
        let matchKey: String
        let title: String
        let systemImage: String
        let itemCount: Int
        let entries: [Entry]

        init(matchKey: String, title: String, systemImage: String, itemCount: Int, entries: [Entry]) {
            self.matchKey = matchKey
            self.title = title
            self.systemImage = systemImage
            self.itemCount = itemCount
            self.entries = entries
        }
    }

    let columns: [Column]

    init(columns: [Column]) {
        self.columns = columns
    }
}

extension EnvironmentMatrix {
    /// Builds the comparison.
    ///
    /// Keys are compared case-insensitively but displayed as first written: `.env` files are
    /// conventionally upper case, and a project that has both `API_KEY` and `api_key` has one
    /// key with a typo, not two keys.
    init(_ input: EnvironmentMatrixInput) {
        let columns = input.columns.map {
            Column(matchKey: $0.matchKey, title: $0.title, systemImage: $0.systemImage, itemCount: $0.itemCount)
        }

        // Each column's entries are grouped by normalised key once, up front. Rescanning a
        // column's whole entry list for every row turned the build into keys × columns × entries,
        // with a fresh lowercasing of every key on each pass.
        var entriesByColumn: [String: [String: [EnvironmentMatrixInput.Entry]]] = [:]

        // First appearance, in column order, decides both the display spelling and the row order:
        // the environment listed first is usually the fullest one.
        var displayKeys: [String: String] = [:]
        var order: [String] = []
        for column in input.columns {
            var grouped: [String: [EnvironmentMatrixInput.Entry]] = [:]
            for entry in column.entries {
                let normalized = entry.key.lowercased()
                grouped[normalized, default: []].append(entry)
                if displayKeys[normalized] == nil {
                    displayKeys[normalized] = entry.key
                    order.append(normalized)
                }
            }
            entriesByColumn[column.matchKey] = grouped
        }

        // "Missing" only counts against environments that hold something: a project that has
        // declared Staging and put nothing in it yet is not missing every key. Fixed for the whole
        // matrix, so it is settled once rather than rebuilt for every row.
        let populatedColumnKeys = Set(
            input.columns.filter { !$0.entries.isEmpty }.map(\.matchKey)
        )

        let rows: [Row] = order.map { normalizedKey in
            var cells: [Cell] = []
            var isSensitive = false
            var digestsByColumn: [String: String] = [:]

            for column in input.columns {
                let matches = entriesByColumn[column.matchKey]?[normalizedKey] ?? []
                if matches.contains(where: \.isSensitive) { isSensitive = true }

                guard let first = matches.first else {
                    cells.append(
                        Cell(
                            columnKey: column.matchKey,
                            // An environment with no secrets in it at all is not "missing" this
                            // key; it simply has not been filled in yet.
                            presence: .missing,
                            itemID: nil,
                            sourceCount: 0,
                            valueDigest: nil
                        )
                    )
                    continue
                }
                if !first.isBlank {
                    digestsByColumn[column.matchKey] = first.valueDigest
                }
                cells.append(
                    Cell(
                        columnKey: column.matchKey,
                        presence: first.isBlank ? .blank : .set,
                        itemID: first.itemID,
                        sourceCount: matches.count,
                        valueDigest: first.isBlank ? nil : first.valueDigest
                    )
                )
            }

            let missingCount = cells.count {
                $0.presence == .missing && populatedColumnKeys.contains($0.columnKey)
            }

            var sharedColumnKeys: [String] = []
            if isSensitive {
                let grouped = Dictionary(grouping: digestsByColumn.keys) { digestsByColumn[$0] ?? "" }
                for (_, columnKeys) in grouped where columnKeys.count > 1 {
                    sharedColumnKeys.append(contentsOf: columnKeys)
                }
            }

            return Row(
                key: displayKeys[normalizedKey] ?? normalizedKey,
                isSensitive: isSensitive,
                cells: cells,
                missingCount: missingCount,
                // Sorted so the order does not depend on how a dictionary happened to hash.
                sharedSecretColumnKeys: sharedColumnKeys.sorted()
            )
        }

        self.columns = columns
        self.rows = rows
    }
}
