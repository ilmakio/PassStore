import Foundation

/// The shape of a `.env` file, without its values.
///
/// An item stores its variables as fields, which is what makes them searchable, maskable and
/// individually copyable — and which is also why copying an item back out used to produce a
/// regenerated document: keys sorted by the item's own order, every value quoted, and not one of
/// the comments the owner wrote to explain what the variables are for.
///
/// This keeps everything the fields cannot carry: comments, blank lines, ordering, indentation,
/// `export` prefixes and the quoting each value had. It deliberately holds **no values**. A
/// value lives in exactly one place — the field — so the layout can never become a stale second
/// copy of a secret, and rendering a document means putting the current fields back into the
/// owner's own file.
nonisolated struct EnvDocumentLayout: Codable, Hashable, Sendable {
    /// One physical line of the original file, except for an assignment, which stands for every
    /// line its value spanned.
    enum Line: Codable, Hashable, Sendable {
        /// A comment, a blank line, or anything else that is not an assignment — reproduced
        /// exactly as it was written.
        case text(String)
        case assignment(EnvAssignmentLayout)
    }

    var lines: [Line]
    var capturedAt: Date

    init(lines: [Line], capturedAt: Date = .now) {
        self.lines = lines
        self.capturedAt = capturedAt
    }

    /// Structural cap, checked with the rest of the vault's limits. A layout is bounded by the
    /// 16 MB read limit on the file it came from, but a hand-built or malicious backup is not.
    static let maximumLines = 200_000

    var keys: [String] {
        lines.compactMap {
            switch $0 {
            case .text: nil
            case let .assignment(assignment): assignment.key
            }
        }
    }

    /// True for a layout that says nothing the fields do not already say, so it is not worth
    /// storing: no comments, no blank lines, nothing but plain assignments.
    var isTrivial: Bool {
        lines.allSatisfy {
            switch $0 {
            case let .text(text): text.trimmingCharacters(in: .whitespaces).isEmpty
            case let .assignment(assignment):
                assignment.prefix.isEmpty
                    && assignment.trailingComment.isEmpty
                    && assignment.quote == .none
                    && !assignment.wraps
            }
        }
    }
}

nonisolated struct EnvAssignmentLayout: Codable, Hashable, Sendable {
    /// Indentation and any `export ` that came before the key, reproduced verbatim.
    var prefix: String
    var key: String
    var quote: EnvQuoteStyle
    /// True when the file wrote this value across several physical lines inside its quotes, as a
    /// PEM key usually is.
    var wraps: Bool
    /// A trailing `# comment` after the value.
    var trailingComment: String

    init(prefix: String = "", key: String, quote: EnvQuoteStyle = .none, wraps: Bool = false, trailingComment: String = "") {
        self.prefix = prefix
        self.key = key
        self.quote = quote
        self.wraps = wraps
        self.trailingComment = trailingComment
    }
}

// MARK: - Reading the comments

extension EnvDocumentLayout {
    /// What the file's comments are *about*.
    ///
    /// A `.env` says which comment belongs to which variable by position, and a person reading
    /// the file has no trouble with it. Two rules cover what people actually write:
    ///
    /// - A comment block followed by a blank line introduces everything under it — the banner
    ///   headings that split a long file into sections.
    /// - A comment block sitting directly above one or more assignments belongs to them.
    ///
    /// Getting this wrong costs nothing: it only decides where a comment is displayed. The file
    /// itself is reproduced from `lines`, never from this reading of it.
    struct Outline: Hashable, Sendable {
        struct Group: Hashable, Sendable, Identifiable {
            var id: Int
            /// The comment block above this run of variables, `#` and decoration lines removed.
            var comments: [String]
            var keys: [String]
        }

        struct Section: Hashable, Sendable, Identifiable {
            var id: Int
            /// Empty for whatever comes before the first banner in the file.
            var title: String
            /// The rest of the banner block, when it explains the section rather than naming it.
            var detail: [String]
            var groups: [Group]
        }

        var sections: [Section]
        /// Keyed by variable: the `# note` written after its value.
        var trailingComments: [String: String]

        var isEmpty: Bool { sections.allSatisfy(\.groups.isEmpty) }
    }

    var outline: Outline {
        var sections: [Outline.Section] = []
        var currentSection = Outline.Section(id: 0, title: "", detail: [], groups: [])
        var openGroup: Outline.Group?
        var pendingComments: [String] = []
        var trailingComments: [String: String] = [:]
        var groupCount = 0

        func closeGroup() {
            guard let group = openGroup else { return }
            currentSection.groups.append(group)
            openGroup = nil
        }

        func startSection(title: String, detail: [String]) {
            closeGroup()
            if !currentSection.groups.isEmpty || !currentSection.title.isEmpty {
                sections.append(currentSection)
            }
            currentSection = Outline.Section(id: sections.count, title: title, detail: detail, groups: [])
        }

        for line in lines {
            switch line {
            case let .text(raw):
                let trimmed = raw.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty {
                    // A blank line ends the run below a comment block, which turns that block
                    // into a heading for what follows rather than a note on one variable.
                    if !pendingComments.isEmpty {
                        let readable = pendingComments.filter { !Self.isDecoration($0) }
                        startSection(
                            title: readable.first ?? "",
                            detail: Array(readable.dropFirst())
                        )
                        pendingComments = []
                    }
                    closeGroup()
                } else if let comment = Self.commentBody(trimmed) {
                    closeGroup()
                    pendingComments.append(comment)
                } else {
                    // Something the parser did not recognise. It separates what is above it from
                    // what is below just as a blank line does, but it is not a heading.
                    closeGroup()
                    pendingComments = []
                }
            case let .assignment(assignment):
                if openGroup == nil {
                    openGroup = Outline.Group(
                        id: groupCount,
                        comments: pendingComments.filter { !Self.isDecoration($0) && !$0.isEmpty },
                        keys: []
                    )
                    groupCount += 1
                    pendingComments = []
                }
                openGroup?.keys.append(assignment.key)
                if !assignment.trailingComment.isEmpty,
                   let comment = Self.commentBody(assignment.trailingComment.trimmingCharacters(in: .whitespaces)) {
                    trailingComments[assignment.key] = comment
                }
            }
        }
        closeGroup()
        if !currentSection.groups.isEmpty || !currentSection.title.isEmpty {
            sections.append(currentSection)
        }

        return Outline(sections: sections, trailingComments: trailingComments)
    }

    /// The comment text, or nil when the line is not a comment.
    private static func commentBody(_ trimmedLine: String) -> String? {
        guard trimmedLine.hasPrefix("#") else { return nil }
        return String(trimmedLine.dropFirst()).trimmingCharacters(in: .whitespaces)
    }

    /// `====`, `----`, `####` and friends: a rule drawn across the file, not something to read
    /// back to somebody in a list of notes.
    private static func isDecoration(_ comment: String) -> Bool {
        let stripped = comment.filter { !$0.isWhitespace }
        guard stripped.count >= 3 else { return comment.isEmpty }
        return stripped.allSatisfy { "=-_*#~+.".contains($0) }
    }
}
