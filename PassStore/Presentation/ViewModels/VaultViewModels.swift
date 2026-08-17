import AppKit
import CryptoKit
import Foundation
import Observation

@MainActor
@Observable
final class VaultViewModel {
    let container: AppContainer

    /// Encrypted payload produced by the export sheet; consumed when the sheet dismisses, then drives `.fileExporter`.
    @ObservationIgnored private var pendingExportData: Data?

    var exportFileDocument: JSONExportDocument?
    var isPresentingExportFileExporter = false

    var importExportSelectedFileName: String?
    @ObservationIgnored private var pendingImportFileData: Data?

    var workspaces: [WorkspaceEntity] = []
    var items: [SecretItemEntity] = []
    var templates: [SecretFieldTemplateEntity] = []

    var selectedDestination: VaultDestination = .library(.allItems)
    var selectedItemID: UUID?
    var multiSelectedIDs: Set<UUID> = []
    /// Stable origin for repeated Shift-clicks. `selectedItemID` follows the active edge of
    /// the range, so using it as the anchor would make each click start a different range.
    @ObservationIgnored private var selectionAnchorID: UUID?
    var searchText = ""
    var selectedType: SecretItemType?
    var activeSheet: VaultSheet?
    var alertMessage: String?
    var isSettingsPresented = false

    /// Set by the sidebar's Delete Workspace action; drives the confirmation alert in `AppView`.
    var workspacePendingDeletion: WorkspaceEntity?
    /// Items awaiting delete confirmation. Deleting a secret is irreversible, so every entry
    /// point (context menu, multi-selection, detail toolbar, palette) funnels through here.
    var itemsPendingDeletion: [SecretItemEntity] = []
    /// Incremented by the Find command; `ItemListView` moves focus to the search field on change.
    var searchFocusRequests = 0

    var isCommandPalettePresented = false
    var commandPaletteQuery = ""
    /// Shared so the View menu and the split view's own toggle drive the same state.
    var isSidebarVisible = true
    /// Cancels installation of async crypto results after lock, dismissal or a newer request.
    @ObservationIgnored private var transientOperationGeneration: UInt64 = 0

    init(container: AppContainer) {
        self.container = container
        let existingLockHandler = container.sessionManager.onLock
        container.sessionManager.onLock = { [weak self] in
            existingLockHandler?()
            self?.clearUnlockedState()
        }
        reload()
        applyUITestLaunchOverrides()
    }

    var selectedItem: SecretItemEntity? {
        items.first(where: { $0.id == selectedItemID })
    }

    var selectedFields: [FieldResolvedValue] {
        guard let selectedItem else { return [] }
        return resolvedFields(for: selectedItem)
    }

    var visibleSelectedFields: [FieldResolvedValue] {
        Self.visibleFields(in: selectedFields)
    }

    var selectedNotes: String? {
        guard let notes = selectedItem?.notes.trimmingCharacters(in: .whitespacesAndNewlines), !notes.isEmpty else {
            return nil
        }
        return notes
    }

    var availableTags: [String] {
        Array(Set(items.flatMap(\.tags))).sorted()
    }

    var availableEnvironments: [String] {
        Array(Set(items.map { $0.environmentValue.title })).sorted()
    }

    var orderedTypes: [SecretItemType] {
        let customOrder = container.settings.sidebarTypesOrder
        if customOrder.isEmpty { return SecretItemType.allCases }
        let mapped = customOrder.compactMap { SecretItemType(rawValue: $0) }
        let remaining = SecretItemType.allCases.filter { !mapped.contains($0) }
        return mapped + remaining
    }

    var orderedTags: [String] {
        let customOrder = container.settings.sidebarTagsOrder
        let current = availableTags
        if customOrder.isEmpty { return current }
        let ordered = customOrder.filter { current.contains($0) }
        let newTags = current.filter { !customOrder.contains($0) }.sorted()
        return ordered + newTags
    }

    var orderedEnvironments: [String] {
        let customOrder = container.settings.sidebarEnvironmentsOrder
        let current = availableEnvironments
        if customOrder.isEmpty { return current }
        let ordered = customOrder.filter { current.contains($0) }
        let newEnvs = current.filter { !customOrder.contains($0) }.sorted()
        return ordered + newEnvs
    }

    func reorderWorkspaces(newIDs: [UUID]) {
        do {
            try container.workspaceRepository.reorderWorkspaces(newIDs)
            reload()
        } catch {
            handleMutationFailure(error)
        }
    }

    func reorderSidebarTags(_ ids: [String]) {
        let previous = container.settings.sidebarTagsOrder
        container.settings.sidebarTagsOrder = ids
        do {
            try container.sessionManager.saveCurrentVault()
        } catch {
            container.settings.sidebarTagsOrder = previous
            handleMutationFailure(error)
        }
    }

    func reorderSidebarEnvironments(_ ids: [String]) {
        let previous = container.settings.sidebarEnvironmentsOrder
        container.settings.sidebarEnvironmentsOrder = ids
        do {
            try container.sessionManager.saveCurrentVault()
        } catch {
            container.settings.sidebarEnvironmentsOrder = previous
            handleMutationFailure(error)
        }
    }

    func requestWorkspaceDeletion(id: UUID) {
        workspacePendingDeletion = workspace(for: id)
    }

    /// Deletes the workspace and un-assigns (never deletes) the items that belonged to it.
    func confirmWorkspaceDeletion() {
        guard let workspace = workspacePendingDeletion else { return }
        workspacePendingDeletion = nil
        // Covers both the workspace itself and any of its environments.
        let wasSelected = selectedDestination.workspaceID == workspace.id
        do {
            try container.workspaceRepository.deleteWorkspace(workspace)
            if wasSelected {
                selectedDestination = .library(.allItems)
            }
            reload()
        } catch {
            handleMutationFailure(error)
        }
    }

    func itemCount(in section: LibrarySection) -> Int {
        items.count { Self.matches(section: section, item: $0) }
    }

    func itemCount(inWorkspace id: UUID) -> Int {
        items.filter { $0.workspace?.id == id && !$0.isArchived }.count
    }

    // MARK: - Workspace environments

    /// One pass over the vault, keyed by workspace and then by environment.
    ///
    /// The sidebar asks for a badge per environment per workspace on every render; filtering the
    /// whole item list once per badge turned that into a quadratic walk of the vault.
    @ObservationIgnored private var environmentCountsCache: (generation: Int, value: [UUID: [String: Int]])?

    private var environmentCounts: [UUID: [String: Int]] {
        if let cached = environmentCountsCache, cached.generation == vaultGeneration {
            return cached.value
        }
        var counts: [UUID: [String: Int]] = [:]
        for item in items where !item.isArchived {
            guard let workspaceID = item.workspace?.id else { continue }
            let key = WorkspaceEnvironment.matchKey(for: item.environmentValue.title)
            counts[workspaceID, default: [:]][key, default: 0] += 1
        }
        environmentCountsCache = (vaultGeneration, counts)
        return counts
    }

    /// Environment titles the workspace's items actually use.
    func presentEnvironmentTitles(inWorkspace id: UUID) -> [String] {
        items
            .filter { $0.workspace?.id == id && !$0.isArchived }
            .map { $0.environmentValue.title }
    }

    /// Every environment of a workspace: what it declares, plus what its items already use.
    func environments(inWorkspace id: UUID) -> [ResolvedWorkspaceEnvironment] {
        guard let workspace = workspace(for: id) else { return [] }
        return WorkspaceEnvironment.resolvedList(
            declared: workspace.environments,
            presentTitles: presentEnvironmentTitles(inWorkspace: id)
        )
    }

    /// The environments the sidebar and the chip bar offer.
    ///
    /// A switched-off environment that still holds items stays in the list. Hiding it would hide
    /// working credentials behind a layout preference, which is not a trade a password manager
    /// gets to make; it is shown as switched off instead.
    func offeredEnvironments(inWorkspace id: UUID) -> [ResolvedWorkspaceEnvironment] {
        environments(inWorkspace: id).filter {
            $0.isEnabled || itemCount(inWorkspace: id, environmentMatchKey: $0.matchKey) > 0
        }
    }

    func itemCount(inWorkspace id: UUID, environmentMatchKey key: String) -> Int {
        environmentCounts[id]?[key] ?? 0
    }

    func itemCount(inWorkspace id: UUID, environmentTitle title: String) -> Int {
        itemCount(inWorkspace: id, environmentMatchKey: WorkspaceEnvironment.matchKey(for: title))
    }

    /// Whether this workspace has enough of an environment structure to be worth expanding.
    ///
    /// One environment is not a structure: a workspace whose secrets all live in the same place
    /// keeps the plain row it had in 1.2 instead of growing a disclosure triangle that reveals a
    /// single child.
    func hasEnvironmentStructure(inWorkspace id: UUID) -> Bool {
        guard let workspace = workspace(for: id) else { return false }
        if !workspace.environments.isEmpty { return true }
        return environments(inWorkspace: id).count > 1
    }

    /// Adopts an environment the items already use into the workspace's declared list.
    func declareEnvironment(_ environment: ResolvedWorkspaceEnvironment, inWorkspace id: UUID) {
        guard let workspace = workspace(for: id) else { return }
        guard !workspace.environments.contains(where: { $0.matchKey == environment.matchKey }) else { return }
        var updated = workspace.environments
        updated.append(
            WorkspaceEnvironment.declaration(
                for: environment.environmentValue,
                sortOrder: updated.count
            )
        )
        applyEnvironments(updated, inWorkspace: id)
    }

    /// Adopts every environment the items use, for a workspace that has declared none.
    func declareEnvironmentsInUse(inWorkspace id: UUID) {
        guard let workspace = workspace(for: id) else { return }
        var updated = workspace.environments
        for environment in environments(inWorkspace: id) where !environment.isDeclared {
            updated.append(
                WorkspaceEnvironment.declaration(
                    for: environment.environmentValue,
                    sortOrder: updated.count
                )
            )
        }
        guard updated.count != workspace.environments.count else { return }
        applyEnvironments(updated, inWorkspace: id)
    }

    func setEnvironmentEnabled(_ isEnabled: Bool, matchKey: String, inWorkspace id: UUID) {
        guard let workspace = workspace(for: id) else { return }
        var updated = workspace.environments
        guard let index = updated.firstIndex(where: { $0.matchKey == matchKey }) else { return }
        updated[index].isEnabled = isEnabled
        applyEnvironments(updated, inWorkspace: id)
    }

    /// Reorders the declared environments to the given match keys. Keys that are not declared
    /// are ignored, so dropping an in-use-but-undeclared row on the list cannot reorder nothing.
    func reorderEnvironments(matchKeys: [String], inWorkspace id: UUID) {
        guard let workspace = workspace(for: id) else { return }
        var remaining = workspace.environments
        var reordered: [WorkspaceEnvironment] = []
        for key in matchKeys {
            guard let index = remaining.firstIndex(where: { $0.matchKey == key }) else { continue }
            reordered.append(remaining.remove(at: index))
        }
        reordered.append(contentsOf: remaining)
        applyEnvironments(reordered, inWorkspace: id)
    }

    /// Removes a declaration. The items stay exactly where they are: the environment simply
    /// stops being one the project claims, and reappears as in-use-but-undeclared if it still
    /// holds anything.
    func undeclareEnvironment(matchKey: String, inWorkspace id: UUID) {
        guard let workspace = workspace(for: id) else { return }
        let updated = workspace.environments.filter { $0.matchKey != matchKey }
        guard updated.count != workspace.environments.count else { return }
        applyEnvironments(updated, inWorkspace: id)
    }

    private func applyEnvironments(_ environments: [WorkspaceEnvironment], inWorkspace id: UUID) {
        do {
            try container.workspaceRepository.setEnvironments(environments, onWorkspaceWithID: id)
            reload()
        } catch {
            handleMutationFailure(error)
        }
    }

    // MARK: - Project folder

    /// What the discovery sheet is working with. Nil when no scan has been run.
    var envDiscovery: EnvDiscoveryState?

    struct EnvDiscoveryState {
        let workspaceID: UUID
        let folderPath: String
        var plans: [EnvFileImportPlan]
        /// True when the walk stopped at its cap, so the sheet can say the list is not
        /// everything rather than implying it is.
        var didReachLimit: Bool
        var isWorking: Bool = false

        var selectedCount: Int { plans.count { $0.isSelected } }
    }

