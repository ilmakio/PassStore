import SwiftUI
import UniformTypeIdentifiers

// MARK: - Sheet Button Style

/// Retained so older call sites keep compiling; new code uses `VaultButtonStyle` directly.
struct SheetCapsuleButtonStyle: ButtonStyle {
    let isPrimary: Bool

    func makeBody(configuration: Configuration) -> some View {
        VaultButtonStyle(isPrimary ? .primary : .secondary).makeBody(configuration: configuration)
    }
}

// MARK: - .env staging (merged into draft on Save)

private enum EnvImportSaveSupport {
    /// Applies staged paste / file contents into a copy of `base` when saving an `.env` item.
    static func draftForSave(
        viewModel: VaultViewModel,
        base: SecretItemDraft,
        pasteBuffer: String,
        parseIntoEntries: Bool,
        suggestedTitleFromFile: String?
    ) -> SecretItemDraft {
        var d = base
        guard d.type == .envGroup else { return d }
        guard !pasteBuffer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return d }
        viewModel.applyEnvImportContent(
            to: &d,
            raw: pasteBuffer,
            parseIntoEntries: parseIntoEntries,
            suggestedTitle: suggestedTitleFromFile
        )
        return d
    }
}

// MARK: - Editor header

/// What the header of the new / edit sheet says about a draft.
///
/// Shared so the two sheets cannot drift apart, and so the header can carry the *destination*
/// rather than restating the sheet's own title: the workspace's colour and its icon, with the
/// breadcrumb underneath. Opening this from inside a workspace already files the secret there,
/// and now the sheet looks like it.
enum ItemEditorHeader {
    static func workspace(for draft: SecretItemDraft, viewModel: VaultViewModel) -> WorkspaceEntity? {
        draft.workspaceID.flatMap { viewModel.workspace(for: $0) }
    }

    static func tint(for draft: SecretItemDraft, viewModel: VaultViewModel) -> Color {
        workspace(for: draft, viewModel: viewModel).map { Color(hex: $0.colorHex) } ?? .vaultAccent
    }

    /// The workspace's icon when there is one — it is the strongest answer to "where will this
    /// end up?" — and the kind's glyph when the secret belongs to no project.
    static func systemImage(for draft: SecretItemDraft, viewModel: VaultViewModel) -> String {
        workspace(for: draft, viewModel: viewModel)?.icon ?? draft.type.systemImage
    }

    static func subtitle(for draft: SecretItemDraft, viewModel: VaultViewModel) -> String {
        var parts: [String] = []
        if let workspace = workspace(for: draft, viewModel: viewModel) {
            parts.append(workspace.name)
        } else {
            parts.append("No workspace")
        }
        let environment = draft.environment.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !environment.isEmpty { parts.append(environment) }
        parts.append(draft.type.title)
        return parts.joined(separator: " · ")
    }

    /// A project's own colour for the confirming button, matching the header above it. Without a
    /// workspace there is no colour to borrow and the brand yellow is the right answer.
    static func saveRole(for draft: SecretItemDraft, viewModel: VaultViewModel) -> VaultButtonStyle.Role {
        guard let workspace = workspace(for: draft, viewModel: viewModel) else { return .primary }
        return .tinted(Color(hex: workspace.colorHex))
    }
}

// MARK: - Creation Flow

struct ItemCreationFlowSheet: View {
    @Environment(\.dismiss) private var dismiss

    @Bindable var viewModel: VaultViewModel
    @State private var draft: SecretItemDraft
    @State private var tagText = ""
    @State private var showWorkspaceSheet = false
    @State private var envImportPasteBuffer = ""
    @State private var envImportParseIntoEntries = true
    @State private var envImportSuggestedTitleFromFile: String?
    @State private var envImportSourceURL: URL?
    @State private var envImportLinkToFile = true

    init(viewModel: VaultViewModel) {
        self.viewModel = viewModel
        _draft = State(initialValue: viewModel.newItemDraft())
    }

    var body: some View {
        VaultSheetScaffold(
            title: "New Secret",
            subtitle: ItemEditorHeader.subtitle(for: draft, viewModel: viewModel),
            systemImage: ItemEditorHeader.systemImage(for: draft, viewModel: viewModel),
            tint: ItemEditorHeader.tint(for: draft, viewModel: viewModel),
            scrolls: false
        ) {
            Spacer(minLength: 0)

            Button("Cancel") { dismiss() }
                .buttonStyle(VaultButtonStyle(.secondary))
                .keyboardShortcut(.cancelAction)

            Button("Save") { save() }
                .buttonStyle(VaultButtonStyle(ItemEditorHeader.saveRole(for: draft, viewModel: viewModel)))
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
                .accessibilityIdentifier("creation-save")
        } content: {
            ItemEditorContent(
                viewModel: viewModel,
                availableWorkspaces: viewModel.workspaces,
                draft: $draft,
                tagText: $tagText,
                showWorkspaceSheet: $showWorkspaceSheet,
                showEnvImportStaging: true,
                envImportPasteBuffer: $envImportPasteBuffer,
                envImportParseIntoEntries: $envImportParseIntoEntries,
                envImportSuggestedTitleFromFile: $envImportSuggestedTitleFromFile,
                envImportSourceURL: $envImportSourceURL,
                envImportLinkToFile: $envImportLinkToFile
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 680, height: 700)
        .sheet(isPresented: $showWorkspaceSheet) {
            WorkspaceEditorSheet(title: "New Workspace", draft: .empty, onSave: onSaveWorkspace)
        }
    }

    private func save() {
        let toSave = EnvImportSaveSupport.draftForSave(
            viewModel: viewModel,
            base: draft,
            pasteBuffer: envImportPasteBuffer,
            parseIntoEntries: envImportParseIntoEntries,
            suggestedTitleFromFile: envImportSuggestedTitleFromFile
        )
        // If the contents came from a file, link the item to it here rather than making the
        // owner pick the same file again from the detail pane.
        let linkURL = envImportLinkToFile ? envImportSourceURL : nil
        viewModel.saveNewItem(toSave, linkingTo: linkURL, parsedIntoFields: envImportParseIntoEntries)
        dismiss()
    }

    /// Mirrors the title `EnvImportSaveSupport.draftForSave` would produce, without re-parsing the
    /// staged `.env` text on every keystroke: staging always supplies a fallback title.
    private var canSave: Bool {
        if !draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
        return draft.type == .envGroup
            && !envImportPasteBuffer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func onSaveWorkspace(_ workspaceDraft: WorkspaceDraft) {
        guard let workspace = viewModel.createWorkspace(workspaceDraft) else { return }
        draft.workspaceID = workspace.id
    }
}

// MARK: - Edit Sheet

struct ItemEditorSheet: View {
    @Environment(\.dismiss) private var dismiss

    @Bindable var viewModel: VaultViewModel
    let title: String
    let onSave: (SecretItemDraft) -> Void

    @State private var draft: SecretItemDraft
    @State private var tagText = ""
    @State private var showWorkspaceSheet = false

    init(
        viewModel: VaultViewModel,
        title: String,
        draft: SecretItemDraft,
        onSave: @escaping (SecretItemDraft) -> Void
    ) {
        self.viewModel = viewModel
        self.title = title
        self.onSave = onSave
        _draft = State(initialValue: draft)
    }

    var body: some View {
        VaultSheetScaffold(
            title: title,
            subtitle: ItemEditorHeader.subtitle(for: draft, viewModel: viewModel),
            systemImage: ItemEditorHeader.systemImage(for: draft, viewModel: viewModel),
            tint: ItemEditorHeader.tint(for: draft, viewModel: viewModel),
            scrolls: false
        ) {
            Spacer(minLength: 0)

            Button("Cancel") { dismiss() }
                .buttonStyle(VaultButtonStyle(.secondary))
                .keyboardShortcut(.cancelAction)

            Button("Save") {
                onSave(draft)
                dismiss()
            }
            .buttonStyle(VaultButtonStyle(ItemEditorHeader.saveRole(for: draft, viewModel: viewModel)))
            .keyboardShortcut(.defaultAction)
            .disabled(draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityIdentifier("editor-save")
        } content: {
            ItemEditorContent(
                viewModel: viewModel,
                availableWorkspaces: viewModel.workspaces,
                draft: $draft,
                tagText: $tagText,
                showWorkspaceSheet: $showWorkspaceSheet,
                showEnvImportStaging: false,
                envImportPasteBuffer: .constant(""),
                envImportParseIntoEntries: .constant(true),
                envImportSuggestedTitleFromFile: .constant(nil),
                envImportSourceURL: .constant(nil),
                envImportLinkToFile: .constant(false)
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 680, height: 700)
        .sheet(isPresented: $showWorkspaceSheet) {
            WorkspaceEditorSheet(title: "New Workspace", draft: .empty, onSave: handleWorkspaceSave)
        }
    }

    private func handleWorkspaceSave(_ workspaceDraft: WorkspaceDraft) {
        guard let workspace = viewModel.createWorkspace(workspaceDraft) else { return }
        draft.workspaceID = workspace.id
    }
}

// MARK: - .env import (new-item staging only)

private enum EnvStagingTab: String, CaseIterable, Identifiable {
    case importFile
    case paste

    var id: String { rawValue }

    var title: String {
        switch self {
        case .importFile: "Import"
        case .paste: "Paste"
        }
    }
}

private struct EnvGroupImportSection: View {
    @Bindable var viewModel: VaultViewModel
    @Binding var pasteBuffer: String
    @Binding var parseIntoEntries: Bool
    @Binding var suggestedTitleFromFile: String?
    /// The file the staged text came from. Carried all the way to Save so the new item can be
    /// linked to it without asking for the same file a second time.
    @Binding var sourceURL: URL?
    @Binding var linkToSourceFile: Bool

    @State private var stagingTab: EnvStagingTab = .importFile
    @State private var isImportDropTargeted = false
    @State private var isPasteDropTargeted = false

    private var hasStagedText: Bool {
        !pasteBuffer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VaultSection("Import .env", systemImage: "square.and.arrow.down") {
            Picker("", selection: $stagingTab) {
                ForEach(EnvStagingTab.allCases) { tab in
                    Text(tab.title).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityLabel("Import source")
            .accessibilityIdentifier("env-import-source-tab")

            Group {
                switch stagingTab {
                case .importFile:
                    importFilePanel
                case .paste:
                    pastePanel
                }
            }
            .animation(.easeInOut(duration: 0.15), value: stagingTab)

            if let sourceURL, hasStagedText {
                envFileLoadedFeedback(url: sourceURL)
            }

            Divider()

            Toggle("Parse KEY=value lines into separate fields", isOn: $parseIntoEntries)
                .toggleStyle(.checkbox)
                .help("When off, the entire file is stored as one multiline .env field.")

            if sourceURL != nil {
                Toggle("Keep a link to this file", isOn: $linkToSourceFile)
                    .toggleStyle(.checkbox)
                    .accessibilityIdentifier("env-import-keep-link")

                VaultNote(
                    text: linkToSourceFile
                        ? "When the file changes on disk, this item will offer to pull the new contents in — no re-importing by hand."
                        : "The contents are copied once. Later changes to the file will not be offered.",
                    tone: linkToSourceFile ? .success : .neutral,
                    systemImage: linkToSourceFile ? "link" : "link.badge.plus"
                )
            } else {
                VaultNote(text: "Staged text is merged into the fields below when you click Save. Import from a file instead of pasting to keep a link you can update later.")
            }
        }
        .onChange(of: pasteBuffer) { _, newValue in
            if newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                sourceURL = nil
            }
        }
    }

    private func envFileLoadedFeedback(url: URL) -> some View {
        HStack(alignment: .center, spacing: VaultSpacing.m) {
            Image(systemName: "checkmark.circle.fill")
                .font(.title3)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.green)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                Text(url.lastPathComponent)
                    .font(.vaultRowTitle)
                    .lineLimit(1)
                // The full path, so it is obvious *which* .env this is when several projects
                // all have one.
                Text((url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath)
                    .font(.vaultFootnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .textSelection(.enabled)
            }

            Spacer(minLength: 0)

            Button("Remove") {
                pasteBuffer = ""
                sourceURL = nil
                suggestedTitleFromFile = nil
            }
            .buttonStyle(.vaultLink)
            .font(.vaultFootnote)
            .accessibilityLabel("Remove the staged file")
        }
        .padding(VaultSpacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: VaultRadius.value, style: .continuous)
                .fill(Color.green.opacity(0.10))
                .overlay(
                    RoundedRectangle(cornerRadius: VaultRadius.value, style: .continuous)
                        .strokeBorder(Color.green.opacity(0.28), lineWidth: 0.5)
                )
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(".env file ready: \(url.lastPathComponent)")
        .accessibilityIdentifier("env-import-file-loaded-feedback")
    }

    private var importFilePanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isImportDropTargeted ? Color.vaultAccent.opacity(0.12) : Color(nsColor: .controlBackgroundColor))
                .frame(height: 120)
                .overlay(
                    VStack(spacing: 8) {
                        Image(systemName: "square.and.arrow.down.on.square")
                            .font(.system(size: 22, weight: .light))
                            .foregroundStyle(isImportDropTargeted ? Color.vaultAccentStrong : .secondary)
                        Text("Drop .env file here")
                            .font(.subheadline.weight(.semibold))
                        Text("Hidden files without extensions are supported.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(
                            isImportDropTargeted ? Color.vaultAccentStrong : Color.primary.opacity(0.1),
                            lineWidth: isImportDropTargeted ? 2 : 0.5
                        )
                )
                .onDrop(of: [UTType.fileURL], isTargeted: $isImportDropTargeted, perform: handleDropFileURL)

            Button("Choose File…", action: applyFromFile)
                .buttonStyle(VaultButtonStyle(.primary))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var pastePanel: some View {
        VaultField(".env contents") {
            TextEditor(text: $pasteBuffer)
                .scrollContentBackground(.hidden)
                .font(.system(.body, design: .monospaced))
                .frame(maxWidth: .infinity, minHeight: 140, alignment: .topLeading)
                .multilineTextAlignment(.leading)
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color(nsColor: .controlBackgroundColor))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(
                                    isPasteDropTargeted ? Color.vaultAccent.opacity(0.5) : Color.primary.opacity(0.06),
                                    lineWidth: isPasteDropTargeted ? 1.5 : 0.5
                                )
                        )
                )
                .accessibilityIdentifier("env-import-paste-editor")
                .onDrop(of: [UTType.fileURL, UTType.plainText], isTargeted: $isPasteDropTargeted, perform: handleDropPastePanel)
        }
    }

    private func applyFromFile() {
        Task {
            guard let picked = await viewModel.readEnvFileForImportOffMain() else { return }
            stage(picked)
        }
    }

    private func stage(_ picked: VaultViewModel.PickedEnvFile) {
        pasteBuffer = picked.contents
        suggestedTitleFromFile = picked.suggestedTitle
        sourceURL = picked.url
        linkToSourceFile = true
    }

    private func handleDropFileURL(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }) else {
            return false
        }
        provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
            guard let data, let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
            Task { @MainActor in
                guard let picked = await viewModel.readEnvFileOffMain(at: url) else { return }
                stage(picked)
            }
        }
        return true
    }

    private func handleDropPastePanel(_ providers: [NSItemProvider]) -> Bool {
        if let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }) {
            provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
                guard let data, let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                Task { @MainActor in
                    guard let picked = await viewModel.readEnvFileOffMain(at: url) else { return }
                    stage(picked)
                }
            }
            return true
        }
        if let provider = providers.first(where: { $0.canLoadObject(ofClass: String.self) }) {
            _ = provider.loadObject(ofClass: String.self) { string, _ in
                guard let string else { return }
                Task { @MainActor in
                    // Dropped text has no file behind it, so there is nothing to link to.
                    pasteBuffer = string
                    suggestedTitleFromFile = nil
                    sourceURL = nil
                }
            }
            return true
        }
        return false
    }
}

/// Where the keyboard is, across the whole form.
///
/// Held by the form rather than by each control so adding a field can hand focus to the field it
/// just made — the one thing the old "Add Field" button could not do, and the reason filling in a
/// handful of fields meant reaching for the mouse between every one of them.
private enum ItemEditorFocus: Hashable {
    case name
    case newFieldName
    case value(UUID)
}

/// The one form behind both "New Secret" and "Edit Secret".
///
/// Three pickers, a name, the fields, then the optional extras. Creating something used to start
/// on a separate page of template cards — a whole screen spent on one popup's worth of choice,
/// before you were allowed to type a name.
private struct ItemEditorContent: View {
    @Bindable var viewModel: VaultViewModel
    let availableWorkspaces: [WorkspaceEntity]

    @Binding var draft: SecretItemDraft
    @Binding var tagText: String
    @Binding var showWorkspaceSheet: Bool
    /// Staging UI (drop / paste before first save) is only shown when creating a new `.env` item.
    let showEnvImportStaging: Bool
    @Binding var envImportPasteBuffer: String
    @Binding var envImportParseIntoEntries: Bool
    @Binding var envImportSuggestedTitleFromFile: String?
    @Binding var envImportSourceURL: URL?
    @Binding var envImportLinkToFile: Bool

    /// Transient, and belongs to the form rather than to the draft: what is typed here is not
    /// part of the item until Return or Add turns it into a field.
    @State private var newFieldName = ""
    @State private var newFieldKind: FieldKind = .text
    @FocusState private var focus: ItemEditorFocus?

    private var accent: Color {
        selectedWorkspace.map { Color(hex: $0.colorHex) } ?? .vaultAccent
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: VaultSpacing.xl) {
                headerCard

                if draft.type == .envGroup, showEnvImportStaging {
                    EnvGroupImportSection(
                        viewModel: viewModel,
                        pasteBuffer: $envImportPasteBuffer,
                        parseIntoEntries: $envImportParseIntoEntries,
                        suggestedTitleFromFile: $envImportSuggestedTitleFromFile,
                        sourceURL: $envImportSourceURL,
                        linkToSourceFile: $envImportLinkToFile
                    )
                }

                fieldsSection

                // Everything above describes the secret. Below it is optional, and the rule says
                // so — without it the last required card and the first optional one were the
                // same twenty points apart as every other pair.
                Rectangle()
                    .fill(VaultChrome.hairline)
                    .frame(height: 1)
                    .padding(.vertical, VaultSpacing.xs)

                expirySection

                extrasSection
            }
            .padding(VaultSpacing.xl)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - Identity

