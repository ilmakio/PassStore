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

// MARK: - Creation Flow

struct ItemCreationFlowSheet: View {
    @Environment(\.dismiss) private var dismiss

    @Bindable var viewModel: VaultViewModel
    @State private var selectedTemplateID: UUID?
    @State private var draft: SecretItemDraft
    @State private var tagText = ""
    @State private var showWorkspaceSheet = false
    @State private var showAdvancedFields = false
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
            title: selectedTemplate == nil ? "New Secret" : (selectedTemplate?.name ?? "New Secret"),
            subtitle: selectedTemplate == nil
                ? "Pick the shape of the thing you're storing."
                : selectedTemplate?.itemType.templateDescription,
            systemImage: selectedTemplate?.itemType.systemImage ?? "plus.rectangle.on.folder",
            scrolls: false
        ) {
            if selectedTemplate != nil {
                Button("Back") {
                    selectedTemplateID = nil
                    resetEnvImportStaging()
                }
                .buttonStyle(VaultButtonStyle(.secondary))
                .accessibilityIdentifier("creation-back-to-templates")
            }

            Spacer(minLength: 0)

            Button("Cancel") { dismiss() }
                .buttonStyle(VaultButtonStyle(.secondary))
                .keyboardShortcut(.cancelAction)

            if selectedTemplate != nil {
                Button("Save") { save() }
                    .buttonStyle(VaultButtonStyle(.primary))
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
                    .accessibilityIdentifier("creation-save")
            }
        } content: {
            Group {
                if selectedTemplateID != nil {
                    ItemEditorContent(
                        viewModel: viewModel,
                        availableWorkspaces: viewModel.workspaces,
                        draft: $draft,
                        tagText: $tagText,
                        showWorkspaceSheet: $showWorkspaceSheet,
                        showAdvancedFields: $showAdvancedFields,
                        showEnvImportStaging: true,
                        envImportPasteBuffer: $envImportPasteBuffer,
                        envImportParseIntoEntries: $envImportParseIntoEntries,
                        envImportSuggestedTitleFromFile: $envImportSuggestedTitleFromFile,
                        envImportSourceURL: $envImportSourceURL,
                        envImportLinkToFile: $envImportLinkToFile
                    )
                } else {
                    TemplatePickerView(viewModel: viewModel) { template in
                        selectedTemplateID = template.id
                        draft = viewModel.newItemDraft(template: template)
                        tagText = ""
                        showAdvancedFields = false
                        resetEnvImportStaging()
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 660, height: 620)
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

    private var selectedTemplate: SecretFieldTemplateEntity? {
        viewModel.template(for: selectedTemplateID)
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

    private func resetEnvImportStaging() {
        envImportPasteBuffer = ""
        envImportSuggestedTitleFromFile = nil
        envImportParseIntoEntries = true
        envImportSourceURL = nil
        envImportLinkToFile = true
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
    @State private var showAdvancedFields = false

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
            subtitle: draft.title.isEmpty ? nil : draft.title,
            systemImage: draft.type.systemImage,
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
            .buttonStyle(VaultButtonStyle(.primary))
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
                showAdvancedFields: $showAdvancedFields,
                showEnvImportStaging: false,
                envImportPasteBuffer: .constant(""),
                envImportParseIntoEntries: .constant(true),
                envImportSuggestedTitleFromFile: .constant(nil),
                envImportSourceURL: .constant(nil),
                envImportLinkToFile: .constant(false)
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 660, height: 620)
        .sheet(isPresented: $showWorkspaceSheet) {
            WorkspaceEditorSheet(title: "New Workspace", draft: .empty, onSave: handleWorkspaceSave)
        }
    }

    private func handleWorkspaceSave(_ workspaceDraft: WorkspaceDraft) {
        guard let workspace = viewModel.createWorkspace(workspaceDraft) else { return }
        draft.workspaceID = workspace.id
    }
}

// MARK: - Template Picker

private struct TemplatePickerView: View {
    @Bindable var viewModel: VaultViewModel
    let onSelect: (SecretFieldTemplateEntity) -> Void

    /// Two even columns. The cards are the surface here, so they are not wrapped in a card of
    /// their own — a box drawn around a row of boxes reads as a mistake.
    private static let columns = [
        GridItem(.flexible(), spacing: VaultSpacing.m),
        GridItem(.flexible(), spacing: VaultSpacing.m)
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: VaultSpacing.xl) {
                if !viewModel.featuredTemplates.isEmpty {
                    templateGroup("Common", systemImage: "star", templates: viewModel.featuredTemplates)
                }
                templateGroup("Built-in", systemImage: "square.grid.2x2", templates: viewModel.standardBuiltInTemplates)
                if !viewModel.customTemplates.isEmpty {
                    templateGroup("Custom", systemImage: "wrench.and.screwdriver", templates: viewModel.customTemplates)
                }
            }
            .padding(VaultSpacing.xl)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func templateGroup(
        _ title: String,
        systemImage: String,
        templates: [SecretFieldTemplateEntity]
    ) -> some View {
        VStack(alignment: .leading, spacing: VaultSpacing.m) {
            VaultSectionHeader(title, systemImage: systemImage)

            LazyVGrid(columns: Self.columns, spacing: VaultSpacing.m) {
                ForEach(templates, id: \.id) { template in
                    Button { onSelect(template) } label: {
                        TemplateCard(template: template)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("template-card-\(template.name)")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct TemplateCard: View {
    let template: SecretFieldTemplateEntity

    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: VaultSpacing.s) {
            HStack(alignment: .top) {
                Image(systemName: template.itemType.systemImage)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Color.vaultAccentStrong)
                    .frame(width: 30, height: 30)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.vaultAccent.opacity(isHovering ? 0.26 : 0.16))
                    )
                    .accessibilityHidden(true)

                Spacer(minLength: 0)

                if template.isBuiltIn {
                    Text("Built-in")
                        .font(.vaultBadge)
                        .foregroundStyle(.tertiary)
                }
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(template.name)
                    .font(.vaultRowTitle)
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(template.itemType.templateDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Spacer(minLength: 0)

            Text(template.summaryText)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(VaultSpacing.m)
        .frame(maxWidth: .infinity, minHeight: 128, alignment: .topLeading)
        // Hovering is the only affordance a grid of cards has to say it is clickable, and this
        // one had none: the accent edge is what tells you the card is a button.
        .background(
            RoundedRectangle(cornerRadius: VaultRadius.card, style: .continuous)
                .fill(Color.primary.opacity(isHovering ? 0.08 : 0.045))
        )
        .overlay(
            RoundedRectangle(cornerRadius: VaultRadius.card, style: .continuous)
                .strokeBorder(
                    isHovering ? Color.vaultAccent.opacity(0.55) : VaultChrome.hairline,
                    lineWidth: 1
                )
        )
        .contentShape(RoundedRectangle(cornerRadius: VaultRadius.card, style: .continuous))
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovering)
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
            .buttonStyle(.link)
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
                .fill(isImportDropTargeted ? Color.accentColor.opacity(0.12) : Color(nsColor: .controlBackgroundColor))
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
                                    isPasteDropTargeted ? Color.accentColor.opacity(0.5) : Color.primary.opacity(0.06),
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

private struct ItemEditorContent: View {
    @Bindable var viewModel: VaultViewModel
    let availableWorkspaces: [WorkspaceEntity]

    @Binding var draft: SecretItemDraft
    @Binding var tagText: String
    @Binding var showWorkspaceSheet: Bool
    @Binding var showAdvancedFields: Bool
    /// Staging UI (drop / paste before first save) is only shown when creating a new `.env` item.
    let showEnvImportStaging: Bool
    @Binding var envImportPasteBuffer: String
    @Binding var envImportParseIntoEntries: Bool
    @Binding var envImportSuggestedTitleFromFile: String?
    @Binding var envImportSourceURL: URL?
    @Binding var envImportLinkToFile: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VaultSection("Basics", systemImage: "textformat") {
                    VaultField("Name") {
                        TextField("", text: $draft.title, prompt: Text("Required"))
                            .textFieldStyle(.roundedBorder)
                            .multilineTextAlignment(.leading)
                            .accessibilityIdentifier("editor-title-field")
                    }

                    // Workspace and type sit side by side rather than stacked with a stray
                    // button hanging off the first one.
                    HStack(alignment: .top, spacing: VaultSpacing.m) {
                        VaultField("Workspace") { workspaceMenu }
                        VaultField("Type") { typeMenu }
                    }

                    Divider()

                    VaultField("Environment") {
                        Picker("", selection: Binding(
                            get: { draft.environment.kind },
                            set: { newKind in
                                draft.environment = newKind == .custom
                                    ? .custom(draft.environment.customName ?? "")
                                    : .preset(newKind)
                            }
                        )) {
                            ForEach(EnvironmentKind.allCases) { env in
                                Text(env.title).tag(env)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                    }

                    if draft.environment.kind == .custom {
                        VaultField("Custom environment name") {
                            TextField("", text: Binding(
                                get: { draft.environment.customName ?? "" },
                                set: { draft.environment = .custom($0) }
                            ), prompt: Text("e.g. Staging EU"))
                            .textFieldStyle(.roundedBorder)
                            .multilineTextAlignment(.leading)
                        }
                    }

                    Divider()

                    // A labelled checkbox rather than a bare star under a "Favorite" caption,
                    // which read as a stray icon with no obvious state.
                    Toggle(isOn: $draft.isFavorite) {
                        Label("Add to favourites", systemImage: draft.isFavorite ? "star.fill" : "star")
                            .foregroundStyle(draft.isFavorite ? Color.yellow : Color.primary)
                    }
                    .toggleStyle(.checkbox)
                    .accessibilityIdentifier("editor-favorite-toggle")
                }

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

                VaultSection("Fields", systemImage: "list.bullet") {
                    // The Advanced switch belongs in the section header, not floating above
                    // the card in a hand-rolled row of its own.
                    Toggle("Advanced", isOn: $showAdvancedFields)
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .accessibilityIdentifier("editor-advanced-toggle")
                } content: {
                    if draft.fieldDrafts.isEmpty {
                        VaultNote(text: showAdvancedFields
                                  ? "No fields yet. Add one below."
                                  : "This item has no fields. Turn on Advanced to add one.")
                    }

                    ForEach(Array($draft.fieldDrafts.enumerated()), id: \.element.id) { index, $field in
                        SimpleFieldEditor(
                            field: $field,
                            itemType: draft.type,
                            showAdvanced: showAdvancedFields,
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

                    if showAdvancedFields {
                        Button(action: addField) {
                            Label("Add Field", systemImage: "plus.circle")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityIdentifier("editor-add-field")
                    }
                }

                VaultSection("Tags", systemImage: "tag") {
                    VaultField("Add tags") {
                        HStack(alignment: .center, spacing: VaultSpacing.s) {
                            TextField("", text: $tagText, prompt: Text("Type a tag, then Add or press Return"))
                                .textFieldStyle(.roundedBorder)
                                .multilineTextAlignment(.leading)
                                .onSubmit(addTag)
                            Button("Add", action: addTag)
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .disabled(tagText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }

                    if !draft.tags.isEmpty {
                        FlowTagView(tags: draft.tags) { tag in
                            draft.tags.removeAll { $0 == tag }
                        }
                    }
                }

                VaultSection("Notes", systemImage: "note.text") {
                    VaultTextEditor(text: $draft.notes, placeholder: "Optional notes for this item")
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - Basics controls

    private var selectedWorkspace: WorkspaceEntity? {
        availableWorkspaces.first { $0.id == draft.workspaceID }
    }

    /// Workspace chooser that shows the workspace's own icon and colour, and offers to make a
    /// new one from inside the same menu.
    ///
    /// This used to be a plain popup with a separate "New Workspace…" button nudged into
    /// alignment with a hard-coded top padding.
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
            HStack(spacing: VaultSpacing.s) {
                Image(systemName: selectedWorkspace?.icon ?? "tray")
                    .foregroundStyle(selectedWorkspace.map { Color(hex: $0.colorHex) } ?? .secondary)
                Text(selectedWorkspace?.name ?? "No workspace")
                    .foregroundStyle(selectedWorkspace == nil ? .secondary : .primary)
                    .lineLimit(1)
            }
        }
        .accessibilityIdentifier("editor-workspace-picker")
    }

    private var typeMenu: some View {
        Picker(
            "",
            selection: Binding(
                get: { draft.type },
                set: { viewModel.applyItemTypeChange(to: &draft, newType: $0) }
            )
        ) {
            ForEach(SecretItemType.allCases) { type in
                Label(type.title, systemImage: type.systemImage)
                    .tag(type)
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .accessibilityIdentifier("editor-item-type-picker")
    }

    private func addTag() {
        let tag = tagText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tag.isEmpty, !draft.tags.contains(tag) else {
            tagText = ""
            return
        }
        draft.tags.append(tag)
        tagText = ""
    }

    private func addField() {
        let nextIndex = draft.fieldDrafts.count + 1
        draft.fieldDrafts.append(.init(
            key: uniqueFieldKey(base: "field\(nextIndex)"),
            label: "New Field",
            kind: .text,
            isSensitive: false,
            sortOrder: draft.fieldDrafts.count
        ))
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
    /// One entry per item in the workspace, so the editor can both list the environments that
    /// are already in use and say how much is in each of them. Empty for a new workspace.
    let environmentTitlesInUse: [String]
    @State private var draft: WorkspaceDraft

    init(
        title: String,
        draft: WorkspaceDraft,
        environmentTitlesInUse: [String] = [],
        onSave: @escaping (WorkspaceDraft) -> Void
    ) {
        self.title = title
        self.onSave = onSave
        self.environmentTitlesInUse = environmentTitlesInUse
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
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(Color(hex: draft.colorHex).opacity(0.15))
                                .frame(width: 46, height: 46)
                                .overlay(
                                    Image(systemName: draft.icon)
                                        .font(.system(size: 20, weight: .medium))
                                        .foregroundStyle(Color(hex: draft.colorHex))
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

    /// Declaring environments is what turns a workspace into a project with tabs. It stays
    /// optional on purpose: a workspace that declares none behaves exactly as it did in 1.2.
    private var environmentsSection: some View {
        VaultSection("Environments", systemImage: "circle.hexagongrid") {
            VStack(alignment: .leading, spacing: VaultSpacing.s) {
                if draft.environments.isEmpty {
                    VaultNote(
                        text: "Declare the environments this project has — Local, Staging, Production — and its secrets get one tab each. Leave this empty to keep the workspace a plain folder."
                    )
                }

                ForEach(Array(draft.environments.enumerated()), id: \.element.id) { index, environment in
                    if index > 0 {
                        Divider().opacity(0.4)
                    }
                    environmentRow(at: index, environment: environment)
                }

                if let environmentProblem {
                    VaultNote(text: environmentProblem, tone: .warning)
                }

                if draft.environments.contains(where: { !$0.isEnabled }) {
                    VaultNote(
                        text: "A switched-off environment is not offered in the sidebar. Anything already in it stays in your vault, keeps working, and still shows up in All Items."
                    )
                }

                if !undeclaredEnvironments.isEmpty {
                    Divider().opacity(0.4)
                    VaultNote(text: undeclaredSummary)
                    Button(undeclaredEnvironments.count == 1 ? "Add It to the Project" : "Add Them to the Project") {
                        adoptEnvironmentsInUse()
                    }
                    .buttonStyle(VaultButtonStyle(.secondary))
                    .accessibilityIdentifier("workspace-adopt-environments")
                }

                addEnvironmentMenu
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func environmentRow(at index: Int, environment: WorkspaceEnvironment) -> some View {
        let count = itemCount(for: environment)
        HStack(spacing: VaultSpacing.s) {
            Circle()
                .fill(Color(hex: environment.effectiveColorHex))
                .frame(width: 10, height: 10)
                .opacity(environment.isEnabled ? 1 : 0.3)
                .accessibilityHidden(true)

            if environment.kind == .custom {
                TextField("", text: $draft.environments[index].name, prompt: Text("e.g. QA"))
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 180)
                    .accessibilityIdentifier("workspace-environment-name-\(index)")
            } else {
                Text(environment.name)
                    .font(.vaultRowTitle)
            }

            if count > 0 {
                Text("\(count) \(count == 1 ? "item" : "items")")
                    .font(.vaultBadge)
                    .foregroundStyle(.secondary)
            }

            if !environment.isEnabled {
                VaultChip(title: "Off")
            }

            Spacer(minLength: 0)

            Menu {
                environmentRowMenu(at: index, environment: environment, itemCount: count)
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 13))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityIdentifier("workspace-environment-menu-\(index)")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func environmentRowMenu(at index: Int, environment: WorkspaceEnvironment, itemCount: Int) -> some View {
        Button(environment.isEnabled ? "Switch Off" : "Switch On") {
            draft.environments[index].isEnabled.toggle()
        }

        if environment.kind != .custom {
            // Presets are named by their kind, so renaming one means making it a custom
            // environment. Saving then moves the items that were in it.
            Button("Use a Custom Name…") {
                draft.environments[index].kind = .custom
            }
        }

        Menu("Color") {
            Button("Default for \(environment.kind == .custom ? "Custom" : environment.kind.title)") {
                draft.environments[index].colorHex = nil
            }
            ForEach(WorkspaceStylePresets.colors) { preset in
                Button(preset.name) { draft.environments[index].colorHex = preset.hex }
            }
        }

        Divider()

        Button("Move Up") { moveEnvironment(from: index, to: index - 1) }
            .disabled(index == 0)
        Button("Move Down") { moveEnvironment(from: index, to: index + 1) }
            .disabled(index >= draft.environments.count - 1)

        Divider()

        Button(itemCount > 0 ? "Remove from Project" : "Remove", role: .destructive) {
            draft.environments.remove(at: index)
            renumberEnvironments()
        }
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

    /// Environments the items already use that the project has not claimed. Shown rather than
    /// hidden: they are where the secrets actually are.
    private var undeclaredEnvironments: [ResolvedWorkspaceEnvironment] {
        WorkspaceEnvironment
            .resolvedList(declared: draft.environments, presentTitles: environmentTitlesInUse)
            .filter { !$0.isDeclared }
    }

    private var undeclaredSummary: String {
        let names = undeclaredEnvironments.map(\.title)
        guard names.count > 1 else {
            return "\(names[0]) is already in use here but is not part of the project yet."
        }
        return "Already in use here but not part of the project yet: \(names.joined(separator: ", "))."
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

    private func itemCount(for environment: WorkspaceEnvironment) -> Int {
        let key = environment.matchKey
        return environmentTitlesInUse.count { WorkspaceEnvironment.matchKey(for: $0) == key }
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

    private func adoptEnvironmentsInUse() {
        for environment in undeclaredEnvironments {
            draft.environments.append(
                WorkspaceEnvironment.declaration(
                    for: environment.environmentValue,
                    sortOrder: draft.environments.count
                )
            )
        }
    }

    private func moveEnvironment(from source: Int, to destination: Int) {
        guard draft.environments.indices.contains(source),
              draft.environments.indices.contains(destination) else { return }
        let environment = draft.environments.remove(at: source)
        draft.environments.insert(environment, at: destination)
        renumberEnvironments()
    }

    private func renumberEnvironments() {
        for index in draft.environments.indices {
            draft.environments[index].sortOrder = index
        }
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
                            .disabled(viewModel.storedPreviousValueCount == 0)
                            .accessibilityIdentifier("settings-purge-history")
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
                        .accessibilityIdentifier("settings-erase-vault")
                }

                VaultSection("Recovery", systemImage: "arrow.uturn.backward") {
                    if let date = viewModel.rollbackCopyDate {
                        VaultNote(text: "A copy of your vault from before the last backup restore is on disk, taken \(Self.formatter.string(from: date)).")
                        HStack {
                            Button("Restore That Copy…") { isConfirmingRollback = true }
                                .accessibilityIdentifier("settings-restore-rollback")
                            Spacer(minLength: 0)
                            Button("Discard Copy") { viewModel.discardRollbackCopy() }
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

                VaultSection("Shortcuts", systemImage: "command") {
                    Toggle("Global command palette (⌘⌥P)", isOn: $settings.globalCommandPaletteHotkeyEnabled)
                        .toggleStyle(.checkbox)
                        .accessibilityIdentifier("settings-global-command-palette-hotkey")

                    VaultNote(text: "Opens the palette from any app while the vault is unlocked. PassStore has to keep running — the menu bar icon is enough.")

                    VaultNote(
                        text: "PassStore registers this one chord with the system. It does not request Accessibility and never sees anything else you type.",
                        tone: .success,
                        systemImage: "lock.shield"
                    )

                    if settings.globalCommandPaletteHotkeyEnabled, isShortcutUnavailable {
                        VaultNote(
                            text: "⌘⌥P could not be registered — another app is already using it. Quit that app or turn this off.",
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
                tint: .yellow
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
                    .buttonStyle(.link)
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
                .buttonStyle(.link)
                .font(.caption)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("health-restore-all")
            }
        }
    }

    private func tint(for kind: VaultHealthFinding.Kind) -> Color {
        switch kind {
        case .reused: .red
        case .weak: .orange
        case .stale: .yellow
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
                        .buttonStyle(.bordered)
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

/// Reusable generator panel. `onUse` is nil when opened standalone (command palette), in which
/// case only copying makes sense.
struct PasswordGeneratorPanel: View {
    var onUse: ((String) -> Void)?
    var onDismiss: () -> Void
    var onCopy: (String) -> Void

    @State private var options = PasswordGeneratorOptions()
    @State private var password = ""
    @State private var didCopy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VaultSection("Generated password", systemImage: "wand.and.sparkles") {
                generatedValue

                HStack(spacing: 10) {
                    Button {
                        regenerate()
                    } label: {
                        Label("Regenerate", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .accessibilityIdentifier("generator-regenerate")

                    Button {
                        onCopy(password)
                        didCopy = true
                    } label: {
                        Label(didCopy ? "Copied" : "Copy", systemImage: didCopy ? "checkmark" : "doc.on.doc")
                    }
                    .disabled(password.isEmpty)
                    .accessibilityIdentifier("generator-copy")

                    Spacer(minLength: 0)
                }

                PasswordStrengthBar(password: password)
            }

            VaultSection("Options", systemImage: "slider.horizontal.3") {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Length")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(options.length)")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    Slider(
                        value: Binding(
                            get: { Double(options.length) },
                            set: { options.length = Int($0.rounded()) }
                        ),
                        in: Double(PasswordGenerator.minimumLength)...Double(PasswordGenerator.maximumLength),
                        step: 1
                    )
                    .accessibilityIdentifier("generator-length")
                    .accessibilityValue("\(options.length) characters")
                }

                Toggle("Lowercase (a–z)", isOn: $options.includeLowercase).toggleStyle(.checkbox)
                Toggle("Uppercase (A–Z)", isOn: $options.includeUppercase).toggleStyle(.checkbox)
                Toggle("Digits (0–9)", isOn: $options.includeDigits).toggleStyle(.checkbox)
                Toggle("Symbols (!@#…)", isOn: $options.includeSymbols).toggleStyle(.checkbox)
                Toggle("Avoid look-alike characters", isOn: $options.excludeAmbiguous)
                    .toggleStyle(.checkbox)
                    .help("Leaves out 0/O, 1/l/I and similar pairs for secrets you may have to read aloud or retype.")

                if !options.hasUsableCharacterSet {
                    Text("Turn on at least one character set. Lowercase is used until you do.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .multilineTextAlignment(.leading)
                }
            }

            HStack(spacing: 12) {
                Button(onUse == nil ? "Done" : "Cancel") { onDismiss() }
                    .buttonStyle(SheetCapsuleButtonStyle(isPrimary: onUse == nil))
                if let onUse {
                    Button("Use Password") {
                        onUse(password)
                        onDismiss()
                    }
                    .buttonStyle(SheetCapsuleButtonStyle(isPrimary: true))
                    .disabled(password.isEmpty)
                    .accessibilityIdentifier("generator-use")
                }
            }
            .frame(maxWidth: .infinity)
        }
        .padding(20)
        .frame(width: 440)
        .onAppear { if password.isEmpty { regenerate() } }
        .onChange(of: options) { _, _ in regenerate() }
    }

    private var generatedValue: some View {
        Text(password.isEmpty ? " " : password)
            .font(.system(.body, design: .monospaced))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
                    )
            )
            .accessibilityIdentifier("generator-value")
    }

    private func regenerate() {
        password = PasswordGenerator.generate(options: options)
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
                .buttonStyle(.link)
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
                    .fill(Color.accentColor.opacity(0.12))
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
                    .fill(Color.accentColor.opacity(0.12))
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
                            Label("Add field", systemImage: "plus.circle")
                        }
                        .buttonStyle(.borderless)
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
            tint: mode == .replace ? .orange : .accentColor
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

private struct SimpleFieldEditor: View {
    @Binding var field: FieldDraft
    let itemType: SecretItemType
    let showAdvanced: Bool
    let onRemove: () -> Void
    let canMoveUp: Bool
    let canMoveDown: Bool
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void
    /// Routed through the clipboard service so generated passwords honour auto-clear too.
    let onCopyGenerated: (String) -> Void
    @State private var isRevealed = false
    @State private var isPresentingGenerator = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            fieldHeader

            fieldValueRow

            if showAdvanced {
                advancedControls
                    .padding(.top, 6)
            }
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

    /// Basic mode shows the field name as a static caption, so filling in values is the only visible job.
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
            if showAdvanced {
                Button(action: onMoveUp) {
                    Label("Move Up", systemImage: "chevron.up")
                        .labelStyle(.iconOnly)
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .disabled(!canMoveUp)
                .help("Move this field up")
                .accessibilityIdentifier("editor-move-up-\(field.key)")

                Button(action: onMoveDown) {
                    Label("Move Down", systemImage: "chevron.down")
                        .labelStyle(.iconOnly)
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .disabled(!canMoveDown)
                .help("Move this field down")
                .accessibilityIdentifier("editor-move-down-\(field.key)")

                Button(role: .destructive, action: onRemove) {
                    Label("Remove Field", systemImage: "minus.circle")
                        .labelStyle(.iconOnly)
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Remove this field")
                .accessibilityIdentifier("editor-remove-field-\(field.key)")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var displayLabel: String {
        let trimmed = field.label.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        let key = field.key.trimmingCharacters(in: .whitespacesAndNewlines)
        return key.isEmpty ? "Untitled field" : key
    }

    private var advancedControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Advanced")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            VaultField("Field label") {
                TextField("", text: $field.label, prompt: Text("e.g. Password"))
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.leading)
                    .onChange(of: field.label) { oldValue, newValue in
                        if field.key.isEmpty || field.key == slugify(from: oldValue) {
                            field.key = slugify(from: newValue)
                        }
                    }
            }

            VaultField("Storage key") {
                TextField("", text: $field.key, prompt: Text("Machine-readable id"))
                    .font(.system(.body, design: .monospaced))
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.leading)
            }

            VaultField("Value kind") {
                VStack(alignment: .leading, spacing: 8) {
                    Picker("", selection: $field.kind) {
                        ForEach(FieldKind.allCases) { kind in
                            Text(kind.title).tag(kind)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    HStack(alignment: .top, spacing: 12) {
                        Toggle("Sensitive", isOn: $field.isSensitive)
                            .toggleStyle(.checkbox)
                        Toggle("Copy allowed", isOn: $field.isCopyable)
                            .toggleStyle(.checkbox)
                        Toggle("Masked by default", isOn: $field.isMasked)
                            .toggleStyle(.checkbox)
                    }
                    .font(.caption)
                }
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
                                .buttonStyle(.bordered)
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
                            .buttonStyle(.bordered)
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

                    if field.kind == .secret || field.isSensitive {
                        Button {
                            isPresentingGenerator = true
                        } label: {
                            Label("Generate", systemImage: "wand.and.sparkles")
                                .labelStyle(.iconOnly)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help("Generate a strong password")
                        .accessibilityLabel("Generate password")
                        .accessibilityIdentifier("editor-generate-\(field.key)")
                    }

                    if isConcealed {
                        Button(isRevealed ? "Hide" : "Reveal") {
                            isRevealed.toggle()
                        }
                        .buttonStyle(.bordered)
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