    /// Asks for a folder and links it to the workspace.
    ///
    /// A folder grant reaches everything inside it, so it is deliberately a separate, explicit
    /// act: the panel says what it is for, nothing is scanned until this returns, and
    /// `unlinkProjectFolder` gives the permission back in one click.
    func linkProjectFolder(toWorkspace id: UUID) {
        guard container.sessionManager.lockState == .unlocked else {
            alertMessage = "Unlock the vault before linking a folder."
            return
        }
        guard let workspace = workspace(for: id) else { return }

        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.prompt = "Link Folder"
        panel.message = "Choose the project folder for “\(workspace.name)”. PassStore will be able to read files inside it, and will only look when you ask it to."
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let folder = try container.envDiscovery.makeLink(to: url)
            try container.workspaceRepository.setLinkedFolder(folder, onWorkspaceWithID: id)
            reload()
            lastActionMessage = "Linked \(folder.folderName)."
            Task { await scanProjectFolder(inWorkspace: id, presentingSheet: true) }
        } catch {
            handleMutationFailure(error)
        }
    }

    /// Forgets the folder. Secrets already imported from it keep their own per-file links: they
    /// were given bookmarks of their own precisely so unlinking the folder costs nothing.
    func unlinkProjectFolder(fromWorkspace id: UUID) {
        do {
            try container.workspaceRepository.setLinkedFolder(nil, onWorkspaceWithID: id)
            if envDiscovery?.workspaceID == id { envDiscovery = nil }
            reload()
            lastActionMessage = "Folder unlinked."
        } catch {
            handleMutationFailure(error)
        }
    }

    /// Looks for `.env` files in the linked folder. Only ever runs from an explicit action —
    /// never at unlock, and never on a timer.
    func scanProjectFolder(inWorkspace id: UUID, presentingSheet: Bool = false) async {
        guard container.sessionManager.lockState == .unlocked,
              let folder = workspace(for: id)?.linkedFolder else { return }

        let service = container.envDiscovery
        let linkedPaths = Set(
            items.compactMap { $0.linkedFile?.displayPath }
                .filter { !$0.isEmpty }
                .map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
        )
        let sessionGeneration = container.sessionManager.captureSecurityGeneration()

        do {
            let result = try await Task.detached(priority: .userInitiated) {
                try service.discover(in: folder, alreadyLinkedPaths: linkedPaths)
            }.value
            guard container.sessionManager.isSecurityGenerationCurrent(sessionGeneration),
                  let current = workspace(for: id) else { return }

            // A moved folder renews its own bookmark; record it so the next scan still works.
            if result.refreshedBookmark != nil || current.linkedFolder?.lastScannedAt == nil {
                var updated = current.linkedFolder ?? folder
                updated.bookmark = result.refreshedBookmark ?? updated.bookmark
                if result.refreshedBookmark != nil { updated.displayPath = result.resolvedPath }
                updated.lastScannedAt = .now
                try? container.workspaceRepository.setLinkedFolder(updated, onWorkspaceWithID: id)
            } else {
                var updated = current.linkedFolder
                updated?.lastScannedAt = .now
                if let updated {
                    try? container.workspaceRepository.setLinkedFolder(updated, onWorkspaceWithID: id)
                }
            }
            reload()

            let declared = environments(inWorkspace: id)
            envDiscovery = EnvDiscoveryState(
                workspaceID: id,
                folderPath: result.resolvedPath,
                plans: result.files.map { file in
                    EnvFileImportPlan(
                        file: file,
                        // Templates and files already mirrored are listed but not pre-selected:
                        // an example file holds no secrets, and importing the same file twice
                        // makes two records that disagree the moment one is edited.
                        isSelected: !file.isTemplate && !file.isAlreadyLinked,
                        environment: Self.environment(
                            matching: file.suggestedEnvironment,
                            declaredIn: declared
                        ),
                        parsesIntoFields: true
                    )
                },
                didReachLimit: result.didReachLimit
            )
            if presentingSheet {
                activeSheet = .envDiscovery(id)
            }
            if result.files.isEmpty {
                lastActionMessage = "No .env files found in \(result.resolvedPath.isEmpty ? "that folder" : (result.resolvedPath as NSString).lastPathComponent)."
            }
        } catch {
            guard container.sessionManager.isSecurityGenerationCurrent(sessionGeneration) else { return }
            alertMessage = error.localizedDescription
        }
    }

    /// Prefers an environment the project already knows about over a new one with the same name,
    /// so `.env.production` lands in the declared "Production" rather than creating "Prod".
    private static func environment(
        matching suggestion: EnvironmentValue,
        declaredIn environments: [ResolvedWorkspaceEnvironment]
    ) -> EnvironmentValue {
        let key = WorkspaceEnvironment.matchKey(for: suggestion.title)
        if let existing = environments.first(where: { $0.matchKey == key }) {
            return existing.environmentValue
        }
        if suggestion.kind != .custom,
           let sameKind = environments.first(where: { $0.kind == suggestion.kind }) {
            return sameKind.environmentValue
        }
        return suggestion
    }

    func setEnvDiscoverySelection(_ isSelected: Bool, forFileID id: String) {
        guard let index = envDiscovery?.plans.firstIndex(where: { $0.id == id }) else { return }
        envDiscovery?.plans[index].isSelected = isSelected
    }

    func setEnvDiscoveryEnvironment(_ environment: EnvironmentValue, forFileID id: String) {
        guard let index = envDiscovery?.plans.firstIndex(where: { $0.id == id }) else { return }
        envDiscovery?.plans[index].environment = environment
    }

    func setEnvDiscoveryParsing(_ parsesIntoFields: Bool, forFileID id: String) {
        guard let index = envDiscovery?.plans.firstIndex(where: { $0.id == id }) else { return }
        envDiscovery?.plans[index].parsesIntoFields = parsesIntoFields
    }

    /// Imports the files the owner ticked, one secret each, linked to the file it came from.
    func importDiscoveredEnvFiles() async {
        guard container.sessionManager.lockState == .unlocked,
              let state = envDiscovery,
              let workspace = workspace(for: state.workspaceID),
              let folder = workspace.linkedFolder else { return }
        let selected = state.plans.filter(\.isSelected)
        guard !selected.isEmpty else { return }

        envDiscovery?.isWorking = true
        defer { envDiscovery?.isWorking = false }

        let service = container.envDiscovery
        let sessionGeneration = container.sessionManager.captureSecurityGeneration()
        var imported = 0
        var failures: [String] = []

        for plan in selected {
            let relativePath = plan.file.relativePath
            let parsesIntoFields = plan.parsesIntoFields
            do {
                let prepared = try await Task.detached(priority: .userInitiated) {
                    try service.prepare(
                        relativePath: relativePath,
                        in: folder,
                        parsedIntoFields: parsesIntoFields
                    )
                }.value
                guard container.sessionManager.isSecurityGenerationCurrent(sessionGeneration) else { return }

                var draft = buildEnvImportDraft(
                    from: prepared.contents,
                    suggestedTitle: Self.importedTitle(for: plan.file),
                    parseIntoEntries: parsesIntoFields
                )
                draft.workspaceID = state.workspaceID
                draft.environment = plan.environment
                let saved = try container.itemRepository.saveItem(draft)

                // Linked in a second pass, the same way a hand-picked file is: the vault-side
                // digest can only be taken once the item exists.
                var link = prepared.fileLink
                link.syncedDigest = LinkedFileService.digest(prepared.contents)
                link.syncedVaultDigest = LinkedFileService.digest(envContents(for: saved))
                link.syncedAt = .now
                link.requiresInitialSync = false
                var linkDraft = makeDraft(from: saved)
                linkDraft.linkedFile = link
                _ = try container.itemRepository.saveItem(linkDraft)
                linkedFileStatuses[saved.id] = .upToDate
                imported += 1
            } catch {
                failures.append(plan.file.fileName)
            }
        }

        reload()
        envDiscovery = nil
        if imported > 0 {
            lastActionMessage = failures.isEmpty
                ? "Imported \(imported) \(imported == 1 ? "file" : "files") from \(folder.folderName)."
                : "Imported \(imported) of \(selected.count). Could not read: \(failures.joined(separator: ", "))."
        } else if !failures.isEmpty {
            alertMessage = "None of the selected files could be read: \(failures.joined(separator: ", "))."
        }
    }

    /// "Acme API — .env.production" rather than five secrets all called ".env".
    private static func importedTitle(for file: DiscoveredEnvFile) -> String {
        let directory = (file.relativePath as NSString).deletingLastPathComponent
        guard !directory.isEmpty else { return file.fileName }
        return "\(directory)/\(file.fileName)"
    }

    // MARK: - Workspace overview

    /// Secrets in this workspace that mirror a file on disk.
    func linkedFileCount(inWorkspace id: UUID) -> Int {
        items.count { $0.workspace?.id == id && !$0.isArchived && $0.linkedFile != nil }
    }

    /// Of those, the ones whose file and vault copy have drifted apart.
    func outdatedLinkedFileCount(inWorkspace id: UUID) -> Int {
        let outdated = Set(itemsWithOutdatedLinks)
        return items.count { $0.workspace?.id == id && !$0.isArchived && outdated.contains($0.id) }
    }

    func lastUpdatedAt(inWorkspace id: UUID) -> Date? {
        items
            .filter { $0.workspace?.id == id && !$0.isArchived }
            .map(\.updatedAt)
            .max()
    }

    /// Environments the items use that the project has not claimed — what the overview offers
    /// to adopt in one gesture.
    func undeclaredEnvironments(inWorkspace id: UUID) -> [ResolvedWorkspaceEnvironment] {
        environments(inWorkspace: id).filter { !$0.isDeclared }
    }

    // MARK: - Environment comparison

    /// Builds the key-by-environment comparison for one workspace.
    ///
    /// Values are digested here and never leave this function: what the matrix carries is
    /// presence and sameness, which is enough to answer "what is missing in production?" and
    /// "am I using the same key in local?" without putting a secret on screen.
    func environmentMatrix(inWorkspace id: UUID) -> EnvironmentMatrix {
        let offered = offeredEnvironments(inWorkspace: id)
        let columns: [EnvironmentMatrixInput.Column] = offered.map { environment in
            let environmentItems = items.filter {
                $0.workspace?.id == id
                    && !$0.isArchived
                    && WorkspaceEnvironment.matchKey(for: $0.environmentValue.title) == environment.matchKey
            }
            let entries: [EnvironmentMatrixInput.Entry] = environmentItems.flatMap { item in
                resolvedFields(for: item).map { field in
                    EnvironmentMatrixInput.Entry(
                        key: field.key,
                        valueDigest: Self.digest(field.value),
                        isBlank: field.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                        isSensitive: field.isSensitive,
                        itemID: item.id
                    )
                }
            }
            return EnvironmentMatrixInput.Column(
                matchKey: environment.matchKey,
                title: environment.title,
                colorHex: environment.colorHex,
                itemCount: environmentItems.count,
                entries: entries
            )
        }
        return EnvironmentMatrix(EnvironmentMatrixInput(columns: columns))
    }

    /// True when there is more than one environment holding something — the only case where a
    /// comparison has anything to say.
    func canCompareEnvironments(inWorkspace id: UUID) -> Bool {
        offeredEnvironments(inWorkspace: id).count(where: {
            itemCount(inWorkspace: id, environmentMatchKey: $0.matchKey) > 0
        }) > 1
    }

    /// Opens the secret behind one cell of the matrix.
    func revealMatrixCell(itemID: UUID) {
        guard let item = items.first(where: { $0.id == itemID }) else { return }
        activeSheet = nil
        revealAndSelectItemFromPalette(item)
    }

    // MARK: - Environment bar

    /// The workspace whose environments the item list should offer as tabs, or nil when the
    /// current destination is not a project view. A workspace with nothing to divide gets no bar.
    var environmentBarWorkspaceID: UUID? {
        guard let id = selectedDestination.workspaceID,
              hasEnvironmentStructure(inWorkspace: id) else { return nil }
        return id
    }

    var environmentBarItems: [ResolvedWorkspaceEnvironment] {
        guard let id = environmentBarWorkspaceID else { return [] }
        return offeredEnvironments(inWorkspace: id)
    }

    /// Nil means the workspace as a whole — the "All" tab.
    var selectedEnvironmentMatchKey: String? {
        guard case let .workspaceEnvironment(_, environment) = selectedDestination else { return nil }
        return WorkspaceEnvironment.matchKey(for: environment)
    }

    /// Switches tab. Passing nil goes back to the whole workspace.
    func selectEnvironment(matchKey: String?) {
        guard let id = selectedDestination.workspaceID else { return }
        guard let matchKey,
              let environment = environments(inWorkspace: id).first(where: { $0.matchKey == matchKey }) else {
            selectDestination(.workspace(id))
            return
        }
        selectDestination(.workspaceEnvironment(id, environment.title))
    }

    /// Moves along the bar, wrapping. "All" is part of the cycle: it is where you go to see the
    /// whole project again.
    func cycleEnvironment(by offset: Int) {
        guard let id = environmentBarWorkspaceID else { return }
        let keys: [String?] = [nil] + environmentBarItems.map { $0.matchKey }
        guard keys.count > 1 else { return }
        let current = keys.firstIndex(of: selectedEnvironmentMatchKey) ?? 0
        let next = (current + offset % keys.count + keys.count) % keys.count
        selectEnvironment(matchKey: keys[next])
    }

    func requestSearchFocus() {
        searchFocusRequests += 1
    }

    /// Moves the list selection by `offset` within the currently filtered items (keyboard navigation).
    func moveSelection(by offset: Int) {
        let visible = filteredItems
        guard !visible.isEmpty else { return }
        guard let current = selectedItemID, let index = visible.firstIndex(where: { $0.id == current }) else {
            select(visible.first)
            return
        }
        let next = min(max(index + offset, 0), visible.count - 1)
        // At the edge of the list an arrow press still collapses a multi-selection back to a
        // single row, rather than appearing to do nothing.
        guard next != index || isMultiSelecting else { return }
        select(visible[next])
    }

    var builtInTemplates: [SecretFieldTemplateEntity] {
        templates
            .filter(\.isBuiltIn)
            .sorted(by: templateSortComparator)
    }

    var customTemplates: [SecretFieldTemplateEntity] {
        templates
            .filter { !$0.isBuiltIn }
            .sorted(by: templateSortComparator)
    }

    var featuredTemplates: [SecretFieldTemplateEntity] {
        builtInTemplates.filter { [.generic, .websiteService].contains($0.itemType) }
    }

    var standardBuiltInTemplates: [SecretFieldTemplateEntity] {
        builtInTemplates.filter { ![.generic, .websiteService].contains($0.itemType) }
    }

    // MARK: - Filtered list (memoised)

    /// Identity of one filtered-list result. When this is unchanged, so is the list.
    private struct FilterFingerprint: Equatable {
        let destination: VaultDestination
        let type: SecretItemType?
        let query: String
        let sortOrder: ItemSortOrder
        let generation: Int
    }

    /// Bumped by `reload()`; every mutation path funnels through it.
    @ObservationIgnored private var vaultGeneration = 0
    @ObservationIgnored private var filteredCache: (key: FilterFingerprint, value: [SecretItemEntity])?

    /// The list the middle column shows.
    ///
    /// Memoised because it is read many times per render — the list body, the selection bar,
    /// selection syncing and keyboard navigation all ask for it — and each miss was two
    /// passes plus a sort over the whole vault.
    var filteredItems: [SecretItemEntity] {
        // Touch `items` so SwiftUI still registers the dependency on a cache hit.
        let all = items
        let key = FilterFingerprint(
            destination: selectedDestination,
            type: selectedType,
            query: searchText.trimmingCharacters(in: .whitespacesAndNewlines),
            sortOrder: sortOrder,
            generation: vaultGeneration
        )
        if let cached = filteredCache, cached.key == key {
            return cached.value
        }
        let result = all
            .filter(matchesDestination)
            .filter(matchesSearchAndType)
            .sorted(by: sortComparator)
        filteredCache = (key, result)
        return result
    }

    var sortOrder: ItemSortOrder {
        get { container.settings.itemSortOrder }
        set { container.settings.itemSortOrder = newValue }
    }

    var destinationTitle: String {
        switch selectedDestination {
        case let .library(section):
            section.title
        case let .workspace(id):
            workspace(for: id)?.name ?? "Workspace"
        case let .workspaceEnvironment(id, environment):
            workspace(for: id).map { "\($0.name) › \(environment)" } ?? environment
        case let .tag(tag):
            "#\(tag)"
        case let .environment(environment):
            environment
        }
    }

    var hasActiveFilters: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || selectedType != nil
    }

    func clearFilters() {
        searchText = ""
        setSelectedType(nil)
    }

    /// Shown when the vault has items but this particular destination is empty.
    var emptyDestinationHint: String {
        switch selectedDestination {
        case .library(.allItems):
            "Every item in your vault is archived."
        case .library(.favorites):
            "Star an item to pin it here for quick access."
        case .library(.recent):
            "Items you create or edit will show up here."
        case .library(.archived):
            "Nothing is archived. Archived items stay recoverable."
        case .workspace:
            "This workspace has no items yet."
        case let .workspaceEnvironment(_, environment):
            "Nothing in \(environment) yet. Add a secret here, or copy one over from another environment."
        case .tag:
            "No items carry this tag anymore."
        case .environment:
            "No items target this environment anymore."
        }
    }

    var destinationSystemImage: String {
        switch selectedDestination {
        case let .library(section):
            section.systemImage
        case let .workspace(id):
            workspace(for: id)?.icon ?? "folder"
        case let .workspaceEnvironment(id, _):
            workspace(for: id)?.icon ?? "circle.hexagongrid"
        case .tag:
            "tag"
        case .environment:
            "circle.hexagongrid"
        }
    }

    func reload() {
        do {
            vaultGeneration &+= 1
            filteredCache = nil
            workspaces = try container.workspaceRepository.fetchAll(includeArchived: false)
            items = try container.itemRepository.fetchAll(includeArchived: true)
            templates = try container.templateRepository.fetchAll()
            normalizeSelection()
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    /// Repository transactions restore the memory store from a snapshot when persistence
    /// fails. That rebuilds the entity graph, so every UI reference must be refreshed before
    /// the error is shown; otherwise later edits can target detached, stale objects.
    private func handleMutationFailure(_ error: Error) {
        reload()
        alertMessage = error.localizedDescription
    }

    /// Invalidates the filtered-list cache without re-reading the store.
    ///
    /// Used by mutations that change an entity in place (favourite, last-used) where a full
    /// `reload()` would be pure waste.
    private func invalidateFilteredCache() {
        vaultGeneration &+= 1
        filteredCache = nil
    }

    /// Removes every reference that can carry vault plaintext outside the memory store.
    ///
    /// This runs directly from the session lock callback, so it also covers a closed main
    /// window, system sleep and resets initiated from the lock screen.
    func clearUnlockedState() {
        transientOperationGeneration &+= 1
        isWorking = false
        pendingExportData = nil
        exportFileDocument = nil
        isPresentingExportFileExporter = false
        pendingImportFileData = nil
        importExportSelectedFileName = nil
        stagedImport = nil
        importPreview = nil
        undoStep = nil

        workspaces = []
        items = []
        templates = []
        selectedDestination = .library(.allItems)
        selectedItemID = nil
        multiSelectedIDs.removeAll()
        selectionAnchorID = nil
        searchText = ""
        selectedType = nil
        activeSheet = nil
        alertMessage = nil
        isSettingsPresented = false
        workspacePendingDeletion = nil
        itemsPendingDeletion = []
        isCommandPalettePresented = false
        commandPaletteQuery = ""
        itemsWithOutdatedLinks = []
        linkedFileStatuses = [:]
        linkedStatusRefreshGeneration &+= 1
        statusMessageDismissal?.cancel()
        statusMessageDismissal = nil
        lastActionMessage = nil
        invalidateFilteredCache()
    }

    func dismissCommandPalette() {
        isCommandPalettePresented = false
        commandPaletteQuery = ""
    }

    func presentCommandPalette() {
        guard container.sessionManager.lockState == .unlocked else { return }
        commandPaletteQuery = ""
        isCommandPalettePresented = true
    }

    /// Switches destination so the item appears in the list, then selects it (palette / quick open).
    func revealAndSelectItemFromPalette(_ item: SecretItemEntity) {
        searchText = ""
        selectedType = nil
        if item.isArchived {
            selectDestination(.library(.archived))
        } else if let workspaceID = item.workspace?.id {
            selectDestination(.workspace(workspaceID))
        } else {
            selectDestination(.library(.allItems))
        }
        if !filteredItems.contains(where: { $0.id == item.id }) {
            selectDestination(.library(item.isArchived ? .archived : .allItems))
        }
        select(item)
    }

    func selectDestination(_ destination: VaultDestination) {
        selectedDestination = destination
        multiSelectedIDs.removeAll()
        selectionAnchorID = nil
        syncSelectedItem()
    }

    /// Updates the sidebar type filter and keeps the list selection consistent with `filteredItems`.
    func setSelectedType(_ type: SecretItemType?) {
        selectedType = type
        syncSelectedItem()
    }

    /// Selects a row and stamps "last used".
    ///
    /// The stamp used to trigger a synchronous full-vault re-encrypt plus a complete
    /// `reload()` — every entity in the vault rebuilt — on every click. The repository now
    /// coalesces the write, and the entity is observable, so nothing has to be reloaded.
    func select(_ item: SecretItemEntity?) {
        multiSelectedIDs.removeAll()
        selectedItemID = item?.id
        selectionAnchorID = item?.id
        guard let item else { return }
        try? container.itemRepository.recordItemAccess(item)
        // Deliberately no cache invalidation: under a last-used sort, re-ordering the list
        // under the pointer on every click would make it impossible to work down a list.
        // The new order lands on the next natural refresh.
    }

    // MARK: - Multi-selection

    /// Everything currently highlighted, whether that is one row or many.
    ///
    /// Read-only: the list draws its own selection rather than handing the job to AppKit, so
    /// nothing writes a selection set back in. Clicks go through `select`, `toggleMultiSelect`
    /// and `extendSelection`.
    var listSelection: Set<UUID> {
        if !multiSelectedIDs.isEmpty { return multiSelectedIDs }
        return selectedItemID.map { [$0] } ?? []
    }

    func isSelected(_ item: SecretItemEntity) -> Bool {
        listSelection.contains(item.id)
    }

    /// The field a one-click copy should reach for.
    ///
    /// Prefers a password, then any other secret, then the first copyable value — which is
    /// what "copy this item" means for the .env and connection-string types that have no
    /// password at all.
    func primaryCopyField(for item: SecretItemEntity) -> FieldResolvedValue? {
        let fields = Self.visibleFields(in: resolvedFields(for: item)).filter(\.isCopyable)
        if let password = fields.first(where: {
            SecretFieldClassification.isPasswordLike(key: $0.key, label: $0.label)
        }) {
            return password
        }
        return fields.first(where: \.isSensitive) ?? fields.first
    }

    var isMultiSelecting: Bool { !multiSelectedIDs.isEmpty }

    var multiSelectedItems: [SecretItemEntity] {
        filteredItems.filter { multiSelectedIDs.contains($0.id) }
    }

    /// ⇧-click: selects everything between the current anchor and `item`.
    ///
    /// The list draws and handles its own selection, so the range behaviour a Mac list is
    /// expected to have has to be implemented rather than inherited.
    func extendSelection(to item: SecretItemEntity) {
        let visible = filteredItems
        guard let targetIndex = visible.firstIndex(where: { $0.id == item.id }) else { return }

        let anchorID = selectionAnchorID ?? selectedItemID ?? multiSelectedIDs.first
        guard let anchorID, let anchorIndex = visible.firstIndex(where: { $0.id == anchorID }) else {
            select(item)
            return
        }

        let range = anchorIndex <= targetIndex ? anchorIndex...targetIndex : targetIndex...anchorIndex
        multiSelectedIDs = Set(visible[range].map(\.id))
        selectedItemID = item.id
    }

    /// ⌘-click: adds or removes one row.
    ///
    /// Seeded from whatever is highlighted rather than from `multiSelectedIDs` alone. With a
    /// single row selected that set is empty, so ⌘-clicking a second row used to drop the
    /// first one and start a new selection from the row just clicked.
    func toggleMultiSelect(_ item: SecretItemEntity) {
        var selection = multiSelectedIDs.isEmpty ? listSelection : multiSelectedIDs

        if selection.contains(item.id) {
            selection.remove(item.id)
        } else {
            selection.insert(item.id)
        }
        multiSelectedIDs = selection

        if selection.isEmpty {
            selectedItemID = nil
            selectionAnchorID = nil
        } else if selection.contains(item.id) {
            // The row just added becomes the anchor for a following ⇧-click.
            selectedItemID = item.id
            selectionAnchorID = item.id
        } else if let current = selectedItemID, !selection.contains(current) {
            selectedItemID = filteredItems.first { selection.contains($0.id) }?.id
            selectionAnchorID = selectedItemID
        } else if selectionAnchorID == item.id {
            selectionAnchorID = selectedItemID
        }
    }

    func selectAll() {
        multiSelectedIDs = Set(filteredItems.map(\.id))
        selectedItemID = filteredItems.first?.id
        selectionAnchorID = selectedItemID
    }

    /// Drops the whole selection — used by Escape and by the selection bar's dismiss button,
    /// which should both leave nothing highlighted.
    func clearMultiSelection() {
        multiSelectedIDs.removeAll()
        selectedItemID = nil
        selectionAnchorID = nil
    }

    func bulkAddFavorite() {
        do {
            try container.memoryStore.performTransaction {
                for item in multiSelectedItems where !item.isFavorite {
                    var draft = makeDraft(from: item)
                    draft.isFavorite = true
                    try container.itemRepository.saveItem(draft)
                }
            }
            reload()
        } catch {
            handleMutationFailure(error)
        }
    }

    func bulkRemoveFavorite() {
        do {
            try container.memoryStore.performTransaction {
                for item in multiSelectedItems where item.isFavorite {
                    var draft = makeDraft(from: item)
                    draft.isFavorite = false
                    try container.itemRepository.saveItem(draft)
                }
            }
            reload()
        } catch {
            handleMutationFailure(error)
        }
    }

    func bulkCopyEnv() {
        let selected = multiSelectedItems
        guard !selected.isEmpty else { return }
        let parts = selected.map { item in
            let fields = Self.visibleFields(in: resolvedFields(for: item))
            return CopyFormatter.envString(for: item, fields: fields)
        }
        let combined = parts.joined(separator: "\n\n")
        let hasSensitive = selected.contains { item in
            Self.visibleFields(in: resolvedFields(for: item)).contains(where: \.isSensitive)
        }
        maybeWarnForSensitiveCopy(isSensitive: hasSensitive)
        container.clipboard.copy(combined, label: ".env")
    }

    func bulkCopyJSON() {
        let selected = multiSelectedItems
        guard !selected.isEmpty else { return }
        var allPayloads: [String: Any] = [:]
        var hasSensitive = false
        for item in selected {
            let fields = Self.visibleFields(in: resolvedFields(for: item))
            if fields.contains(where: \.isSensitive) { hasSensitive = true }
            // Two items can share a title, so disambiguate instead of letting the last one win.
            var key = item.title
            var suffix = 2
            while allPayloads[key] != nil {
                key = "\(item.title) (\(suffix))"
                suffix += 1
            }
            allPayloads[key] = CopyFormatter.keyedValues(fields)
        }
        guard let data = try? JSONSerialization.data(withJSONObject: allPayloads, options: [.prettyPrinted, .sortedKeys]) else { return }
        let json = String(decoding: data, as: UTF8.self)
        maybeWarnForSensitiveCopy(isSensitive: hasSensitive)
        container.clipboard.copy(json, label: "JSON")
    }

    func bulkDuplicate() {
        do {
            try container.memoryStore.performTransaction {
                for item in multiSelectedItems {
                    _ = try container.itemRepository.duplicateItem(item)
                }
            }
            reload()
            multiSelectedIDs.removeAll()
        } catch {
            handleMutationFailure(error)
        }
    }

    /// Archives every selected item with a single reload; the per-item path would otherwise
    /// re-fetch the vault and retarget the sidebar destination once per item.
    func bulkArchive() {
        let selected = multiSelectedItems
        guard !selected.isEmpty else { return }
        do {
            try container.memoryStore.performTransaction {
                for item in selected {
                    var draft = makeDraft(from: item)
                    draft.id = item.id
                    draft.isArchived = true
                    try container.itemRepository.saveItem(draft)
                }
            }
            multiSelectedIDs.removeAll()
            selectedItemID = nil
            selectedDestination = .library(.archived)
            reload()
        } catch {
            handleMutationFailure(error)
        }
    }

    // MARK: - Bulk edit

    /// Applies one set of edits across the whole multi-selection.
    ///
    /// Every item goes through the normal `saveItem` path, so each one gets its own audit
    /// entries and the same normalization a single-item edit would get.
    func applyBulkEdit(_ draft: BulkEditDraft) {
        let targets = multiSelectedItems
        guard !targets.isEmpty, draft.hasChanges else { return }

        let removals = Set(draft.tagsToRemove.map { $0.lowercased() })
        var didArchive = false

        do {
            try container.memoryStore.performTransaction {
                for item in targets {
                    var itemDraft = makeDraft(from: item)
                    itemDraft.id = item.id

                    var tags = itemDraft.tags.filter { !removals.contains($0.lowercased()) }
                    tags.append(contentsOf: draft.tagsToAdd)
                    itemDraft.tags = tags

                    switch draft.workspaceAction {
                    case .keep: break
                    case .clear: itemDraft.workspaceID = nil
                    case let .move(id): itemDraft.workspaceID = id
                    }

                    if case let .set(environment) = draft.environmentAction {
                        itemDraft.environment = environment
                    }

                    switch draft.favoriteAction {
                    case .keep: break
                    case .enable: itemDraft.isFavorite = true
                    case .disable: itemDraft.isFavorite = false
                    }

                    switch draft.archiveAction {
                    case .keep: break
                    case .enable:
                        itemDraft.isArchived = true
                        didArchive = true
                    case .disable:
                        itemDraft.isArchived = false
                    }

                    try container.itemRepository.saveItem(itemDraft)
                }
            }
            // Edited items can drop out of the current destination (archived, moved, retagged),
            // so the stale selection is cleared rather than left pointing at rows that vanished.
            multiSelectedIDs.removeAll()
            selectedItemID = nil
            if didArchive {
                selectedDestination = .library(.archived)
            }
            reload()
        } catch {
            handleMutationFailure(error)
        }
    }

    /// Tags shared by every selected item — the ones a bulk "remove" can meaningfully offer.
    var commonTagsInMultiSelection: [String] {
        let selected = multiSelectedItems
        guard let first = selected.first else { return [] }
        var shared = Set(first.tags.map { $0.lowercased() })
        for item in selected.dropFirst() {
            shared.formIntersection(item.tags.map { $0.lowercased() })
        }
        return Array(Set(selected.flatMap(\.tags)).filter { shared.contains($0.lowercased()) }).sorted()
    }

    func saveItem(_ draft: SecretItemDraft) {
        _ = saveItemReturningResult(draft)
    }

    @discardableResult
    private func saveItemReturningResult(_ draft: SecretItemDraft) -> SecretItemEntity? {
        do {
            let item = try container.itemRepository.saveItem(draft)
            reload()
            selectedItemID = item.id
            selectionAnchorID = item.id
            return items.first(where: { $0.id == item.id }) ?? item
        } catch {
            handleMutationFailure(error)
            return nil
        }
    }

    func saveWorkspace(_ draft: WorkspaceDraft) {
        _ = createWorkspace(draft)
    }

    @discardableResult
    func createWorkspace(_ draft: WorkspaceDraft) -> WorkspaceEntity? {
        do {
            // Renaming a declared environment has to take its items with it, or the old name
            // would survive as an undeclared environment and the list would appear to have
            // split in two. Both halves go in one transaction: a failure rolls the rename back
            // rather than leaving the items behind.
            let renames = environmentRenames(in: draft)
            let workspace = try container.memoryStore.performTransaction { () -> WorkspaceEntity in
                let saved = try container.workspaceRepository.saveWorkspace(draft)
                if !renames.isEmpty {
                    try migrateItems(inWorkspaceWithID: saved.id, applying: renames)
                }
                return saved
            }
            reload()
            return workspace
        } catch {
            handleMutationFailure(error)
            return nil
        }
    }

    /// Declarations the draft keeps by id but renames, as the environment values to move from
    /// and to. Matched on the declaration's id: that is the only thing that survives a rename.
    private func environmentRenames(in draft: WorkspaceDraft) -> [(from: EnvironmentValue, to: EnvironmentValue)] {
        guard let id = draft.id, let workspace = workspace(for: id) else { return [] }
        let updated = WorkspaceEnvironment.sanitizedList(draft.environments)
        let existingByID = Dictionary(
            workspace.environments.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        return updated.compactMap { environment in
            guard let previous = existingByID[environment.id],
                  previous.matchKey != environment.matchKey else { return nil }
            return (from: previous.environmentValue, to: environment.environmentValue)
        }
    }

    /// Moves every item of one workspace from one environment to another, through the normal
    /// item save path so each one gets its own audit entry.
    private func migrateItems(
        inWorkspaceWithID id: UUID,
        applying renames: [(from: EnvironmentValue, to: EnvironmentValue)]
    ) throws {
        for rename in renames {
            let sourceKey = WorkspaceEnvironment.matchKey(for: rename.from.title)
            let targets = items.filter {
                $0.workspace?.id == id
                    && WorkspaceEnvironment.matchKey(for: $0.environmentValue.title) == sourceKey
            }
            for item in targets {
                var itemDraft = makeDraft(from: item)
                itemDraft.id = item.id
                itemDraft.environment = rename.to
                try container.itemRepository.saveItem(itemDraft)
            }
        }
    }

    @discardableResult
    func saveTemplate(_ draft: TemplateDraft) -> SecretFieldTemplateEntity? {
        do {
            let template = try container.templateRepository.saveTemplate(draft, isBuiltIn: false)
            reload()
            return template
        } catch {
            handleMutationFailure(error)
            return nil
        }
    }

    func deleteTemplate(_ template: SecretFieldTemplateEntity) {
        do {
            try container.templateRepository.deleteTemplate(template)
            reload()
        } catch {
            handleMutationFailure(error)
        }
    }

    func duplicateSelectedItem() {
        guard let selectedItem else { return }
        duplicate(selectedItem)
    }

    func archiveSelectedItem() {
        guard let selectedItem else { return }
        archive(selectedItem)
    }

    func restoreSelectedItem() {
        guard let selectedItem else { return }
        restore(selectedItem)
    }

    func edit(_ item: SecretItemEntity) {
        selectedItemID = item.id
        selectionAnchorID = item.id
        activeSheet = .editItem(item.id)
    }

    func duplicate(_ item: SecretItemEntity) {
        do {
            let copy = try container.itemRepository.duplicateItem(item)
            reload()
            selectedItemID = copy.id
            selectionAnchorID = copy.id
        } catch {
            handleMutationFailure(error)
        }
    }

    func toggleFavorite(for item: SecretItemEntity) {
        var draft = makeDraft(from: item)
        draft.isFavorite.toggle()
        saveItem(draft)
    }

    func toggleFavoriteForSelectedItem() {
        guard let selectedItem else { return }
        toggleFavorite(for: selectedItem)
    }

    func archive(_ item: SecretItemEntity) {
        updateArchiveState(for: item, isArchived: true)
    }

    func restore(_ item: SecretItemEntity) {
        updateArchiveState(for: item, isArchived: false)
    }

    // MARK: - Deletion confirmation

    func requestDeletion(of items: [SecretItemEntity]) {
        guard !items.isEmpty else { return }
        itemsPendingDeletion = items
    }

    func requestDeletion(of item: SecretItemEntity) {
        requestDeletion(of: [item])
    }

    func requestDeletionOfSelectedItem() {
        guard let selectedItem else { return }
        requestDeletion(of: selectedItem)
    }

    func requestDeletionOfMultiSelection() {
        requestDeletion(of: multiSelectedItems)
    }

    func cancelItemDeletion() {
        itemsPendingDeletion = []
    }

    func confirmItemDeletion() {
        let targets = itemsPendingDeletion
        guard !targets.isEmpty else { return }
        let deletedIDs = Set(targets.map(\.id))
        do {
            try container.memoryStore.performTransaction {
                for item in targets {
                    try container.itemRepository.deleteItem(item)
                }
            }
            itemsPendingDeletion = []
            multiSelectedIDs.subtract(deletedIDs)
            if let selectedItemID, deletedIDs.contains(selectedItemID) {
                self.selectedItemID = nil
            }
            reload()
        } catch {
            handleMutationFailure(error)
        }
    }

    var itemDeletionTitle: String {
        switch itemsPendingDeletion.count {
        case 0: "Delete item?"
        case 1: "Delete “\(itemsPendingDeletion[0].title)”?"
        default: "Delete \(itemsPendingDeletion.count) items?"
        }
    }

    var itemDeletionConfirmLabel: String {
        itemsPendingDeletion.count > 1 ? "Delete \(itemsPendingDeletion.count) Items" : "Delete"
    }

    var itemDeletionMessage: String {
        let secretCount = itemsPendingDeletion.reduce(0) { total, item in
            total + Self.visibleFields(in: resolvedFields(for: item)).filter(\.isSensitive).count
        }
        let base = itemsPendingDeletion.count > 1
            ? "These items and all their fields will be permanently deleted."
            : "This item and all its fields will be permanently deleted."
        guard secretCount > 0 else { return "\(base) This cannot be undone." }
        let noun = secretCount == 1 ? "stored secret" : "stored secrets"
        return "\(base) That includes \(secretCount) \(noun). This cannot be undone — consider archiving instead."
    }

    // MARK: - Vault health

    /// Audits stored secrets for weak, reused and stale entries.
    /// Findings deliberately carry only item titles and field labels — never secret values —
    /// so the report itself is safe to show, screenshot, or read aloud.
    ///
    /// Findings the owner dismissed are moved to `ignoredFindings` rather than dropped, so the
    /// sheet can still say how many are hidden and offer to bring them back.
    func vaultHealthReport() -> VaultHealthReport {
        let active = items.filter { !$0.isArchived }
        var findings: [VaultHealthFinding] = []

        // Group sensitive values to spot reuse. Hashed so plaintext never lands in the report.
        var occurrencesByDigest: [String: [(item: SecretItemEntity, key: String, label: String)]] = [:]

        for item in active {
            let fields = Self.visibleFields(in: resolvedFields(for: item))
            for field in fields where field.isSensitive {
                let digest = Self.digest(field.value)
                occurrencesByDigest[digest, default: []].append((item, field.key, field.label))

                let strength = PasswordStrength.evaluate(field.value)
                if strength.needsAttention {
                    findings.append(
                        VaultHealthFinding(
                            id: "weak-\(item.id.uuidString)-\(field.key)",
                            kind: .weak,
                            itemID: item.id,
                            itemTitle: item.title,
                            detail: "\(field.label) — \(strength.label.lowercased())",
                            fieldKey: field.key,
                            valueDigest: digest
                        )
                    )
                }
            }
        }

        for (digest, occurrences) in occurrencesByDigest {
            let distinctItems = Set(occurrences.map(\.item.id))
            guard distinctItems.count > 1 else { continue }
            for occurrence in occurrences {
                // Identity, not title, distinguishes the current item. Two records can share
                // a title, and one record can contain the same secret in multiple fields.
                let othersByID = Dictionary(
                    occurrences
                        .filter { $0.item.id != occurrence.item.id }
                        .map { ($0.item.id, $0.item.title) },
                    uniquingKeysWith: { first, _ in first }
                )
                let others = othersByID.values.sorted()
                findings.append(
                    VaultHealthFinding(
                        id: "reused-\(occurrence.item.id.uuidString)-\(occurrence.key)",
                        kind: .reused,
                        itemID: occurrence.item.id,
                        itemTitle: occurrence.item.title,
                        detail: "\(occurrence.label) — also used in \(others.joined(separator: ", "))",
                        fieldKey: occurrence.key,
                        valueDigest: digest
                    )
                )
            }
        }

        let staleCutoff = Date().addingTimeInterval(-Self.staleItemInterval)
        for item in active {
            // Dated from the password's own rotation when history knows it, so editing a
            // title no longer makes a years-old credential look freshly reviewed.
            let reference = item.healthReferenceDate
            guard reference < staleCutoff else { continue }
            let months = Int(Date().timeIntervalSince(reference) / (30 * 24 * 3600))
            let detail = item.passwordLastChangedAt == nil
                ? "Not updated in about \(months) months"
                : "Password not rotated in about \(months) months"
            findings.append(
                VaultHealthFinding(
                    id: "stale-\(item.id.uuidString)",
                    kind: .stale,
                    itemID: item.id,
                    itemTitle: item.title,
                    detail: detail,
                    referenceDate: reference
                )
            )
        }

        let ignoresByItem = Dictionary(active.map { ($0.id, $0.ignoredHealthIssues) }, uniquingKeysWith: { first, _ in first })
        let isSilenced = { (finding: VaultHealthFinding) in
            (ignoresByItem[finding.itemID] ?? []).contains { finding.isSilenced(by: $0) }
        }

        let sorter: (VaultHealthFinding, VaultHealthFinding) -> Bool = {
            if $0.kind != $1.kind { return $0.kind.severity < $1.kind.severity }
            return $0.itemTitle.localizedCaseInsensitiveCompare($1.itemTitle) == .orderedAscending
        }

        return VaultHealthReport(
            auditedItemCount: active.count,
            findings: findings.filter { !isSilenced($0) }.sorted(by: sorter),
            ignoredFindings: findings.filter(isSilenced).sorted(by: sorter)
        )
    }

    /// Dismisses a finding for the value that produced it. Rotating that secret makes the
    /// finding come back on its own.
    func ignoreHealthFinding(_ finding: VaultHealthFinding) {
        guard let item = items.first(where: { $0.id == finding.itemID }) else { return }
        let record = finding.ignoreRecord
        guard !item.ignoredHealthIssues.contains(where: { $0.id == record.id }) else { return }
        persistIgnoredHealthIssues {
            item.ignoredHealthIssues.append(record)
        }
    }

    func restoreIgnoredFinding(_ finding: VaultHealthFinding) {
        guard let item = items.first(where: { $0.id == finding.itemID }) else { return }
        persistIgnoredHealthIssues {
            item.ignoredHealthIssues.removeAll { finding.isSilenced(by: $0) }
        }
    }

    func restoreAllIgnoredFindings() {
        persistIgnoredHealthIssues {
            for item in items where !item.ignoredHealthIssues.isEmpty {
                item.ignoredHealthIssues = []
            }
        }
    }

    /// Writes the vault directly: dismissals live on the item but are not an edit to it, so
    /// they must not bump `updatedAt` or land in the audit trail.
    private func persistIgnoredHealthIssues(_ mutation: () -> Void) {
        do {
            try container.memoryStore.performTransaction {
                mutation()
                try container.memoryStore.persist()
            }
        } catch {
            reload()
            alertMessage = error.localizedDescription
        }
    }

    /// Items untouched for a year are surfaced as worth rotating or retiring.
    private static let staleItemInterval: TimeInterval = 365 * 24 * 3600

    /// Must stay the same function the repository uses to prune dismissals — a mismatch
    /// would make every ignore look orphaned and get swept away on the next save.
    private static func digest(_ value: String) -> String {
        SecretItemRepository.digest(value)
    }

    // MARK: - Linked .env files
    //
    // A `.env` is not a one-off import: it changes, and re-importing it by hand meant
    // find file → copy → paste → save, every time. An item now remembers the file it came
    // from and can pull the latest contents in one click — or push its contents back out.

    /// Last computed states are retained for badges; file access itself always runs off-main.
    private(set) var linkedFileStatuses: [UUID: LinkedFileStatus] = [:]
    @ObservationIgnored private var linkedStatusRefreshGeneration: UInt64 = 0

    /// Both sides are digested at the last successful sync, so a change can be attributed to
    /// the file, to the vault, or to both. A stale bookmark is renewed and persisted here.
    func linkedFileStatus(for item: SecretItemEntity) async -> LinkedFileStatus {
        guard let link = item.linkedFile else {
            linkedFileStatuses[item.id] = .unlinked
            return .unlinked
        }
        let itemID = item.id
        let sessionGeneration = container.sessionManager.captureSecurityGeneration()
        let service = container.linkedFiles
        do {
            let result = try await Task.detached(priority: .utility) {
                try service.read(link)
            }.value
            guard container.sessionManager.isSecurityGenerationCurrent(sessionGeneration),
                  let current = items.first(where: { $0.id == itemID }),
                  var currentLink = current.linkedFile,
                  currentLink.bookmark == link.bookmark,
                  currentLink.parsedIntoFields == link.parsedIntoFields else { return .unavailable }

            if let refreshed = result.refreshedBookmark {
                let previousLink = current.linkedFile
                currentLink.bookmark = refreshed
                currentLink.displayPath = result.resolvedPath
                current.linkedFile = currentLink
                do {
                    try container.memoryStore.persist()
                } catch {
                    current.linkedFile = previousLink
                    throw error
                }
            }

            let status: LinkedFileStatus
            if currentLink.requiresInitialSync {
                status = .needsInitialSync
            } else {
                let fileDigest = LinkedFileService.digest(result.contents)
                let vaultDigest = LinkedFileService.digest(envContents(for: current))
                let fileMoved = currentLink.syncedDigest != nil && currentLink.syncedDigest != fileDigest
                let vaultMoved = currentLink.syncedVaultDigest != nil && currentLink.syncedVaultDigest != vaultDigest
                switch (fileMoved, vaultMoved) {
                case (false, false): status = .upToDate
                case (true, false): status = .fileChanged
                case (false, true): status = .vaultChanged
                case (true, true): status = .diverged
                }
            }
            linkedFileStatuses[itemID] = status
            return status
        } catch {
            guard container.sessionManager.isSecurityGenerationCurrent(sessionGeneration) else { return .unavailable }
            linkedFileStatuses[itemID] = .unavailable
            return .unavailable
        }
    }

    /// The `.env` text this item currently represents.
    func envContents(for item: SecretItemEntity) -> String {
        // Empty values and intentional leading/trailing spaces are meaningful in .env files.
        // UI visibility filtering must never decide what is written back to disk.
        let fields = resolvedFields(for: item)
        if item.linkedFile?.parsedIntoFields == false, let blob = fields.first(where: { $0.key == "env" }) {
            return blob.value
        }
        return CopyFormatter.envFileContents(fields: fields)
    }

    /// Pulls the current file contents into the item.
    @discardableResult
    func updateItemFromLinkedFile(_ item: SecretItemEntity) async -> Bool {
        guard let link = item.linkedFile else {
            alertMessage = LinkedFileError.noLink.localizedDescription
            return false
        }
        let itemID = item.id
        let sessionGeneration = container.sessionManager.captureSecurityGeneration()
        let service = container.linkedFiles
        var replacedUndoStep: UndoStep?
        var didReplaceUndoStep = false
        do {
            let result = try await Task.detached(priority: .userInitiated) {
                try service.read(link)
            }.value
            guard container.sessionManager.isSecurityGenerationCurrent(sessionGeneration),
                  let current = items.first(where: { $0.id == itemID }),
                  current.linkedFile?.bookmark == link.bookmark,
                  current.linkedFile?.parsedIntoFields == link.parsedIntoFields else { return false }
            // A pull rewrites every field, so it gets the same undo cover as a bulk edit.
            replacedUndoStep = undoStep
            didReplaceUndoStep = true
            captureUndo("Update from file")

            var draft = makeDraft(from: current)
            draft.id = current.id
            applyEnvImportContent(
                to: &draft,
                raw: result.contents,
                parseIntoEntries: link.parsedIntoFields,
                suggestedTitle: nil
            )

            var updatedLink = link
            updatedLink.bookmark = result.refreshedBookmark ?? link.bookmark
            if result.refreshedBookmark != nil { updatedLink.displayPath = result.resolvedPath }
            updatedLink.syncedDigest = LinkedFileService.digest(result.contents)
            updatedLink.syncedAt = .now
            updatedLink.requiresInitialSync = false
            draft.linkedFile = updatedLink

            let savedID = try container.memoryStore.performTransaction {
                let saved = try container.itemRepository.saveItem(draft)
                // Digest the result rather than the draft: normalisation can change it.
                updatedLink.syncedVaultDigest = LinkedFileService.digest(envContents(for: saved))
                saved.linkedFile = updatedLink
                try container.memoryStore.persist()
                return saved.id
            }

            reload()
            selectedItemID = savedID
            selectionAnchorID = savedID
            linkedFileStatuses[savedID] = .upToDate
            let savedTitle = items.first(where: { $0.id == savedID })?.title ?? current.title
            lastActionMessage = "Updated “\(savedTitle)” from \(link.fileName)."
            return true
        } catch {
            // Lock/reset clears the undo snapshot and presentation state. A late file-read
            // failure must not restore either from this suspended operation.
            guard container.sessionManager.isSecurityGenerationCurrent(sessionGeneration) else {
                return false
            }
            if didReplaceUndoStep { undoStep = replacedUndoStep }
            handleMutationFailure(error)
            return false
        }
    }

    /// Writes the item's contents back over the linked file.
    @discardableResult
    func writeLinkedFile(from item: SecretItemEntity, allowingFileChanges: Bool = false) async -> Bool {
        guard let link = item.linkedFile else {
            alertMessage = LinkedFileError.noLink.localizedDescription
            return false
        }
        let itemID = item.id
        let sessionGeneration = container.sessionManager.captureSecurityGeneration()
        let service = container.linkedFiles

        // Update the file in place rather than regenerating it. Writing `envContents` over the
        // top replaced the whole document, so every comment, blank line and untracked variable
        // in the owner's `.env` disappeared the first time they pressed Write.
        let vaultContents = envContents(for: item)
        let contents: String
        if link.parsedIntoFields, let existing = try? await Task.detached(priority: .userInitiated, operation: {
            try service.read(link).contents
        }).value {
            contents = CopyFormatter.envFileByUpdating(existing, with: resolvedFields(for: item))
        } else {
            contents = vaultContents
        }
        let contentsDigest = LinkedFileService.digest(contents)
        let vaultDigest = LinkedFileService.digest(vaultContents)
        var didWriteFile = false
        do {
            let writeResult = try await Task.detached(priority: .userInitiated) { () -> LinkedFileService.WriteResult in
                guard allowingFileChanges || link.syncedDigest != nil else {
                    throw LinkedFileError.fileChangedBeforeWrite
                }
                return try service.write(
                    contents,
                    to: link,
                    requiringCurrentDigest: allowingFileChanges ? nil : link.syncedDigest
                )
            }.value
            didWriteFile = true
            guard container.sessionManager.isSecurityGenerationCurrent(sessionGeneration) else {
                return false
            }
            guard let current = items.first(where: { $0.id == itemID }),
                  current.linkedFile == link else {
                alertMessage = "The file was written, but this item's link changed while the write was in progress. Review both versions before writing again."
                return false
            }
            let currentVaultDigest = LinkedFileService.digest(envContents(for: current))
            var updatedLink = current.linkedFile ?? link
            updatedLink.bookmark = writeResult.refreshedBookmark ?? link.bookmark
            if writeResult.refreshedBookmark != nil { updatedLink.displayPath = writeResult.resolvedPath }
            // The two digests are no longer the same string: the file keeps its comments and
            // untracked variables, so what landed on disk is not what the item alone renders.
            updatedLink.syncedDigest = contentsDigest
            // The exact vault state written, not necessarily the current one: an edit can
            // complete while the file operation is suspended off-main.
            updatedLink.syncedVaultDigest = vaultDigest
            updatedLink.syncedAt = .now
            updatedLink.requiresInitialSync = false
            let previousLink = current.linkedFile
            current.linkedFile = updatedLink
            do {
                try container.memoryStore.persist()
            } catch {
                current.linkedFile = previousLink
                throw error
            }
            invalidateFilteredCache()
            linkedFileStatuses[itemID] = currentVaultDigest == contentsDigest ? .upToDate : .vaultChanged
            lastActionMessage = "Wrote \(link.fileName)."
            return true
        } catch {
            guard container.sessionManager.isSecurityGenerationCurrent(sessionGeneration) else {
                return false
            }
            handleMutationFailure(error)
            if didWriteFile {
                alertMessage = "The file was written, but PassStore could not save its sync state (\(error.localizedDescription)). Review both versions before writing again."
            }
            return false
        }
    }

    /// Attaches a file to an item, or replaces the existing link.
    func linkFile(
        at url: URL,
        to item: SecretItemEntity,
        parsedIntoFields: Bool,
        acceptCurrentContentsAsSynced: Bool = false
    ) async {
        let itemID = item.id
        let originalLink = item.linkedFile
        let sessionGeneration = container.sessionManager.captureSecurityGeneration()
        let service = container.linkedFiles
        do {
            let pair = try await Task.detached(priority: .userInitiated) { () -> (LinkedFileReference, LinkedFileService.ReadResult) in
                let link = try service.makeLink(to: url, parsedIntoFields: parsedIntoFields)
                return (link, try service.read(link))
            }.value
            guard container.sessionManager.isSecurityGenerationCurrent(sessionGeneration) else { return }
            guard let current = items.first(where: { $0.id == itemID }) else { return }
            guard current.linkedFile == originalLink else {
                alertMessage = "This item's file link changed while PassStore was opening the selected file. Choose the file again if you still want to replace the link."
                return
            }
            var link = pair.0
            link.bookmark = pair.1.refreshedBookmark ?? link.bookmark
            if pair.1.refreshedBookmark != nil { link.displayPath = pair.1.resolvedPath }
            link.syncedDigest = LinkedFileService.digest(pair.1.contents)
            link.syncedVaultDigest = LinkedFileService.digest(envContents(for: current))
            link.syncedAt = .now
            link.requiresInitialSync = !acceptCurrentContentsAsSynced
                && link.syncedDigest != link.syncedVaultDigest
            var draft = makeDraft(from: current)
            draft.linkedFile = link
            _ = try container.itemRepository.saveItem(draft)
            reload()
            invalidateFilteredCache()
            linkedFileStatuses[itemID] = link.requiresInitialSync ? .needsInitialSync : .upToDate
            lastActionMessage = "Linked to \(link.fileName)."
        } catch {
            guard container.sessionManager.isSecurityGenerationCurrent(sessionGeneration) else { return }
            handleMutationFailure(error)
        }
    }

    func unlinkFile(from item: SecretItemEntity) {
        do {
            var draft = makeDraft(from: item)
            draft.linkedFile = nil
            _ = try container.itemRepository.saveItem(draft)
            reload()
            linkedFileStatuses[item.id] = .unlinked
            invalidateFilteredCache()
        } catch {
            handleMutationFailure(error)
        }
    }

    /// Opens a picker and links the chosen file. `showsHiddenFiles` matters: `.env` is hidden.
    func chooseLinkedFile(for item: SecretItemEntity, parsedIntoFields: Bool) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.canChooseDirectories = false
        panel.prompt = "Link"
        panel.message = "Choose the .env file this item mirrors."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await linkFile(at: url, to: item, parsedIntoFields: parsedIntoFields) }
    }

    /// Items whose linked file changed on disk. Recomputed when the window regains focus.
    private(set) var itemsWithOutdatedLinks: [UUID] = []

    /// Rechecks every linked file. Called when the window comes forward, so a `.env` edited
    /// in an editor shows up as "changed" without any polling.
    func refreshLinkedFileStatuses() async {
        guard container.settings.checksLinkedFilesOnFocus,
              container.sessionManager.lockState == .unlocked else { return }
        linkedStatusRefreshGeneration &+= 1
        let refreshGeneration = linkedStatusRefreshGeneration
        let sessionGeneration = container.sessionManager.captureSecurityGeneration()
        var outdated: [UUID] = []
        for item in items where item.linkedFile != nil {
            let status = await linkedFileStatus(for: item)
            if status == .fileChanged || status == .diverged || status == .needsInitialSync {
                outdated.append(item.id)
            }
        }
        guard refreshGeneration == linkedStatusRefreshGeneration,
              container.sessionManager.isSecurityGenerationCurrent(sessionGeneration) else { return }
        itemsWithOutdatedLinks = outdated
    }

    var outdatedLinkedFileCount: Int { itemsWithOutdatedLinks.count }

    // MARK: - Secret value history

    /// Fields on this item that have at least one recorded previous value.
    func fieldsWithHistory(for item: SecretItemEntity) -> [FieldResolvedValue] {
        resolvedFields(for: item).filter { !$0.previousValues.isEmpty }
    }

    var isValueHistoryEnabled: Bool {
        container.settings.keepsSecretValueHistory
    }

    func copyPreviousValue(_ version: SecretValueVersion, label: String) {
        maybeWarnForSensitiveCopy(isSensitive: true)
        container.clipboard.copy(version.value, label: "\(label) (previous)")
    }

    /// Puts an old value back into the field. The value being replaced is itself pushed onto
    /// the history, so restoring is reversible too.
    func restorePreviousValue(_ version: SecretValueVersion, fieldKey: String, in item: SecretItemEntity) {
        var draft = makeDraft(from: item)
        draft.id = item.id
        guard let index = draft.fieldDrafts.firstIndex(where: { $0.key == fieldKey }) else { return }
        guard draft.fieldDrafts[index].value != version.value else { return }
        let previousUndo = undoStep
        captureUndo("Value restore")
        draft.fieldDrafts[index].value = version.value
        guard saveItemReturningResult(draft) != nil else {
            undoStep = previousUndo
            return
        }
        lastActionMessage = "Restored the previous value of “\(draft.fieldDrafts[index].label)”."
    }

    func purgeValueHistory(for item: SecretItemEntity) {
        let previousUndo = undoStep
        do {
            captureUndo("History purge")
            try container.itemRepository.purgeValueHistory(for: item)
            reload()
            lastActionMessage = "Previous values for “\(item.title)” deleted."
        } catch {
            undoStep = previousUndo
            handleMutationFailure(error)
        }
    }

    func purgeAllValueHistory() {
        let previousUndo = undoStep
        do {
            captureUndo("History purge")
            try container.itemRepository.purgeAllValueHistory()
            reload()
            lastActionMessage = "All stored previous values deleted."
        } catch {
            undoStep = previousUndo
            handleMutationFailure(error)
        }
    }

    /// How many previous values are stored across the whole vault — shown in Settings so the
    /// trade-off is visible rather than implicit.
    var storedPreviousValueCount: Int {
        items.reduce(0) { total, item in
            total + item.fields.reduce(0) { $0 + $1.previousValues.count }
        }
    }

    func selectItem(id: UUID) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        revealAndSelectItemFromPalette(item)
    }

    func openFieldURL(_ field: FieldResolvedValue) {
        guard let url = FieldURLSupport.url(from: field.value) else {
            alertMessage = "“\(field.label)” doesn't contain a web address that can be opened."
            return
        }
        NSWorkspace.shared.open(url)
    }

    func copyGeneratedPassword(_ password: String) {
        guard !password.isEmpty else { return }
        maybeWarnForSensitiveCopy(isSensitive: true)
        container.clipboard.copy(password, label: "Generated password")
    }

    func copyField(_ field: FieldResolvedValue) {
        maybeWarnForSensitiveCopy(isSensitive: field.isSensitive)
        container.clipboard.copy(field.value, label: field.label)
    }

    /// Palette actions retain only stable identifiers. Resolving at invocation time avoids
    /// keeping entity graphs and a second plaintext field value alive after the vault locks.
    func copyField(itemID: UUID, fieldID: UUID) {
        guard container.sessionManager.lockState == .unlocked,
              let item = items.first(where: { $0.id == itemID }),
              let field = resolvedFields(for: item).first(where: { $0.id == fieldID }) else { return }
        copyField(field)
    }

    /// Copies the selected item's password, or its first secret when it has no password.
    ///
    /// The commonest thing anyone does in this app had no shortcut at all.
    func copyPrimaryFieldOfSelectedItem() {
        guard let selectedItem, let field = primaryCopyField(for: selectedItem) else { return }
        copyField(field)
        lastActionMessage = "Copied \(field.label) from “\(selectedItem.title)”."
    }

    func updateSelectedItemFromLinkedFile() {
        guard let selectedItem else { return }
        Task { await updateItemFromLinkedFile(selectedItem) }
    }

    func copyEnv() {
        guard let selectedItem else { return }
        copyEnv(for: selectedItem)
    }

    func copyJSON() {
        guard let selectedItem else { return }
        copyJSON(for: selectedItem)
    }

    func copyConnectionString() {
        guard let selectedItem else { return }
        copyConnectionString(for: selectedItem)
    }

    func copyEnv(for item: SecretItemEntity) {
        let fields = Self.visibleFields(in: resolvedFields(for: item))
        maybeWarnForSensitiveCopy(isSensitive: fields.contains(where: \.isSensitive))
        container.clipboard.copy(CopyFormatter.envString(for: item, fields: fields), label: ".env")
    }

    func copyJSON(for item: SecretItemEntity) {
        let fields = Self.visibleFields(in: resolvedFields(for: item))
        guard let json = try? CopyFormatter.jsonString(for: item, fields: fields) else { return }
        maybeWarnForSensitiveCopy(isSensitive: fields.contains(where: \.isSensitive))
        container.clipboard.copy(json, label: "JSON")
    }

    func copyConnectionString(for item: SecretItemEntity) {
        let fields = Self.visibleFields(in: resolvedFields(for: item))
        guard let value = try? CopyFormatter.databaseConnectionString(for: item, fields: fields) else { return }
        maybeWarnForSensitiveCopy(isSensitive: fields.contains(where: \.isSensitive))
        container.clipboard.copy(value, label: "Connection String")
    }

    // MARK: - Undo

    /// One reversible step: the whole vault as it was, plus what the action was called.
    private struct UndoStep {
        let snapshot: VaultSnapshot
        let settings: ExportedSettingsPayload
        let label: String
    }

    /// Single-level undo for actions that destroy or rewrite data in bulk.
    ///
    /// Snapshots are cheap relative to the operations they guard (delete, bulk edit,
    /// restore-from-backup), and one level is enough to cover "that wasn't what I meant"
    /// without turning the vault into a document store.
    @ObservationIgnored private var undoStep: UndoStep?

    var undoActionLabel: String? {
        guard container.sessionManager.lockState == .unlocked else { return nil }
        return undoStep?.label
    }

    /// Captures the current vault before a destructive action.
    private func captureUndo(_ label: String) {
        guard container.sessionManager.lockState == .unlocked else { return }
        undoStep = UndoStep(
            snapshot: container.memoryStore.makeSnapshot(),
            settings: container.settings.makeSettingsSnapshot(),
            label: label
        )
    }

    func undoLastDestructiveAction() {
        guard container.sessionManager.lockState == .unlocked, let step = undoStep else { return }
        let currentSnapshot = container.memoryStore.makeSnapshot()
        let currentSettings = container.settings.makeSettingsSnapshot()
        undoStep = nil
        do {
            try container.memoryStore.replaceContents(with: step.snapshot)
            container.settings.applySettings(from: step.settings)
            try container.sessionManager.syncBiometricPreferenceIfUnlocked()
            reload()
            lastActionMessage = "Undid \(step.label.lowercased())."
        } catch {
            let operationError = error
            do {
                try container.memoryStore.replaceContents(with: currentSnapshot)
                container.settings.applySettings(from: currentSettings)
                try container.sessionManager.syncBiometricPreferenceIfUnlocked()
                undoStep = step
                reload()
                alertMessage = operationError.localizedDescription
            } catch {
                undoStep = step
                reload()
                alertMessage = "Undo failed (\(operationError.localizedDescription)) and PassStore could not fully restore the running vault (\(error.localizedDescription)). Lock and reopen the vault before making more changes."
            }
        }
    }

    @discardableResult
    func exportSelectedItems(password: String, confirmation: String) async -> Bool {
        guard container.sessionManager.lockState == .unlocked else {
            alertMessage = TransferError.missingPassword.localizedDescription
            return false
        }
        guard !password.isEmpty else {
            alertMessage = TransferError.missingPassword.localizedDescription
            return false
        }
        guard password.count >= VaultSessionManager.minimumPasswordLength else {
            alertMessage = TransferError.exportPasswordTooShort(
                VaultSessionManager.minimumPasswordLength
            ).localizedDescription
            return false
        }
        guard password == confirmation else {
            alertMessage = TransferError.exportPasswordMismatch.localizedDescription
            return false
        }
        let operation = beginTransientOperation()
        let securityGeneration = container.sessionManager.captureSecurityGeneration()
        isWorking = true
        defer { finishTransientOperation(operation) }
        do {
            // Wrapping the export key is a full Argon2id pass; on the main actor it froze
            // the sheet for about a second with no indication anything was happening. Do not
            // snapshot plaintext until that suspension point has completed and the vault is
            // confirmed to still be unlocked.
            var material = try await container.exportService.prepareFullBackup(password: password)
            defer { material.securelyClear() }
            guard isTransientOperationCurrent(operation),
                  container.sessionManager.isSecurityGenerationCurrent(securityGeneration),
                  !Task.isCancelled else {
                return false
            }
            let backup = ExportedBackupPayload(
                vault: container.memoryStore.makeSnapshot(),
                settings: container.settings.makeSettingsSnapshot()
            )
            let data = try container.exportService.finishFullBackupSynchronously(
                backup: backup,
                material: material
            )
            pendingExportData = data
            return true
        } catch {
            guard isTransientOperationCurrent(operation),
                  container.sessionManager.isSecurityGenerationCurrent(securityGeneration) else { return false }
            alertMessage = error.localizedDescription
            return false
        }
    }

    /// True while a long crypto operation is running, so sheets can show a spinner.
    var isWorking = false

    /// Run after the export SwiftUI sheet dismisses; presents the system save UI via SwiftUI `fileExporter` (works with App Sandbox write entitlement).
    func completeExportAfterSheetDismissed() {
        guard let data = pendingExportData else { return }
        pendingExportData = nil
        exportFileDocument = JSONExportDocument(data: data)
        isPresentingExportFileExporter = true
    }

    func handleExportFileCompletion(_ result: Result<URL, Error>) {
        exportFileDocument = nil
        isPresentingExportFileExporter = false
        if case let .failure(error) = result {
            let ns = error as NSError
            if ns.domain == NSCocoaErrorDomain, ns.code == NSUserCancelledError { return }
            alertMessage = error.localizedDescription
        }
    }

    func applyImportFilePickerResult(_ result: Result<[URL], Error>) {
        switch result {
        case let .failure(error):
            let ns = error as NSError
            if ns.domain == NSCocoaErrorDomain, ns.code == NSUserCancelledError { return }
            alertMessage = error.localizedDescription
        case let .success(urls):
            guard let url = urls.first else { return }
            let operation = beginTransientOperation()
            let securityGeneration = container.sessionManager.captureSecurityGeneration()
            isWorking = true
            // A newly selected file invalidates any decrypted preview from the previous
            // selection. Otherwise a failed read could leave the old payload available to
            // `applyStagedImport`, despite the picker showing a different filename.
            stagedImport = nil
            importPreview = nil
            pendingImportFileData = nil
            importExportSelectedFileName = nil
            Task {
                defer { finishTransientOperation(operation) }
                do {
                    let data = try await Task.detached(priority: .userInitiated) {
                        try ExportService.readImportFile(at: url)
                    }.value
                    guard isTransientOperationCurrent(operation),
                          container.sessionManager.isSecurityGenerationCurrent(securityGeneration),
                          !Task.isCancelled else { return }
                    pendingImportFileData = data
                    importExportSelectedFileName = url.lastPathComponent
                } catch {
                    guard isTransientOperationCurrent(operation),
                          container.sessionManager.isSecurityGenerationCurrent(securityGeneration) else { return }
                    alertMessage = error.localizedDescription
                }
            }
        }
    }

    /// Clears file-picker selection when the import sheet closes.
    func onImportExportSheetDismissed() {
        if isWorking {
            cancelPendingCryptoOperation()
        }
        pendingImportFileData = nil
        importExportSelectedFileName = nil
    }

    // MARK: - Backup import
    //
    // Restoring a backup used to run the moment the password was accepted: a v3 file silently
    // replaced every workspace, item, template and preference in the vault, with no summary,
    // no confirmation and no way back. It is now a two-step flow — decrypt and summarise,
    // then apply the way the owner chooses — and the previous vault is copied aside first.

    /// Decrypted backup waiting for the owner to choose how to apply it.
    @ObservationIgnored private var stagedImport: ImportedPayload?
    /// Summary of `stagedImport`, shown by the preview sheet.
    private(set) var importPreview: ImportPreview?

    /// Stages backup bytes that are already in memory.
    ///
    /// The picker path goes through `applyImportFilePickerResult`; this is the same step for
    /// callers that already hold the data.
    func stageImport(data: Data, fileName: String) {
        cancelPendingCryptoOperation()
        stagedImport = nil
        importPreview = nil
        pendingImportFileData = nil
        importExportSelectedFileName = nil
        guard data.count <= ExportService.maximumImportFileSize else {
            alertMessage = TransferError.importFileTooLarge.localizedDescription
            return
        }
        pendingImportFileData = data
        importExportSelectedFileName = fileName
    }

    /// Decrypts the chosen file and produces a summary. Nothing is written yet.
    @discardableResult
    func prepareImport(password: String) async -> Bool {
        guard container.sessionManager.lockState == .unlocked else {
            alertMessage = "Unlock the vault before importing."
            return false
        }
        guard !password.isEmpty else {
            alertMessage = TransferError.missingPassword.localizedDescription
            return false
        }
        guard let fileData = pendingImportFileData else {
            alertMessage = TransferError.importFileMissing.localizedDescription
            return false
        }
        guard fileData.count <= ExportService.maximumImportFileSize else {
            alertMessage = TransferError.importFileTooLarge.localizedDescription
            return false
        }

        let operation = beginTransientOperation()
        let securityGeneration = container.sessionManager.captureSecurityGeneration()
        isWorking = true
        defer { finishTransientOperation(operation) }

        do {
            let imported = try await container.exportService.importPayload(from: fileData, password: password)
            guard isTransientOperationCurrent(operation),
                  container.sessionManager.isSecurityGenerationCurrent(securityGeneration),
                  !Task.isCancelled else {
                return false
            }
            stagedImport = imported
            importPreview = makePreview(for: imported, fileName: importExportSelectedFileName ?? "backup.pstore")
            return true
        } catch {
            guard isTransientOperationCurrent(operation),
                  container.sessionManager.isSecurityGenerationCurrent(securityGeneration) else { return false }
            alertMessage = error.localizedDescription
            return false
        }
    }

    func cancelStagedImport() {
        cancelPendingCryptoOperation()
        stagedImport = nil
        importPreview = nil
        pendingImportFileData = nil
        importExportSelectedFileName = nil
    }

    func cancelPendingCryptoOperation() {
        transientOperationGeneration &+= 1
        isWorking = false
    }

    private func beginTransientOperation() -> UInt64 {
        transientOperationGeneration &+= 1
        return transientOperationGeneration
    }

    private func isTransientOperationCurrent(_ generation: UInt64) -> Bool {
        transientOperationGeneration == generation
    }

    private func finishTransientOperation(_ generation: UInt64) {
        guard isTransientOperationCurrent(generation) else { return }
        isWorking = false
    }

    private func makePreview(for imported: ImportedPayload, fileName: String) -> ImportPreview {
        switch imported {
        case let .fullBackup(backup):
            let existing = Dictionary(
                container.memoryStore.makeSnapshot().items.map { ($0.id, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            var identical = 0
            var conflicting = 0
            for incoming in backup.vault.items {
                guard let current = existing[incoming.id] else { continue }
                if Self.isSameContent(current, incoming) { identical += 1 } else { conflicting += 1 }
            }
            return ImportPreview(
                itemCount: backup.vault.items.count,
                workspaceCount: backup.vault.workspaces.count,
                templateCount: backup.vault.customTemplates.count,
                createdAt: nil,
                fileName: fileName,
                conflictingItemCount: conflicting,
                identicalItemCount: identical,
                isLegacyFormat: false
            )
        case let .legacyItems(payloads):
            return ImportPreview(
                itemCount: payloads.count,
                workspaceCount: Set(payloads.compactMap(\.workspaceName)).count,
                templateCount: 0,
                createdAt: nil,
                fileName: fileName,
                conflictingItemCount: 0,
                identicalItemCount: 0,
                isLegacyFormat: true
            )
        }
    }

    /// Writes the staged backup into the vault.
    @discardableResult
    func applyStagedImport(mode: ImportPreview.Mode) -> ImportOutcome? {
        guard container.sessionManager.lockState == .unlocked else {
            alertMessage = "Unlock the vault before restoring a backup."
            return nil
        }
        guard let imported = stagedImport else {
            alertMessage = TransferError.importFileMissing.localizedDescription
            return nil
        }

        let originalSnapshot = container.memoryStore.makeSnapshot()
        let originalSettings = container.settings.makeSettingsSnapshot()
        let previousUndo = undoStep
        var mutationStarted = false
        do {
            // Do not start a destructive import unless its durable safety copy completed.
            // Capturing settings with it keeps Restore truthful after a relaunch too.
            try container.sessionManager.writeRollbackCopy()
            captureUndo(mode == .replace ? "Vault replacement" : "Backup merge")
            mutationStarted = true
            let outcome: ImportOutcome
            switch imported {
            case let .fullBackup(backup):
                outcome = try applyFullBackup(backup, mode: mode)
            case let .legacyItems(payloads):
                outcome = try applyLegacyItems(payloads, mode: mode)
            }
            stagedImport = nil
            importPreview = nil
            pendingImportFileData = nil
            importExportSelectedFileName = nil
            reload()
            lastActionMessage = outcome.summary
            return outcome
        } catch {
            let operationError = error
            undoStep = previousUndo
            if mutationStarted {
                do {
                    try container.memoryStore.replaceContents(with: originalSnapshot)
                    container.settings.applySettings(from: originalSettings)
                    try container.sessionManager.syncBiometricPreferenceIfUnlocked()
                } catch {
                    reload()
                    alertMessage = "The import failed (\(operationError.localizedDescription)) and PassStore could not fully restore the running vault (\(error.localizedDescription)). The encrypted pre-import copy is still available in Settings."
                    return nil
                }
            }
            // `replaceContents` and merge restore the prior memory snapshot on write failure;
            // reload so views stop retaining any entity instances mutated before rollback.
            reload()
            alertMessage = operationError.localizedDescription
            return nil
        }
    }

    private func applyFullBackup(_ backup: ExportedBackupPayload, mode: ImportPreview.Mode) throws -> ImportOutcome {
        switch mode {
        case .replace:
            // The imported file was protected by a different master password. Its password
            // audit trail therefore does not describe this vault's current credential.
            var replacement = backup.vault
            replacement.masterPasswordHistory = container.memoryStore.masterPasswordHistory
            try container.memoryStore.replaceContents(with: replacement)
            container.settings.applySettings(from: backup.settings)
            // The restored preference and the Keychain entry must not disagree: a backup that
            // says "biometrics on" does not by itself put a usable key in this Mac's Keychain.
            try container.sessionManager.syncBiometricPreferenceIfUnlocked()
            return ImportOutcome(
                mode: .replace,
                addedItems: backup.vault.items.count,
                addedWorkspaces: backup.vault.workspaces.count,
                skippedIdentical: 0
            )
        case .merge:
            return try mergeSnapshot(backup.vault)
        }
    }

    /// Builds the complete merged snapshot first and persists it once. This is both atomic at
    /// the repository boundary and idempotent: importing the same backup again cannot create
    /// another conflict copy merely because the first copy received a fresh UUID.
    private func mergeSnapshot(
        _ sourceSnapshot: VaultSnapshot,
        coalescingWorkspaceNames: Bool = false
    ) throws -> ImportOutcome {
        let snapshot = container.memoryStore.normalizedSnapshotCopy(sourceSnapshot)
        var merged = container.memoryStore.makeSnapshot()
        var addedWorkspaces = 0
        var workspaceRemap: [UUID: UUID] = [:]

        for incoming in snapshot.workspaces {
            if let sameID = merged.workspaces.first(where: { $0.id == incoming.id }) {
                if Self.isSameWorkspace(sameID, incoming)
                    || (sameID.name.hasPrefix("\(incoming.name) (imported")
                        && Self.isSameWorkspaceBody(sameID, incoming)) {
                    workspaceRemap[incoming.id] = sameID.id
                    continue
                }
                var attempt = 0
                var importedID = Self.deterministicImportedID(
                    for: incoming,
                    namespace: "workspace-conflict",
                    attempt: attempt
                )
                while let occupied = merged.workspaces.first(where: { $0.id == importedID }) {
                    if Self.isSameWorkspaceBody(occupied, incoming) {
                        workspaceRemap[incoming.id] = occupied.id
                        break
                    }
                    attempt += 1
                    importedID = Self.deterministicImportedID(
                        for: incoming,
                        namespace: "workspace-conflict",
                        attempt: attempt
                    )
                }
                if workspaceRemap[incoming.id] != nil { continue }
                let importedName = Self.availableImportedName(
                    for: incoming.name,
                    among: merged.workspaces.map(\.name)
                )
                merged.workspaces.append(Self.copyWorkspace(incoming, id: importedID, name: importedName))
                workspaceRemap[incoming.id] = importedID
                addedWorkspaces += 1
                continue
            }
            if coalescingWorkspaceNames, let sameName = merged.workspaces.first(where: {
                $0.name.localizedCaseInsensitiveCompare(incoming.name) == .orderedSame
            }) {
                workspaceRemap[incoming.id] = sameName.id
                continue
            }
            let hasNameCollision = merged.workspaces.contains {
                $0.name.localizedCaseInsensitiveCompare(incoming.name) == .orderedSame
            }
            let importedName = hasNameCollision
                ? Self.availableImportedName(for: incoming.name, among: merged.workspaces.map(\.name))
                : incoming.name
            merged.workspaces.append(Self.copyWorkspace(incoming, id: incoming.id, name: importedName))
            workspaceRemap[incoming.id] = incoming.id
            addedWorkspaces += 1
        }

        // Custom templates are data too. Keep built-in IDs stable, map an identical custom
        // template by name/content, and preserve every definition and timestamp when adding.
        var templateRemap: [UUID: UUID] = [:]
        let builtInTemplateIDs = Set(container.memoryStore.allTemplates.filter(\.isBuiltIn).map(\.id))
        for incoming in snapshot.customTemplates {
            if builtInTemplateIDs.contains(incoming.id) {
                templateRemap[incoming.id] = incoming.id
                continue
            }
            if let sameID = merged.customTemplates.first(where: { $0.id == incoming.id }) {
                if Self.isSameTemplate(sameID, incoming)
                    || (sameID.name.hasPrefix("\(incoming.name) (imported")
                        && Self.isSameTemplateBody(sameID, incoming)) {
                    templateRemap[incoming.id] = sameID.id
                    continue
                }
                var attempt = 0
                var importedID = Self.deterministicImportedID(
                    for: incoming,
                    namespace: "template-conflict",
                    attempt: attempt
                )
                while let occupied = merged.customTemplates.first(where: { $0.id == importedID }) {
                    if Self.isSameTemplateBody(occupied, incoming) {
                        templateRemap[incoming.id] = occupied.id
                        break
                    }
                    attempt += 1
                    importedID = Self.deterministicImportedID(
                        for: incoming,
                        namespace: "template-conflict",
                        attempt: attempt
                    )
                }
                if templateRemap[incoming.id] != nil { continue }
                let importedName = Self.availableImportedName(
                    for: incoming.name,
                    among: merged.customTemplates.map(\.name)
                )
                merged.customTemplates.append(Self.copyTemplate(incoming, id: importedID, name: importedName))
                templateRemap[incoming.id] = importedID
                continue
            }

            let hasNameCollision = merged.customTemplates.contains {
                $0.name.localizedCaseInsensitiveCompare(incoming.name) == .orderedSame
            }
            let importedName = hasNameCollision
                ? Self.availableImportedName(for: incoming.name, among: merged.customTemplates.map(\.name))
                : incoming.name
            merged.customTemplates.append(Self.copyTemplate(incoming, id: incoming.id, name: importedName))
            templateRemap[incoming.id] = incoming.id
        }

        var added = 0
        var skipped = 0

        for incoming in snapshot.items {
            let remapped = Self.copyItem(
                incoming,
                workspaceID: incoming.workspaceID.flatMap { workspaceRemap[$0] ?? $0 },
                templateID: incoming.templateID.flatMap { templateRemap[$0] ?? $0 }
            )
            if let current = merged.items.first(where: { $0.id == incoming.id }) {
                if Self.isSameContent(current, remapped) {
                    skipped += 1
                    continue
                }
                var attempt = 0
                while true {
                    let conflictID = Self.deterministicImportedID(
                        for: remapped,
                        namespace: "item-conflict",
                        attempt: attempt
                    )
                    let conflict = Self.copyItem(
                        remapped,
                        id: conflictID,
                        title: "\(incoming.title) (imported)"
                    )
                    if let occupied = merged.items.first(where: { $0.id == conflictID }) {
                        if Self.isSameContent(occupied, conflict) {
                            skipped += 1
                            break
                        }
                        attempt += 1
                        continue
                    }
                    merged.items.append(conflict)
                    added += 1
                    break
                }
                continue
            }

            // Different stable IDs represent different records, even when every visible value
            // matches. Collapsing by content silently deleted intentional duplicate secrets.
            merged.items.append(remapped)
            added += 1
        }

        // The backup's master-password history belongs to its export password, not this
        // vault's credential. `merged` started from the current snapshot, so it stays local.
        try container.memoryStore.replaceContents(with: merged)
        return ImportOutcome(mode: .merge, addedItems: added, addedWorkspaces: addedWorkspaces, skippedIdentical: skipped)
    }

    private static func copyItem(
        _ item: SecretItemSnapshot,
        id: UUID? = nil,
        title: String? = nil,
        workspaceID: UUID?? = nil,
        templateID: UUID?? = nil
    ) -> SecretItemSnapshot {
        SecretItemSnapshot(
            id: id ?? item.id,
            title: title ?? item.title,
            typeRawValue: item.typeRawValue,
            environmentRawValue: item.environmentRawValue,
            customEnvironmentName: item.customEnvironmentName,
            notes: item.notes,
            tagsRawValue: item.tagsRawValue,
            isFavorite: item.isFavorite,
            isArchived: item.isArchived,
            createdAt: item.createdAt,
            updatedAt: item.updatedAt,
            lastAccessedAt: item.lastAccessedAt,
            workspaceID: workspaceID ?? item.workspaceID,
            templateID: templateID ?? item.templateID,
            fields: item.fields,
            changeHistory: item.changeHistory,
            ignoredHealthIssues: item.ignoredHealthIssues,
            linkedFile: item.linkedFile
        )
    }

    private static func copyWorkspace(_ workspace: WorkspaceSnapshot, id: UUID, name: String) -> WorkspaceSnapshot {
        WorkspaceSnapshot(
            id: id,
            name: name,
            icon: workspace.icon,
            colorHex: workspace.colorHex,
            notes: workspace.notes,
            isArchived: workspace.isArchived,
            createdAt: workspace.createdAt,
            updatedAt: workspace.updatedAt,
            sortOrder: workspace.sortOrder,
            environments: workspace.environments
        )
    }

    private static func isSameWorkspace(_ lhs: WorkspaceSnapshot, _ rhs: WorkspaceSnapshot) -> Bool {
        lhs.name == rhs.name && isSameWorkspaceBody(lhs, rhs)
    }

    /// Declared environments are deliberately not part of a workspace's identity.
    ///
    /// A merge adds what the backup has and the vault does not, and overwrites nothing. If the
    /// two sides describe the same workspace, the local declarations are the ones in use and the
    /// backup's list is not a reason to import a second copy of the workspace.
    private static func isSameWorkspaceBody(_ lhs: WorkspaceSnapshot, _ rhs: WorkspaceSnapshot) -> Bool {
        lhs.icon == rhs.icon
            && lhs.colorHex == rhs.colorHex
            && lhs.notes == rhs.notes
            && lhs.isArchived == rhs.isArchived
            && lhs.sortOrder == rhs.sortOrder
    }

    private static func availableImportedName(for base: String, among existingNames: [String]) -> String {
        let names = Set(existingNames.map { $0.lowercased() })
        var candidate = "\(base) (imported)"
        var suffix = 2
        while names.contains(candidate.lowercased()) {
            candidate = "\(base) (imported \(suffix))"
            suffix += 1
        }
        return candidate
    }

    /// Conflict copies need a stable identity. Content-only de-duplication erased legitimate
    /// records that happened to look the same, while random UUIDs duplicated the same import
    /// on every run. A namespaced digest gives the same source record the same alternate id.
    private static func deterministicImportedID<Value: Encodable>(
        for value: Value,
        namespace: String,
        attempt: Int
    ) -> UUID {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var input = Data("\(namespace)|\(attempt)|".utf8)
        defer { VaultCryptoService.overwrite(&input) }
        if var encoded = try? encoder.encode(value) {
            input.append(encoded)
            VaultCryptoService.overwrite(&encoded)
        }
        var bytes = Array(SHA256.hash(data: input).prefix(16))
        // Mark it as an RFC 4122 name-based UUID and set the standard variant bits.
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    private static func isSameContent(_ lhs: SecretItemSnapshot, _ rhs: SecretItemSnapshot) -> Bool {
        lhs.title == rhs.title
            && lhs.typeRawValue == rhs.typeRawValue
            && lhs.environmentRawValue == rhs.environmentRawValue
            && lhs.customEnvironmentName == rhs.customEnvironmentName
            && lhs.notes == rhs.notes
            && lhs.tagsRawValue == rhs.tagsRawValue
            && lhs.isFavorite == rhs.isFavorite
            && lhs.isArchived == rhs.isArchived
            && lhs.workspaceID == rhs.workspaceID
            && lhs.templateID == rhs.templateID
            && lhs.linkedFile == rhs.linkedFile
            && lhs.ignoredHealthIssues == rhs.ignoredHealthIssues
            && lhs.changeHistory == rhs.changeHistory
            && Self.isSameFields(lhs.fields, rhs.fields)
    }

    private static func isSameFields(_ lhs: [FieldValueSnapshot], _ rhs: [FieldValueSnapshot]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        return zip(lhs.sorted(by: fieldSnapshotPrecedes), rhs.sorted(by: fieldSnapshotPrecedes)).allSatisfy { left, right in
            left.fieldKey == right.fieldKey
                && left.labelSnapshot == right.labelSnapshot
                && left.kindRawValue == right.kindRawValue
                && left.isSensitive == right.isSensitive
                && left.isCopyable == right.isCopyable
                && left.isMasked == right.isMasked
                && left.sortOrder == right.sortOrder
                && left.plainValue == right.plainValue
                && left.previousValues == right.previousValues
        }
    }

    /// Canonical content ordering makes conflict comparison deterministic even when a corrupt
    /// or legacy payload contains two fields with the same `sortOrder`.
    private static func fieldSnapshotPrecedes(_ lhs: FieldValueSnapshot, _ rhs: FieldValueSnapshot) -> Bool {
        if lhs.sortOrder != rhs.sortOrder { return lhs.sortOrder < rhs.sortOrder }
        if lhs.fieldKey != rhs.fieldKey { return lhs.fieldKey < rhs.fieldKey }
        if lhs.labelSnapshot != rhs.labelSnapshot { return lhs.labelSnapshot < rhs.labelSnapshot }
        if lhs.kindRawValue != rhs.kindRawValue { return lhs.kindRawValue < rhs.kindRawValue }
        if lhs.isSensitive != rhs.isSensitive { return !lhs.isSensitive }
        if lhs.isCopyable != rhs.isCopyable { return !lhs.isCopyable }
        if lhs.isMasked != rhs.isMasked { return !lhs.isMasked }
        if lhs.plainValue != rhs.plainValue { return lhs.plainValue < rhs.plainValue }
        if lhs.previousValues.count != rhs.previousValues.count {
            return lhs.previousValues.count < rhs.previousValues.count
        }
        for (left, right) in zip(lhs.previousValues, rhs.previousValues) {
            if left.replacedAt != right.replacedAt { return left.replacedAt < right.replacedAt }
            if left.value != right.value { return left.value < right.value }
            if left.id != right.id { return left.id.uuidString < right.id.uuidString }
        }
        return false
    }

    private static func isSameTemplate(_ lhs: TemplateSnapshot, _ rhs: TemplateSnapshot) -> Bool {
        lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedSame && isSameTemplateBody(lhs, rhs)
    }

    private static func isSameTemplateBody(_ lhs: TemplateSnapshot, _ rhs: TemplateSnapshot) -> Bool {
        guard lhs.itemTypeRawValue == rhs.itemTypeRawValue,
              lhs.fieldDefinitions.count == rhs.fieldDefinitions.count else { return false }
        return zip(
            lhs.fieldDefinitions.sorted(by: templateFieldSnapshotPrecedes),
            rhs.fieldDefinitions.sorted(by: templateFieldSnapshotPrecedes)
        ).allSatisfy { left, right in
            left.key == right.key
                && left.label == right.label
                && left.kindRawValue == right.kindRawValue
                && left.isSensitive == right.isSensitive
                && left.isCopyable == right.isCopyable
                && left.isMaskedByDefault == right.isMaskedByDefault
                && left.sortOrder == right.sortOrder
        }
    }

    private static func templateFieldSnapshotPrecedes(_ lhs: TemplateFieldSnapshot, _ rhs: TemplateFieldSnapshot) -> Bool {
        if lhs.sortOrder != rhs.sortOrder { return lhs.sortOrder < rhs.sortOrder }
        if lhs.key != rhs.key { return lhs.key < rhs.key }
        if lhs.label != rhs.label { return lhs.label < rhs.label }
        if lhs.kindRawValue != rhs.kindRawValue { return lhs.kindRawValue < rhs.kindRawValue }
        if lhs.isSensitive != rhs.isSensitive { return !lhs.isSensitive }
        if lhs.isCopyable != rhs.isCopyable { return !lhs.isCopyable }
        if lhs.isMaskedByDefault != rhs.isMaskedByDefault { return !lhs.isMaskedByDefault }
        return false
    }

    private static func copyTemplate(_ template: TemplateSnapshot, id: UUID, name: String) -> TemplateSnapshot {
        TemplateSnapshot(
            id: id,
            itemTypeRawValue: template.itemTypeRawValue,
            name: name,
            createdAt: template.createdAt,
            updatedAt: template.updatedAt,
            fieldDefinitions: template.fieldDefinitions
        )
    }

    private func applyLegacyItems(_ payloads: [ExportedItemPayload], mode: ImportPreview.Mode) throws -> ImportOutcome {
        guard !payloads.isEmpty else {
            throw TransferError.invalidExportFile
        }
        var workspaceIDs: [String: UUID] = [:]
        var legacyWorkspaces: [WorkspaceSnapshot] = []
        for payload in payloads {
            guard let rawName = payload.workspaceName?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !rawName.isEmpty, workspaceIDs[rawName.lowercased()] == nil else { continue }
            let id = UUID()
            workspaceIDs[rawName.lowercased()] = id
            legacyWorkspaces.append(WorkspaceSnapshot(
                id: id,
                name: rawName,
                icon: "shippingbox",
                colorHex: "#4A7AFF",
                notes: "",
                isArchived: false,
                createdAt: payload.createdAt,
                updatedAt: payload.updatedAt
            ))
        }
        let legacyItems = payloads.map { payload -> SecretItemSnapshot in
            let environment = environmentFromExport(payload.environment)
            let type = SecretItemType.allCases.first { $0.title == payload.type } ?? .generic
            return SecretItemSnapshot(
                id: payload.id,
                title: payload.title,
                typeRawValue: type.rawValue,
                environmentRawValue: environment.kind.rawValue,
                customEnvironmentName: environment.customName,
                notes: payload.notes,
                tagsRawValue: payload.tags.joined(separator: ","),
                isFavorite: payload.isFavorite,
                isArchived: false,
                createdAt: payload.createdAt,
                updatedAt: payload.updatedAt,
                lastAccessedAt: nil,
                workspaceID: payload.workspaceName.flatMap {
                    workspaceIDs[$0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()]
                },
                templateID: nil,
                fields: payload.fields.enumerated().map { index, field in
                    FieldValueSnapshot(
                        id: UUID(),
                        fieldKey: field.key,
                        labelSnapshot: field.label,
                        kindRawValue: field.kind,
                        isSensitive: field.isSensitive,
                        isCopyable: true,
                        isMasked: field.isSensitive,
                        sortOrder: index,
                        plainValue: field.value
                    )
                }
            )
        }
        let legacySnapshot = VaultSnapshot(
            workspaces: legacyWorkspaces,
            items: legacyItems,
            customTemplates: [],
            masterPasswordHistory: container.memoryStore.masterPasswordHistory
        )
        switch mode {
        case .replace:
            try container.memoryStore.replaceContents(with: legacySnapshot)
            return ImportOutcome(
                mode: .replace,
                addedItems: legacyItems.count,
                addedWorkspaces: legacyWorkspaces.count,
                skippedIdentical: 0
            )
        case .merge:
            return try mergeSnapshot(legacySnapshot, coalescingWorkspaceNames: true)
        }
    }

    // MARK: Rollback

    /// Date of the pre-import copy on disk, if one exists.
    var rollbackCopyDate: Date? {
        container.sessionManager.rollbackCopyDate()
    }

    /// Puts the pre-import vault back and locks, so the restored file is read from scratch.
    func restoreRollbackCopy() {
        do {
            try container.sessionManager.restoreRollbackCopy()
            lastActionMessage = "Previous vault restored. Unlock to continue."
        } catch {
            handleMutationFailure(error)
        }
    }

    func discardRollbackCopy() {
        do {
            try container.sessionManager.discardRollbackCopy()
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    private func resolveOrCreateWorkspaceID(named name: String?) throws -> UUID? {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return nil }
        let all = try container.workspaceRepository.fetchAll(includeArchived: true)
        if let match = all.first(where: { $0.name.localizedCaseInsensitiveCompare(trimmed) == .orderedSame }) {
            return match.id
        }
        let created = try container.workspaceRepository.saveWorkspace(
            WorkspaceDraft(id: nil, name: trimmed, icon: "shippingbox", colorHex: "#4A7AFF", notes: "")
        )
        return created.id
    }

    private func environmentFromExport(_ title: String) -> EnvironmentValue {
        if let kind = EnvironmentKind.allCases.first(where: { $0.title == title }) {
            return .preset(kind)
        }
        if title == EnvironmentKind.custom.title {
            return .custom("Custom")
        }
        return .custom(title)
    }

    private func makeDraft(fromExportedPayload payload: ExportedItemPayload, workspaceID: UUID?) -> SecretItemDraft {
        let type = SecretItemType.allCases.first { $0.title == payload.type } ?? .generic
        let fieldDrafts = payload.fields.enumerated().map { index, field in
            FieldDraft(
                id: UUID(),
                key: field.key,
                label: field.label,
                value: field.value,
                kind: FieldKind(rawValue: field.kind) ?? .text,
                isSensitive: field.isSensitive,
                isCopyable: true,
                isMasked: field.isSensitive,
                sortOrder: index
            )
        }
        return SecretItemDraft(
            id: nil,
            title: payload.title,
            type: type,
            workspaceID: workspaceID,
            environment: environmentFromExport(payload.environment),
            notes: payload.notes,
            tags: payload.tags,
            isFavorite: payload.isFavorite,
            fieldDrafts: fieldDrafts,
            templateID: nil
        )
    }

    /// A `.env` chosen from disk, with everything the creation flow needs to both fill in the
    /// item and remember where it came from.
    struct PickedEnvFile {
        let url: URL
        let contents: String
        let suggestedTitle: String

        var fileName: String { url.lastPathComponent }
    }

    /// Reads a `.env` file from an open panel. `showsHiddenFiles` matters: `.env` is hidden.
    func readEnvFileForImport() -> PickedEnvFile? {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.canChooseDirectories = false
        panel.prompt = "Import"
        panel.message = "Choose a .env file to import."
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return readEnvFile(at: url)
    }

    func readEnvFile(at url: URL) -> PickedEnvFile? {
        do {
            let string = try LinkedFileService.readPickedFile(at: url)
            return PickedEnvFile(url: url, contents: string, suggestedTitle: importedEnvTitle(from: url))
        } catch {
            alertMessage = error.localizedDescription
            return nil
        }
    }

    /// Production file-import paths use this variant so a slow local/network volume cannot
    /// block the main actor. The synchronous overload remains useful for deterministic tests.
    func readEnvFileOffMain(at url: URL) async -> PickedEnvFile? {
        guard container.sessionManager.lockState == .unlocked else { return nil }
        let securityGeneration = container.sessionManager.captureSecurityGeneration()
        do {
            let string = try await Task.detached(priority: .userInitiated) {
                try LinkedFileService.readPickedFile(at: url)
            }.value
            guard !Task.isCancelled,
                  container.sessionManager.lockState == .unlocked,
                  container.sessionManager.isSecurityGenerationCurrent(securityGeneration) else {
                return nil
            }
            return PickedEnvFile(url: url, contents: string, suggestedTitle: importedEnvTitle(from: url))
        } catch {
            guard container.sessionManager.lockState == .unlocked,
                  container.sessionManager.isSecurityGenerationCurrent(securityGeneration) else {
                return nil
            }
            alertMessage = error.localizedDescription
            return nil
        }
    }

    func readEnvFileForImportOffMain() async -> PickedEnvFile? {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.canChooseDirectories = false
        panel.prompt = "Import"
        panel.message = "Choose a .env file to import."
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return await readEnvFileOffMain(at: url)
    }

    /// Picks a `.env`, creates the item from it and links the two — in one step.
    ///
    /// The long way round still exists (New Secret → .env File → drop the file), but for the
    /// commonest job in the app there is no reason to walk through a template picker.
    @discardableResult
    private func importEnvFileCreatingItemOffMain(parseIntoEntries: Bool = true) async -> SecretItemEntity? {
        guard container.sessionManager.lockState == .unlocked else {
            alertMessage = "Unlock the vault before importing."
            return nil
        }
        guard let picked = await readEnvFileForImportOffMain() else { return nil }

        var draft = buildEnvImportDraft(
            from: picked.contents,
            suggestedTitle: picked.suggestedTitle,
            parseIntoEntries: parseIntoEntries
        )
        draft.workspaceID = preferredWorkspaceID
        return saveNewItem(draft, linkingTo: picked.url, parsedIntoFields: parseIntoEntries)
    }

    /// Synchronous UI action wrapper for Button/Command closures. Keeping the unstructured
    /// task out of large SwiftUI result builders also avoids expensive generic inference.
    func importEnvFileCreatingItem(parseIntoEntries: Bool = true) {
        Task { _ = await importEnvFileCreatingItemOffMain(parseIntoEntries: parseIntoEntries) }
    }

    /// Saves a new item and, when it came from a file, links it to that file straight away.
    ///
    /// Importing used to throw the source URL away, so the item you had just built from a
    /// file had to be linked to that same file by hand, through a second file picker.
    @discardableResult
    func saveNewItem(_ draft: SecretItemDraft, linkingTo url: URL?, parsedIntoFields: Bool) -> SecretItemEntity? {
        do {
            let item = try container.itemRepository.saveItem(draft)
            reload()
            selectedItemID = item.id
            selectionAnchorID = item.id
            if let url {
                Task {
                    await linkFile(
                        at: url,
                        to: item,
                        parsedIntoFields: parsedIntoFields,
                        acceptCurrentContentsAsSynced: true
                    )
                }
                lastActionMessage = "Created “\(item.title)”. Linking to \(url.lastPathComponent)…"
            }
            return items.first(where: { $0.id == item.id }) ?? item
        } catch {
            handleMutationFailure(error)
            return nil
        }
    }

    func prepareEnvImport(from source: EnvImportSource, parseIntoEntries: Bool = true) -> SecretItemDraft? {
        switch source {
        case let .file(url):
            let string: String
            do {
                string = try LinkedFileService.readPickedFile(at: url)
            } catch {
                alertMessage = error.localizedDescription
                return nil
            }
            return buildEnvImportDraft(
                from: string,
                suggestedTitle: importedEnvTitle(from: url),
                parseIntoEntries: parseIntoEntries
            )
        case let .pastedText(text):
            return buildEnvImportDraft(from: text, suggestedTitle: "Imported .env", parseIntoEntries: parseIntoEntries)
        }
    }

    /// Merges imported `.env` text into an in-progress draft (workspace, tags, title left intact when appropriate).
    func applyEnvImportContent(
        to draft: inout SecretItemDraft,
        raw: String,
        parseIntoEntries: Bool,
        suggestedTitle: String?
    ) {
        let trimmedTitle = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let titleForBuild: String
        if let suggestedTitle, !suggestedTitle.isEmpty {
            titleForBuild = suggestedTitle
        } else if trimmedTitle.isEmpty {
            titleForBuild = "Imported .env"
        } else {
            titleForBuild = trimmedTitle
        }

        let built = buildEnvImportDraft(from: raw, suggestedTitle: titleForBuild, parseIntoEntries: parseIntoEntries)
        draft.fieldDrafts = built.fieldDrafts
        draft.notes = built.notes

        guard trimmedTitle.isEmpty else { return }
        if let suggestedTitle, !suggestedTitle.isEmpty {
            draft.title = suggestedTitle
        } else {
            draft.title = built.title
        }
    }

    func draftForSelectedItem() -> SecretItemDraft {
        selectedItem.map(makeDraft(from:)) ?? newItemDraft()
    }

    /// Editor draft for a specific item, independent of what is selected.
    func draft(forItemID id: UUID) -> SecretItemDraft {
        items.first(where: { $0.id == id }).map(makeDraft(from:)) ?? draftForSelectedItem()
    }

    func item(withID id: UUID) -> SecretItemEntity? {
        items.first(where: { $0.id == id })
    }

    func newItemDraft(template: SecretFieldTemplateEntity? = nil) -> SecretItemDraft {
        let template = template ?? defaultTemplate(for: .generic)
        return SecretItemDraft(
            title: "",
            type: template?.itemType ?? .generic,
            workspaceID: preferredWorkspaceID,
            environment: preferredEnvironment,
            notes: "",
            tags: [],
            isFavorite: false,
            fieldDrafts: (template?.fieldDefinitions.sorted { $0.sortOrder < $1.sortOrder } ?? []).map {
                FieldDraft(
                    key: $0.key,
                    label: $0.label,
                    value: "",
                    kind: $0.kind,
                    isSensitive: $0.isSensitive,
                    isCopyable: $0.isCopyable,
                    isMasked: $0.isMaskedByDefault,
                    sortOrder: $0.sortOrder
                )
            },
            templateID: template?.id
        )
    }

    func defaultTemplate(for type: SecretItemType) -> SecretFieldTemplateEntity? {
        templates.first(where: { $0.itemType == type && $0.isBuiltIn })
            ?? templates.first(where: { $0.itemType == type })
    }

    /// Updates the draft's item type. When no field has stored content yet, replaces `fieldDrafts`
    /// with the default template for `newType`. When any value or secret reference is present,
    /// only `type` changes so existing data is never cleared.
    func applyItemTypeChange(to draft: inout SecretItemDraft, newType: SecretItemType) {
        guard draft.type != newType else { return }

        if Self.draftHasAnyStoredFieldContent(draft) {
            draft.type = newType
            return
        }

        let oldByKey = Dictionary(draft.fieldDrafts.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        let template = defaultTemplate(for: newType)
        let defs = template?.fieldDefinitions.sorted { $0.sortOrder < $1.sortOrder } ?? []

        draft.type = newType
        draft.templateID = template?.id

        guard !defs.isEmpty else { return }

        draft.fieldDrafts = defs.enumerated().map { index, def in
            if let old = oldByKey[def.key] {
                FieldDraft(
                    id: old.id,
                    key: def.key,
                    label: def.label,
                    value: old.value,
                    kind: def.kind,
                    isSensitive: def.isSensitive,
                    isCopyable: def.isCopyable,
                    isMasked: def.isMaskedByDefault,
                    sortOrder: index,
                    secretReference: old.secretReference
                )
            } else {
                FieldDraft(
                    key: def.key,
                    label: def.label,
                    value: "",
                    kind: def.kind,
                    isSensitive: def.isSensitive,
                    isCopyable: def.isCopyable,
                    isMasked: def.isMaskedByDefault,
                    sortOrder: index
                )
            }
        }
    }

    private static func draftHasAnyStoredFieldContent(_ draft: SecretItemDraft) -> Bool {
        draft.fieldDrafts.contains { fieldHasStoredContent($0) }
    }

    private static func fieldHasStoredContent(_ field: FieldDraft) -> Bool {
        if field.secretReference != nil { return true }
        // Spaces can be an intentional .env value. Only the truly empty string is safe to
        // replace when switching templates.
        return !field.value.isEmpty
    }

    func draftForWorkspace(_ workspace: WorkspaceEntity?) -> WorkspaceDraft {
        guard let workspace else { return .empty }
        return WorkspaceDraft(
            id: workspace.id,
            name: workspace.name,
            icon: workspace.icon,
            colorHex: workspace.colorHex,
            notes: workspace.notes,
            environments: workspace.environments
        )
    }

    func draftForTemplate(_ template: SecretFieldTemplateEntity?) -> TemplateDraft {
        guard let template else {
            return TemplateDraft(name: "", itemType: .customTemplate, fieldDefinitions: [])
        }
        return TemplateDraft(
            id: template.isBuiltIn ? nil : template.id,
            name: template.name,
            itemType: template.itemType,
            fieldDefinitions: template.fieldDefinitions.sorted { $0.sortOrder < $1.sortOrder }.map {
                .init(
                    id: $0.id,
                    key: $0.key,
                    label: $0.label,
                    kind: $0.kind,
                    isSensitive: $0.isSensitive,
                    isCopyable: $0.isCopyable,
                    isMaskedByDefault: $0.isMaskedByDefault,
                    sortOrder: $0.sortOrder
                )
            }
        )
    }

    func workspace(for id: UUID?) -> WorkspaceEntity? {
        guard let id else { return nil }
        return workspaces.first(where: { $0.id == id })
    }

    func template(for id: UUID?) -> SecretFieldTemplateEntity? {
        guard let id else { return nil }
        return templates.first(where: { $0.id == id })
    }

    func resolvedFields(for item: SecretItemEntity) -> [FieldResolvedValue] {
        (try? container.itemRepository.resolveFields(for: item)) ?? []
    }

    static func visibleFields(in fields: [FieldResolvedValue]) -> [FieldResolvedValue] {
        fields.filter { !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    private var preferredWorkspaceID: UUID? {
        selectedDestination.workspaceID ?? selectedItem?.workspace?.id ?? workspaces.first?.id
    }

    /// What a new item's environment starts as.
    ///
    /// Inside one environment of a workspace, that environment. Inside a workspace as a whole,
    /// the first environment the project offers — a new secret in a project that has declared
    /// Local, Dev and Prod belongs in one of those, not in whatever the global default is.
    private var preferredEnvironment: EnvironmentValue {
        switch selectedDestination {
        case let .workspaceEnvironment(_, environment):
            return WorkspaceEnvironment.value(forTitle: environment)
        case let .environment(environment):
            return Self.environmentValue(from: environment)
        case let .workspace(id):
            if let first = offeredEnvironments(inWorkspace: id).first(where: \.isEnabled) {
                return first.environmentValue
            }
            return selectedItem?.environmentValue ?? .preset(.dev)
        case .library, .tag:
            return selectedItem?.environmentValue ?? .preset(.dev)
        }
    }

    private static func environmentValue(from title: String) -> EnvironmentValue {
        if let kind = EnvironmentKind.allCases.first(where: { $0.title == title && $0 != .custom }) {
            return .preset(kind)
        }
        return .custom(title)
    }

    private func makeDraft(from item: SecretItemEntity) -> SecretItemDraft {
        SecretItemDraft(
            id: item.id,
            title: item.title,
            type: item.type,
            workspaceID: item.workspace?.id,
            environment: item.environmentValue,
            notes: item.notes,
            tags: item.tags,
            isFavorite: item.isFavorite,
            isArchived: item.isArchived,
            fieldDrafts: resolvedFields(for: item).enumerated().map { index, field in
                FieldDraft(
                    id: field.id,
                    key: field.key,
                    label: field.label,
                    value: field.value,
                    kind: field.kind,
                    isSensitive: field.isSensitive,
                    isCopyable: field.isCopyable,
                    isMasked: field.isMasked,
                    sortOrder: index,
                    secretReference: item.fields.first(where: { $0.id == field.id })?.secretReference
                )
            },
            templateID: item.template?.id,
            linkedFile: item.linkedFile
        )
    }

    private func normalizeSelection() {
        if let workspaceID = selectedDestination.workspaceID, workspace(for: workspaceID) == nil {
            selectedDestination = .library(.allItems)
        }
        // An environment can stop existing — its last item moved away and it was never
        // declared. Fall back to the workspace rather than to the whole vault: that is the
        // scope the owner was actually looking at.
        if case let .workspaceEnvironment(id, environment) = selectedDestination {
            let key = WorkspaceEnvironment.matchKey(for: environment)
            if !environments(inWorkspace: id).contains(where: { $0.matchKey == key }) {
                selectedDestination = .workspace(id)
            }
        }
        syncSelectedItem()
    }

    private func syncSelectedItem() {
        let visibleIDs = Set(filteredItems.map(\.id))
        multiSelectedIDs.formIntersection(visibleIDs)
        if let selectedItemID, !visibleIDs.contains(selectedItemID) {
            self.selectedItemID = nil
        }
        if let selectionAnchorID, !visibleIDs.contains(selectionAnchorID) {
            self.selectionAnchorID = nil
        }
        if selectionAnchorID == nil {
            selectionAnchorID = selectedItemID
                ?? filteredItems.first(where: { multiSelectedIDs.contains($0.id) })?.id
        }
        if selectedItemID == nil, multiSelectedIDs.isEmpty {
            selectionAnchorID = nil
        }
    }

    private func applyUITestLaunchOverrides() {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("--uitesting") else { return }

        if let destinationArgument = arguments.first(where: { $0.hasPrefix("--ui-select-destination=") }) {
            let token = String(destinationArgument.dropFirst("--ui-select-destination=".count))
            if token == "all-items" {
                selectedDestination = .library(.allItems)
            } else if token.hasPrefix("workspace:") {
                let workspaceToken = String(token.dropFirst("workspace:".count))
                if let workspace = workspaces.first(where: { Self.launchToken(for: $0.name) == workspaceToken }) {
                    selectedDestination = .workspace(workspace.id)
                }
            }
        }

        if let itemArgument = arguments.first(where: { $0.hasPrefix("--ui-select-item=") }) {
            let token = String(itemArgument.dropFirst("--ui-select-item=".count))
            if let item = items.first(where: { Self.launchToken(for: $0.title) == token }) {
                selectedItemID = item.id
            }
        }
    }

    private static func launchToken(for value: String) -> String {
        value
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .replacingOccurrences(of: "[^a-zA-Z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
            .lowercased()
    }

    /// Archives or restores in place.
    ///
    /// This used to jump the sidebar to Archived (or All Items) afterwards, so archiving one
    /// item while working inside a workspace threw you out of that workspace. The selection
    /// is simply cleared when the item leaves the current destination.
    private func updateArchiveState(for item: SecretItemEntity, isArchived: Bool) {
        var draft = makeDraft(from: item)
        draft.id = item.id
        draft.isArchived = isArchived
        do {
            let saved = try container.itemRepository.saveItem(draft)
            reload()
            if filteredItems.contains(where: { $0.id == saved.id }) {
                selectedItemID = saved.id
                selectionAnchorID = saved.id
            } else {
                selectedItemID = nil
                selectionAnchorID = nil
                lastActionMessage = isArchived
                    ? "“\(saved.title)” archived."
                    : "“\(saved.title)” restored."
            }
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    // MARK: - Transient status message

    /// Short confirmation shown in the list footer — used when something succeeded but the
    /// result moved out of view, which otherwise looks like nothing happened.
    var lastActionMessage: String? {
        didSet {
            guard lastActionMessage != nil else { return }
            statusMessageDismissal?.cancel()
            statusMessageDismissal = Task { [weak self] in
                try? await Task.sleep(for: .seconds(4))
                guard !Task.isCancelled else { return }
                self?.lastActionMessage = nil
            }
        }
    }

    @ObservationIgnored private var statusMessageDismissal: Task<Void, Never>?

    private func buildEnvImportDraft(from string: String, suggestedTitle: String, parseIntoEntries: Bool) -> SecretItemDraft {
        if parseIntoEntries {
            makeEnvImportDraft(from: string, suggestedTitle: suggestedTitle)
        } else {
            makeEnvRawTextDraft(from: string, suggestedTitle: suggestedTitle)
        }
    }

    /// Parses `KEY=value` lines into separate fields; if nothing parses, keeps one multiline block.
    private func makeEnvImportDraft(from string: String, suggestedTitle: String) -> SecretItemDraft {
        let parsed = container.envImport.parse(string)
        let fieldDrafts: [FieldDraft]
        if parsed.entries.isEmpty {
            fieldDrafts = [
                FieldDraft(
                    key: "env",
                    label: ".env",
                    value: string,
                    kind: .multiline,
                    isSensitive: true,
                    isCopyable: true,
                    isMasked: true,
                    sortOrder: 0
                )
            ]
        } else {
            fieldDrafts = parsed.entries.enumerated().map { index, entry in
                FieldDraft(
                    key: entry.key,
                    label: entry.key,
                    value: entry.value,
                    kind: .text,
                    isSensitive: entry.isSensitive,
                    isCopyable: true,
                    isMasked: entry.isSensitive,
                    sortOrder: index
                )
            }
        }

        return SecretItemDraft(
            title: suggestedTitle,
            type: .envGroup,
            workspaceID: preferredWorkspaceID,
            environment: preferredEnvironment,
            notes: parsed.notes,
            tags: [],
            isFavorite: false,
            fieldDrafts: fieldDrafts,
            templateID: templates.first(where: { $0.itemType == .envGroup })?.id
        )
    }

    /// Stores the entire file as a single multiline `.env` field (no parsing).
    private func makeEnvRawTextDraft(from string: String, suggestedTitle: String) -> SecretItemDraft {
        SecretItemDraft(
            title: suggestedTitle,
            type: .envGroup,
            workspaceID: preferredWorkspaceID,
            environment: preferredEnvironment,
            notes: "",
            tags: [],
            isFavorite: false,
            fieldDrafts: [
                FieldDraft(
                    key: "env",
                    label: ".env",
                    value: string,
                    kind: .multiline,
                    isSensitive: true,
                    isCopyable: true,
                    isMasked: true,
                    sortOrder: 0
                )
            ],
            templateID: templates.first(where: { $0.itemType == .envGroup })?.id
        )
    }

    private func maybeWarnForSensitiveCopy(isSensitive: Bool) {
        guard isSensitive, container.clipboard.shouldWarnAboutSensitiveCopy else { return }
        container.clipboard.markSensitiveCopyWarningShown()
        alertMessage = "Copied secrets go through the macOS system clipboard and can be read by clipboard managers or other apps while present."
    }

    private func matchesDestination(_ item: SecretItemEntity) -> Bool {
        switch selectedDestination {
        case let .library(section):
            return Self.matches(section: section, item: item)
        case let .workspace(id):
            // The type filter narrows within the workspace. It used to widen to the whole
            // vault while the header still named the workspace, so the title described a
            // scope the list was not showing.
            return item.workspace?.id == id && !item.isArchived
        case let .workspaceEnvironment(id, environment):
            return item.workspace?.id == id
                && !item.isArchived
                && WorkspaceEnvironment.matchKey(for: item.environmentValue.title)
                    == WorkspaceEnvironment.matchKey(for: environment)
        case let .tag(tag):
            return item.tags.contains(tag) && !item.isArchived
        case let .environment(environment):
            return item.environmentValue.title == environment && !item.isArchived
        }
    }

    /// Shared by the list filter and the sidebar badges so a count can never disagree with
    /// what clicking it shows.
    private static func matches(section: LibrarySection, item: SecretItemEntity) -> Bool {
        switch section {
        case .allItems:
            !item.isArchived
        case .favorites:
            item.isFavorite && !item.isArchived
        // "Recent" used to be an exact copy of "All Items" with a different sort — same rows,
        // same badge. It now means what it says: things actually opened.
        case .recent:
            !item.isArchived && item.lastAccessedAt != nil
        case .archived:
            item.isArchived
        }
    }

    private func matchesSearchAndType(_ item: SecretItemEntity) -> Bool {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let typeMatch = selectedType == nil || item.type == selectedType
        guard !query.isEmpty else { return typeMatch }
        return typeMatch && matchesQuery(item, query: query)
    }

    /// Every whitespace-separated token has to match somewhere, so "postgres prod" narrows
    /// instead of matching either word.
    private func matchesQuery(_ item: SecretItemEntity, query: String) -> Bool {
        let tokens = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !tokens.isEmpty else { return true }
        return tokens.allSatisfy { token in
            item.title.localizedCaseInsensitiveContains(token)
                || item.notes.localizedCaseInsensitiveContains(token)
                || item.tags.contains(where: { $0.localizedCaseInsensitiveContains(token) })
                || item.environmentValue.title.localizedCaseInsensitiveContains(token)
                || item.type.title.localizedCaseInsensitiveContains(token)
                || item.workspace?.name.localizedCaseInsensitiveContains(token) == true
                || item.fields.contains { field in
                    if field.labelSnapshot.localizedCaseInsensitiveContains(token) { return true }
                    // Non-sensitive values only: matching on a password or token would let the
                    // search box confirm a secret's contents without ever revealing it.
                    guard !field.isSensitive else { return false }
                    return field.plainValue.localizedCaseInsensitiveContains(token)
                }
        }
    }

    /// "Recent" is the one destination that defines its own order — it exists to answer
    /// "what did I just use?" — so it ignores the chosen sort. Everywhere else the sort is
    /// the owner's choice rather than a hard-coded A-Z.
    var effectiveSortOrder: ItemSortOrder {
        if case .library(.recent) = selectedDestination { return .recentlyUsed }
        return sortOrder
    }

    /// True where the destination fixes the order, so the sort control should say so rather
    /// than claim a setting that is not being applied.
    var isSortOrderFixedByDestination: Bool {
        if case .library(.recent) = selectedDestination { return true }
        return false
    }

    private func sortComparator(lhs: SecretItemEntity, rhs: SecretItemEntity) -> Bool {
        switch effectiveSortOrder {
        case .title:
            break
        case .recentlyUsed:
            // Never used sorts below everything used, rather than pretending it was used at
            // the epoch or at its edit date.
            let lhsDate = lhs.lastAccessedAt
            let rhsDate = rhs.lastAccessedAt
            if lhsDate != rhsDate {
                switch (lhsDate, rhsDate) {
                case let (l?, r?): return l > r
                case (_?, nil): return true
                case (nil, _?): return false
                default: break
                }
            }
        case .recentlyUpdated:
            if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
        case .newestFirst:
            if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
        }
        return compareByTitleThenWorkspace(lhs: lhs, rhs: rhs)
    }

    private func compareByTitleThenWorkspace(lhs: SecretItemEntity, rhs: SecretItemEntity) -> Bool {
        let titleComparison = lhs.title.localizedCaseInsensitiveCompare(rhs.title)
        if titleComparison != .orderedSame {
            return titleComparison == .orderedAscending
        }

        let lhsWorkspace = lhs.workspace?.name ?? ""
        let rhsWorkspace = rhs.workspace?.name ?? ""
        let workspaceComparison = lhsWorkspace.localizedCaseInsensitiveCompare(rhsWorkspace)
        if workspaceComparison != .orderedSame {
            return workspaceComparison == .orderedAscending
        }

        let environmentComparison = lhs.environmentValue.title.localizedCaseInsensitiveCompare(rhs.environmentValue.title)
        if environmentComparison != .orderedSame {
            return environmentComparison == .orderedAscending
        }

        return lhs.id.uuidString < rhs.id.uuidString
    }

    private func templateSortComparator(lhs: SecretFieldTemplateEntity, rhs: SecretFieldTemplateEntity) -> Bool {
        if lhs.isBuiltIn != rhs.isBuiltIn {
            return lhs.isBuiltIn && !rhs.isBuiltIn
        }
        let lhsPriority = templatePriority(for: lhs.itemType)
        let rhsPriority = templatePriority(for: rhs.itemType)
        if lhsPriority != rhsPriority {
            return lhsPriority < rhsPriority
        }
        return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
    }

    private func templatePriority(for type: SecretItemType) -> Int {
        switch type {
        case .generic:
            0
        case .websiteService:
            1
        case .apiCredential:
            2
        case .database:
            3
        case .serverSSH:
            4
        case .savedCommand:
            5
        case .s3Compatible:
            6
        case .envGroup:
            7
        case .customTemplate:
            8
        }
    }

    func suggestedEnvImportTitle(for url: URL) -> String {
        importedEnvTitle(from: url)
    }

    private func importedEnvTitle(from url: URL) -> String {
        let trimmedName = url.deletingPathExtension().lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedName.isEmpty {
            return trimmedName
        }
        return url.lastPathComponent
    }
}

@MainActor
@Observable
final class MenuBarViewModel {
    let vault: VaultViewModel

    init(vault: VaultViewModel) {
        self.vault = vault
    }

    var quickItems: [SecretItemEntity] {
        vault.items
            .filter { $0.isFavorite && !$0.isArchived }
            .filter { !quickFields(for: $0).isEmpty }
            .sorted {
                let lhsDate = $0.lastAccessedAt ?? $0.updatedAt
                let rhsDate = $1.lastAccessedAt ?? $1.updatedAt
                if lhsDate != rhsDate { return lhsDate > rhsDate }
                return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
            }
            .prefix(Self.quickItemLimit)
            .map { $0 }
    }

    private static let quickItemLimit = 8

    func quickFields(for item: SecretItemEntity) -> [FieldResolvedValue] {
        vault.resolvedFields(for: item)
            .filter(\.isCopyable)
            .filter { !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    var canUnlockWithBiometrics: Bool {
        vault.container.sessionManager.canAttemptBiometricUnlock
    }

    func unlockWithBiometrics() async {
        if await vault.container.sessionManager.unlockWithBiometrics() {
            vault.reload()
        }
    }

    /// Copies through the view model rather than straight to the pasteboard.
    ///
    /// Copying from the menu bar used to bypass the first-time "this goes through the system
    /// clipboard" warning, and never stamped "last used" — so the menu bar's own
    /// most-recently-used ordering never actually moved.
    func copy(_ field: FieldResolvedValue, from item: SecretItemEntity) {
        vault.copyField(field)
        try? vault.container.itemRepository.recordItemAccess(item)
    }
}
