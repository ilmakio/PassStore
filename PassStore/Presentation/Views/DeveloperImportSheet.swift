import SwiftUI

/// Reading credentials out of a developer tool's own config file.
///
/// Two states in one sheet: what can be handed over, and then what was found in what you handed
/// over. It used to put the list of supported formats in an open panel's header, which is neither
/// the place for it nor readable, and then show a preview that gave counts without ever saying which
/// fields were coming in.
struct DeveloperImportSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var viewModel: VaultViewModel

    /// Which credentials the owner has opened to inspect.
    @State private var expanded: Set<UUID> = []

    private var hasParsedFile: Bool { !viewModel.pendingDeveloperImport.isEmpty }

    var body: some View {
        VaultSheetScaffold(
            title: "Import Credentials",
            subtitle: subtitle,
            systemImage: "square.and.arrow.down.on.square"
        ) {
            Spacer(minLength: 0)

            Button(hasParsedFile ? "Cancel" : "Close") {
                viewModel.cancelDeveloperImport()
                dismiss()
            }
            .buttonStyle(SheetCapsuleButtonStyle(isPrimary: !hasParsedFile))

            if hasParsedFile {
                Button(confirmLabel) {
                    viewModel.confirmDeveloperImport()
                }
                .buttonStyle(SheetCapsuleButtonStyle(isPrimary: true))
                .accessibilityIdentifier("developer-import-confirm")
            }
        } content: {
            if hasParsedFile {
                preview
            } else {
                explanation
            }
        }
        .frame(width: 580, height: 600)
    }

    private var subtitle: String? {
        guard hasParsedFile else { return "What PassStore can read, and what it will create" }
        let format = viewModel.pendingDeveloperImportFormat?.title ?? "credentials"
        guard let fileName = viewModel.developerImportFileName else { return format }
        return "\(fileName) · read as \(format)"
    }

    // MARK: - Before a file is chosen

    private var explanation: some View {
        VStack(alignment: .leading, spacing: VaultSpacing.l) {
            VaultSection("What can be imported", systemImage: "list.bullet") {
                VStack(alignment: .leading, spacing: VaultSpacing.s) {
                    ForEach(DeveloperCredentialFormat.allCases, id: \.self) { format in
                        HStack(alignment: .top, spacing: VaultSpacing.s) {
                            Image(systemName: format.systemImage)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .frame(width: 18)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(format.title)
                                    .font(.vaultRowTitle)
                                Text(format.importDescription)
                                    .font(.vaultRowSubtitle)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 0)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }

            if let problem = viewModel.developerImportProblem {
                VaultNote(text: problem, tone: .warning)
            }

            Button {
                viewModel.chooseDeveloperCredentialFile()
            } label: {
                Label("Choose File…", systemImage: "folder")
            }
            .buttonStyle(VaultButtonStyle(.primary))
            .accessibilityIdentifier("developer-import-choose-file")

            VaultNote(text: "Nothing is written until you have seen what was found. The file itself is never changed.")
        }
    }

    // MARK: - After a file is chosen

    private var preview: some View {
        VStack(alignment: .leading, spacing: VaultSpacing.l) {
            VaultNote(text: summary)

            VaultSection("Where to put them", systemImage: "shippingbox") {
                Picker("Workspace", selection: workspaceSelection) {
                    Text("No workspace").tag(UUID?.none)
                    ForEach(viewModel.workspaces) { workspace in
                        Text(workspace.name).tag(UUID?.some(workspace.id))
                    }
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("developer-import-workspace")
            }

            VaultSection("What will be created", systemImage: "list.bullet.rectangle") {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: VaultSpacing.xs) {
                        ForEach(viewModel.pendingDeveloperImport) { credential in
                            credentialRow(credential)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 260)
            }

            HStack(spacing: VaultSpacing.s) {
                Button("Choose a Different File…") {
                    viewModel.chooseDeveloperCredentialFile()
                }
                .buttonStyle(.vaultLink)
                Spacer(minLength: 0)
            }

            VaultNote(
                text: "Once these are in the vault, deleting the file is the point — a credential in two places is a credential you have to rotate twice.",
                tone: .warning
            )
        }
    }

    /// One item, openable to show exactly which fields it will have.
    ///
    /// Field *names* only. Showing the values would make this sheet a list of the very secrets it is
    /// about to take charge of, on screen, before anything has been encrypted.
    private func credentialRow(_ credential: ImportedCredential) -> some View {
        let isExpanded = expanded.contains(credential.id)
        return VStack(alignment: .leading, spacing: VaultSpacing.xs) {
            Button {
                if isExpanded { expanded.remove(credential.id) } else { expanded.insert(credential.id) }
            } label: {
                HStack(spacing: VaultSpacing.s) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 10)
                    Image(systemName: credential.type.systemImage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(credential.title)
                            .font(.vaultRowTitle)
                            .lineLimit(1)
                        Text(detail(for: credential))
                            .font(.vaultRowSubtitle)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("developer-import-row-\(credential.id.uuidString)")

            if isExpanded {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(credential.fields.enumerated()), id: \.offset) { _, field in
                        HStack(spacing: VaultSpacing.xs) {
                            Image(systemName: field.isSensitive ? "lock.fill" : "text.alignleft")
                                .font(.system(size: 8))
                                .foregroundStyle(field.isSensitive ? AnyShapeStyle(Color.vaultAccentStrong) : AnyShapeStyle(.tertiary))
                                .frame(width: 12)
                                .accessibilityHidden(true)
                            Text(field.label)
                                .font(.vaultFootnote)
                            Text(field.isSensitive ? "secret" : "plain")
                                .font(.vaultBadge)
                                .foregroundStyle(.tertiary)
                            Spacer(minLength: 0)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                .padding(.leading, 22)
                .padding(.bottom, VaultSpacing.xs)
            }

            Divider()
        }
    }

    private var workspaceSelection: Binding<UUID?> {
        Binding(
            get: { viewModel.developerImportWorkspaceID },
            set: { viewModel.developerImportWorkspaceID = $0 }
        )
    }

    private var confirmLabel: String {
        let count = viewModel.pendingDeveloperImport.count
        return count == 1 ? "Import 1 Item" : "Import \(count) Items"
    }

    private var summary: String {
        let credentials = viewModel.pendingDeveloperImport
        let secrets = credentials.reduce(0) { $0 + $1.sensitiveFieldCount }
        let itemNoun = credentials.count == 1 ? "credential" : "credentials"
        let secretNoun = secrets == 1 ? "secret value" : "secret values"
        return "Found \(credentials.count) \(itemNoun) holding \(secrets) \(secretNoun). Open one to see the fields it will have."
    }

    private func detail(for credential: ImportedCredential) -> String {
        let fields = credential.fields.count
        let secrets = credential.sensitiveFieldCount
        return "\(credential.sourceDescription) · \(fields) \(fields == 1 ? "field" : "fields"), \(secrets) secret"
    }
}
