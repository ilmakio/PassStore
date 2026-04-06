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
            .foregroundStyle(isPrimary ? Color.black : Color.primary)
            .opacity((configuration.isPressed || !isEnabled) ? 0.55 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
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
                        .disabled(
                            EnvImportSaveSupport.draftForSave(
                                viewModel: viewModel,
                                base: draft,
                                pasteBuffer: envImportPasteBuffer,
                                parseIntoEntries: envImportParseIntoEntries,
                                suggestedTitleFromFile: envImportSuggestedTitleFromFile
                            ).title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        )
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
                        ForEach($draft.fieldDrafts) { $field in
                            SimpleFieldEditor(field: $field, itemType: draft.type, showAdvanced: showAdvancedFields)
                            if field.id != draft.fieldDrafts.last?.id {
                                Divider()
                            }
                        }

                        if showAdvancedFields {
                            Button {
                                draft.fieldDrafts.append(.init(
                                    key: "field\(draft.fieldDrafts.count + 1)",
                                    label: "New Field",
                                    kind: .text,
                                    isSensitive: false,
                                    sortOrder: draft.fieldDrafts.count
                                ))
                            } label: {
                                Label("Add Field", systemImage: "plus.circle")
                            }
                            .buttonStyle(.borderless)
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
                                templateFieldRow(field: $field, readOnly: isBuiltInSelected)
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

    @ViewBuilder
    private func templateFieldRow(field: Binding<TemplateFieldDraft>, readOnly: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
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
        .frame(width: 420, height: 320)
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
        .frame(width: 420, height: 320)
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
    @State private var isRevealed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
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

            Toggle("Sensitive value", isOn: $field.isSensitive)
                .toggleStyle(.checkbox)
                .controlSize(.small)
                .font(.subheadline)
                .frame(maxWidth: .infinity, alignment: .leading)

            SheetLabeledField(title: "Value") {
                fieldValueRow
            }

            if showAdvanced {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Advanced")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 4)

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
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
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

                    if field.supportsGeneratedPassword {
                        Button("Generate") {
                            field.value = PasswordGenerator.generate()
                            isRevealed = true
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
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

// MARK: - Legacy helpers (used by remaining custom views)

private struct EditorSheetBackground: View {
    var body: some View {
        Color(nsColor: .windowBackgroundColor).ignoresSafeArea()
    }
}
