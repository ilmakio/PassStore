import SwiftUI
import UniformTypeIdentifiers

// MARK: - Sheet Button Style

struct SheetCapsuleButtonStyle: ButtonStyle {
    let isPrimary: Bool
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .padding(.vertical, 8)
            .padding(.horizontal, 18)
            .background(Capsule().fill(isPrimary ? Color.accentColor : Color.primary.opacity(0.08)))
            // `.white` rather than `.black`: the fill is the user's accent colour, which is dark
            // for most of the macOS presets, so black text failed contrast on the default blue.
            .foregroundStyle(isPrimary ? Color.white : Color.primary)
            .opacity(pressedOrDisabledOpacity(isPressed: configuration.isPressed))
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }

    private func pressedOrDisabledOpacity(isPressed: Bool) -> Double {
        if !isEnabled { return 0.4 }
        return isPressed ? 0.7 : 1
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

    init(viewModel: VaultViewModel) {
        self.viewModel = viewModel
        _draft = State(initialValue: viewModel.newItemDraft())
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
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
                            envImportSuggestedTitleFromFile: $envImportSuggestedTitleFromFile
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

                HStack(spacing: 12) {
                    Button("Cancel") { dismiss() }
                        .buttonStyle(SheetCapsuleButtonStyle(isPrimary: false))
                    if selectedTemplate != nil {
                        Button("Save") {
                            let toSave = EnvImportSaveSupport.draftForSave(
                                viewModel: viewModel,
                                base: draft,
                                pasteBuffer: envImportPasteBuffer,
                                parseIntoEntries: envImportParseIntoEntries,
                                suggestedTitleFromFile: envImportSuggestedTitleFromFile
                            )
                            viewModel.saveItem(toSave)
                            dismiss()
                        }
                        .buttonStyle(SheetCapsuleButtonStyle(isPrimary: true))
                        .disabled(!canSave)
                    }
                }
                .padding(.vertical, 14)
            }
            .navigationTitle(selectedTemplate == nil ? "Choose a Template" : "New Secret Item")
            .toolbar {
                if selectedTemplate != nil {
                    ToolbarItem(placement: .navigation) {
                        Button("Templates") {
                            selectedTemplateID = nil
                            resetEnvImportStaging()
                        }
                    }
                }
            }
            .sheet(isPresented: $showWorkspaceSheet) {
                NavigationStack {
                    WorkspaceEditorSheet(title: "New Workspace", draft: .empty, onSave: onSaveWorkspace)
                }
            }
        }
        .frame(minWidth: 620, minHeight: 520)
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
        NavigationStack {
            VStack(spacing: 0) {
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
                    envImportSuggestedTitleFromFile: .constant(nil)
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                HStack(spacing: 12) {
                    Button("Cancel") { dismiss() }
                        .buttonStyle(SheetCapsuleButtonStyle(isPrimary: false))
                    Button("Save") {
                        onSave(draft)
                        dismiss()
                    }
                    .buttonStyle(SheetCapsuleButtonStyle(isPrimary: true))
                    .disabled(draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .padding(.vertical, 14)
            }
            .navigationTitle(title)
            .sheet(isPresented: $showWorkspaceSheet) {
                NavigationStack {
                    WorkspaceEditorSheet(title: "New Workspace", draft: .empty, onSave: handleWorkspaceSave)
                }
            }
        }
        .frame(minWidth: 580, minHeight: 480)
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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if !viewModel.featuredTemplates.isEmpty {
                    GroupedSheetSection(title: "Common") {
                        templateGrid(templates: viewModel.featuredTemplates)
                    }
                }
                GroupedSheetSection(title: "Built-in") {
                    templateGrid(templates: viewModel.standardBuiltInTemplates)
                }
                if !viewModel.customTemplates.isEmpty {
                    GroupedSheetSection(title: "Custom") {
                        templateGrid(templates: viewModel.customTemplates)
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func templateGrid(templates: [SecretFieldTemplateEntity]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 10)], spacing: 10) {
            ForEach(templates, id: \.id) { template in
                Button { onSelect(template) } label: {
                    TemplateCard(template: template)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("template-card-\(template.name)")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
    }
}

private struct TemplateCard: View {
    let template: SecretFieldTemplateEntity

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                Image(systemName: template.itemType.systemImage)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 30, height: 30)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.accentColor.opacity(0.1))
                    )
                Spacer(minLength: 0)
                if template.isBuiltIn {
                    Text("Built-in")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.leading)
                }
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(template.name)
                    .font(.system(size: 13, weight: .semibold))
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

            Text(template.summaryText)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.05))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
                )
        )
    }
}