    /// Untitled on purpose. The three pickers and the name *are* the top of the form; giving them
    /// a heading meant inventing a word for "the obvious part", and the header above already says
    /// what the sheet is.
    ///
    /// Destination first because it decides where the secret will be when you go looking for it —
    /// and because opening this from inside a workspace already files it there, which was true
    /// before and impossible to see with the picker four controls down.
    private var headerCard: some View {
        VaultCard {
            HStack(alignment: .top, spacing: VaultSpacing.m) {
                VaultField("Workspace") { workspaceMenu }
                VaultField("Environment") { environmentMenu }
                VaultField("Type") { typeMenu }
            }

            if draft.environment.kind == .custom {
                VaultField("Environment name") {
                    TextField("", text: Binding(
                        get: { draft.environment.customName ?? "" },
                        set: { draft.environment = .custom($0) }
                    ), prompt: Text("e.g. Staging EU"))
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.leading)
                    .accessibilityIdentifier("editor-custom-environment-field")
                }
            }

            VaultField("Name") {
                HStack(spacing: VaultSpacing.s) {
                    TextField("", text: $draft.title, prompt: Text("Required"))
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.leading)
                        .focused($focus, equals: .name)
                        .accessibilityIdentifier("editor-title-field")

                    favouriteButton
                }
            }
        }
    }

    /// A star on the end of the name, where you are already looking, instead of a checkbox
    /// captioned "Add to favourites" taking a whole row of the form for a one-bit decision.
    private var favouriteButton: some View {
        Button {
            draft.isFavorite.toggle()
        } label: {
            Image(systemName: draft.isFavorite ? "star.fill" : "star")
        }
        .buttonStyle(VaultIconButtonStyle(isActive: draft.isFavorite))
        .help(draft.isFavorite ? "Remove from favourites" : "Add to favourites")
        .accessibilityLabel("Favourite")
        .accessibilityIdentifier("editor-favorite-toggle")
    }

    private var selectedWorkspace: WorkspaceEntity? {
        availableWorkspaces.first { $0.id == draft.workspaceID }
    }

    /// Workspace chooser that shows the workspace's own icon and colour, and offers to make a
    /// new one from inside the same menu.
    private var workspaceMenu: some View {
        Menu {
            Button {
                draft.workspaceID = nil
            } label: {
                Label("No workspace", systemImage: "tray")
            }

            if !availableWorkspaces.isEmpty {
                Divider()
                ForEach(availableWorkspaces, id: \.id) { workspace in
                    Button {
                        draft.workspaceID = workspace.id
                    } label: {
                        Label(workspace.name, systemImage: workspace.icon)
                    }
                }
            }

            Divider()
            Button {
                showWorkspaceSheet = true
            } label: {
                Label("New Workspace…", systemImage: "folder.badge.plus")
            }
        } label: {
            menuLabel(
                systemImage: selectedWorkspace?.icon ?? "tray",
                title: selectedWorkspace?.name ?? "No workspace",
                isPlaceholder: selectedWorkspace == nil
            )
        }
        .accessibilityIdentifier("editor-workspace-picker")
    }

    /// The environments the *chosen workspace* actually has, first.
    ///
    /// This was a segmented control over the five global presets, which is not what a project
    /// with "Local, Staging EU, Prod" has — so filing a secret in one of its own environments
    /// meant picking Custom and typing the name again, exactly right, from memory.
    private var offeredEnvironments: [ResolvedWorkspaceEnvironment] {
        guard let id = draft.workspaceID else { return [] }
        return viewModel.offeredEnvironments(inWorkspace: id)
    }

    private var otherPresetKinds: [EnvironmentKind] {
        let taken = Set(offeredEnvironments.map { WorkspaceEnvironment.matchKey(for: $0.title) })
        return EnvironmentKind.allCases.filter {
            $0 != .custom && !taken.contains(WorkspaceEnvironment.matchKey(for: $0.title))
        }
    }

    private var environmentMenu: some View {
        Menu {
            let offered = offeredEnvironments
            if !offered.isEmpty {
                Section("In this workspace") {
                    ForEach(offered) { environment in
                        Button {
                            draft.environment = environment.environmentValue
                        } label: {
                            Label(environment.title, systemImage: environment.systemImage)
                        }
                    }
                }
            }

            let others = otherPresetKinds
            if !others.isEmpty {
                // Unheaded when the workspace declared nothing, because then there is no
                // "elsewhere" for these to be elsewhere *from* — they are the whole list.
                if offered.isEmpty {
                    ForEach(others) { kind in
                        presetButton(kind)
                    }
                } else {
                    Section("Elsewhere") {
                        ForEach(others) { kind in
                            presetButton(kind)
                        }
                    }
                }
            }

            Divider()
            Button {
                draft.environment = .custom(draft.environment.customName ?? "")
            } label: {
                Label("Custom Name…", systemImage: "pencil")
            }
        } label: {
            menuLabel(
                systemImage: draft.environment.kind.systemImage,
                title: environmentLabel,
                isPlaceholder: false
            )
        }
        .accessibilityIdentifier("editor-environment-picker")
    }

    private func presetButton(_ kind: EnvironmentKind) -> some View {
        Button {
            draft.environment = .preset(kind)
        } label: {
            Label(kind.title, systemImage: kind.systemImage)
        }
    }

    private var environmentLabel: String {
        let title = draft.environment.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? "Custom" : title
    }

    /// Templates, not just item types: a custom template used to be reachable only from the page
    /// of cards this sheet opened on, so removing that page would have hidden them for good.
    private var typeMenu: some View {
        Menu {
            templateGroup("Common", viewModel.featuredTemplates)
            templateGroup("Built-in", viewModel.standardBuiltInTemplates)
            templateGroup("Custom", viewModel.customTemplates)
        } label: {
            menuLabel(
                systemImage: draft.type.systemImage,
                title: viewModel.template(for: draft.templateID)?.name ?? draft.type.title,
                isPlaceholder: false
            )
        }
        .accessibilityIdentifier("editor-item-type-picker")
    }

    @ViewBuilder
    private func templateGroup(_ title: String, _ templates: [SecretFieldTemplateEntity]) -> some View {
        if !templates.isEmpty {
            Section(title) {
                ForEach(templates, id: \.id) { template in
                    Button {
                        viewModel.applyTemplateChange(to: &draft, template: template)
                    } label: {
                        Label(template.name, systemImage: template.itemType.systemImage)
                    }
                }
            }
        }
    }

    /// The three pickers read as one row of three of the same thing, so they are laid out by one
    /// function rather than three near-identical `HStack`s.
    private func menuLabel(systemImage: String, title: String, isPlaceholder: Bool) -> some View {
        HStack(spacing: VaultSpacing.s) {
            Image(systemName: systemImage)
                .foregroundStyle(isPlaceholder ? AnyShapeStyle(.secondary) : AnyShapeStyle(accent.vaultInk))
            Text(title)
                .foregroundStyle(isPlaceholder ? .secondary : .primary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    // MARK: - Fields

    private var fieldsSection: some View {
        VaultSection("Fields", systemImage: "list.bullet", tint: accent) {
            if draft.fieldDrafts.isEmpty {
                VaultNote(text: "This type has no predefined fields. Name one below to add it.")
            }

            ForEach(Array($draft.fieldDrafts.enumerated()), id: \.element.id) { index, $field in
                SimpleFieldEditor(
                    field: $field,
                    itemType: draft.type,
                    focus: $focus,
                    onSubmitValue: { focusValueAfter(index) },
                    onRemove: { removeField(id: field.id) },
                    canMoveUp: index > 0,
                    canMoveDown: index < draft.fieldDrafts.count - 1,
                    onMoveUp: { moveField(from: index, to: index - 1) },
                    onMoveDown: { moveField(from: index, to: index + 1) },
                    onCopyGenerated: { viewModel.copyGeneratedPassword($0) }
                )
                if field.id != draft.fieldDrafts.last?.id {
                    Divider()
                }
            }

            Divider()

            addFieldRow
        }
    }

    /// Name it, pick what kind of value it holds, press Return.
    ///
    /// Adding a field used to mean finding a switch called "Advanced", turning it on — which also
    /// unfolded three rows of controls under every existing field — then pressing "Add Field" to
    /// get something called "New Field" that had to be renamed in yet another box. This is one
    /// line, always visible, and Return moves to the value you were about to type rather than
    /// leaving you here with a named but empty field.
    private var addFieldRow: some View {
        VStack(alignment: .leading, spacing: VaultSpacing.xs) {
            HStack(alignment: .center, spacing: VaultSpacing.s) {
                Image(systemName: "plus.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)

                TextField("", text: $newFieldName, prompt: Text("New field name"))
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.leading)
                    .focused($focus, equals: .newFieldName)
                    .onSubmit(addNamedField)
                    .accessibilityLabel("New field name")
                    .accessibilityIdentifier("editor-new-field-name")

                Picker("", selection: $newFieldKind) {
                    ForEach(FieldKind.allCases) { kind in
                        Text(kind.title).tag(kind)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
                .accessibilityLabel("New field kind")
                .accessibilityIdentifier("editor-new-field-kind")

                Button("Add", action: addNamedField)
                    .buttonStyle(VaultButtonStyle(.secondary))
                    .controlSize(.small)
                    .disabled(trimmedNewFieldName.isEmpty)
                    .accessibilityIdentifier("editor-add-field")
            }

            VaultNote(text: "Return adds the field and moves to its value; Return there comes back here for the next one.")
        }
    }

    private var trimmedNewFieldName: String {
        newFieldName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Extras

    /// Tags and notes in one card with a rule between them.
    ///
    /// They were two cards of their own, which gave two optional afterthoughts the same weight
    /// as the fields.
    /// When this credential stops working, if its owner knows.
    ///
    /// Off by default and one toggle away, because most secrets have no expiry and a date picker
    /// demanding a value for all of them would be answered with a lie.
    private var expirySection: some View {
        VaultSection("Expiry", systemImage: "calendar.badge.clock", tint: accent) {
            Toggle("This secret expires", isOn: expiryEnabled)
                .toggleStyle(.checkbox)
                .accessibilityIdentifier("editor-expiry-toggle")

            if let expiry = draft.expiresAt {
                DatePicker(
                    "Expires on",
                    selection: Binding(
                        get: { expiry },
                        set: { draft.expiresAt = Calendar.current.startOfDay(for: $0) }
                    ),
                    displayedComponents: .date
                )
                .datePickerStyle(.field)
                .accessibilityIdentifier("editor-expiry-date")

                VaultNote(
                    text: expiry <= Date()
                        ? "This date has passed. Vault Health lists it as expired."
                        : "Vault Health starts reminding you a month before this date."
                )
            } else {
                VaultNote(text: "Useful for the things that stop working on a date somebody else chose: API keys with a lifetime, certificates, access tokens, rotation deadlines.")
            }
        }
    }

    /// Turning it on proposes a date rather than an empty picker; turning it off forgets it.
    private var expiryEnabled: Binding<Bool> {
        Binding(
            get: { draft.expiresAt != nil },
            set: { isOn in
                guard isOn else {
                    draft.expiresAt = nil
                    return
                }
                guard draft.expiresAt == nil else { return }
                let proposed = Calendar.current.date(byAdding: .day, value: 90, to: Date()) ?? Date()
                draft.expiresAt = Calendar.current.startOfDay(for: proposed)
            }
        )
    }

    private var extrasSection: some View {
        VaultSection("Tags and Notes", systemImage: "tag", tint: accent) {
            VaultField("Tags") {
                VStack(alignment: .leading, spacing: VaultSpacing.s) {
                    HStack(alignment: .center, spacing: VaultSpacing.s) {
                        TextField("", text: $tagText, prompt: Text("Type a tag, then Add or press Return"))
                            .textFieldStyle(.roundedBorder)
                            .multilineTextAlignment(.leading)
                            .onSubmit(addTag)
                        Button("Add", action: addTag)
                            .buttonStyle(VaultButtonStyle(.secondary))
                            .controlSize(.small)
                            .disabled(tagText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }

                    if !draft.tags.isEmpty {
                        FlowTagView(tags: draft.tags) { tag in
                            draft.tags.removeAll { $0 == tag }
                        }
                    }
                }
            }

            Divider()

            VaultField("Notes") {
                VaultTextEditor(text: $draft.notes, placeholder: "Optional notes for this item")
            }
        }
    }

    // MARK: - Mutations

    private func addTag() {
        let tag = tagText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tag.isEmpty, !draft.tags.contains(tag) else {
            tagText = ""
            return
        }
        draft.tags.append(tag)
        tagText = ""
    }

    /// Adds the field named in the add row and puts the cursor in its value.
    private func addNamedField() {
        let label = trimmedNewFieldName
        guard !label.isEmpty else { return }

        var field = FieldDraft(
            key: uniqueFieldKey(base: slugifiedFieldKey(from: label)),
            label: label,
            value: "",
            kind: .text,
            isSensitive: false,
            sortOrder: draft.fieldDrafts.count
        )
        // Same rule as changing the kind of an existing field, rather than a second copy of it.
        field.applyKind(newFieldKind)
        draft.fieldDrafts.append(field)
        newFieldName = ""
        newFieldKind = .text
        focusValue(field.id)
    }

    /// Focus has to wait for the row to exist: asking for it in the same pass that appends the
    /// field aims at a text field SwiftUI has not built yet, and the request is dropped.
    private func focusValue(_ id: UUID) {
        Task { @MainActor in
            await Task.yield()
            focus = .value(id)
        }
    }

    /// Return in a value goes to the next field's value, and off the end of the list back to the
    /// add row — so a whole set of fields can be typed without touching the mouse.
    private func focusValueAfter(_ index: Int) {
        let next = index + 1
        if draft.fieldDrafts.indices.contains(next) {
            focus = .value(draft.fieldDrafts[next].id)
        } else {
            focus = .newFieldName
        }
    }

    private func removeField(id: UUID) {
        draft.fieldDrafts.removeAll { $0.id == id }
        renumberFields()
    }

    private func moveField(from source: Int, to destination: Int) {
        let fields = draft.fieldDrafts
        guard fields.indices.contains(source), fields.indices.contains(destination) else { return }
        draft.fieldDrafts.swapAt(source, destination)
        renumberFields()
    }

    /// `sortOrder` drives display order everywhere downstream, so keep it in sync with the array.
    private func renumberFields() {
        for index in draft.fieldDrafts.indices {
            draft.fieldDrafts[index].sortOrder = index
        }
    }

    private func slugifiedFieldKey(from label: String) -> String {
        let slug = label
            .folding(options: .diacriticInsensitive, locale: .current)
            .lowercased()
            .map { $0.isLetter || $0.isNumber ? $0 : "_" }
            .reduce(into: "") { partial, character in
                if character == "_", partial.last == "_" || partial.isEmpty { return }
                partial.append(character)
            }
        let trimmed = slug.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        return trimmed.isEmpty ? "field" : trimmed
    }

    /// Storage keys are the identity used when merging drafts back onto an item, so they must not collide.
    private func uniqueFieldKey(base: String) -> String {
        let existing = Set(draft.fieldDrafts.map(\.key))
        guard existing.contains(base) else { return base }
        var suffix = 2
        while existing.contains("\(base)_\(suffix)") { suffix += 1 }
        return "\(base)_\(suffix)"
    }
}

// MARK: - Workspace Editor Sheet

struct WorkspaceEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let onSave: (WorkspaceDraft) -> Void
    /// What the workspace's items say about its environments, so the editor can both list the
    /// ones already in use and say how much is in each. Empty for a new workspace.
    let environmentUsage: WorkspaceEnvironmentUsage
    @State private var draft: WorkspaceDraft
    /// Environments whose `.env` file mapping is open for editing. A mapping that already exists
    /// is always shown; the rest stay behind a menu entry so the common row keeps one line.
    @State private var mappingEditorIDs: Set<UUID> = []

    init(
        title: String,
        draft: WorkspaceDraft,
        environmentUsage: WorkspaceEnvironmentUsage = WorkspaceEnvironmentUsage(),
        onSave: @escaping (WorkspaceDraft) -> Void
    ) {
        self.title = title
        self.onSave = onSave
        self.environmentUsage = environmentUsage
        _draft = State(initialValue: draft)
    }

    var body: some View {
        VaultSheetScaffold(
            title: title,
            subtitle: "Workspaces group secrets by project or team.",
            systemImage: draft.icon,
            tint: Color(hex: draft.colorHex)
        ) {
            Spacer(minLength: 0)
            Button("Cancel") { dismiss() }
                .buttonStyle(VaultButtonStyle(.secondary))
                .keyboardShortcut(.cancelAction)
            Button("Save") {
                onSave(draft)
                dismiss()
            }
            .buttonStyle(VaultButtonStyle(.primary))
            .keyboardShortcut(.defaultAction)
            .disabled(
                draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || environmentProblem != nil
            )
            .accessibilityIdentifier("workspace-save")
        } content: {
            legacyBody
        }
        .frame(width: 460, height: 620)
    }

    private var legacyBody: some View {
        Group {
                VStack(alignment: .leading, spacing: VaultSpacing.xl) {
                    VaultCard {
                        HStack(spacing: 14) {
                            VaultGlyphTile(
                                systemImage: draft.icon,
                                tint: Color(hex: draft.colorHex),
                                size: 46,
                                cornerRadius: 12,
                                glyphSize: 20,
                                castsShadow: false
                            )
                            VStack(alignment: .leading, spacing: 2) {
                                Text(draft.name.isEmpty ? "New Workspace" : draft.name)
                                    .font(.headline)
                                    .foregroundStyle(draft.name.isEmpty ? .secondary : .primary)
                                if let colorPreset = WorkspaceStylePresets.color(for: draft.colorHex) {
                                    Text(colorPreset.name)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 2)
                    }

                    VaultSection("Basics", systemImage: "textformat") {
                        VaultField("Name") {
                            TextField("", text: $draft.name, prompt: Text("e.g. Production API"))
                                .textFieldStyle(.roundedBorder)
                                .multilineTextAlignment(.leading)
                                .accessibilityIdentifier("workspace-name-field")
                        }

                        VaultField("Notes") {
                            VaultTextEditor(
                                text: $draft.notes,
                                placeholder: "Optional context for this workspace",
                                minHeight: 60
                            )
                        }
                    }

                    environmentsSection

                    VaultSection("Icon", systemImage: "app.badge") {
                        LazyVGrid(
                            columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 5),
                            spacing: 6
                        ) {
                            ForEach(WorkspaceStylePresets.icons) { preset in
                                Button { draft.icon = preset.systemImage } label: {
                                    let isActive = draft.icon == preset.systemImage
                                    VStack(spacing: 5) {
                                        Image(systemName: preset.systemImage)
                                            .font(.system(size: 15, weight: .medium))
                                        Text(preset.label)
                                            .font(.caption2)
                                            .lineLimit(1)
                                    }
                                    .foregroundStyle(isActive ? Color(hex: draft.colorHex) : .secondary)
                                    .frame(maxWidth: .infinity, minHeight: 48)
                                    .background(
                                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                                            .fill(isActive
                                                  ? Color(hex: draft.colorHex).opacity(0.12)
                                                  : Color.clear)
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.vertical, 2)
                    }

                    VaultSection("Color", systemImage: "paintpalette") {
                        ForEach(WorkspaceStylePresets.colors) { preset in
                            Button { draft.colorHex = preset.hex } label: {
                                HStack(spacing: 10) {
                                    Circle()
                                        .fill(preset.color)
                                        .frame(width: 13, height: 13)
                                    Text(preset.name)
                                        .foregroundStyle(.primary)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .multilineTextAlignment(.leading)
                                    if draft.colorHex.caseInsensitiveCompare(preset.hex) == .orderedSame {
                                        Image(systemName: "checkmark")
                                            .font(.system(size: 11, weight: .semibold))
                                            .foregroundStyle(Color.vaultAccentStrong)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Environments

    /// The environments this workspace has: one list, no distinction between the ones written
    /// down and the ones its secrets are simply using. Leaving it empty keeps the workspace a
    /// plain folder of secrets, which is a perfectly good thing for it to be.
    private var environmentsSection: some View {
        VaultSection("Environments", systemImage: "circle.hexagongrid") {
            VStack(alignment: .leading, spacing: VaultSpacing.s) {
                if draft.environments.isEmpty {
                    Text("The copies of this project you keep secrets for. Add some and each gets its own tab; leave this empty and the workspace stays a plain folder of secrets.")
                        .font(.vaultFootnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .multilineTextAlignment(.leading)

                    Button("Add Local, Staging and Prod") { addLifecycleEnvironments() }
                        .buttonStyle(VaultButtonStyle(.secondary))
                        .accessibilityIdentifier("workspace-add-lifecycle-environments")
                }

                // Bound by element rather than by index. An index-based binding outlives the row
                // it came from: removing an environment left the binding of every row after it
                // pointing one place too far along an array that had just got shorter.
                ForEach($draft.environments) { $environment in
                    if position(of: environment.id) != 0 {
                        Divider().opacity(0.4)
                    }
                    environmentRow($environment)
                }

                if let environmentProblem {
                    VaultNote(text: environmentProblem, tone: .warning)
                }

                if draft.environments.contains(where: { !$0.isEnabled }) {
                    VaultNote(
                        text: "A hidden environment is kept out of the sidebar and the tabs. Its secrets stay in your vault and still turn up in All Items — and while it holds any, it keeps its row so nothing goes missing."
                    )
                }

                addEnvironmentMenu
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func environmentRow(_ environment: Binding<WorkspaceEnvironment>) -> some View {
        let value = environment.wrappedValue
        let index = position(of: value.id) ?? 0
        let count = environmentUsage.count(forMatchKey: value.matchKey)

        VStack(alignment: .leading, spacing: VaultSpacing.xs) {
            HStack(spacing: VaultSpacing.s) {
                // The workspace's own colour, with the glyph doing the distinguishing: an
                // environment does not get a palette of its own.
                Image(systemName: value.systemImage)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color(hex: draft.colorHex))
                    .opacity(value.isEnabled ? 1 : 0.4)
                    .frame(width: 14)
                    .accessibilityHidden(true)

                if value.kind == .custom {
                    TextField("", text: environment.name, prompt: Text("e.g. QA"))
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 180)
                        .accessibilityIdentifier("workspace-environment-name-\(index)")
                } else {
                    Text(value.name)
                        .font(.vaultRowTitle)
                }

                if count > 0 {
                    Text("\(count) \(count == 1 ? "item" : "items")")
                        .font(.vaultBadge)
                        .foregroundStyle(.secondary)
                }

                if !value.isEnabled {
                    VaultChip(title: "Hidden")
                }

                Spacer(minLength: 0)

                Menu {
                    environmentRowMenu(environment, itemCount: count)
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 13))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .accessibilityIdentifier("workspace-environment-menu-\(index)")
            }

            if value.envFileName != nil || mappingEditorIDs.contains(value.id) {
                HStack(spacing: VaultSpacing.s) {
                    Image(systemName: "doc.text")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .frame(width: 14)
                        .accessibilityHidden(true)
                    TextField(
                        "",
                        text: Binding(
                            get: { environment.wrappedValue.envFileName ?? "" },
                            // Cleared back to nil rather than to an empty string, so an emptied
                            // field means "no mapping" instead of a mapping to a file called "".
                            set: { environment.wrappedValue.envFileName = $0.isEmpty ? nil : $0 }
                        ),
                        prompt: Text("e.g. .env.production")
                    )
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 220)
                    .accessibilityLabel("File this environment maps to")
                    .accessibilityIdentifier("workspace-environment-file-\(index)")

                    Text("in the linked project folder")
                        .font(.vaultBadge)
                        .foregroundStyle(.tertiary)
                }
                .padding(.leading, VaultSpacing.xs)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func environmentRowMenu(
        _ environment: Binding<WorkspaceEnvironment>,
        itemCount: Int
    ) -> some View {
        let value = environment.wrappedValue
        let index = position(of: value.id)

        Button(value.isEnabled ? "Hide from Sidebar" : "Show in Sidebar") {
            environment.wrappedValue.isEnabled.toggle()
        }

        if value.kind != .custom {
            // Presets are named by their kind, so renaming one means making it a custom
            // environment. Saving then moves the items that were in it.
            Button("Use a Custom Name…") {
                environment.wrappedValue.kind = .custom
            }
        }

        if value.envFileName == nil, !mappingEditorIDs.contains(value.id) {
            Button("Map to a .env File…") { mappingEditorIDs.insert(value.id) }
        }

        Button("Move Up") { moveEnvironment(id: value.id, by: -1) }
            .disabled(index == 0)
        Button("Move Down") { moveEnvironment(id: value.id, by: 1) }
            .disabled(index == nil || index! >= draft.environments.count - 1)

        Divider()

        Button("Remove from Workspace", role: .destructive) {
            removeEnvironment(id: value.id)
        }
        // Removing one that still holds secrets would look like it took them with it. Move them
        // out first, or rename this environment and the secrets follow.
        .disabled(itemCount > 0)
    }

    private var addEnvironmentMenu: some View {
        Menu {
            ForEach(EnvironmentKind.allCases.filter { $0 != .custom }) { kind in
                Button(kind.title) { addEnvironment(kind: kind) }
                    .disabled(draft.environments.contains {
                        $0.matchKey == WorkspaceEnvironment.matchKey(for: kind.title)
                    })
            }
            Divider()
            Button("Custom…") { addEnvironment(kind: .custom) }
        } label: {
            Label("Add Environment", systemImage: "plus")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(draft.environments.count >= WorkspaceEnvironment.maximumPerWorkspace)
        .accessibilityIdentifier("workspace-add-environment")
    }

    /// Blocks a save that would silently lose a declaration, rather than letting the vault's own
    /// de-duplication drop it without saying so.
    private var environmentProblem: String? {
        let named = draft.environments.filter {
            $0.kind != .custom || !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        if named.count != draft.environments.count {
            return "Give every environment a name, or remove the empty one."
        }
        let keys = draft.environments.map(\.matchKey)
        if Set(keys).count != keys.count {
            return "Two environments have the same name."
        }
        return nil
    }

    private func position(of id: UUID) -> Int? {
        draft.environments.firstIndex { $0.id == id }
    }

    private func addEnvironment(kind: EnvironmentKind) {
        draft.environments.append(
            WorkspaceEnvironment(
                name: kind == .custom ? "" : kind.title,
                kind: kind,
                sortOrder: draft.environments.count
            )
        )
    }

    /// The lifecycle almost every project has, in one gesture instead of three trips to a menu.
    private func addLifecycleEnvironments() {
        for kind in [EnvironmentKind.local, .staging, .prod] {
            guard !draft.environments.contains(where: {
                $0.matchKey == WorkspaceEnvironment.matchKey(for: kind.title)
            }) else { continue }
            draft.environments.append(
                WorkspaceEnvironment(name: kind.title, kind: kind, sortOrder: draft.environments.count)
            )
        }
    }

    private func moveEnvironment(id: UUID, by offset: Int) {
        guard let source = position(of: id) else { return }
        let destination = source + offset
        guard draft.environments.indices.contains(destination) else { return }
        let environment = draft.environments.remove(at: source)
        draft.environments.insert(environment, at: destination)
        renumberEnvironments()
    }

    private func removeEnvironment(id: UUID) {
        guard let index = position(of: id) else { return }
        draft.environments.remove(at: index)
        mappingEditorIDs.remove(id)
        renumberEnvironments()
    }

    private func renumberEnvironments() {
        for index in draft.environments.indices {
            draft.environments[index].sortOrder = index
        }
    }
}

// MARK: - .env files

/// One found `.env` file, and what will become of it.
///
/// Shared by the two places a `.env` gets in — setting up a new workspace from its folder, and
/// pulling more in later — because the decision is the same one both times.
private struct EnvFilePlanRow: View {
    let plan: EnvFileImportPlan
    let environmentOptions: [EnvironmentValue]
    let identifierPrefix: String
    let onSelect: (Bool) -> Void
    let onChangeEnvironment: (EnvironmentValue) -> Void
    let onChangeParsing: (Bool) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: VaultSpacing.m) {
            Toggle("", isOn: Binding(get: { plan.isSelected }, set: onSelect))
                .labelsHidden()
                .accessibilityIdentifier("\(identifierPrefix)-select-\(plan.id)")
                .accessibilityLabel("Import \(plan.file.relativePath)")

            VStack(alignment: .leading, spacing: VaultSpacing.xs) {
                HStack(spacing: VaultSpacing.s) {
                    Text(plan.file.relativePath)
                        .font(.vaultValueSmall)
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(byteDescription(plan.file.byteCount))
                        .font(.vaultBadge)
                        .foregroundStyle(.tertiary)
                    if plan.file.isTemplate {
                        VaultChip(title: "Example", systemImage: "doc.plaintext")
                    }
                    if plan.file.isAlreadyLinked {
                        VaultChip(title: "Already imported", systemImage: "link", color: .orange)
                    }
                    Spacer(minLength: 0)
                }

                if plan.isSelected {
                    HStack(spacing: VaultSpacing.s) {
                        Text("goes in")
                            .font(.vaultBadge)
                            .foregroundStyle(.tertiary)

                        Picker("", selection: Binding(
                            get: { plan.environment },
                            set: onChangeEnvironment
                        )) {
                            ForEach(environmentOptions, id: \.self) { option in
                                Text(option.title).tag(option)
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: 150)
                        .accessibilityLabel("Environment for \(plan.file.relativePath)")
                        .accessibilityIdentifier("\(identifierPrefix)-environment-\(plan.id)")

                        Toggle("Split into one field per key", isOn: Binding(
                            get: { plan.parsesIntoFields },
                            set: onChangeParsing
                        ))
                        .toggleStyle(.checkbox)
                        .font(.vaultFootnote)
                        .help("On: each KEY=value line becomes its own field, so you can copy one at a time. Off: the file is kept as a single block of text.")
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func byteDescription(_ count: Int) -> String {
        count < 1_024 ? "\(count) bytes" : "\(count / 1_024) KB"
    }
}

/// Everything a workspace already has, plus the presets, plus whatever a file suggested — so a
/// `.env.qa` can stay "Qa" without being forced into one of the four built-in names.
private func environmentPickerOptions(
    existing: [EnvironmentValue],
    including current: EnvironmentValue
) -> [EnvironmentValue] {
    var options = existing
    for kind in EnvironmentKind.allCases where kind != .custom {
        options.append(.preset(kind))
    }
    options.append(current)

    var seen: Set<String> = []
    return options.filter { seen.insert(WorkspaceEnvironment.matchKey(for: $0.title)).inserted }
}

// MARK: - New workspace, from a folder

/// A whole workspace proposed from a folder, for review before anything is created.
///
/// A repository already knows its own name, and the `.env` files sitting next to its code already
/// say which environments it has. Asking someone to type all that in and *then* point at the
/// folder is asking them to describe something the folder just described itself.
struct NewWorkspaceFromFolderSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var viewModel: VaultViewModel

    private var state: VaultViewModel.NewWorkspaceFromFolder? { viewModel.newWorkspaceFromFolder }

    var body: some View {
        VaultSheetScaffold(
            title: "New Workspace",
            subtitle: state.map { ($0.folderPath as NSString).abbreviatingWithTildeInPath } ?? "",
            systemImage: "folder.badge.gearshape",
            tint: state.map { Color(hex: $0.colorHex) } ?? .vaultAccent
        ) {
            Spacer(minLength: 0)
            Button("Cancel") {
                viewModel.newWorkspaceFromFolder = nil
                dismiss()
            }
            .buttonStyle(VaultButtonStyle(.secondary))
            .keyboardShortcut(.cancelAction)

            Button(state?.isWorking == true ? "Creating…" : "Create Workspace") {
                Task {
                    await viewModel.createWorkspaceFromFolder()
                    dismiss()
                }
            }
            .buttonStyle(VaultButtonStyle(.primary))
            .keyboardShortcut(.defaultAction)
            .disabled(state?.canCreate != true)
            .accessibilityIdentifier("new-workspace-create")
        } content: {
            if let state {
                VStack(alignment: .leading, spacing: VaultSpacing.xl) {
                    identitySection(state)
                    filesSection(state)
                    outcome(state)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: 660, height: 640)
    }

    private func identitySection(_ state: VaultViewModel.NewWorkspaceFromFolder) -> some View {
        VaultSection("Name and Look", systemImage: "textformat") {
            VStack(alignment: .leading, spacing: VaultSpacing.m) {
                TextField(
                    "",
                    text: Binding(get: { state.name }, set: viewModel.setNewWorkspaceName),
                    prompt: Text("Workspace name")
                )
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Workspace name")
                .accessibilityIdentifier("new-workspace-name")

                // The same presets the editor offers, laid out tighter: this sheet is a review,
                // not the place to spend time on decoration.
                HStack(spacing: VaultSpacing.s) {
                    ForEach(WorkspaceStylePresets.colors) { preset in
                        Button { viewModel.setNewWorkspaceColor(preset.hex) } label: {
                            Circle()
                                .fill(preset.color)
                                .frame(width: 18, height: 18)
                                .overlay(
                                    Circle().strokeBorder(
                                        .primary.opacity(
                                            state.colorHex.caseInsensitiveCompare(preset.hex) == .orderedSame ? 0.55 : 0
                                        ),
                                        lineWidth: 2
                                    )
                                )
                        }
                        .buttonStyle(.plain)
                        .help(preset.name)
                        .accessibilityLabel(preset.name)
                    }
                    Spacer(minLength: 0)
                }

                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 5),
                    spacing: 6
                ) {
                    ForEach(WorkspaceStylePresets.icons) { preset in
                        Button { viewModel.setNewWorkspaceIcon(preset.systemImage) } label: {
                            let isActive = state.icon == preset.systemImage
                            VStack(spacing: 4) {
                                Image(systemName: preset.systemImage)
                                    .font(.system(size: 14, weight: .medium))
                                Text(preset.label)
                                    .font(.caption2)
                                    .lineLimit(1)
                            }
                            .foregroundStyle(isActive ? Color(hex: state.colorHex) : .secondary)
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(isActive ? Color(hex: state.colorHex).opacity(0.12) : Color.clear)
                            )
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(preset.label)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func filesSection(_ state: VaultViewModel.NewWorkspaceFromFolder) -> some View {
        VaultSection(
            state.plans.isEmpty ? "No .env Files Found" : "Found \(state.plans.count) .env \(state.plans.count == 1 ? "File" : "Files")",
            systemImage: "doc.text.magnifyingglass"
        ) {
            VStack(alignment: .leading, spacing: VaultSpacing.m) {
                if state.plans.isEmpty {
                    Text("PassStore looked at file names only and opened nothing. You can still create the workspace and add secrets by hand.")
                        .font(.vaultFootnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .multilineTextAlignment(.leading)
                } else {
                    Text("Each file you keep ticked becomes one secret, linked to that file so it can be pulled in again later. Nothing is read until you create the workspace.")
                        .font(.vaultFootnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .multilineTextAlignment(.leading)

                    if state.didReachLimit {
                        VaultNote(
                            text: "This folder holds more .env files than one scan lists. Create the workspace with these, then look again from inside it.",
                            tone: .warning
                        )
                    }

                    ForEach(state.plans) { plan in
                        EnvFilePlanRow(
                            plan: plan,
                            environmentOptions: environmentPickerOptions(existing: [], including: plan.environment),
                            identifierPrefix: "new-workspace-file",
                            onSelect: { viewModel.setNewWorkspaceSelection($0, forFileID: plan.id) },
                            onChangeEnvironment: { viewModel.setNewWorkspaceEnvironment($0, forFileID: plan.id) },
                            onChangeParsing: { viewModel.setNewWorkspaceParsing($0, forFileID: plan.id) }
                        )
                        if plan.id != state.plans.last?.id {
                            Divider().opacity(0.4)
                        }
                    }
                }
            }
        }
    }

    /// Says what the button is about to do, in the same words as the thing it will produce. The
    /// environments are not a separate decision — they are whichever ones the ticked files land in.
    private func outcome(_ state: VaultViewModel.NewWorkspaceFromFolder) -> some View {
        let name = state.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let environments = state.environmentValues.map(\.title)
        let count = state.selectedCount

        var sentence = "Creates “\(name.isEmpty ? "Untitled" : name)”"
        if !environments.isEmpty {
            sentence += " with \(environments.joined(separator: ", "))"
        }
        if count > 0 {
            sentence += ", and \(count) \(count == 1 ? "secret" : "secrets")"
        }
        sentence += ". The folder stays linked so you can pull in changes later."

        return VaultNote(text: sentence)
            .accessibilityIdentifier("new-workspace-outcome")
    }
}

// MARK: - Finding more .env files

/// The `.env` files found in a workspace's linked folder, listed before anything is imported.
///
/// Nothing here has been read yet: discovery looked at names and sizes only. Ticking a file is
/// what gives PassStore permission to open it, which is why the list arrives with the plain
/// secret files ticked and the example files not.
struct EnvDiscoverySheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var viewModel: VaultViewModel
    let workspaceID: UUID

    private var state: VaultViewModel.EnvDiscoveryState? {
        guard let state = viewModel.envDiscovery, state.workspaceID == workspaceID else { return nil }
        return state
    }

    var body: some View {
        VaultSheetScaffold(
            title: "Import .env Files",
            subtitle: state.map { ($0.folderPath as NSString).abbreviatingWithTildeInPath } ?? "",
            systemImage: "folder.badge.gearshape"
        ) {
            Spacer(minLength: 0)
            Button("Cancel") {
                viewModel.envDiscovery = nil
                dismiss()
            }
            .buttonStyle(VaultButtonStyle(.secondary))
            .keyboardShortcut(.cancelAction)

            Button(importLabel) {
                Task {
                    await viewModel.importDiscoveredEnvFiles()
                    dismiss()
                }
            }
            .buttonStyle(VaultButtonStyle(.primary))
            .keyboardShortcut(.defaultAction)
            .disabled((state?.selectedCount ?? 0) == 0 || state?.isWorking == true)
            .accessibilityIdentifier("env-discovery-import")
        } content: {
            if let state {
                VStack(alignment: .leading, spacing: VaultSpacing.l) {
                    if state.plans.isEmpty {
                        VaultNote(text: "No .env files in this folder. PassStore looked at file names only — nothing was opened.")
                    } else {
                        Text("Each file you tick becomes one secret, linked to that file so it can be pulled in again later. Nothing is read until you import.")
                            .font(.vaultFootnote)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .multilineTextAlignment(.leading)
                    }

                    if state.didReachLimit {
                        VaultNote(
                            text: "This folder holds more .env files than one scan lists. Import what you need, or link a folder further in.",
                            tone: .warning
                        )
                    }

                    ForEach(state.plans) { plan in
                        EnvFilePlanRow(
                            plan: plan,
                            environmentOptions: environmentPickerOptions(
                                existing: viewModel.environments(inWorkspace: workspaceID).map(\.environmentValue),
                                including: plan.environment
                            ),
                            identifierPrefix: "env-discovery",
                            onSelect: { viewModel.setEnvDiscoverySelection($0, forFileID: plan.id) },
                            onChangeEnvironment: { viewModel.setEnvDiscoveryEnvironment($0, forFileID: plan.id) },
                            onChangeParsing: { viewModel.setEnvDiscoveryParsing($0, forFileID: plan.id) }
                        )
                        if plan.id != state.plans.last?.id {
                            Divider().opacity(0.4)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: 640, height: 620)
    }

    private var importLabel: String {
        let count = state?.selectedCount ?? 0
        if state?.isWorking == true { return "Importing…" }
        return count == 1 ? "Import 1 File" : "Import \(count) Files"
    }
}

// MARK: - Environment matrix

/// Every key a project uses, against every environment it has.
///
/// The sheet deliberately shows presence rather than contents: a tick, a gap, a blank. It can
/// say that local and production hold the *same* secret without showing either of them, because
/// the comparison is made on digests. Reading a value still means opening the secret.
struct EnvironmentMatrixSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var viewModel: VaultViewModel
    let workspaceID: UUID

    @State private var showsOnlyProblems = false

    private static let keyColumnWidth: CGFloat = 230
    private static let cellWidth: CGFloat = 92

    private var matrix: EnvironmentMatrix {
        viewModel.environmentMatrix(inWorkspace: workspaceID)
    }

    private var workspaceName: String {
        viewModel.workspace(for: workspaceID)?.name ?? "Workspace"
    }

    private var accent: Color {
        viewModel.workspace(for: workspaceID).map { Color(hex: $0.colorHex) } ?? .vaultAccent
    }

    var body: some View {
        let matrix = matrix
        let rows = showsOnlyProblems ? matrix.rowsNeedingAttention : matrix.rows

        return VaultSheetScaffold(
            title: "Keys Across Environments",
            subtitle: workspaceName,
            systemImage: "tablecells",
            tint: accent,
            // The grid scrolls in both directions on its own, so the scaffold must not wrap it
            // in a scroll view — which also means the padding is this sheet's job.
            scrolls: false
        ) {
            Toggle("Only rows with something wrong", isOn: $showsOnlyProblems)
                .toggleStyle(.checkbox)
                .font(.vaultFootnote)
                .accessibilityIdentifier("matrix-only-problems")

            Spacer(minLength: 0)

            Button("Done") { dismiss() }
                .buttonStyle(VaultButtonStyle(.primary))
                .keyboardShortcut(.defaultAction)
        } content: {
            VStack(alignment: .leading, spacing: VaultSpacing.m) {
                Text("Every key your secrets define here, and which environments define it. Values are never shown — the comparison runs on digests, so two environments can be reported as holding the same secret without either being put on screen.")
                    .font(.vaultFootnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .multilineTextAlignment(.leading)

                summary(matrix)

                if matrix.columns.count < 2 {
                    VaultNote(text: "This workspace has one environment, so there is nothing to compare yet. Add another and its keys line up beside these.")
                } else if rows.isEmpty {
                    VaultNote(
                        text: showsOnlyProblems
                            ? "Every key is defined in every environment, and no secret is shared between them."
                            : "None of the secrets here define any keys yet.",
                        tone: .success
                    )
                } else {
                    grid(matrix: matrix, rows: rows)
                }

                legend
            }
            .padding(VaultSpacing.xl)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(width: 780, height: 620)
    }

    private func summary(_ matrix: EnvironmentMatrix) -> some View {
        VaultFlowLayout(spacing: VaultSpacing.s, lineSpacing: VaultSpacing.xs) {
            VaultChip(title: "\(matrix.keyCount) keys", systemImage: "number")
            if matrix.missingCount > 0 {
                VaultChip(title: "\(matrix.missingCount) missing", systemImage: "minus.circle", color: .orange)
            }
            if matrix.sharedSecretCount > 0 {
                VaultChip(
                    title: "\(matrix.sharedSecretCount) shared \(matrix.sharedSecretCount == 1 ? "secret" : "secrets")",
                    systemImage: "arrow.triangle.2.circlepath",
                    color: .red
                )
            }
        }
    }

    private func grid(matrix: EnvironmentMatrix, rows: [EnvironmentMatrix.Row]) -> some View {
        ScrollView([.horizontal, .vertical]) {
            VStack(alignment: .leading, spacing: 0) {
                headerRow(matrix)
                Divider()

                ForEach(rows) { row in
                    gridRow(row, columns: matrix.columns)
                    Divider().opacity(0.35)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityIdentifier("environment-matrix-grid")
    }

    private func headerRow(_ matrix: EnvironmentMatrix) -> some View {
        HStack(spacing: 0) {
            Text("Key")
                .font(.vaultFieldLabel)
                .foregroundStyle(.secondary)
                .frame(width: Self.keyColumnWidth, alignment: .leading)

            ForEach(matrix.columns) { column in
                VStack(spacing: 2) {
                    Image(systemName: column.systemImage)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(accent)
                        .accessibilityHidden(true)
                    Text(column.title)
                        .font(.vaultBadge)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(width: Self.cellWidth)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(column.title), \(column.itemCount) items")
            }
        }
        .padding(.vertical, VaultSpacing.xs)
    }

    private func gridRow(_ row: EnvironmentMatrix.Row, columns: [EnvironmentMatrix.Column]) -> some View {
        HStack(spacing: 0) {
            HStack(spacing: VaultSpacing.xs) {
                if row.isSensitive {
                    Image(systemName: "lock.fill")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
                Text(row.key)
                    .font(.vaultValueSmall)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if row.hasSharedSecret {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .help("The same secret is used in more than one environment")
                }
                if row.isDefinedTwiceSomewhere {
                    Image(systemName: "exclamationmark.2")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .help("Two secrets in the same environment define this key")
                }
                Spacer(minLength: 0)
            }
            .frame(width: Self.keyColumnWidth, alignment: .leading)

            ForEach(row.cells) { cell in
                cellView(cell, row: row)
                    .frame(width: Self.cellWidth)
            }
        }
        .padding(.vertical, VaultSpacing.xs)
        .accessibilityIdentifier("matrix-row-\(row.key)")
    }

    @ViewBuilder
    private func cellView(_ cell: EnvironmentMatrix.Cell, row: EnvironmentMatrix.Row) -> some View {
        let isShared = row.sharedSecretColumnKeys.contains(cell.columnKey)
        switch cell.presence {
        case .set:
            Button {
                if let itemID = cell.itemID { viewModel.revealMatrixCell(itemID: itemID) }
            } label: {
                Image(systemName: isShared ? "equal.circle.fill" : "checkmark")
                    .font(.system(size: isShared ? 12 : 11, weight: .semibold))
                    .foregroundStyle(isShared ? Color.red : Color.green)
            }
            .buttonStyle(.plain)
            .help(isShared ? "Same value as another environment — open the secret" : "Open the secret that defines it")
        case .blank:
            Image(systemName: "circle")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .help("Defined, with an empty value")
        case .missing:
            Image(systemName: "minus")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.orange.opacity(0.8))
                .help("Not defined in this environment")
        }
    }

    /// A key to the marks, as marks. A paragraph explaining a table of symbols is a paragraph
    /// nobody reads while looking at the symbols.
    private var legend: some View {
        VaultFlowLayout(spacing: VaultSpacing.m, lineSpacing: VaultSpacing.xs) {
            legendEntry("checkmark", "defined", .green)
            legendEntry("minus", "not defined here", .orange)
            legendEntry("circle", "defined, but empty", .secondary)
            legendEntry("equal.circle.fill", "same value as another environment", .red)
        }
        .accessibilityIdentifier("matrix-legend")
    }

    private func legendEntry(_ symbol: String, _ text: String, _ color: some ShapeStyle) -> some View {
        HStack(spacing: VaultSpacing.xs) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 12)
                .accessibilityHidden(true)
            Text(text)
                .font(.vaultBadge)
                .foregroundStyle(.tertiary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(text)
    }
}

// MARK: - Settings

private enum SettingsTab: String, CaseIterable, Hashable, Identifiable {
    case general
    case data
    case templates

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .data: "Data"
        case .templates: "Templates"
        }
    }

    var systemImage: String {
        switch self {
        case .general: "gearshape"
        case .data: "externaldrive"
        case .templates: "square.on.square"
        }
    }
}

struct SettingsSheetView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var settings: AppSettingsStore
    @Bindable var viewModel: VaultViewModel

    var body: some View {
        VaultSheetScaffold(
            title: "Settings",
            systemImage: "gearshape",
            scrolls: false
        ) {
            Spacer(minLength: 0)
            Button("Done") { dismiss() }
                .buttonStyle(VaultButtonStyle(.primary))
                .keyboardShortcut(.defaultAction)
        } content: {
            AppSettingsView(settings: settings, viewModel: viewModel)
        }
        .frame(width: 720, height: 600)
    }
}

struct AppSettingsView: View {
    @Bindable var settings: AppSettingsStore
    @Bindable var viewModel: VaultViewModel

    @State private var selectedTab: SettingsTab = .general

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $selectedTab) {
                ForEach(SettingsTab.allCases) { tab in
                    Label(tab.title, systemImage: tab.systemImage).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityLabel("Settings category")
            .padding(.horizontal, VaultSpacing.xl)
            .padding(.vertical, VaultSpacing.m)

            Divider()

            Group {
                switch selectedTab {
                case .general:
                    GeneralSettingsPane(
                        settings: settings,
                        sessionManager: viewModel.container.sessionManager,
                        viewModel: viewModel
                    )
                case .data:
                    DataSettingsPane(settings: settings, viewModel: viewModel)
                case .templates:
                    TemplateSettingsPane(viewModel: viewModel)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }
}

/// Everything about what PassStore keeps on disk beyond the secrets themselves.
private struct DataSettingsPane: View {
    @Bindable var settings: AppSettingsStore
    @Bindable var viewModel: VaultViewModel

    @State private var isConfirmingPurge = false
    @State private var isConfirmingRollback = false
    @State private var isConfirmingErase = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: VaultSpacing.xl) {
                VaultSection("Previous values", systemImage: "clock.arrow.circlepath") {
                    Toggle("Keep previous values when a secret changes", isOn: $settings.keepsSecretValueHistory)
                        .toggleStyle(.checkbox)
                        .accessibilityIdentifier("settings-value-history")

                    VaultNote(text: "Lets you look up or restore the password an item had before you rotated it. Up to \(SecretItemRepository.valueHistoryLimit) versions per field, inside the encrypted vault.")

                    VaultNote(
                        text: "This means an old secret stays recoverable until you delete it. If a value was leaked, purge it here after rotating.",
                        tone: .warning
                    )

                    Divider()

                    HStack {
                        Text(storedCountLabel)
                            .font(.vaultFootnote)
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                        Button("Delete All Previous Values…") { isConfirmingPurge = true }
                            .buttonStyle(VaultButtonStyle(.destructive))
                            .controlSize(.small)
                            .disabled(viewModel.storedPreviousValueCount == 0)
                            .accessibilityIdentifier("settings-purge-history")
                    }
                }

                VaultSection("Where the vault is kept", systemImage: "externaldrive") {
                    VaultNote(
                        text: "PassStore keeps one encrypted file. Put it in a folder something else already syncs — iCloud Drive, Dropbox, a repository — and the same vault opens on your other Macs. PassStore still syncs nothing itself."
                    )

                    LabeledContent("Folder") {
                        Text(viewModel.vaultLocationPath)
                            .font(.vaultValueSmall)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .lineLimit(2)
                            .truncationMode(.middle)
                            .accessibilityIdentifier("settings-vault-location-path")
                    }

                    if let problem = viewModel.vaultLocationProblemMessage {
                        VaultNote(text: problem, tone: .warning)
                    }

                    VaultNote(
                        text: "Open on two Macs at once and each will keep its own changes until it saves. Whichever saves second is told the vault moved underneath it and gets to choose — nothing is merged behind your back, and nothing is thrown away without you saying so.",
                        tone: .warning
                    )

                    HStack(spacing: VaultSpacing.s) {
                        Button("Move Vault to Folder…") { viewModel.moveVaultToChosenFolder() }
                            .buttonStyle(VaultButtonStyle(.secondary))
                            .controlSize(.small)
                            .disabled(!viewModel.canRelocateVault)
                            .accessibilityIdentifier("settings-move-vault")

                        Button("Open Vault in Another Folder…") { viewModel.openVaultInChosenFolder() }
                            .buttonStyle(VaultButtonStyle(.secondary))
                            .controlSize(.small)
                            .disabled(!viewModel.canRelocateVault)
                            .accessibilityIdentifier("settings-open-vault-elsewhere")

                        Spacer(minLength: 0)
                    }

                    if viewModel.isVaultInCustomLocation {
                        Button("Move Back to Default Location") { viewModel.moveVaultBackToDefaultLocation() }
                            .buttonStyle(.vaultLink)
                            .accessibilityIdentifier("settings-vault-default-location")
                    }
                }

                VaultSection("Linked files", systemImage: "link") {
                    Toggle("Check linked files when PassStore comes to the front", isOn: $settings.checksLinkedFilesOnFocus)
                        .toggleStyle(.checkbox)
                        .accessibilityIdentifier("settings-check-linked-files")

                    VaultNote(text: "An item imported from a .env can remember that file. When the file changes on disk, the item shows an Update button — nothing runs in the background and nothing is written without you asking.")

                    if viewModel.outdatedLinkedFileCount > 0 {
                        VaultNote(
                            text: "\(viewModel.outdatedLinkedFileCount) linked \(viewModel.outdatedLinkedFileCount == 1 ? "file needs" : "files need") your attention.",
                            tone: .warning
                        )
                    }
                }

                VaultSection("Erase everything", systemImage: "exclamationmark.triangle", tint: .red) {
                    VaultNote(
                        text: "Deletes every secret stored on this Mac and returns PassStore to first-run setup. Useful when handing the machine on, or to start again from a backup.",
                        tone: .warning
                    )
                    Button("Erase Vault…") { isConfirmingErase = true }
                        .buttonStyle(VaultButtonStyle(.destructive))
                        .controlSize(.small)
                        .accessibilityIdentifier("settings-erase-vault")
                }

                VaultSection("Recovery", systemImage: "arrow.uturn.backward") {
                    if let date = viewModel.rollbackCopyDate {
                        VaultNote(text: "A copy of your vault from before the last backup restore is on disk, taken \(Self.formatter.string(from: date)).")
                        HStack {
                            Button("Restore That Copy…") { isConfirmingRollback = true }
                                .buttonStyle(VaultButtonStyle(.secondary))
                                .controlSize(.small)
                                .accessibilityIdentifier("settings-restore-rollback")
                            Spacer(minLength: 0)
                            Button("Discard Copy") { viewModel.discardRollbackCopy() }
                                .buttonStyle(VaultButtonStyle(.secondary))
                                .controlSize(.small)
                                .accessibilityIdentifier("settings-discard-rollback")
                        }
                    } else {
                        VaultNote(text: "No pre-restore copy is stored. Before applying a backup, PassStore must successfully save one; otherwise the import is not applied.")
                    }
                }
            }
            .padding(VaultSpacing.xl)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .sheet(isPresented: $isConfirmingErase) {
            EraseVaultSheet(sessionManager: viewModel.container.sessionManager) {
                try viewModel.container.sessionManager.resetVaultDestroyingAllData()
            }
        }
        .confirmationDialog(
            "Delete every stored previous value?",
            isPresented: $isConfirmingPurge,
            titleVisibility: .visible
        ) {
            Button("Delete All", role: .destructive) { viewModel.purgeAllValueHistory() }
                .accessibilityIdentifier("settings-confirm-purge-history")
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Change logs are kept — only the old values are removed across every item. You can press ⌘Z until the vault locks or the app quits.")
        }
        .confirmationDialog(
            "Restore the vault from before the last backup restore?",
            isPresented: $isConfirmingRollback,
            titleVisibility: .visible
        ) {
            Button("Restore and Lock", role: .destructive) { viewModel.restoreRollbackCopy() }
                .accessibilityIdentifier("settings-confirm-rollback")
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Everything imported since then is discarded. PassStore will lock so the restored vault is read from disk.")
        }
    }

    private var storedCountLabel: String {
        let count = viewModel.storedPreviousValueCount
        guard count > 0 else { return "No previous values stored." }
        return "\(count) previous \(count == 1 ? "value" : "values") stored."
    }

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}

private struct GeneralSettingsPane: View {
    @Bindable var settings: AppSettingsStore
    @Bindable var sessionManager: VaultSessionManager
    @Bindable var viewModel: VaultViewModel

    @State private var isShortcutUnavailable = false
    /// Set when the system refused to register or unregister the login item, so the reason is shown
    /// rather than the toggle silently springing back.
    @State private var loginItemFailure: String?

    /// Reads the system's answer rather than the stored preference: the owner can revoke a login
    /// item in System Settings, and the toggle has to follow that.
    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { LoginItemService.status.isOn },
            set: { isOn in
                loginItemFailure = nil
                do {
                    try LoginItemService.setEnabled(isOn)
                    settings.launchesAtLogin = isOn
                } catch {
                    loginItemFailure = error.localizedDescription
                }
            }
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: VaultSpacing.xl) {
                VaultSection("Unlock", systemImage: "touchid") {
                    Toggle("Use Touch ID to unlock", isOn: $settings.biometricsEnabled)
                        .toggleStyle(.checkbox)
                        .disabled(sessionManager.isBusy)
                        .accessibilityIdentifier("settings-biometrics")

                    Toggle("Ask automatically when PassStore opens", isOn: $settings.unlocksWithBiometricsAutomatically)
                        .toggleStyle(.checkbox)
                        .disabled(!settings.biometricsEnabled || sessionManager.isBusy)
                        .accessibilityIdentifier("settings-auto-biometrics")

                    VaultNote(text: "The Touch ID prompt appears by itself on launch and when you switch back to PassStore, so unlocking needs no clicks. Turn it off to reach for it yourself.")
                }

                MasterPasswordSection(sessionManager: sessionManager)

                VaultSection("Locking", systemImage: "lock") {
                    VaultField("Lock after inactivity") {
                        Picker("", selection: $settings.autoLockInterval) {
                            ForEach(AutoLockPreset.allCases) { preset in
                                Text(preset.label).tag(preset.seconds)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(maxWidth: 220)
                    }

                    Toggle("Lock when the Mac sleeps or the screen locks", isOn: $settings.locksOnSystemLock)
                        .toggleStyle(.checkbox)
                        .accessibilityIdentifier("settings-lock-on-sleep")

                    VaultNote(text: "Closing the lid used to leave the vault open in memory until the inactivity timer happened to fire.")
                }

                VaultSection("Clipboard", systemImage: "doc.on.clipboard") {
                    VaultField("Clear clipboard after") {
                        Picker("", selection: $settings.clipboardClearInterval) {
                            ForEach(ClipboardClearPreset.allCases) { preset in
                                Text(preset.label).tag(preset.seconds)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(maxWidth: 220)
                    }

                    VaultNote(text: "Other apps and clipboard managers can read the system clipboard until PassStore clears it. A shorter interval narrows that window — it does not make the clipboard private while the secret is on it.")
                }

                VaultSection("Opening PassStore", systemImage: "power") {
                    Toggle("Open at login", isOn: launchAtLoginBinding)
                        .toggleStyle(.checkbox)
                        .accessibilityIdentifier("settings-launch-at-login")

                    if let explanation = LoginItemService.explanation {
                        VaultNote(text: explanation, tone: .warning)
                    }

                    if let failure = loginItemFailure {
                        VaultNote(text: failure, tone: .warning)
                    }

                    Divider()

                    Toggle("Menu bar only, no Dock icon", isOn: $settings.showsInMenuBarOnly)
                        .toggleStyle(.checkbox)
                        .accessibilityIdentifier("settings-menu-bar-only")

                    VaultNote(text: "With the window closed, PassStore leaves the Dock and ⌘-Tab and stays reachable from its menu bar item and its shortcut. Opening the window puts it back, so the menus are always there when there is a window to use them on.")
                }

                VaultSection("Shortcuts", systemImage: "command") {
                    Toggle("Global command palette", isOn: $settings.globalCommandPaletteHotkeyEnabled)
                        .toggleStyle(.checkbox)
                        .accessibilityIdentifier("settings-global-command-palette-hotkey")

                    VaultNote(text: "Opens the palette from any app while the vault is unlocked. PassStore has to keep running — the menu bar icon is enough.")

                    VaultNote(
                        text: "PassStore registers this one chord with the system. It does not request Accessibility and never sees anything else you type.",
                        tone: .success,
                        systemImage: "lock.shield"
                    )

                    if settings.globalCommandPaletteHotkeyEnabled {
                        Divider()

                        HotkeyRecorderField(settings: settings)
                    }

                    if settings.globalCommandPaletteHotkeyEnabled, isShortcutUnavailable {
                        VaultNote(
                            text: "\(settings.globalHotkeyDisplay) could not be registered — another app is already using it. Choose a different one, or quit that app.",
                            tone: .warning
                        )
                    }
                }
            }
            .padding(VaultSpacing.xl)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            refreshGlobalHotkeyAccessibilityState()
            let lockPresets = Set(AutoLockPreset.allCases.map(\.seconds))
            if !lockPresets.contains(settings.autoLockInterval) {
                settings.autoLockInterval = AutoLockPreset.nearest(to: settings.autoLockInterval).seconds
            }
            let clipPresets = Set(ClipboardClearPreset.allCases.map(\.seconds))
            if !clipPresets.contains(settings.clipboardClearInterval) {
                settings.clipboardClearInterval = ClipboardClearPreset.nearest(to: settings.clipboardClearInterval).seconds
            }
        }
        .onChange(of: settings.biometricsEnabled) { _, _ in
            do {
                try sessionManager.syncBiometricPreferenceIfUnlocked()
                if let warning = sessionManager.lastErrorMessage {
                    viewModel.alertMessage = warning
                }
            } catch {
                viewModel.alertMessage = error.localizedDescription
            }
        }
        .onChange(of: settings.globalCommandPaletteHotkeyEnabled) { _, _ in
            refreshGlobalHotkeyAccessibilityState()
        }
    }

    private func refreshGlobalHotkeyAccessibilityState() {
        GlobalCommandPaletteHotkey.shared.reinstallMonitors()
        isShortcutUnavailable = GlobalCommandPaletteHotkey.shared.isShortcutUnavailable
    }
}

// MARK: - Vault health

struct VaultHealthSheet: View {
    @Environment(\.dismiss) private var dismiss
    let viewModel: VaultViewModel

    @State private var report: VaultHealthReport?

    var body: some View {
        VaultSheetScaffold(
            title: "Vault Health",
            subtitle: report.map { "Checked \($0.auditedItemCount) active \($0.auditedItemCount == 1 ? "item" : "items")." },
            systemImage: "checkmark.shield",
            tint: (report?.isClean ?? true) ? .green : .orange
        ) {
            Spacer(minLength: 0)
            Button("Done") { dismiss() }
                .buttonStyle(VaultButtonStyle(.primary))
                .keyboardShortcut(.defaultAction)
        } content: {
            if let report {
                summary(for: report)
                if report.isClean {
                    cleanState(auditedItemCount: report.auditedItemCount, ignoredCount: report.ignoredCount)
                } else {
                    findingsList(report.findings)
                }
                if !report.ignoredFindings.isEmpty {
                    ignoredList(report.ignoredFindings)
                }
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 40)
            }

            VaultNote(text: "This report is built from your unlocked vault. It names items and field labels, and never shows or stores a secret value.", tone: .success, systemImage: "lock.shield")
        }
        .frame(width: 580, height: 620)
        .onAppear { report = viewModel.vaultHealthReport() }
    }

    private func summary(for report: VaultHealthReport) -> some View {
        HStack(spacing: 10) {
            summaryTile(
                count: report.count(of: .reused),
                label: "Reused",
                systemImage: VaultHealthFinding.Kind.reused.systemImage,
                tint: .red
            )
            summaryTile(
                count: report.count(of: .weak),
                label: "Weak",
                systemImage: VaultHealthFinding.Kind.weak.systemImage,
                tint: .orange
            )
            summaryTile(
                count: report.count(of: .stale),
                label: "Stale",
                systemImage: VaultHealthFinding.Kind.stale.systemImage,
                tint: .vaultAccentStrong
            )
        }
        .frame(maxWidth: .infinity)
    }

    private func summaryTile(count: Int, label: String, systemImage: String, tint: Color) -> some View {
        VStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(count > 0 ? tint : Color.secondary)
            Text("\(count)")
                .font(.title2.weight(.semibold).monospacedDigit())
                .foregroundStyle(count > 0 ? .primary : .secondary)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background { VaultCardBackground(cornerRadius: VaultRadius.value) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(count) \(label)")
    }

    private func cleanState(auditedItemCount: Int, ignoredCount: Int) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "checkmark.shield.fill")
                .font(.system(size: 32))
                .foregroundStyle(.green)
            Text(ignoredCount > 0 ? "No open issues" : "No issues found")
                .font(.headline)
            Text("Checked \(auditedItemCount) active \(auditedItemCount == 1 ? "item" : "items") for reused, weak, and stale secrets.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }

    private func findingsList(_ findings: [VaultHealthFinding]) -> some View {
        VaultSection("\(findings.count) \(findings.count == 1 ? "finding" : "findings")", systemImage: "exclamationmark.triangle", tint: .orange) {
            ForEach(Array(findings.enumerated()), id: \.element.id) { index, finding in
                HStack(alignment: .top, spacing: 8) {
                    Button {
                        viewModel.selectItem(id: finding.itemID)
                        dismiss()
                    } label: {
                        findingRow(finding, showsChevron: true)
                    }
                    .buttonStyle(.plain)
                    .help("Reveal this item in the list")
                    .accessibilityIdentifier("health-finding-\(finding.id)")

                    Button {
                        viewModel.ignoreHealthFinding(finding)
                        report = viewModel.vaultHealthReport()
                    } label: {
                        Image(systemName: "bell.slash")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .frame(width: 22, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(ignoreHelp(for: finding.kind))
                    .accessibilityLabel("Ignore this finding")
                    .accessibilityIdentifier("health-ignore-\(finding.id)")
                }

                if index != findings.count - 1 {
                    Divider()
                }
            }
        }
    }

    private func findingRow(_ finding: VaultHealthFinding, showsChevron: Bool) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: finding.kind.systemImage)
                .font(.system(size: 13))
                .foregroundStyle(tint(for: finding.kind))
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(finding.itemTitle)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(finding.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .multilineTextAlignment(.leading)
            }
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .contentShape(Rectangle())
    }

    /// Spells out that dismissing is not permanent, which is the whole point of keying the
    /// dismissal to the value.
    private func ignoreHelp(for kind: VaultHealthFinding.Kind) -> String {
        kind == .stale
            ? "Ignore until this item changes again"
            : "Ignore for this value — comes back if the secret is changed"
    }

    private func ignoredList(_ findings: [VaultHealthFinding]) -> some View {
        VaultSection("Ignored (\(findings.count))", systemImage: "bell.slash") {
            ForEach(Array(findings.enumerated()), id: \.element.id) { index, finding in
                HStack(alignment: .top, spacing: 8) {
                    findingRow(finding, showsChevron: false)
                        .opacity(0.55)

                    Button("Restore") {
                        viewModel.restoreIgnoredFinding(finding)
                        report = viewModel.vaultHealthReport()
                    }
                    .buttonStyle(.vaultLink)
                    .font(.caption)
                    .accessibilityIdentifier("health-restore-\(finding.id)")
                }

                if index != findings.count - 1 {
                    Divider()
                }
            }

            if findings.count > 1 {
                Divider()
                Button("Restore All") {
                    viewModel.restoreAllIgnoredFindings()
                    report = viewModel.vaultHealthReport()
                }
                .buttonStyle(.vaultLink)
                .font(.caption)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("health-restore-all")
            }
        }
    }

    private func tint(for kind: VaultHealthFinding.Kind) -> Color {
        switch kind {
        // An expired credential has already stopped working, so it reads as loudly as reuse.
        case .reused, .expired: .red
        case .weak, .expiring: .orange
        case .stale: .vaultAccentStrong
        }
    }
}

// MARK: - Bulk edit

/// Applies one set of changes to every item in the multi-selection.
///
/// Each control defaults to "keep", so the sheet can only do what was explicitly asked for —
/// opening it and pressing Apply without touching anything is impossible (Apply stays disabled).
struct BulkEditSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var viewModel: VaultViewModel

    @State private var draft = BulkEditDraft.empty
    @State private var tagText = ""
    /// Captured on appear: applying the edit clears the selection, and the footer should keep
    /// showing the count it acted on rather than dropping to zero mid-dismiss.
    @State private var targetCount = 0

    private var removableTags: [String] {
        viewModel.commonTagsInMultiSelection
    }

    var body: some View {
        VaultSheetScaffold(
            title: "Edit \(targetCount) \(targetCount == 1 ? "Item" : "Items")",
            subtitle: "Only what you change is applied. Everything else is left as it is on each item.",
            systemImage: "slider.horizontal.3"
        ) {
            Text(draft.hasChanges ? draft.summary : "Nothing to change yet")
                .font(.vaultFootnote)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button("Cancel") { dismiss() }
                .buttonStyle(VaultButtonStyle(.secondary))
                .keyboardShortcut(.cancelAction)

            Button("Apply") {
                viewModel.applyBulkEdit(draft)
                dismiss()
            }
            .buttonStyle(VaultButtonStyle(.primary))
            .keyboardShortcut(.defaultAction)
            .disabled(!draft.hasChanges)
            .accessibilityIdentifier("bulk-edit-apply")
        } content: {
            tagsSection
            organizeSection
            flagsSection
        }
        .frame(width: 580, height: 600)
        .onAppear { targetCount = viewModel.multiSelectedIDs.count }
    }

    private var tagsSection: some View {
        VaultSection("Tags", systemImage: "tag") {
            VaultField("Add to every item") {
                HStack(alignment: .center, spacing: 8) {
                    TextField("", text: $tagText, prompt: Text("Type a tag, then Add or press Return"))
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.leading)
                        .onSubmit(addTag)
                        .accessibilityIdentifier("bulk-edit-tag-field")
                    Button("Add", action: addTag)
                        .buttonStyle(VaultButtonStyle(.secondary))
                        .controlSize(.small)
                        .disabled(tagText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }

            if !draft.tagsToAdd.isEmpty {
                FlowTagView(tags: draft.tagsToAdd) { tag in
                    draft.tagsToAdd.removeAll { $0 == tag }
                }
            }

            if !removableTags.isEmpty {
                Divider()
                VaultField("Remove from every item") {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(removableTags, id: \.self) { tag in
                            Toggle(isOn: removalBinding(for: tag)) {
                                Text("#\(tag)")
                                    .font(.callout)
                            }
                            .toggleStyle(.checkbox)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private var organizeSection: some View {
        VaultSection("Organize", systemImage: "folder") {
            VaultField("Workspace") {
                Picker("", selection: workspaceBinding) {
                    Text("Keep current").tag(BulkEditWorkspaceAction.keep)
                    Text("No workspace").tag(BulkEditWorkspaceAction.clear)
                    ForEach(viewModel.workspaces) { workspace in
                        Text(workspace.name).tag(BulkEditWorkspaceAction.move(workspace.id))
                    }
                }
                .labelsHidden()
                .accessibilityIdentifier("bulk-edit-workspace")
            }

            VaultField("Environment") {
                Picker("", selection: environmentBinding) {
                    Text("Keep current").tag(BulkEditEnvironmentAction.keep)
                    ForEach(EnvironmentKind.allCases.filter { $0 != .custom }) { kind in
                        Text(kind.title).tag(BulkEditEnvironmentAction.set(.preset(kind)))
                    }
                }
                .labelsHidden()
                .accessibilityIdentifier("bulk-edit-environment")
            }
        }
    }

    private var flagsSection: some View {
        VaultSection("Status", systemImage: "flag") {
            VaultField("Favorite") {
                Picker("", selection: $draft.favoriteAction) {
                    Text("Keep").tag(BulkEditBooleanAction.keep)
                    Text("Add").tag(BulkEditBooleanAction.enable)
                    Text("Remove").tag(BulkEditBooleanAction.disable)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityIdentifier("bulk-edit-favorite")
            }

            VaultField("Archive") {
                Picker("", selection: $draft.archiveAction) {
                    Text("Keep").tag(BulkEditBooleanAction.keep)
                    Text("Archive").tag(BulkEditBooleanAction.enable)
                    Text("Restore").tag(BulkEditBooleanAction.disable)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityIdentifier("bulk-edit-archive")
            }

            Text("Archiving keeps items recoverable — nothing here deletes anything.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var workspaceBinding: Binding<BulkEditWorkspaceAction> {
        Binding(get: { draft.workspaceAction }, set: { draft.workspaceAction = $0 })
    }

    private var environmentBinding: Binding<BulkEditEnvironmentAction> {
        Binding(get: { draft.environmentAction }, set: { draft.environmentAction = $0 })
    }

    private func removalBinding(for tag: String) -> Binding<Bool> {
        Binding(
            get: { draft.tagsToRemove.contains(tag) },
            set: { isOn in
                if isOn {
                    guard !draft.tagsToRemove.contains(tag) else { return }
                    draft.tagsToRemove.append(tag)
                } else {
                    draft.tagsToRemove.removeAll { $0 == tag }
                }
            }
        )
    }

    private func addTag() {
        let tag = tagText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tag.isEmpty, !draft.tagsToAdd.contains(tag) else {
            tagText = ""
            return
        }
        draft.tagsToAdd.append(tag)
        tagText = ""
    }
}

// MARK: - Password generator

/// Makes a secret, of whichever kind is wanted.
///
/// Built on the same scaffold as every other sheet — header band, inset sections, one footer with
/// the buttons — because it used to be a bare stack with its own padding and its own idea of where
/// a Done button goes, and it showed.
struct PasswordGeneratorPanel: View {
    var onUse: ((String) -> Void)?
    var onDismiss: () -> Void
    var onCopy: (String) -> Void

    @State private var recipe: SecretRecipe = .password
    @State private var options = PasswordGeneratorOptions()
    @State private var passphraseOptions = PassphraseOptions()
    @State private var tokenOptions = RandomTokenOptions()
    @State private var password = ""
    @State private var didCopy = false

    var body: some View {
        VaultSheetScaffold(
            title: "Generate a Secret",
            subtitle: recipe.explanation,
            systemImage: "wand.and.sparkles"
        ) {
            Spacer(minLength: 0)

            Button(onUse == nil ? "Done" : "Cancel") { onDismiss() }
                .buttonStyle(SheetCapsuleButtonStyle(isPrimary: onUse == nil))

            if let onUse {
                Button("Use \(recipe.title)") {
                    onUse(password)
                    onDismiss()
                }
                .buttonStyle(SheetCapsuleButtonStyle(isPrimary: true))
                .disabled(password.isEmpty)
                .accessibilityIdentifier("generator-use")
            }
        } content: {
            kindSection
            resultSection
            optionsSection
        }
        .frame(width: 520, height: 620)
        .onAppear { if password.isEmpty { regenerate() } }
        .onChange(of: recipe) { _, _ in regenerate() }
        .onChange(of: options) { _, _ in regenerate() }
        .onChange(of: passphraseOptions) { _, _ in regenerate() }
        .onChange(of: tokenOptions) { _, _ in regenerate() }
    }

    // MARK: - Kind

    private var kindSection: some View {
        VaultSection("What to generate", systemImage: "square.grid.2x2") {
            Picker("", selection: $recipe) {
                ForEach(SecretRecipe.allCases) { recipe in
                    Text(recipe.shortTitle).tag(recipe)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .accessibilityIdentifier("generator-recipe")
        }
    }

    // MARK: - Result

    private var resultSection: some View {
        VaultSection("Result", systemImage: "text.cursor") {
            generatedValue

            HStack(spacing: VaultSpacing.s) {
                Button {
                    regenerate()
                } label: {
                    Label("Regenerate", systemImage: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(VaultButtonStyle(.secondary))
                .controlSize(.small)
                .accessibilityIdentifier("generator-regenerate")

                Button {
                    onCopy(password)
                    didCopy = true
                } label: {
                    Label(didCopy ? "Copied" : "Copy", systemImage: didCopy ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(VaultButtonStyle(.secondary))
                .controlSize(.small)
                .disabled(password.isEmpty)
                .accessibilityIdentifier("generator-copy")

                Spacer(minLength: 0)
            }

            Divider()

            // A password is judged by the estimator, like any stored secret. Everything else here
            // has a draw the generator performed itself, so it states the number rather than
            // inferring a verdict from the result.
            if recipe == .password {
                PasswordStrengthBar(password: password)
            } else {
                statedStrength
            }
        }
    }

    private var generatedValue: some View {
        Text(password.isEmpty ? " " : password)
            .font(.system(.body, design: .monospaced))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(VaultSpacing.m)
            .background(
                RoundedRectangle(cornerRadius: VaultRadius.value, style: .continuous)
                    .fill(Color(nsColor: .textBackgroundColor).opacity(0.6))
                    .overlay(
                        RoundedRectangle(cornerRadius: VaultRadius.value, style: .continuous)
                            .strokeBorder(VaultChrome.hairline, lineWidth: 0.5)
                    )
            )
            .accessibilityIdentifier("generator-value")
    }

    private var statedStrength: some View {
        Label(
            "About \(Int(statedEntropyBits.rounded())) bits of randomness",
            systemImage: "dice"
        )
        .font(.vaultFootnote)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("generator-entropy")
    }

    private var statedEntropyBits: Double {
        switch recipe {
        case .password: SecretEntropy.bits(of: password)
        case .passphrase: PassphraseGenerator.entropyBits(passphraseOptions)
        case .hex, .base64, .base64URL: RandomTokenGenerator.entropyBits(byteCount: tokenOptions.byteCount)
        case .uuid: RandomTokenGenerator.uuidEntropyBits
        }
    }

    // MARK: - Options

    @ViewBuilder
    private var optionsSection: some View {
        VaultSection("Options", systemImage: "slider.horizontal.3") {
            switch recipe {
            case .password:
                passwordOptions
            case .passphrase:
                passphraseControls
            case .hex, .base64, .base64URL:
                byteCountControl
            case .uuid:
                VaultNote(text: "A version 4 UUID has no options. 122 of its 128 bits are random; the rest state the version.")
            }
        }
    }

    private var passwordOptions: some View {
        VStack(alignment: .leading, spacing: VaultSpacing.s) {
            stepperRow(
                title: "Length",
                value: Binding(
                    get: { Double(options.length) },
                    set: { options.length = Int($0.rounded()) }
                ),
                range: Double(PasswordGenerator.minimumLength)...Double(PasswordGenerator.maximumLength),
                display: "\(options.length)",
                accessibilityIdentifier: "generator-length",
                accessibilityValue: "\(options.length) characters"
            )

            Divider()

            Toggle("Lowercase (a–z)", isOn: $options.includeLowercase).toggleStyle(.checkbox)
            Toggle("Uppercase (A–Z)", isOn: $options.includeUppercase).toggleStyle(.checkbox)
            Toggle("Digits (0–9)", isOn: $options.includeDigits).toggleStyle(.checkbox)
            Toggle("Symbols (!@#…)", isOn: $options.includeSymbols).toggleStyle(.checkbox)
            Toggle("Avoid look-alike characters", isOn: $options.excludeAmbiguous)
                .toggleStyle(.checkbox)
                .help("Leaves out 0/O, 1/l/I and similar pairs for secrets you may have to read aloud or retype.")

            if !options.hasUsableCharacterSet {
                VaultNote(
                    text: "Turn on at least one character set. Lowercase is used until you do.",
                    tone: .warning
                )
            }
        }
    }

    private var passphraseControls: some View {
        VStack(alignment: .leading, spacing: VaultSpacing.s) {
            stepperRow(
                title: "Words",
                value: Binding(
                    get: { Double(passphraseOptions.wordCount) },
                    set: { passphraseOptions.wordCount = Int($0.rounded()) }
                ),
                range: Double(PassphraseOptions.wordCountRange.lowerBound)...Double(PassphraseOptions.wordCountRange.upperBound),
                display: "\(passphraseOptions.wordCount)",
                accessibilityIdentifier: "generator-word-count",
                accessibilityValue: "\(passphraseOptions.wordCount) words"
            )

            Divider()

            Picker("Separator", selection: $passphraseOptions.separator) {
                ForEach(PassphraseSeparator.allCases) { separator in
                    Text(separator.title).tag(separator)
                }
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier("generator-separator")

            Toggle("Capitalise each word", isOn: $passphraseOptions.capitalizesWords).toggleStyle(.checkbox)
            Toggle("Add a number at the end", isOn: $passphraseOptions.appendsNumber)
                .toggleStyle(.checkbox)
                .help("For the sites that insist on a digit. It adds about six bits, not security.")

            VaultNote(text: "Drawn from \(PassphraseGenerator.wordListSize) words, independently and uniformly.")
        }
    }

    private var byteCountControl: some View {
        VStack(alignment: .leading, spacing: VaultSpacing.s) {
            stepperRow(
                title: "Bytes of randomness",
                value: Binding(
                    get: { Double(tokenOptions.byteCount) },
                    set: { tokenOptions.byteCount = Int($0.rounded()) }
                ),
                range: Double(RandomTokenOptions.byteCountRange.lowerBound)...Double(RandomTokenOptions.byteCountRange.upperBound),
                display: "\(tokenOptions.byteCount)",
                accessibilityIdentifier: "generator-byte-count",
                accessibilityValue: "\(tokenOptions.byteCount) bytes"
            )

            VaultNote(text: "32 bytes is the usual answer for a signing key or a session secret.")
        }
    }

    /// One labelled slider, so the three of them cannot drift apart.
    private func stepperRow(
        title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        display: String,
        accessibilityIdentifier: String,
        accessibilityValue: String
    ) -> some View {
        VStack(alignment: .leading, spacing: VaultSpacing.xs) {
            HStack {
                Text(title)
                    .font(.vaultFieldLabel)
                    .foregroundStyle(.secondary)
                Spacer(minLength: VaultSpacing.s)
                Text(display)
                    .font(.vaultValueSmall)
                    .foregroundStyle(.secondary)
            }
            Slider(value: value, in: range, step: 1)
                .accessibilityIdentifier(accessibilityIdentifier)
                .accessibilityValue(accessibilityValue)
        }
    }

    private func regenerate() {
        password = switch recipe {
        case .password: PasswordGenerator.generate(options: options)
        case .passphrase: PassphraseGenerator.generate(passphraseOptions)
        case .hex: RandomTokenGenerator.hex(byteCount: tokenOptions.byteCount)
        case .base64: RandomTokenGenerator.base64(byteCount: tokenOptions.byteCount, urlSafe: false)
        case .base64URL: RandomTokenGenerator.base64(byteCount: tokenOptions.byteCount, urlSafe: true)
        case .uuid: RandomTokenGenerator.uuid()
        }
        didCopy = false
    }
}
struct PasswordGeneratorSheet: View {
    @Environment(\.dismiss) private var dismiss
    let viewModel: VaultViewModel

    var body: some View {
        PasswordGeneratorPanel(
            onUse: nil,
            onDismiss: { dismiss() },
            onCopy: { viewModel.copyGeneratedPassword($0) }
        )
        .accessibilityIdentifier("password-generator-sheet")
    }
}

// MARK: - Master password

/// Changing the master password only re-wraps the vault key, so no stored data is re-encrypted
/// and the Touch ID Keychain entry keeps working.
private struct MasterPasswordSection: View {
    @Bindable var sessionManager: VaultSessionManager

    @State private var isExpanded = false
    @State private var isHistoryExpanded = false
    @State private var currentPassword = ""
    @State private var newPassword = ""
    @State private var confirmPassword = ""
    @State private var errorMessage: String?
    @State private var didSucceed = false

    private var passwordsMatch: Bool {
        !confirmPassword.isEmpty && newPassword == confirmPassword
    }

    private var canSubmit: Bool {
        !currentPassword.isEmpty
            && newPassword.count >= VaultSessionManager.minimumPasswordLength
            && passwordsMatch
            && newPassword != currentPassword
            && !sessionManager.isBusy
    }

    var body: some View {
        VaultSection("Master Password", systemImage: "key.horizontal") {
            if isExpanded {
                expandedForm
            } else {
                collapsedRow
            }
        }
    }

    private var collapsedRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            if didSucceed {
                Label("Master password updated", systemImage: "checkmark.circle.fill")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.green)
            }

            lastChangedRow

            Text("Your master password unwraps the vault key. Changing it does not re-encrypt your secrets and does not affect Touch ID.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .multilineTextAlignment(.leading)
            Button("Change Master Password…") {
                didSucceed = false
                isExpanded = true
            }
            .accessibilityIdentifier("settings-change-master-password")

            if history.count > 1 {
                Button(isHistoryExpanded ? "Hide history" : "Show history (\(history.count))") {
                    isHistoryExpanded.toggle()
                }
                .buttonStyle(.vaultLink)
                .font(.caption)
                .accessibilityIdentifier("master-password-history-toggle")
            }

            if isHistoryExpanded {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(history) { entry in
                        HStack(spacing: 6) {
                            Text(entry.kind.title)
                                .font(.caption)
                                .foregroundStyle(.primary)
                            Text(Self.absoluteFormatter.string(from: entry.changedAt))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.top, 2)
            }
        }
    }

    /// Vaults created before 1.1.1 have no recorded history, so this stays honest about
    /// not knowing rather than implying the password has never been changed.
    @ViewBuilder
    private var lastChangedRow: some View {
        if let changedAt = sessionManager.masterPasswordLastChangedAt {
            Label("Last changed \(Self.relativeFormatter.localizedString(for: changedAt, relativeTo: Date()))", systemImage: "clock.arrow.circlepath")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("master-password-last-changed")
        } else if let created = history.first(where: { $0.kind == .vaultCreated }) {
            Label("Never changed since the vault was created \(Self.relativeFormatter.localizedString(for: created.changedAt, relativeTo: Date()))", systemImage: "clock.arrow.circlepath")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("master-password-last-changed")
        }
    }

    private var history: [MasterPasswordChangeEntry] {
        sessionManager.masterPasswordHistory
    }

    private static let absoluteFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter
    }()

    private var expandedForm: some View {
        VStack(alignment: .leading, spacing: 12) {
            VaultField("Current password") {
                SecureField("", text: $currentPassword, prompt: Text("Your current master password"))
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("master-password-current")
            }

            VaultField("New password") {
                SecureField("", text: $newPassword, prompt: Text("At least \(VaultSessionManager.minimumPasswordLength) characters"))
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("master-password-new")
            }

            VaultField("Confirm new password") {
                SecureField("", text: $confirmPassword, prompt: Text("Re-enter the new password"))
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { if canSubmit { submit() } }
                    .accessibilityIdentifier("master-password-confirm")
            }

            PasswordStrengthBar(password: newPassword)

            if let message = validationHint {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .multilineTextAlignment(.leading)
            }

            Text("If you forget this password your secrets cannot be recovered — there is no reset. Export an encrypted backup first.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .multilineTextAlignment(.leading)

            HStack(spacing: 10) {
                Button("Cancel", action: reset)
                    .disabled(sessionManager.isBusy)
                Spacer(minLength: 0)
                Button("Update Password", action: submit)
                    .buttonStyle(VaultButtonStyle(.primary))
                    .disabled(!canSubmit)
                    .accessibilityIdentifier("master-password-submit")
            }
        }
    }

    private var validationHint: String? {
        if let errorMessage { return errorMessage }
        if !newPassword.isEmpty, newPassword.count < VaultSessionManager.minimumPasswordLength {
            return "New password must be at least \(VaultSessionManager.minimumPasswordLength) characters."
        }
        if !confirmPassword.isEmpty, !passwordsMatch {
            return "The new passwords don't match."
        }
        if !newPassword.isEmpty, newPassword == currentPassword {
            return "The new password must be different from the current one."
        }
        return nil
    }

    private func submit() {
        errorMessage = nil
        Task {
            do {
                // Two Argon2id passes — verify the old password, wrap under the new one.
                // Both now run off the main actor, so the sheet can show progress instead
                // of locking up for a couple of seconds.
                try await sessionManager.changeMasterPassword(current: currentPassword, to: newPassword)
                reset()
                didSucceed = true
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func reset() {
        currentPassword = ""
        newPassword = ""
        confirmPassword = ""
        errorMessage = nil
        isExpanded = false
    }
}

private enum AutoLockPreset: CaseIterable, Identifiable, Hashable {
    case oneMinute, twoMinutes, fiveMinutes, fifteenMinutes, thirtyMinutes, oneHour

    var id: Self { self }

    var seconds: TimeInterval {
        switch self {
        case .oneMinute: 60
        case .twoMinutes: 120
        case .fiveMinutes: 300
        case .fifteenMinutes: 900
        case .thirtyMinutes: 1800
        case .oneHour: 3600
        }
    }

    var label: String {
        switch self {
        case .oneMinute: "1 minute"
        case .twoMinutes: "2 minutes"
        case .fiveMinutes: "5 minutes"
        case .fifteenMinutes: "15 minutes"
        case .thirtyMinutes: "30 minutes"
        case .oneHour: "1 hour"
        }
    }

    static func nearest(to value: TimeInterval) -> AutoLockPreset {
        allCases.min(by: { abs($0.seconds - value) < abs($1.seconds - value) }) ?? .fiveMinutes
    }
}

private enum ClipboardClearPreset: CaseIterable, Identifiable, Hashable {
    case ten, thirty, oneMinute, twoMinutes, fiveMinutes

    var id: Self { self }

    var seconds: TimeInterval {
        switch self {
        case .ten: 10
        case .thirty: 30
        case .oneMinute: 60
        case .twoMinutes: 120
        case .fiveMinutes: 300
        }
    }

    var label: String {
        switch self {
        case .ten: "10 seconds"
        case .thirty: "30 seconds"
        case .oneMinute: "1 minute"
        case .twoMinutes: "2 minutes"
        case .fiveMinutes: "5 minutes"
        }
    }

    static func nearest(to value: TimeInterval) -> ClipboardClearPreset {
        allCases.min(by: { abs($0.seconds - value) < abs($1.seconds - value) }) ?? .thirty
    }
}

private enum TemplateSidebarSelection: Hashable {
    case newDraft
    case template(UUID)
}

private struct TemplateSettingsPane: View {
    @Bindable var viewModel: VaultViewModel
    @State private var selection: TemplateSidebarSelection = .newDraft
    @State private var draft = TemplateDraft(name: "", itemType: .customTemplate, fieldDefinitions: [])
    @State private var didInitializeSidebar = false

    var body: some View {
        HSplitView {
            List {
                Section {
                    sidebarRowNewTemplate
                }
                Section("All templates") {
                    ForEach(viewModel.templates, id: \.id) { template in
                        sidebarRow(for: template)
                    }
                }
            }
            .listStyle(.sidebar)
            .frame(minWidth: 200, idealWidth: 240, maxWidth: 280)

            NavigationStack {
                templateDetail
            }
            .frame(minWidth: 380)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            guard !didInitializeSidebar else { return }
            didInitializeSidebar = true
            if let first = viewModel.templates.first {
                selection = .template(first.id)
                draft = viewModel.draftForTemplate(first)
            }
        }
        .onChange(of: viewModel.templates.count) { _, _ in
            if !isSelectionValid { selectFirstAvailable() }
        }
    }

    private var isSelectionValid: Bool {
        switch selection {
        case .newDraft:
            return true
        case .template(let id):
            return viewModel.template(for: id) != nil
        }
    }

    private func selectFirstAvailable() {
        if let first = viewModel.templates.first {
            selection = .template(first.id)
            draft = viewModel.draftForTemplate(first)
        } else {
            selection = .newDraft
            draft = TemplateDraft(name: "", itemType: .customTemplate, fieldDefinitions: [])
        }
    }

    private var sidebarRowNewTemplate: some View {
        let isSelected = selection == .newDraft
        return Button {
            selection = .newDraft
            draft = TemplateDraft(name: "", itemType: .customTemplate, fieldDefinitions: [])
        } label: {
            Label("New custom template", systemImage: "plus.circle")
                .foregroundStyle(isSelected ? Color.vaultAccentStrong : .primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(
            isSelected
                ? RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.vaultAccent.opacity(0.12))
                : nil
        )
    }

    private func sidebarRow(for template: SecretFieldTemplateEntity) -> some View {
        let isSelected = selection == .template(template.id)
        return Button {
            selection = .template(template.id)
            draft = viewModel.draftForTemplate(template)
        } label: {
                    HStack {
                        Label(template.name, systemImage: template.itemType.systemImage)
                    .foregroundStyle(isSelected ? Color.vaultAccentStrong : .primary)
                Spacer(minLength: 0)
                        if template.isBuiltIn {
                            Text("Built-in")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(
            isSelected
                ? RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.vaultAccent.opacity(0.12))
                : nil
        )
    }

    private var selectedTemplateEntity: SecretFieldTemplateEntity? {
        guard case .template(let id) = selection else { return nil }
        return viewModel.template(for: id)
    }

    private var isBuiltInSelected: Bool {
        selectedTemplateEntity?.isBuiltIn ?? false
    }

    private var detailTitle: String {
        switch selection {
        case .newDraft:
            return "New template"
        case .template:
            return selectedTemplateEntity?.name ?? "Template"
        }
    }

    private var templateDetail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VaultSection("Definition", systemImage: "square.on.square") {
                    VaultField("Template name") {
                        TextField("", text: $draft.name, prompt: Text("e.g. My API template"))
                            .textFieldStyle(.roundedBorder)
                            .multilineTextAlignment(.leading)
                            .disabled(isBuiltInSelected)
                    }

                    VaultField("Item type") {
                        Picker("", selection: $draft.itemType) {
                            ForEach(SecretItemType.allCases) { type in
                                Text(type.title).tag(type)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .disabled(isBuiltInSelected)
                    }

                    if isBuiltInSelected {
                        Text("Built-in templates are read-only. Create a new custom template to define your own fields.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .multilineTextAlignment(.leading)
                            .padding(.top, 4)
                    }
                }

                VaultSection("Fields", systemImage: "list.bullet") {
                    if draft.fieldDefinitions.isEmpty {
                        Text("No fields yet")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        VStack(alignment: .leading, spacing: VaultSpacing.l) {
                            ForEach(Array($draft.fieldDefinitions.enumerated()), id: \.element.id) { index, $field in
                                templateFieldRow(
                                    field: $field,
                                    readOnly: isBuiltInSelected,
                                    onRemove: isBuiltInSelected ? nil : { removeTemplateField(id: field.id) },
                                    canMoveUp: !isBuiltInSelected && index > 0,
                                    canMoveDown: !isBuiltInSelected && index < draft.fieldDefinitions.count - 1,
                                    onMoveUp: { moveTemplateField(from: index, by: -1) },
                                    onMoveDown: { moveTemplateField(from: index, by: 1) }
                                )
                                if field.id != draft.fieldDefinitions.last?.id {
                                    Divider()
                                }
                            }
                        }
                    }

                    if !isBuiltInSelected {
                        Button {
                            draft.fieldDefinitions.append(.init(
                                key: "field\(draft.fieldDefinitions.count + 1)",
                                label: "Field \(draft.fieldDefinitions.count + 1)",
                                kind: .text,
                                isSensitive: false,
                                isCopyable: true,
                                isMaskedByDefault: false,
                                sortOrder: draft.fieldDefinitions.count
                            ))
                        } label: {
                            Label("Add Field", systemImage: "plus.circle")
                        }
                        .buttonStyle(VaultButtonStyle(.secondary))
                        .controlSize(.small)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                VaultCard {
                    HStack(alignment: .center, spacing: VaultSpacing.m) {
                        if isBuiltInSelected {
                            // Built-ins are read-only, and there used to be no way to start
                            // from one: adding a field to "Database" meant rebuilding the
                            // whole template by hand.
                            Button("Duplicate as Custom Template") { duplicateSelected() }
                                .buttonStyle(VaultButtonStyle(.primary))
                                .accessibilityIdentifier("template-duplicate")
                            Spacer(minLength: 0)
                        } else {
                            if case .template(let id) = selection,
                               let tpl = viewModel.template(for: id), !tpl.isBuiltIn {
                                Button("Delete Template", role: .destructive) {
                                    viewModel.deleteTemplate(tpl)
                                    selectFirstAvailable()
                                }
                                .accessibilityIdentifier("template-delete")
                            }
                            Spacer(minLength: 0)
                            Button("Save") {
                                guard let saved = viewModel.saveTemplate(draft) else { return }
                                selection = .template(saved.id)
                                draft = viewModel.draftForTemplate(saved)
                            }
                            .buttonStyle(VaultButtonStyle(.primary))
                            .keyboardShortcut(.defaultAction)
                            .disabled(draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            .accessibilityIdentifier("template-save")
                        }
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .navigationTitle(detailTitle)
    }

    /// Copies a built-in into an editable custom template, so it can be used as a starting
    /// point instead of a dead end.
    private func duplicateSelected() {
        guard let template = selectedTemplateEntity else { return }
        var copy = viewModel.draftForTemplate(template)
        copy.id = nil
        copy.name = "\(template.name) Copy"
        copy.fieldDefinitions = copy.fieldDefinitions.map { field in
            var field = field
            // New ids: the originals belong to the built-in and must not be re-parented.
            field.id = UUID()
            return field
        }
        guard let saved = viewModel.saveTemplate(copy) else { return }
        selection = .template(saved.id)
        draft = viewModel.draftForTemplate(saved)
    }

    private func removeTemplateField(id: UUID) {
        draft.fieldDefinitions.removeAll { $0.id == id }
        renumberTemplateFields()
    }

    /// Field order drives display order everywhere downstream. The item editor got move
    /// up/down in 1.1.0; the template editor did not, so a template's field order was fixed
    /// at whatever sequence you happened to add them in.
    private func moveTemplateField(from index: Int, by offset: Int) {
        let target = index + offset
        guard draft.fieldDefinitions.indices.contains(index),
              draft.fieldDefinitions.indices.contains(target) else { return }
        draft.fieldDefinitions.swapAt(index, target)
        renumberTemplateFields()
    }

    private func renumberTemplateFields() {
        for index in draft.fieldDefinitions.indices {
            draft.fieldDefinitions[index].sortOrder = index
        }
    }

    @ViewBuilder
    private func templateFieldRow(
        field: Binding<TemplateFieldDraft>,
        readOnly: Bool,
        onRemove: (() -> Void)?,
        canMoveUp: Bool,
        canMoveDown: Bool,
        onMoveUp: @escaping () -> Void,
        onMoveDown: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: VaultSpacing.s) {
            HStack(spacing: VaultSpacing.xs) {
                Text(field.wrappedValue.label.isEmpty ? "Untitled field" : field.wrappedValue.label)
                    .font(.vaultFieldLabel)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Spacer(minLength: VaultSpacing.s)

                if !readOnly {
                    Button(action: onMoveUp) {
                        Image(systemName: "chevron.up")
                    }
                    .buttonStyle(VaultIconButtonStyle())
                    .disabled(!canMoveUp)
                    .help("Move this field up")
                    .accessibilityLabel("Move field up")

                    Button(action: onMoveDown) {
                        Image(systemName: "chevron.down")
                    }
                    .buttonStyle(VaultIconButtonStyle())
                    .disabled(!canMoveDown)
                    .help("Move this field down")
                    .accessibilityLabel("Move field down")
                }

                if let onRemove {
                    Button(role: .destructive, action: onRemove) {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(VaultIconButtonStyle())
                    .help("Remove this field from the template")
                    .accessibilityLabel("Remove field")
                }
            }

            VaultField("Field label") {
                TextField("", text: field.label, prompt: Text("Shown in the editor"))
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.leading)
                    .disabled(readOnly)
            }

            VaultField("Storage key") {
                TextField("", text: field.key, prompt: Text("e.g. api_key"))
                    .font(.system(.body, design: .monospaced))
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.leading)
                    .disabled(readOnly)
            }

            VaultField("Field kind") {
                VStack(alignment: .leading, spacing: 8) {
                    Picker("", selection: field.kind) {
                        ForEach(FieldKind.allCases) { kind in
                            Text(kind.title).tag(kind)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    HStack(alignment: .top, spacing: 12) {
                        Toggle("Sensitive", isOn: field.isSensitive)
                            .toggleStyle(.checkbox)
                        Toggle("Masked default", isOn: field.isMaskedByDefault)
                            .toggleStyle(.checkbox)
                    }
                    .font(.caption)
                }
                .disabled(readOnly)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
    }
}

// MARK: - Export Sheet

struct ExportSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var viewModel: VaultViewModel

    @State private var password = ""
    @State private var confirmation = ""
    @FocusState private var isPasswordFocused: Bool

    private var mismatch: Bool {
        !confirmation.isEmpty && password != confirmation
    }

    private var canExport: Bool {
        password.count >= VaultSessionManager.minimumPasswordLength
            && !confirmation.isEmpty
            && !mismatch
            && !viewModel.isWorking
    }

    var body: some View {
        VaultSheetScaffold(
            title: "Export Backup",
            subtitle: "An encrypted copy of your whole vault, as a .pstore file.",
            systemImage: "arrow.up.doc"
        ) {
            Button("Cancel") {
                viewModel.cancelPendingCryptoOperation()
                dismiss()
            }
                .buttonStyle(VaultButtonStyle(.secondary))
                .keyboardShortcut(.cancelAction)

            Spacer(minLength: 0)

            if viewModel.isWorking {
                ProgressView()
                    .controlSize(.small)
            }

            Button("Export…") { export() }
                .buttonStyle(VaultButtonStyle(.primary))
                .keyboardShortcut(.defaultAction)
                .disabled(!canExport)
                .accessibilityIdentifier("export-confirm")
        } content: {
            VaultSection("Backup password", systemImage: "key.horizontal") {
                VaultField("Password") {
                    SecureField("", text: $password, prompt: Text("Choose a strong password"))
                        .textFieldStyle(.roundedBorder)
                        .focused($isPasswordFocused)
                        .accessibilityIdentifier("export-password")
                }

                PasswordStrengthBar(password: password)

                VaultField("Confirm password") {
                    SecureField("", text: $confirmation, prompt: Text("Re-enter the same password"))
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { if canExport { export() } }
                        .accessibilityIdentifier("export-confirmation")
                }

                if mismatch {
                    VaultNote(text: "The two passwords don't match.", tone: .danger)
                }
            }

            VaultSection("What this means", systemImage: "info.circle") {
                VaultNote(text: "This password is separate from your master password, and it is the only thing protecting the file. Anyone holding the backup can try to guess it offline, at their own pace.")
                VaultNote(text: "There is no recovery if you forget it. Store the file somewhere you trust.", tone: .warning)
            }
        }
        .frame(width: 460, height: 520)
        .onAppear { isPasswordFocused = true }
        .onDisappear {
            if viewModel.isWorking {
                viewModel.cancelPendingCryptoOperation()
            }
        }
    }

    private func export() {
        Task {
            if await viewModel.exportSelectedItems(password: password, confirmation: confirmation) {
                dismiss()
            }
        }
    }
}

// MARK: - Import PassStore export

struct ImportEncryptedExportSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var viewModel: VaultViewModel

    @State private var password = ""
    @State private var isPresentingFileImporter = false
    @FocusState private var isPasswordFocused: Bool

    private var canContinue: Bool {
        !password.isEmpty && viewModel.importExportSelectedFileName != nil && !viewModel.isWorking
    }

    var body: some View {
        VaultSheetScaffold(
            title: "Restore Backup",
            subtitle: "Open a .pstore file. You choose what to do with it on the next step.",
            systemImage: "arrow.down.doc"
        ) {
            Button("Cancel") {
                viewModel.cancelPendingCryptoOperation()
                dismiss()
            }
                .buttonStyle(VaultButtonStyle(.secondary))
                .keyboardShortcut(.cancelAction)

            Spacer(minLength: 0)

            if viewModel.isWorking {
                ProgressView()
                    .controlSize(.small)
            }

            Button("Continue") { unlockBackup() }
                .buttonStyle(VaultButtonStyle(.primary))
                .keyboardShortcut(.defaultAction)
                .disabled(!canContinue)
                .accessibilityIdentifier("import-continue")
        } content: {
            VaultSection("Backup file", systemImage: "doc.badge.arrow.up") {
                Button {
                    isPresentingFileImporter = true
                } label: {
                    HStack(spacing: VaultSpacing.s) {
                        Image(systemName: viewModel.importExportSelectedFileName == nil ? "doc.badge.plus" : "doc.fill")
                        Text(viewModel.importExportSelectedFileName ?? "Choose a .pstore file…")
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .buttonStyle(VaultButtonStyle(.secondary))
                .controlSize(.small)
                .accessibilityIdentifier("import-choose-file")

                VaultNote(text: "Legacy .json exports written by PassStore 1.0 also work.")
            }

            VaultSection("Backup password", systemImage: "key.horizontal") {
                VaultField("Password") {
                    SecureField("", text: $password, prompt: Text("Password used when exporting"))
                        .textFieldStyle(.roundedBorder)
                        .focused($isPasswordFocused)
                        .onSubmit { if canContinue { unlockBackup() } }
                        .accessibilityIdentifier("import-password")
                }
            }

            VaultNote(text: "Nothing is written yet. PassStore will show you what the backup contains and let you choose whether to replace your vault or merge into it.", tone: .success)
        }
        .frame(width: 460, height: 520)
        .fileImporter(
            isPresented: $isPresentingFileImporter,
            allowedContentTypes: [.passStoreBackup, .json],
            allowsMultipleSelection: false
        ) { result in
            viewModel.applyImportFilePickerResult(result)
            isPasswordFocused = true
        }
        .onDisappear {
            if viewModel.isWorking {
                viewModel.cancelPendingCryptoOperation()
            }
        }
    }

    private func unlockBackup() {
        Task {
            if await viewModel.prepareImport(password: password) {
                // Hand over to the preview sheet, which owns the replace / merge decision.
                viewModel.activeSheet = .importPreview
            }
        }
    }
}

// MARK: - Import preview

/// Shows what a decrypted backup contains and how it would be applied.
///
/// Restoring used to be a single irreversible step triggered by the password field. This is
/// the step that was missing: the counts, the consequence spelled out, and a default that
/// does not destroy anything.
struct ImportPreviewSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var viewModel: VaultViewModel

    @State private var mode: ImportPreview.Mode = .merge
    @State private var isConfirmingReplace = false

    var body: some View {
        VaultSheetScaffold(
            title: "Restore Backup",
            subtitle: viewModel.importPreview?.fileName,
            systemImage: "arrow.down.doc",
            tint: mode == .replace ? .orange : .vaultAccent
        ) {
            Button("Cancel") {
                viewModel.cancelStagedImport()
                dismiss()
            }
            .buttonStyle(VaultButtonStyle(.secondary))
            .keyboardShortcut(.cancelAction)

            Spacer(minLength: 0)

            Button(applyButtonTitle) {
                // Replacing is only destructive when there is something to destroy.
                if mode == .replace, !vaultIsEmpty {
                    isConfirmingReplace = true
                } else {
                    apply()
                }
            }
            .buttonStyle(VaultButtonStyle(mode == .replace && !vaultIsEmpty ? .destructive : .primary))
            .disabled(viewModel.importPreview == nil)
            .accessibilityIdentifier("import-apply")
        } content: {
            if let preview = viewModel.importPreview {
                contents(preview)
                modePicker(preview)
                safetyNote
            } else {
                VaultNote(text: "This backup could not be read.", tone: .danger)
            }
        }
        .frame(width: 520, height: 560)
        .onAppear {
            // Into an empty vault, "replace" is the complete restore — it brings back settings
            // and templates too — and it destroys nothing, so it is the right default.
            if vaultIsEmpty { mode = .replace }
        }
        // Dismissing with Escape must not leave a decrypted backup sitting in memory.
        .onDisappear { viewModel.cancelStagedImport() }
        .confirmationDialog(
            "Replace everything in your vault?",
            isPresented: $isConfirmingReplace,
            titleVisibility: .visible
        ) {
            Button("Replace Vault", role: .destructive) { apply() }
                .accessibilityIdentifier("import-confirm-replace")
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your current \(viewModel.items.count) \(viewModel.items.count == 1 ? "item" : "items") will be discarded and replaced by the backup. PassStore keeps a copy of your current vault so you can undo this, but it is still a full replacement.")
        }
    }

    private func contents(_ preview: ImportPreview) -> some View {
        VaultSection("This backup contains", systemImage: "shippingbox") {
            HStack(spacing: VaultSpacing.m) {
                countTile(preview.itemCount, label: preview.itemCount == 1 ? "item" : "items", systemImage: "key.horizontal")
                countTile(preview.workspaceCount, label: preview.workspaceCount == 1 ? "workspace" : "workspaces", systemImage: "folder")
                countTile(preview.templateCount, label: preview.templateCount == 1 ? "template" : "templates", systemImage: "square.on.square")
            }

            if preview.isLegacyFormat {
                VaultNote(text: "This is a PassStore 1.0 export. It carries items only, so it can only be merged — your workspaces, templates and settings are left alone.")
            }
        }
    }

    private func countTile(_ count: Int, label: String, systemImage: String) -> some View {
        VStack(spacing: VaultSpacing.xs) {
            Image(systemName: systemImage)
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("\(count)")
                .font(.title2.weight(.semibold).monospacedDigit())
            Text(label)
                .font(.vaultFootnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, VaultSpacing.m)
        .background { VaultCardBackground(cornerRadius: VaultRadius.value) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(count) \(label)")
    }

    /// Nothing to merge with and nothing to replace: restoring into a fresh vault, which is
    /// what happens straight after setup or an erase.
    private var vaultIsEmpty: Bool {
        viewModel.items.isEmpty && viewModel.workspaces.isEmpty
    }

    private var applyButtonTitle: String {
        if vaultIsEmpty { return "Restore Backup" }
        return mode == .replace ? "Replace Vault…" : "Merge Into Vault"
    }

    @ViewBuilder
    private func modePicker(_ preview: ImportPreview) -> some View {
        if vaultIsEmpty {
            VaultSection("How it will be applied", systemImage: "arrow.down.doc", tint: .green) {
                VaultNote(
                    text: "Your vault is empty, so the backup is restored as it is — there is nothing here to merge with or overwrite.",
                    tone: .success
                )
            }
        } else if preview.isLegacyFormat {
            VaultSection("How it will be applied", systemImage: "arrow.triangle.merge") {
                VaultNote(text: ImportPreview.Mode.merge.explanation, tone: .success)
            }
        } else {
            VaultSection("How should it be applied?", systemImage: "arrow.triangle.merge") {
                Picker("", selection: $mode) {
                    ForEach(ImportPreview.Mode.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityIdentifier("import-mode")

                VaultNote(text: mode.explanation, tone: mode == .replace ? .warning : .success)

                if mode == .merge {
                    Divider()
                    mergeBreakdown(preview)
                }
            }
        }
    }

    private func mergeBreakdown(_ preview: ImportPreview) -> some View {
        VStack(alignment: .leading, spacing: VaultSpacing.xs) {
            breakdownRow("\(preview.newItemCount) new", detail: "added to your vault", systemImage: "plus.circle")
            if preview.identicalItemCount > 0 {
                breakdownRow("\(preview.identicalItemCount) identical", detail: "already present, skipped", systemImage: "equal.circle")
            }
            if preview.conflictingItemCount > 0 {
                breakdownRow(
                    "\(preview.conflictingItemCount) changed",
                    detail: "kept as separate copies marked “(imported)”",
                    systemImage: "doc.on.doc"
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func breakdownRow(_ title: String, detail: String, systemImage: String) -> some View {
        HStack(spacing: VaultSpacing.s) {
            Image(systemName: systemImage)
                .font(.vaultFootnote)
                .foregroundStyle(.secondary)
                .frame(width: 14)
            Text(title)
                .font(.vaultFootnote)
                .fontWeight(.medium)
            Text(detail)
                .font(.vaultFootnote)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    private var safetyNote: some View {
        VaultNote(
            text: "Before writing anything, PassStore copies your current vault aside. You can undo this with ⌘Z, or restore the copy later from Settings → Advanced.",
            tone: .neutral,
            systemImage: "arrow.uturn.backward"
        )
    }

    private func apply() {
        if viewModel.applyStagedImport(mode: mode) != nil {
            dismiss()
        }
    }
}

// MARK: - Flow Tag View

private struct FlowTagView: View {
    let tags: [String]
    let onDelete: (String) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                ForEach(tags, id: \.self) { tag in
                    HStack(spacing: 4) {
                        Text(tag)
                            .font(.caption)
                        Button {
                            onDelete(tag)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.caption)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        Capsule(style: .continuous)
                            .fill(Color(nsColor: .controlBackgroundColor))
                            .overlay(
                                Capsule(style: .continuous)
                                    .strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5)
                            )
                    )
                }
            }
        }
    }
}

// MARK: - Simple Field Editor

/// One field: its name, its value, and a menu holding everything you can do *to* it.
///
/// Everything in that menu used to be behind a switch called "Advanced" that lived in the
/// section header and applied to every field at once — turning it on to rename one field
/// unfolded a label box, a storage-key box, a kind popup and three checkboxes under *all* of
/// them, and the form doubled in height. The controls are the same; they are now attached to the
/// row they act on and stay out of the way until asked for.
private struct SimpleFieldEditor: View {
    @Binding var field: FieldDraft
    let itemType: SecretItemType
    /// Owned by the form, so adding a field can hand the keyboard straight to this row.
    let focus: FocusState<ItemEditorFocus?>.Binding
    /// Return in the value: the form decides where that goes next.
    let onSubmitValue: () -> Void
    let onRemove: () -> Void
    let canMoveUp: Bool
    let canMoveDown: Bool
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void
    /// Routed through the clipboard service so generated passwords honour auto-clear too.
    let onCopyGenerated: (String) -> Void
    @State private var isRevealed = false
    @State private var isPresentingGenerator = false
    /// Opens the name and storage key for editing, for this field only.
    @State private var isRenaming = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            fieldHeader

            if isRenaming {
                renameControls
                    .padding(.bottom, 2)
            }

            fieldValueRow
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
        .sheet(isPresented: $isPresentingGenerator) {
            PasswordGeneratorPanel(
                onUse: { generated in
                    field.value = generated
                    isRevealed = true
                },
                onDismiss: { isPresentingGenerator = false },
                onCopy: onCopyGenerated
            )
        }
    }

    private var fieldHeader: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text(displayLabel)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            if field.isSensitive {
                Image(systemName: "lock.fill")
                    .font(.system(size: 8))
                    .foregroundStyle(.tertiary)
                    .help("Stored as a sensitive value and masked in the detail view")
                    .accessibilityLabel("Sensitive")
            }
            Spacer(minLength: 8)
            fieldMenu
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var fieldMenu: some View {
        Menu {
            Button(isRenaming ? "Done Renaming" : "Rename…", systemImage: "pencil") {
                isRenaming.toggle()
            }

            Menu("Value Kind") {
                Picker("", selection: Binding(
                    get: { field.kind },
                    set: { field.applyKind($0) }
                )) {
                    ForEach(FieldKind.allCases) { kind in
                        Text(kind.title).tag(kind)
                    }
                }
                .labelsHidden()
                .pickerStyle(.inline)
            }

            Section("Handling") {
                Toggle("Sensitive", isOn: $field.isSensitive)
                Toggle("Masked by default", isOn: $field.isMasked)
                Toggle("Copy allowed", isOn: $field.isCopyable)
            }

            Section {
                Button("Move Up", systemImage: "chevron.up", action: onMoveUp)
                    .disabled(!canMoveUp)
                Button("Move Down", systemImage: "chevron.down", action: onMoveDown)
                    .disabled(!canMoveDown)
            }

            Divider()
            Button("Remove Field", systemImage: "minus.circle", role: .destructive, action: onRemove)
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 11, weight: .semibold))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .foregroundStyle(.secondary)
        .help("Rename, reorder or remove this field")
        .accessibilityLabel("Field options for \(displayLabel)")
        .accessibilityIdentifier("editor-field-menu-\(field.key)")
    }

    private var displayLabel: String {
        let trimmed = field.label.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        let key = field.key.trimmingCharacters(in: .whitespacesAndNewlines)
        return key.isEmpty ? "Untitled field" : key
    }

    /// Name and storage key, in place, only while renaming.
    ///
    /// The key follows the name until somebody edits it directly, so the common case never has
    /// to think about it and the awkward case is still reachable.
    private var renameControls: some View {
        HStack(alignment: .top, spacing: VaultSpacing.s) {
            VaultField("Name") {
                TextField("", text: $field.label, prompt: Text("e.g. Password"))
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.leading)
                    .onChange(of: field.label) { oldValue, newValue in
                        if field.key.isEmpty || field.key == slugify(from: oldValue) {
                            field.key = slugify(from: newValue)
                        }
                    }
                    .accessibilityIdentifier("editor-field-label-\(field.key)")
            }

            VaultField("Storage key") {
                TextField("", text: $field.key, prompt: Text("Machine-readable id"))
                    .font(.system(.body, design: .monospaced))
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.leading)
            }
        }
    }

    private var databaseEngineSelection: Binding<String> {
        Binding(
            get: {
                let v = field.value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if v.isEmpty { return DatabaseEngineOption.defaultStoredID }
                if DatabaseEngineOption.all.contains(where: { $0.id == v }) { return v }
                return DatabaseEngineOption.defaultStoredID
            },
            set: { field.value = $0 }
        )
    }

    private var savedCommandKindSelection: Binding<String> {
        Binding(
            get: {
                let v = field.value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if v.isEmpty { return SavedCommandKindOption.defaultStoredID }
                if SavedCommandKindOption.all.contains(where: { $0.id == v }) { return v }
                return SavedCommandKindOption.defaultStoredID
            },
            set: { field.value = $0 }
        )
    }

    private var isConcealed: Bool {
        field.isSensitive || field.isMasked
    }

    @ViewBuilder
    private var fieldValueRow: some View {
        if itemType == .database, field.key == VaultFormFieldKeys.databaseEngine {
            Picker("", selection: databaseEngineSelection) {
                ForEach(DatabaseEngineOption.all) { opt in
                    Text(opt.title).tag(opt.id)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(maxWidth: .infinity, alignment: .leading)
        } else if itemType == .savedCommand, field.key == VaultFormFieldKeys.savedCommandKind {
            Picker("", selection: savedCommandKindSelection) {
                ForEach(SavedCommandKindOption.all) { opt in
                    Text(opt.title).tag(opt.id)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            switch field.kind {
            case .totp:
                // Its own control rather than a text box: a setup key is unreadable, and the only
                // way to know it was pasted correctly is to watch it produce a code.
                OneTimeCodeFieldEditor(value: $field.value)
            case .multiline, .json:
                VStack(alignment: .trailing, spacing: 6) {
                    if isConcealed, !isRevealed {
                        HStack(spacing: 8) {
                            Image(systemName: "lock.fill")
                                .foregroundStyle(.secondary)
                            Text(field.value.isEmpty ? "Empty masked value" : "Masked value hidden")
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Reveal to edit") { isRevealed = true }
                                .buttonStyle(VaultButtonStyle(.secondary))
                                .controlSize(.small)
                        }
                        .frame(maxWidth: .infinity, minHeight: 80, alignment: .center)
                        .padding(8)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color(nsColor: .controlBackgroundColor))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
                                )
                        )
                        .accessibilityLabel(field.value.isEmpty ? "Empty masked value" : "Masked value hidden")
                    } else {
                        TextEditor(text: $field.value)
                            .scrollContentBackground(.hidden)
                            .font(.system(.body, design: field.kind == .json ? .monospaced : .default))
                            .multilineTextAlignment(.leading)
                            // No `onSubmit` here: in a multi-line value Return is a newline.
                            .focused(focus, equals: .value(field.id))
                            .frame(maxWidth: .infinity, minHeight: 80, alignment: .topLeading)
                            .padding(8)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(Color(nsColor: .controlBackgroundColor))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                                            .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
                                    )
                            )
                    }

                    if isConcealed, isRevealed {
                        Button("Hide") { isRevealed = false }
                            .buttonStyle(VaultButtonStyle(.secondary))
                            .controlSize(.small)
                    }
                }
            default:
                HStack(alignment: .center, spacing: 8) {
                    Group {
                        if isConcealed, !isRevealed {
                            SecureField("", text: $field.value, prompt: Text("Secret value"))
                                .textFieldStyle(.roundedBorder)
                        } else {
                            TextField("", text: $field.value, prompt: Text("Enter value"))
                                .textFieldStyle(.roundedBorder)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .multilineTextAlignment(.leading)
                    .focused(focus, equals: .value(field.id))
                    .onSubmit(onSubmitValue)
                    .accessibilityIdentifier("editor-field-value-\(field.key)")

                    if field.kind == .secret || field.isSensitive {
                        Button {
                            isPresentingGenerator = true
                        } label: {
                            Label("Generate", systemImage: "wand.and.sparkles")
                                .labelStyle(.iconOnly)
                        }
                        .buttonStyle(VaultButtonStyle(.secondary))
                        .controlSize(.small)
                        .help("Generate a password, passphrase, hex or base64 secret")
                        .accessibilityLabel("Generate a secret")
                        .accessibilityIdentifier("editor-generate-\(field.key)")
                    }

                    if isConcealed {
                        Button(isRevealed ? "Hide" : "Reveal") {
                            isRevealed.toggle()
                        }
                        .buttonStyle(VaultButtonStyle(.secondary))
                        .controlSize(.small)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func slugify(from value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: " ", with: "_")
            .filter { $0.isLetter || $0.isNumber || $0 == "_" }
    }
}

// MARK: - Copy into another environment

/// Sending a secret into another environment, and choosing how much of it comes across.
///
/// It asks rather than deciding, because both answers are reasonable and only the owner knows
/// which one this is. What it does bring is a good opening guess: settings come across, secrets
/// arrive empty. That is the same rule the key check applies when it reports a shared secret as a
/// finding, so the default here and the warning there cannot contradict each other.
struct CopyToEnvironmentSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var viewModel: VaultViewModel

    private var plan: VaultViewModel.EnvironmentCopyPlan? { viewModel.environmentCopy }

    var body: some View {
        VaultSheetScaffold(
            title: plan.map { "Copy “\($0.subject)”" } ?? "Copy",
            subtitle: plan.map { "to \($0.destination.title)" } ?? "",
            systemImage: "arrow.right.doc.on.clipboard"
        ) {
            Spacer(minLength: 0)
            Button("Cancel") {
                viewModel.environmentCopy = nil
                dismiss()
            }
            .buttonStyle(VaultButtonStyle(.secondary))
            .keyboardShortcut(.cancelAction)

            Button(plan?.isWorking == true ? "Copying…" : "Copy") {
                viewModel.performEnvironmentCopy()
                dismiss()
            }
            .buttonStyle(VaultButtonStyle(.primary))
            .keyboardShortcut(.defaultAction)
            .disabled(plan == nil || plan?.isWorking == true || plan?.includedFieldCount == 0 && plan?.isSingle == true)
            .accessibilityIdentifier("copy-environment-confirm")
        } content: {
            if let plan {
                VStack(alignment: .leading, spacing: VaultSpacing.xl) {
                    destinationSection(plan)
                    valuesSection(plan)
                    if plan.isSingle { fieldsSection(plan) }
                    outcome(plan)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: 620, height: 600)
    }

    @ViewBuilder
    private func destinationSection(_ plan: VaultViewModel.EnvironmentCopyPlan) -> some View {
        if plan.destinationOptions.count > 1 {
            VaultSection("Into", systemImage: "circle.hexagongrid") {
                Picker("", selection: Binding(
                    get: { plan.destination },
                    set: viewModel.setEnvironmentCopyDestination
                )) {
                    ForEach(plan.destinationOptions, id: \.self) { option in
                        Text(option.title).tag(option)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .accessibilityLabel("Destination environment")
                .accessibilityIdentifier("copy-environment-destination")
            }
        }
    }

    private func valuesSection(_ plan: VaultViewModel.EnvironmentCopyPlan) -> some View {
        VaultSection("What Comes Across", systemImage: "doc.on.doc") {
            VStack(alignment: .leading, spacing: VaultSpacing.s) {
                ForEach(VaultViewModel.EnvironmentCopyPlan.ValueMode.allCases) { mode in
                    Button { viewModel.setEnvironmentCopyMode(mode) } label: {
                        HStack(alignment: .firstTextBaseline, spacing: VaultSpacing.s) {
                            Image(systemName: plan.mode == mode ? "largecircle.fill.circle" : "circle")
                                .font(.system(size: 12))
                                .foregroundStyle(plan.mode == mode ? Color.vaultAccentStrong : .secondary)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(mode.title)
                                    .font(.vaultRowTitle)
                                    .foregroundStyle(.primary)
                                Text(mode.detail)
                                    .font(.vaultBadge)
                                    .foregroundStyle(.tertiary)
                                    .multilineTextAlignment(.leading)
                            }
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(plan.mode == mode ? [.isSelected] : [])
                    .accessibilityIdentifier("copy-environment-mode-\(mode.rawValue)")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func fieldsSection(_ plan: VaultViewModel.EnvironmentCopyPlan) -> some View {
        VaultSection("Fields", systemImage: "list.bullet") {
            VStack(alignment: .leading, spacing: VaultSpacing.xs) {
                ForEach(plan.fields) { field in
                    HStack(spacing: VaultSpacing.s) {
                        Toggle("", isOn: Binding(
                            get: { field.isIncluded },
                            set: { viewModel.setEnvironmentCopyField(included: $0, fieldID: field.id) }
                        ))
                        .labelsHidden()
                        .accessibilityLabel("Include \(field.key)")
                        .accessibilityIdentifier("copy-environment-include-\(field.key.lowercased())")

                        if field.isSensitive {
                            Image(systemName: "lock.fill")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .accessibilityHidden(true)
                        }

                        Text(field.key)
                            .font(.vaultValueSmall)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(field.isIncluded ? .primary : .tertiary)

                        Spacer(minLength: 0)

                        if field.isIncluded {
                            Toggle("Copy its value", isOn: Binding(
                                get: { field.copiesValue },
                                set: { viewModel.setEnvironmentCopyField(copiesValue: $0, fieldID: field.id) }
                            ))
                            .toggleStyle(.checkbox)
                            .font(.vaultFootnote)
                            .disabled(!field.hasValue)
                            .help(field.hasValue
                                  ? "Off: the field is created here, waiting for the value this environment needs."
                                  : "This field is empty, so there is nothing to copy.")
                            .accessibilityIdentifier("copy-environment-value-\(field.key.lowercased())")
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func outcome(_ plan: VaultViewModel.EnvironmentCopyPlan) -> some View {
        VStack(alignment: .leading, spacing: VaultSpacing.s) {
            if let conflict = viewModel.environmentCopyConflict() {
                VaultNote(
                    text: "\(plan.destination.title) already has a secret called “\(conflict)”. Copying makes a second one, and the key check will report the keys they share as defined twice.",
                    tone: .warning
                )
            }

            if plan.isSingle {
                let copied = plan.copiedValueCount
                let included = plan.includedFieldCount
                VaultNote(
                    text: included == 0
                        ? "Nothing is ticked, so there is nothing to create."
                        : "Creates “\(plan.subject)” in \(plan.destination.title) with \(included) \(included == 1 ? "field" : "fields"), \(copied == 0 ? "all empty" : "\(copied) carrying \(copied == 1 ? "its value" : "their values") across")."
                )
            } else {
                VaultNote(text: "Creates \(plan.subject) in \(plan.destination.title). \(plan.mode.detail)")
            }
        }
        .accessibilityIdentifier("copy-environment-outcome")
    }
}
