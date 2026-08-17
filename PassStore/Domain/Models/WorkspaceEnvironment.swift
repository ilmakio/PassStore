import Foundation

/// One environment a workspace declares: "Local", "Staging", a client's "QA".
///
/// This is organisation metadata, not ownership. The authoritative environment of a secret
/// stays where it has always been — on the item, in `SecretItemEntity.environmentValue` — so a
/// vault written by 1.3 still opens intact in a build that knows nothing about any of this: the
/// declarations are simply ignored and every item keeps its environment.
///
/// A workspace's list therefore answers three questions and no others: which environments the
/// project *has*, in which order they should be offered, and which of them are still current.
nonisolated struct WorkspaceEnvironment: Identifiable, Codable, Hashable, Sendable {
    /// Bounds for untrusted input. A restored backup is attacker-controlled data even once its
    /// password has been accepted, so the list it carries is clamped rather than trusted.
    static let maximumPerWorkspace = 24
    static let maximumNameLength = 64
    static let maximumFileNameLength = 96

    let id: UUID
    /// Display name. For every kind but `.custom` this is the kind's own title, so it always
    /// matches the titles items carry.
    var name: String
    var kindRawValue: String
    /// Nil means "use the colour the kind suggests", so a vault does not have to store a
    /// palette to get a red production chip.
    var colorHex: String?
    /// Whether this environment is offered in the sidebar, the chip bar and new-item defaults.
    ///
    /// It is deliberately **not** a filter on what exists. An environment that still holds
    /// items stays reachable however this is set — see `WorkspaceEnvironment.resolvedList`.
    /// Hiding a credential because of a layout preference would be a way to lose a secret.
    var isEnabled: Bool
    var sortOrder: Int
    /// The `.env` file this environment maps to inside a linked project folder, e.g.
    /// `.env.production`. A suggestion for discovery, never an authority: it is a bare file
    /// name, never a path.
    var envFileName: String?

    init(
        id: UUID = UUID(),
        name: String,
        kind: EnvironmentKind,
        colorHex: String? = nil,
        isEnabled: Bool = true,
        sortOrder: Int = 0,
        envFileName: String? = nil
    ) {
        self.id = id
        self.name = name
        self.kindRawValue = kind.rawValue
        self.colorHex = colorHex
        self.isEnabled = isEnabled
        self.sortOrder = sortOrder
        self.envFileName = envFileName
    }

    /// Every field tolerates absence: this type is decoded from vaults and backups written by
    /// builds that had no idea it existed, and one missing key must never fail the whole vault.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        kindRawValue = try container.decodeIfPresent(String.self, forKey: .kindRawValue)
            ?? EnvironmentKind.custom.rawValue
        colorHex = try container.decodeIfPresent(String.self, forKey: .colorHex)
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        sortOrder = try container.decodeIfPresent(Int.self, forKey: .sortOrder) ?? 0
        envFileName = try container.decodeIfPresent(String.self, forKey: .envFileName)
    }

    var kind: EnvironmentKind {
        get { EnvironmentKind(rawValue: kindRawValue) ?? .custom }
        set { kindRawValue = newValue.rawValue }
    }

    /// The item attribute this declaration corresponds to. Assigning it to an item's
    /// `environmentValue` is what actually puts the item in this environment.
    var environmentValue: EnvironmentValue {
        kind == .custom ? .custom(name) : .preset(kind)
    }

    var title: String { environmentValue.title }

    /// Identity used to line a declaration up with the items that carry it.
    ///
    /// The title is the join key rather than `id`, because an environment can exist without ever
    /// having been declared — an imported 1.2 vault has environments on its items and no
    /// declarations anywhere — and both sides must resolve to the same environment.
    var matchKey: String { Self.matchKey(for: title) }

    static func matchKey(for title: String) -> String {
        title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    var effectiveColorHex: String { colorHex ?? kind.defaultColorHex }

    // MARK: - Building

    /// The declaration that describes an environment an item already carries.
    static func declaration(for value: EnvironmentValue, sortOrder: Int = 0) -> WorkspaceEnvironment {
        WorkspaceEnvironment(
            name: value.title,
            kind: value.kind,
            isEnabled: true,
            sortOrder: sortOrder
        )
    }

    /// Declarations for environments that are in use but were never declared, in lifecycle
    /// order rather than alphabetically: Local, Dev, Staging, Prod reads like a pipeline,
    /// "Dev, Local, Prod, Staging" reads like a filing accident.
    static func derived(fromPresentTitles titles: [String]) -> [WorkspaceEnvironment] {
        let values = canonicallyOrderedValues(from: titles)
        return values.enumerated().map { declaration(for: $0.element, sortOrder: $0.offset) }
    }

    /// Lifecycle rank of a kind, used to order anything that has no explicit order yet.
    static func canonicalRank(of kind: EnvironmentKind) -> Int {
        EnvironmentKind.allCases.firstIndex(of: kind) ?? EnvironmentKind.allCases.count
    }

    /// Turns raw item environment titles into de-duplicated values in lifecycle order.
    static func canonicallyOrderedValues(from titles: [String]) -> [EnvironmentValue] {
        var seen: Set<String> = []
        let values: [EnvironmentValue] = titles.compactMap { title in
            let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(matchKey(for: trimmed)).inserted else { return nil }
            return value(forTitle: trimmed)
        }
        return values.sorted { lhs, rhs in
            let lhsRank = canonicalRank(of: lhs.kind)
            let rhsRank = canonicalRank(of: rhs.kind)
            if lhsRank != rhsRank { return lhsRank < rhsRank }
            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
    }

    /// A title back to the value that produces it. Preset titles win, so "Prod" stays the
    /// preset rather than becoming a custom environment that merely looks like one.
    static func value(forTitle title: String) -> EnvironmentValue {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if let preset = EnvironmentKind.allCases.first(where: {
            $0 != .custom && $0.title.localizedCaseInsensitiveCompare(trimmed) == .orderedSame
        }) {
            return .preset(preset)
        }
        return .custom(trimmed)
    }

    // MARK: - Sanitizing

    /// Clamps a list of declarations before it reaches the vault.
    ///
    /// Applied both to editor input and to anything decoded from a snapshot: presets are forced
    /// back onto their canonical name so they keep matching items, names and file names are
    /// bounded, duplicates collapse, and `sortOrder` is renumbered so the stored order is the
    /// displayed order.
    static func sanitizedList(_ list: [WorkspaceEnvironment]) -> [WorkspaceEnvironment] {
        var seenKeys: Set<String> = []
        var seenIDs: Set<UUID> = []
        var result: [WorkspaceEnvironment] = []

        for candidate in list.sorted(by: { $0.sortOrder < $1.sortOrder }) {
            guard result.count < maximumPerWorkspace else { break }
            guard var sanitized = sanitized(candidate) else { continue }
            guard seenKeys.insert(sanitized.matchKey).inserted else { continue }
            // A duplicate id would make the editor's rename diff ambiguous, so a repeated id
            // is re-issued rather than kept.
            if !seenIDs.insert(sanitized.id).inserted {
                sanitized = WorkspaceEnvironment(
                    name: sanitized.name,
                    kind: sanitized.kind,
                    colorHex: sanitized.colorHex,
                    isEnabled: sanitized.isEnabled,
                    sortOrder: sanitized.sortOrder,
                    envFileName: sanitized.envFileName
                )
                seenIDs.insert(sanitized.id)
            }
            sanitized.sortOrder = result.count
            result.append(sanitized)
        }
        return result
    }

    private static func sanitized(_ environment: WorkspaceEnvironment) -> WorkspaceEnvironment? {
        var result = environment
        let kind = EnvironmentKind(rawValue: environment.kindRawValue) ?? .custom
        result.kindRawValue = kind.rawValue

        if kind == .custom {
            let trimmed = environment.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            result.name = String(trimmed.prefix(maximumNameLength))
        } else {
            // Presets are named by their kind. Letting a preset carry a different name would
            // silently detach it from the items that carry the kind's own title.
            result.name = kind.title
        }

        result.colorHex = sanitizedColorHex(environment.colorHex)
        result.envFileName = sanitizedFileName(environment.envFileName)
        return result
    }

    private static func sanitizedColorHex(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("#"), trimmed.count == 7 else { return nil }
        let digits = trimmed.dropFirst()
        guard digits.allSatisfy(\.isHexDigit) else { return nil }
        return "#\(digits.uppercased())"
    }

    /// Reduces anything to a bare file name.
    ///
    /// This value is later matched against the contents of a folder the owner linked, so it
    /// must not be able to describe a path: `../../.ssh/id_rsa` has to come out as `id_rsa` or
    /// nothing at all, never as a traversal.
    static func sanitizedFileName(_ value: String?) -> String? {
        guard let value else { return nil }
        var trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        trimmed = trimmed.replacingOccurrences(of: "\0", with: "")
        guard !trimmed.isEmpty else { return nil }
        let lastComponent = (trimmed as NSString).lastPathComponent
        guard !lastComponent.isEmpty,
              lastComponent != ".",
              lastComponent != "..",
              !lastComponent.contains("/"),
              !lastComponent.contains("\\") else { return nil }
        return String(lastComponent.prefix(maximumFileNameLength))
    }

    // MARK: - Resolution

    /// What a workspace's environments actually are: everything declared, plus everything its
    /// items already use.
    ///
    /// The union is the whole point. Declarations alone would hide the contents of every vault
    /// written before 1.3, and item titles alone could not express "this project will have a
    /// staging environment" before the first staging secret exists.
    static func resolvedList(
        declared: [WorkspaceEnvironment],
        presentTitles: [String]
    ) -> [ResolvedWorkspaceEnvironment] {
        let declarations = sanitizedList(declared)
        var byKey: [String: WorkspaceEnvironment] = [:]
        for declaration in declarations {
            byKey[declaration.matchKey] = declaration
        }

        let resolvedDeclarations = declarations.map {
            ResolvedWorkspaceEnvironment(declaration: $0, isDeclared: true)
        }

        let undeclared = canonicallyOrderedValues(from: presentTitles)
            .filter { byKey[matchKey(for: $0.title)] == nil }
            .enumerated()
            .map { offset, value in
                ResolvedWorkspaceEnvironment(
                    declaration: declaration(for: value, sortOrder: declarations.count + offset),
                    isDeclared: false
                )
            }

        return resolvedDeclarations + undeclared
    }
}

/// A workspace environment as the UI sees it: either a declaration, or an environment the items
/// are already using without one.
nonisolated struct ResolvedWorkspaceEnvironment: Identifiable, Hashable, Sendable {
    let declaration: WorkspaceEnvironment
    /// False for an environment that exists only because items carry it. Those are still shown
    /// — with a way to adopt them into the project — rather than being quietly dropped.
    let isDeclared: Bool

    /// The title, not the declaration's UUID: an undeclared environment has no stable id, and
    /// navigation has to be able to name either kind.
    var id: String { declaration.matchKey }
    var matchKey: String { declaration.matchKey }
    var title: String { declaration.title }
    var kind: EnvironmentKind { declaration.kind }
    var isEnabled: Bool { declaration.isEnabled }
    var colorHex: String { declaration.effectiveColorHex }
    var envFileName: String? { declaration.envFileName }
    var environmentValue: EnvironmentValue { declaration.environmentValue }
}