// MARK: - Sheet field layout (label above control; avoids macOS `Form` two-column alignment)

struct SheetLabeledField<Content: View>: View {
    let title: String
    var titleAccessibilityIdentifier: String?
    @ViewBuilder let content: () -> Content

    init(title: String, titleAccessibilityIdentifier: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.titleAccessibilityIdentifier = titleAccessibilityIdentifier
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            titleLabel
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var titleLabel: some View {
        if let titleAccessibilityIdentifier {
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier(titleAccessibilityIdentifier)
        } else {
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Grouped sheet card chrome (light panels like macOS grouped `Form` sections)

struct GroupedSheetCardBackground: View {
    var cornerRadius: CGFloat = 12

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(.regularMaterial)
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(
                        Color.primary.opacity(colorScheme == .dark ? 0.12 : 0.07),
                        lineWidth: 0.5
                    )
            )
    }
}

// MARK: - Grouped sheet sections

struct GroupedSheetSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !title.isEmpty {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            VStack(alignment: .leading, spacing: 12) {
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background {
                GroupedSheetCardBackground()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
    @State private var stagingTab: EnvStagingTab = .importFile
    @State private var isImportDropTargeted = false
    @State private var isPasteDropTargeted = false
    /// Last file picked or dropped (`lastPathComponent`); cleared when staging text is cleared.
    @State private var stagedPickedEnvFileName: String?

    var body: some View {
        GroupedSheetSection(title: "Import .env") {
            Toggle("Parse KEY=value lines into separate fields", isOn: $parseIntoEntries)
                .toggleStyle(.checkbox)
                .help("When off, the entire file is stored as one multiline .env field.")

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

            if let name = stagedPickedEnvFileName, !pasteBuffer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                envFileLoadedFeedback(fileName: name)
            }

            Text("Staged text and files are merged into the fields below when you click Save.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .multilineTextAlignment(.leading)
        }
        .onChange(of: pasteBuffer) { _, newValue in
            if newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                stagedPickedEnvFileName = nil
            }
        }
    }

    private func envFileLoadedFeedback(fileName: String) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 20, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 2) {
                Text(".env file ready")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(fileName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.green.opacity(0.12))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.green.opacity(0.28), lineWidth: 0.5)
                )
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(".env file ready: \(fileName)")
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
                            .foregroundStyle(isImportDropTargeted ? Color.accentColor : .secondary)
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
                            isImportDropTargeted ? Color.accentColor : Color.primary.opacity(0.1),
                            lineWidth: isImportDropTargeted ? 2 : 0.5
                        )
                )
                .onDrop(of: [UTType.fileURL], isTargeted: $isImportDropTargeted, perform: handleDropFileURL)

            Button("Choose File…", action: applyFromFile)
                .buttonStyle(.borderedProminent)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var pastePanel: some View {
        SheetLabeledField(title: ".env contents") {
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
        guard let (content, title, pickedName) = viewModel.readEnvFileForImport() else { return }
        pasteBuffer = content
        suggestedTitleFromFile = title
        stagedPickedEnvFileName = pickedName
    }

    private func handleDropFileURL(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }) else {
            return false
        }
        provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
            guard let data, let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
            Task { @MainActor in
                guard let string = try? String(contentsOf: url, encoding: .utf8) else { return }
                pasteBuffer = string
                suggestedTitleFromFile = viewModel.suggestedEnvImportTitle(for: url)
                stagedPickedEnvFileName = url.lastPathComponent
            }
        }
        return true
    }

    private func handleDropPastePanel(_ providers: [NSItemProvider]) -> Bool {
        if let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }) {
            provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
                guard let data, let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                Task { @MainActor in
                    guard let string = try? String(contentsOf: url, encoding: .utf8) else { return }
                    pasteBuffer = string
                    suggestedTitleFromFile = viewModel.suggestedEnvImportTitle(for: url)
                    stagedPickedEnvFileName = url.lastPathComponent
                }
            }
            return true
        }
        if let provider = providers.first(where: { $0.canLoadObject(ofClass: String.self) }) {
            _ = provider.loadObject(ofClass: String.self) { string, _ in
                guard let string else { return }
                Task { @MainActor in
                    pasteBuffer = string
                    suggestedTitleFromFile = nil
                    stagedPickedEnvFileName = nil
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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                GroupedSheetSection(title: "Basics") {
                    SheetLabeledField(title: "Name") {
                        TextField("", text: $draft.title, prompt: Text("Required"))
                            .textFieldStyle(.roundedBorder)
                            .multilineTextAlignment(.leading)
                            .accessibilityIdentifier("editor-title-field")
                    }

                    HStack(alignment: .top, spacing: 12) {
                        SheetLabeledField(title: "Workspace") {
                            Picker("", selection: $draft.workspaceID) {
                                Text("None").tag(Optional<UUID>.none)
                                ForEach(availableWorkspaces, id: \.id) { workspace in
                                    Label(workspace.name, systemImage: workspace.icon)
                                        .tag(Optional.some(workspace.id))
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                        }
                        Button("New Workspace…") {
                            showWorkspaceSheet = true
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .padding(.top, 18)
                    }

                    SheetLabeledField(title: "Favorite") {
                        Button {
                            draft.isFavorite.toggle()
                        } label: {
                            Image(systemName: draft.isFavorite ? "star.fill" : "star")
                                .font(.system(size: 16, weight: .medium))
                                .foregroundStyle(draft.isFavorite ? .yellow : .secondary)
                        }
                        .buttonStyle(.plain)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .help(draft.isFavorite ? "Remove from Favorites" : "Add to Favorites")
                        .accessibilityIdentifier("editor-favorite-toggle")
                    }

                    SheetLabeledField(title: "Item type") {
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
                }

                GroupedSheetSection(title: "Environment") {
                    SheetLabeledField(title: "Preset") {
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
                        SheetLabeledField(title: "Custom environment name") {
                            TextField("", text: Binding(
                                get: { draft.environment.customName ?? "" },
                                set: { draft.environment = .custom($0) }
                            ), prompt: Text("e.g. Staging EU"))
                            .textFieldStyle(.roundedBorder)
                            .multilineTextAlignment(.leading)
                        }
                    }
                }

                if draft.type == .envGroup, showEnvImportStaging {
                    EnvGroupImportSection(
                        viewModel: viewModel,
                        pasteBuffer: $envImportPasteBuffer,
                        parseIntoEntries: $envImportParseIntoEntries,
                        suggestedTitleFromFile: $envImportSuggestedTitleFromFile
                    )
                }

                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .center) {
                        Text("Fields")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                        Toggle("Advanced", isOn: $showAdvancedFields)
                            .toggleStyle(.switch)
                            .controlSize(.mini)
                    }
                    VStack(alignment: .leading, spacing: 16) {
                        if draft.fieldDrafts.isEmpty {
                            Text(showAdvancedFields
                                 ? "No fields yet. Add one below."
                                 : "This item has no fields. Turn on Advanced to add one.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
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
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background {
                        GroupedSheetCardBackground()
                    }
                }

                GroupedSheetSection(title: "Tags") {
                    SheetLabeledField(title: "Add tags") {
                        HStack(alignment: .center, spacing: 8) {
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

                GroupedSheetSection(title: "Notes") {
                    SheetLabeledField(title: "Notes") {
                        ZStack(alignment: .topLeading) {
                            TextEditor(text: $draft.notes)
                                .scrollContentBackground(.hidden)
                                .frame(maxWidth: .infinity, minHeight: 90, alignment: .topLeading)
                                .multilineTextAlignment(.leading)
                                .padding(8)
                                .background(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .fill(Color(nsColor: .controlBackgroundColor))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
                                        )
                                )
                            if draft.notes.isEmpty {
                                Text("Optional notes for this item")
                                    .foregroundStyle(.tertiary)
                                    .multilineTextAlignment(.leading)
                                    .padding(.top, 16)
                                    .padding(.leading, 12)
                                    .allowsHitTesting(false)
                            }
                        }
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
    @State private var draft: WorkspaceDraft

    init(title: String, draft: WorkspaceDraft, onSave: @escaping (WorkspaceDraft) -> Void) {
        self.title = title
        self.onSave = onSave
        _draft = State(initialValue: draft)
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    GroupedSheetSection(title: "") {
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

                    GroupedSheetSection(title: "Basics") {
                        SheetLabeledField(title: "Name") {
                            TextField("", text: $draft.name, prompt: Text("e.g. Production API"))
                                .textFieldStyle(.roundedBorder)
                                .multilineTextAlignment(.leading)
                                .accessibilityIdentifier("workspace-name-field")
                        }

                        SheetLabeledField(title: "Notes") {
                            ZStack(alignment: .topLeading) {
                                TextEditor(text: $draft.notes)
                                    .scrollContentBackground(.hidden)
                                    .frame(maxWidth: .infinity, minHeight: 60, alignment: .topLeading)
                                    .multilineTextAlignment(.leading)
                                    .padding(8)
                                    .background(
                                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                                            .fill(Color(nsColor: .controlBackgroundColor))
                                            .overlay(
                                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
                                            )
                                    )
                                if draft.notes.isEmpty {
                                    Text("Optional context for this workspace")
                                        .foregroundStyle(.tertiary)
                                        .multilineTextAlignment(.leading)
                                        .padding(.top, 16)
                                        .padding(.leading, 12)
                                        .allowsHitTesting(false)
                                }
                            }
                        }
                    }

                    GroupedSheetSection(title: "Icon") {
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

                    GroupedSheetSection(title: "Color") {
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
                                            .foregroundStyle(Color.accentColor)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            HStack(spacing: 12) {
                Button("Cancel") { dismiss() }
                    .buttonStyle(SheetCapsuleButtonStyle(isPrimary: false))
                Button("Save") {
                    onSave(draft)
                    dismiss()
                }
                .buttonStyle(SheetCapsuleButtonStyle(isPrimary: true))
                .disabled(draft.name.isEmpty)
            }
            .padding(.vertical, 14)
        }
        .frame(width: 400, height: 580)
        .navigationTitle(title)
    }
}

// MARK: - Settings

private enum SettingsTab: Hashable {
    case general
    case templates
}

struct SettingsSheetView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var settings: AppSettingsStore
    @Bindable var viewModel: VaultViewModel

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                AppSettingsView(settings: settings, viewModel: viewModel)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                Button("Done") { dismiss() }
                    .buttonStyle(SheetCapsuleButtonStyle(isPrimary: true))
                    .padding(.vertical, 14)
            }
            .navigationTitle("Settings")
        }
        .frame(minWidth: 680, minHeight: 520)
    }
}

struct AppSettingsView: View {
    @Bindable var settings: AppSettingsStore
    @Bindable var viewModel: VaultViewModel

    @State private var selectedTab: SettingsTab = .general

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $selectedTab) {
                Text("General").tag(SettingsTab.general)
                Text("Templates").tag(SettingsTab.templates)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityLabel("Settings category")
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 10)

            Divider()

            Group {
                switch selectedTab {
                case .general:
                    GeneralSettingsPane(settings: settings, sessionManager: viewModel.container.sessionManager)
                case .templates:
                    TemplateSettingsPane(viewModel: viewModel)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }
}

private struct GeneralSettingsPane: View {
    @Environment(\.openURL) private var openURL

    @Bindable var settings: AppSettingsStore
    @Bindable var sessionManager: VaultSessionManager

    @State private var globalHotkeyNeedsAccessibility = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                GroupedSheetSection(title: "Unlock") {
                    Toggle("Use Touch ID or password to unlock", isOn: $settings.biometricsEnabled)
                        .toggleStyle(.checkbox)
                    Text("When enabled, you can unlock the vault with biometrics when your Mac supports it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .multilineTextAlignment(.leading)
                }

                MasterPasswordSection(sessionManager: sessionManager)

                GroupedSheetSection(title: "Privacy") {
                    SheetLabeledField(title: "Lock after inactivity") {
                        Picker("", selection: $settings.autoLockInterval) {
                            ForEach(AutoLockPreset.allCases) { preset in
                                Text(preset.label).tag(preset.seconds)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                    }

                    SheetLabeledField(title: "Clear clipboard after") {
                        Picker("", selection: $settings.clipboardClearInterval) {
                            ForEach(ClipboardClearPreset.allCases) { preset in
                                Text(preset.label).tag(preset.seconds)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                    }

                    Text("The system clipboard can be read by other apps and clipboard managers until PassStore clears it or you copy something else. Shorter intervals reduce that window; they do not make the clipboard private while the secret is on it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .multilineTextAlignment(.leading)
                }

                GroupedSheetSection(title: "Shortcuts") {
                    Toggle("Global command palette (⌘⌥P)", isOn: $settings.globalCommandPaletteHotkeyEnabled)
                        .toggleStyle(.checkbox)
                        .accessibilityIdentifier("settings-global-command-palette-hotkey")

                    Text("Activate PassStore from any app and open the command palette when the vault is unlocked. PassStore must keep running (for example via the menu bar icon).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .multilineTextAlignment(.leading)

                    if settings.globalCommandPaletteHotkeyEnabled, globalHotkeyNeedsAccessibility {
                        Text("Turn on PassStore under Accessibility in System Settings so the global shortcut can run while other apps are focused.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .multilineTextAlignment(.leading)

                        Button("Open Accessibility Settings…") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                                openURL(url)
                            }
                        }
                    }
                }


            }
            .padding(20)
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
            sessionManager.syncBiometricPreferenceIfUnlocked()
        }
        .onChange(of: settings.globalCommandPaletteHotkeyEnabled) { _, _ in
            refreshGlobalHotkeyAccessibilityState()
        }
    }

    private func refreshGlobalHotkeyAccessibilityState() {
        GlobalCommandPaletteHotkey.shared.reinstallMonitors()
        globalHotkeyNeedsAccessibility = GlobalCommandPaletteHotkey.shared.isAccessibilityRequiredButMissing
    }
}

// MARK: - Vault health

struct VaultHealthSheet: View {
    @Environment(\.dismiss) private var dismiss
    let viewModel: VaultViewModel

    @State private var report: VaultHealthReport?

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
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

                    Text("This report is built from your unlocked vault and never shows or stores secret values.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .multilineTextAlignment(.leading)
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Button("Done") { dismiss() }
                .buttonStyle(SheetCapsuleButtonStyle(isPrimary: true))
                .padding(.vertical, 14)
        }
        .frame(width: 560)
        .frame(minHeight: 480)
        .navigationTitle("Vault Health")
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
        .background { GroupedSheetCardBackground(cornerRadius: 10) }
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
        GroupedSheetSection(title: "\(findings.count) \(findings.count == 1 ? "finding" : "findings")") {
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
        GroupedSheetSection(title: "Ignored (\(findings.count))") {
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
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    tagsSection
                    organizeSection
                    flagsSection
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()

            HStack(spacing: 10) {
                Text(draft.hasChanges ? draft.summary : "Nothing selected to change")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Button("Cancel") { dismiss() }
                    .buttonStyle(SheetCapsuleButtonStyle(isPrimary: false))

                Button("Apply") {
                    viewModel.applyBulkEdit(draft)
                    dismiss()
                }
                .buttonStyle(SheetCapsuleButtonStyle(isPrimary: true))
                .disabled(!draft.hasChanges)
                .accessibilityIdentifier("bulk-edit-apply")
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(width: 560)
        .frame(minHeight: 520)
        .navigationTitle("Edit Items")
        .onAppear { targetCount = viewModel.multiSelectedIDs.count }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Editing \(targetCount) \(targetCount == 1 ? "item" : "items")")
                .font(.headline)
            Text("Only the options you change are applied. Everything else is left as it is on each item.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .multilineTextAlignment(.leading)
        }
    }

    private var tagsSection: some View {
        GroupedSheetSection(title: "Tags") {
            SheetLabeledField(title: "Add to every item") {
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
                SheetLabeledField(title: "Remove from every item") {
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
        GroupedSheetSection(title: "Organize") {
            SheetLabeledField(title: "Workspace") {
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

            SheetLabeledField(title: "Environment") {
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
        GroupedSheetSection(title: "Status") {
            SheetLabeledField(title: "Favorite") {
                Picker("", selection: $draft.favoriteAction) {
                    Text("Keep").tag(BulkEditBooleanAction.keep)
                    Text("Add").tag(BulkEditBooleanAction.enable)
                    Text("Remove").tag(BulkEditBooleanAction.disable)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityIdentifier("bulk-edit-favorite")
            }

            SheetLabeledField(title: "Archive") {
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
            GroupedSheetSection(title: "Generated password") {
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

            GroupedSheetSection(title: "Options") {
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
        .navigationTitle("Password Generator")
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
        GroupedSheetSection(title: "Master Password") {
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
            SheetLabeledField(title: "Current password") {
                SecureField("", text: $currentPassword, prompt: Text("Your current master password"))
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("master-password-current")
            }

            SheetLabeledField(title: "New password") {
                SecureField("", text: $newPassword, prompt: Text("At least \(VaultSessionManager.minimumPasswordLength) characters"))
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("master-password-new")
            }

            SheetLabeledField(title: "Confirm new password") {
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
                    .buttonStyle(.borderedProminent)
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
        do {
            try sessionManager.changeMasterPassword(current: currentPassword, to: newPassword)
            reset()
            didSucceed = true
        } catch {
            errorMessage = error.localizedDescription
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
                .foregroundStyle(isSelected ? Color.accentColor : .primary)
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
                    .foregroundStyle(isSelected ? Color.accentColor : .primary)
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
                GroupedSheetSection(title: "Definition") {
                    SheetLabeledField(title: "Template name") {
                        TextField("", text: $draft.name, prompt: Text("e.g. My API template"))
                            .textFieldStyle(.roundedBorder)
                            .multilineTextAlignment(.leading)
                            .disabled(isBuiltInSelected)
                    }

                    SheetLabeledField(title: "Item type") {
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

                GroupedSheetSection(title: "Fields") {
                    if draft.fieldDefinitions.isEmpty {
                        Text("No fields yet")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        VStack(alignment: .leading, spacing: 16) {
                            ForEach($draft.fieldDefinitions) { $field in
                                templateFieldRow(
                                    field: $field,
                                    readOnly: isBuiltInSelected,
                                    onRemove: isBuiltInSelected ? nil : { removeTemplateField(id: field.id) }
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

                if !isBuiltInSelected {
                    GroupedSheetSection(title: "") {
                        HStack(alignment: .center) {
                            if case .template(let id) = selection,
                               let tpl = viewModel.template(for: id), !tpl.isBuiltIn {
                                Button("Delete template", role: .destructive) {
                                    viewModel.deleteTemplate(tpl)
                                    selectFirstAvailable()
                                }
                            }
                            Spacer(minLength: 0)
                            Button("Save") {
                                guard let saved = viewModel.saveTemplate(draft) else { return }
                                selection = .template(saved.id)
                                draft = viewModel.draftForTemplate(saved)
                            }
                            .buttonStyle(.borderedProminent)
                            .keyboardShortcut(.defaultAction)
                            .disabled(draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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

    private func removeTemplateField(id: UUID) {
        draft.fieldDefinitions.removeAll { $0.id == id }
        for index in draft.fieldDefinitions.indices {
            draft.fieldDefinitions[index].sortOrder = index
        }
    }

    @ViewBuilder
    private func templateFieldRow(
        field: Binding<TemplateFieldDraft>,
        readOnly: Bool,
        onRemove: (() -> Void)?
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let onRemove {
                HStack {
                    Spacer(minLength: 0)
                    Button(role: .destructive, action: onRemove) {
                        Label("Remove Field", systemImage: "minus.circle")
                            .labelStyle(.iconOnly)
                            .font(.system(size: 12))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Remove this field from the template")
                }
            }

            SheetLabeledField(title: "Field label") {
                TextField("", text: field.label, prompt: Text("Shown in the editor"))
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.leading)
                    .disabled(readOnly)
            }

            SheetLabeledField(title: "Storage key") {
                TextField("", text: field.key, prompt: Text("e.g. api_key"))
                    .font(.system(.body, design: .monospaced))
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.leading)
                    .disabled(readOnly)
            }

            SheetLabeledField(title: "Field kind") {
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
    let onExport: (String, String) -> Bool
    @State private var password = ""
    @State private var confirmation = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                GroupedSheetSection(title: ".pstore backup") {
                    SheetLabeledField(title: "Export password") {
                        SecureField("", text: $password, prompt: Text("Choose a strong password"))
                            .textFieldStyle(.roundedBorder)
                    }

                    SheetLabeledField(title: "Confirm password") {
                        SecureField("", text: $confirmation, prompt: Text("Re-enter the same password"))
                            .textFieldStyle(.roundedBorder)
                    }

                    Text("PassStore saves an AES-encrypted backup as a `.pstore` file. The export password is separate from your vault password. Anyone with the file can try to guess that password offline, so use a long, unique passphrase and store backups only where you trust.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .multilineTextAlignment(.leading)
                }

                HStack(spacing: 12) {
                    Button("Cancel") { dismiss() }
                        .buttonStyle(SheetCapsuleButtonStyle(isPrimary: false))
                    Button("Export") {
                        if onExport(password, confirmation) { dismiss() }
                    }
                    .buttonStyle(SheetCapsuleButtonStyle(isPrimary: true))
                    .disabled(password.isEmpty || confirmation.isEmpty)
                }
                .frame(maxWidth: .infinity)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // minHeight rather than a fixed height: the security explainer wraps to 4-5 lines and
        // was forcing the action buttons out of view at 320pt.
        .frame(width: 440)
        .frame(minHeight: 400)
        .navigationTitle("Export .pstore Backup")
    }
}

// MARK: - Import PassStore export

struct ImportEncryptedExportSheet: View {
    @Environment(\.dismiss) private var dismiss
    let viewModel: VaultViewModel
    @State private var password = ""
    @State private var isPresentingFileImporter = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                GroupedSheetSection(title: ".pstore backup") {
                    Text("Select a `.pstore` backup (or a legacy `.json` export with the same encrypted format), then enter the export password you used when saving it. If the password is weak, the backup may be cracked offline.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .multilineTextAlignment(.leading)

                    Button {
                        isPresentingFileImporter = true
                    } label: {
                        Label(
                            viewModel.importExportSelectedFileName.map { "Selected: \($0)" } ?? "Choose export file…",
                            systemImage: "doc.badge.arrow.up"
                        )
                    }

                    SheetLabeledField(title: "Export password") {
                        SecureField("", text: $password, prompt: Text("Password used when exporting"))
                            .textFieldStyle(.roundedBorder)
                    }
                }

                HStack(spacing: 12) {
                    Button("Cancel") { dismiss() }
                        .buttonStyle(SheetCapsuleButtonStyle(isPrimary: false))
                    Button("Import") {
                        if viewModel.importEncryptedExport(password: password) { dismiss() }
                    }
                    .buttonStyle(SheetCapsuleButtonStyle(isPrimary: true))
                    .disabled(password.isEmpty || viewModel.importExportSelectedFileName == nil)
                }
                .frame(maxWidth: .infinity)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: 440)
        .frame(minHeight: 400)
        .navigationTitle("Import .pstore Backup")
        .fileImporter(
            isPresented: $isPresentingFileImporter,
            allowedContentTypes: [.passStoreBackup, .json],
            allowsMultipleSelection: false
        ) { result in
            viewModel.applyImportFilePickerResult(result)
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

            SheetLabeledField(title: "Field label") {
                TextField("", text: $field.label, prompt: Text("e.g. Password"))
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.leading)
                    .onChange(of: field.label) { oldValue, newValue in
                        if field.key.isEmpty || field.key == slugify(from: oldValue) {
                            field.key = slugify(from: newValue)
                        }
                    }
            }

            SheetLabeledField(title: "Storage key") {
                TextField("", text: $field.key, prompt: Text("Machine-readable id"))
                    .font(.system(.body, design: .monospaced))
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.leading)
            }

            SheetLabeledField(title: "Value kind") {
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
                TextEditor(text: $field.value)
                    .scrollContentBackground(.hidden)
                    .font(.system(field.kind == .json ? .body : .body, design: field.kind == .json ? .monospaced : .default))
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
            default:
                HStack(alignment: .center, spacing: 8) {
                    Group {
                        if field.kind == .secret, !isRevealed {
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

                    if field.kind == .secret {
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
