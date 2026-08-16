import SwiftUI

/// Full history for one item: what changed, when, and — for secret fields — what the value
/// used to be.
///
/// 1.1.1 added an audit trail that deliberately never recorded values. That answers "when did
/// this change?" but not "what was it before?", which is the question you actually have when
/// a deploy starts failing after a rotation. Previous values are kept separately, are capped,
/// and can be purged here or switched off entirely in Settings.
struct ItemHistorySheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var viewModel: VaultViewModel
    let itemID: UUID

    @State private var revealedVersionID: UUID?
    @State private var copiedVersionID: UUID?
    @State private var isConfirmingPurge = false
    @State private var pendingRestore: PendingRestore?

    private struct PendingRestore: Identifiable {
        let id: UUID
        let version: SecretValueVersion
        let fieldKey: String
        let fieldLabel: String
    }

    private var item: SecretItemEntity? {
        viewModel.item(withID: itemID)
    }

    var body: some View {
        VaultSheetScaffold(
            title: "History",
            subtitle: item?.title,
            systemImage: "clock.arrow.circlepath"
        ) {
            if let item, !viewModel.fieldsWithHistory(for: item).isEmpty {
                Button("Delete Previous Values…") { isConfirmingPurge = true }
                    .buttonStyle(VaultButtonStyle(.secondary))
                    .accessibilityIdentifier("history-purge")
            }

            Spacer(minLength: 0)

            Button("Done") { dismiss() }
                .buttonStyle(VaultButtonStyle(.primary))
                .keyboardShortcut(.defaultAction)
        } content: {
            if let item {
                valueHistorySection(for: item)
                changeLogSection(for: item)
            } else {
                VaultNote(text: "This item is no longer in your vault.", tone: .warning)
            }
        }
        .frame(width: 560, height: 620)
        .confirmationDialog(
            "Delete stored previous values?",
            isPresented: $isConfirmingPurge,
            titleVisibility: .visible
        ) {
            Button("Delete Previous Values", role: .destructive) {
                if let item { viewModel.purgeValueHistory(for: item) }
            }
            .accessibilityIdentifier("history-confirm-purge")
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The change log is kept. Only the old values are deleted. You can press ⌘Z until the vault locks or the app quits; after that they cannot be recovered.")
        }
        .confirmationDialog(
            pendingRestore.map { "Restore the previous value of “\($0.fieldLabel)”?" } ?? "Restore previous value?",
            isPresented: Binding(
                get: { pendingRestore != nil },
                set: { if !$0 { pendingRestore = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Restore Value") {
                if let pendingRestore, let item {
                    viewModel.restorePreviousValue(
                        pendingRestore.version,
                        fieldKey: pendingRestore.fieldKey,
                        in: item
                    )
                }
                pendingRestore = nil
            }
            .accessibilityIdentifier("history-confirm-restore")
            Button("Cancel", role: .cancel) { pendingRestore = nil }
        } message: {
            Text("The value currently stored will be pushed onto the history, so this can be undone.")
        }
    }

    // MARK: - Previous values

    @ViewBuilder
    private func valueHistorySection(for item: SecretItemEntity) -> some View {
        let fields = viewModel.fieldsWithHistory(for: item)

        if fields.isEmpty {
            VaultSection("Previous values", systemImage: "arrow.uturn.backward.circle") {
                if viewModel.isValueHistoryEnabled {
                    VaultNote(text: "No value has been replaced yet. When you change a secret, the old one is kept here so you can look it up or put it back.")
                } else {
                    VaultNote(
                        text: "Keeping previous values is switched off in Settings → Data, so nothing is recorded when a secret changes.",
                        tone: .warning
                    )
                }
            }
        } else {
            ForEach(fields) { field in
                VaultSection(field.label, systemImage: field.isSensitive ? "lock" : "textformat") {
                    ForEach(Array(field.previousValues.enumerated()), id: \.element.id) { index, version in
                        versionRow(version, field: field)
                        if index != field.previousValues.count - 1 {
                            Divider()
                        }
                    }
                }
            }
        }
    }

    private func versionRow(_ version: SecretValueVersion, field: FieldResolvedValue) -> some View {
        VStack(alignment: .leading, spacing: VaultSpacing.s) {
            HStack(spacing: VaultSpacing.s) {
                Text("Replaced \(Self.relative(version.replacedAt))")
                    .font(.vaultFootnote)
                    .foregroundStyle(.secondary)

                Spacer(minLength: 0)

                Button {
                    revealedVersionID = revealedVersionID == version.id ? nil : version.id
                } label: {
                    Image(systemName: revealedVersionID == version.id ? "eye.slash" : "eye")
                }
                .buttonStyle(VaultIconButtonStyle(isActive: revealedVersionID == version.id))
                .help(revealedVersionID == version.id ? "Hide this value" : "Show this value")
                .accessibilityLabel(revealedVersionID == version.id ? "Hide previous value" : "Show previous value")
                .accessibilityIdentifier("history-reveal-\(version.id.uuidString)")

                Button {
                    viewModel.copyPreviousValue(version, label: field.label)
                    flashCopied(version.id)
                } label: {
                    Image(systemName: copiedVersionID == version.id ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(VaultIconButtonStyle(isActive: copiedVersionID == version.id))
                .help("Copy this value")
                .accessibilityLabel("Copy previous value")
                .accessibilityIdentifier("history-copy-\(version.id.uuidString)")

                Button {
                    pendingRestore = PendingRestore(
                        id: version.id,
                        version: version,
                        fieldKey: field.key,
                        fieldLabel: field.label
                    )
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                }
                .buttonStyle(VaultIconButtonStyle())
                .help("Put this value back")
                .accessibilityLabel("Restore previous value")
                .accessibilityIdentifier("history-restore-\(version.id.uuidString)")
            }

            VaultValueBox {
                // Selection only while revealed, so a masked value can't be dragged out.
                Group {
                    if revealedVersionID == version.id {
                        Text(displayValue(for: version, field: field))
                            .textSelection(.enabled)
                    } else {
                        Text(displayValue(for: version, field: field))
                    }
                }
                .font(.vaultValueSmall)
                .lineLimit(4)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.vertical, VaultSpacing.hair)
    }

    private func displayValue(for version: SecretValueVersion, field: FieldResolvedValue) -> String {
        guard field.isSensitive, revealedVersionID != version.id else { return version.value }
        return SecretMasking.mask
    }

    private func flashCopied(_ id: UUID) {
        copiedVersionID = id
        Task {
            try? await Task.sleep(for: .seconds(1.4))
            if copiedVersionID == id { copiedVersionID = nil }
        }
    }

    // MARK: - Change log

    @ViewBuilder
    private func changeLogSection(for item: SecretItemEntity) -> some View {
        let entries = item.orderedChangeHistory
        VaultSection("Change log", systemImage: "list.bullet.rectangle") {
            if entries.isEmpty {
                VaultNote(text: "Nothing recorded yet. Changes made from now on will appear here.")
            } else {
                ForEach(entries) { entry in
                    HStack(alignment: .firstTextBaseline, spacing: VaultSpacing.s) {
                        Image(systemName: entry.kind.systemImage)
                            .font(.vaultFootnote)
                            .foregroundStyle(.secondary)
                            .frame(width: 16)
                        Text(entry.kind.title)
                            .font(.vaultRowSubtitle)
                        if let detail = entry.detail, !detail.isEmpty {
                            Text(detail)
                                .font(.vaultRowSubtitle)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: VaultSpacing.s)
                        Text(Self.absolute(entry.changedAt))
                            .font(.vaultRowSubtitle)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    // MARK: - Formatting

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter
    }()

    private static let absoluteFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    static func relative(_ date: Date) -> String {
        guard Date().timeIntervalSince(date) >= 60 else { return "just now" }
        return relativeFormatter.localizedString(for: date, relativeTo: Date())
    }

    static func absolute(_ date: Date) -> String {
        absoluteFormatter.string(from: date)
    }
}

/// Shared masking for hidden secret values.
enum SecretMasking {
    /// A fixed-width mask.
    ///
    /// The old placeholder repeated one bullet per character, which published the exact
    /// length of every hidden secret to anyone looking at the screen.
    static let mask = String(repeating: "•", count: 12)
}
