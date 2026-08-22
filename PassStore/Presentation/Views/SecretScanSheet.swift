import AppKit
import SwiftUI

/// What a folder on disk holds in plaintext that the vault also holds.
///
/// This is the one question only a password manager can answer, because it is the only thing that
/// knows both halves. The report names the secret and the file and never the value — it gets
/// screenshotted and pasted into tickets, so a report about leaked secrets must not itself be a
/// list of them.
struct SecretScanSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var viewModel: VaultViewModel

    var body: some View {
        VaultSheetScaffold(
            title: "Secrets in Files",
            subtitle: subtitle,
            systemImage: "doc.text.magnifyingglass",
            // This sheet owns its own scrolling. Left to the scaffold, the list below sat inside a
            // second scroll view, which hands a lazy stack unbounded height — so it built every row
            // regardless and the sheet crawled on a large repository.
            scrolls: false
        ) {
            if let report = viewModel.secretScanReport, !report.isClean {
                Button("Copy List") { viewModel.copySecretScanReport() }
                    .buttonStyle(SheetCapsuleButtonStyle(isPrimary: false))
                    .accessibilityIdentifier("secret-scan-copy-report")
            }

            Spacer(minLength: 0)
            Button("Done") { dismiss() }
            .buttonStyle(SheetCapsuleButtonStyle(isPrimary: true))
            .accessibilityIdentifier("secret-scan-done")
        } content: {
            Group {
                if viewModel.isScanningForSecrets {
                    scanning
                        .padding(VaultSpacing.xl)
                } else if let report = viewModel.secretScanReport {
                    results(report)
                } else {
                    VaultNote(text: "Choose a folder to check.")
                        .padding(VaultSpacing.xl)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 620, minHeight: 460)
    }

    private var subtitle: String? {
        guard let report = viewModel.secretScanReport else { return nil }
        return (report.root as NSString).abbreviatingWithTildeInPath
    }

    private var scanning: some View {
        VStack(alignment: .leading, spacing: VaultSpacing.m) {
            HStack(spacing: VaultSpacing.s) {
                ProgressView()
                    .controlSize(.small)
                Text("Reading files…")
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button("Stop") { viewModel.cancelSecretScan() }
                    .buttonStyle(VaultButtonStyle(.secondary))
                    .controlSize(.small)
            }
            VaultNote(text: "PassStore is looking for its own stored secrets in the files inside that folder. Nothing is written and nothing leaves your Mac.")
        }
        .accessibilityIdentifier("secret-scan-progress")
    }

    @ViewBuilder
    private func results(_ report: SecretScanReport) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // The verdict does not scroll away: it is the part somebody has to read.
            summary(report)
                .padding(.horizontal, VaultSpacing.xl)
                .padding(.top, VaultSpacing.xl)
                .padding(.bottom, VaultSpacing.l)

            if report.isClean {
                VaultEmptyState(
                    title: "Nothing found",
                    message: "None of your stored secrets appear in the files inside that folder.",
                    systemImage: "checkmark.shield",
                    actions: { EmptyView() }
                )
                .padding(.horizontal, VaultSpacing.xl)
                Spacer(minLength: 0)
            } else {
                Divider()

                // The only scroll view in this sheet, so the lazy stack inside it is actually lazy
                // and a report with hundreds of files costs what is on screen rather than all of it.
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: VaultSpacing.s) {
                        ForEach(report.fileGroups) { group in
                            fileGroup(group)
                        }

                        if report.isPartiallyRendered {
                            remainderNote(report)
                        }
                    }
                    .padding(VaultSpacing.xl)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func summary(_ report: SecretScanReport) -> some View {
        VStack(alignment: .leading, spacing: VaultSpacing.s) {
            if report.isClean {
                VaultNote(
                    text: "Checked \(report.secretsChecked) stored \(report.secretsChecked == 1 ? "secret" : "secrets") against \(report.filesScanned) \(report.filesScanned == 1 ? "file" : "files").",
                    tone: .success
                )
            } else {
                VaultNote(
                    text: "\(report.affectedSecretCount) of your \(report.secretsChecked) stored secrets \(report.affectedSecretCount == 1 ? "appears" : "appear") in \(report.affectedFileCount) \(report.affectedFileCount == 1 ? "file" : "files"). Anything committed is in your history as well — rotate the secret rather than only deleting the line.",
                    tone: .warning
                )
            }

            if !report.isClean {
                VaultNote(
                    text: "PassStore cannot fix these for you, and deleting the line is not enough on its own. For anything that was committed: rotate the secret at the service that issued it, put the new one in the vault, then remove it from the file. Copy List gives you all of this as text to work through.",
                    systemImage: "arrow.triangle.2.circlepath"
                )
            }

            if report.wasTruncated {
                VaultNote(
                    text: "The scan stopped early, so this is not a complete answer. Point it at a project folder rather than a whole home directory.",
                    tone: .warning
                )
            }
        }
    }

    /// What the cap left out, and how to get at it.
    private func remainderNote(_ report: SecretScanReport) -> some View {
        VaultNote(
            text: report.hiddenFileCount > 0
                ? "Showing the first \(report.fileGroups.count) of \(report.affectedFileCount) files. Copy List has every one of the \(report.findings.count) findings."
                : "Some files have more findings than are shown. Copy List has every one of the \(report.findings.count) findings.",
            systemImage: "list.bullet.rectangle"
        )
        .padding(.top, VaultSpacing.xs)
    }

    private func fileGroup(_ group: SecretScanFileGroup) -> some View {
        VaultCard {
            VStack(alignment: .leading, spacing: VaultSpacing.xs) {
                HStack(spacing: VaultSpacing.s) {
                    Text(group.relativePath)
                        .font(.vaultValueSmall)
                        .textSelection(.enabled)
                        .lineLimit(2)
                        .truncationMode(.middle)
                    Spacer(minLength: VaultSpacing.s)
                    Button {
                        viewModel.copyScanFilePath(group.absolutePath)
                    } label: {
                        Label("Copy Path", systemImage: "doc.on.doc")
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(VaultIconButtonStyle())
                    .help("Copy this file's path")
                    .accessibilityLabel("Copy the path of \(group.relativePath)")

                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: group.absolutePath)])
                    } label: {
                        Label("Reveal", systemImage: "folder")
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(VaultIconButtonStyle())
                    .help("Show this file in the Finder")
                    .accessibilityLabel("Reveal \(group.relativePath) in the Finder")
                }

                ForEach(group.findings) { finding in
                    HStack(spacing: VaultSpacing.xs) {
                        Text("line \(finding.line)")
                            .font(.vaultBadge)
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 52, alignment: .leading)
                        Text("\(finding.itemTitle) › \(finding.fieldLabel)")
                            .font(.vaultFootnote)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 0)
                        Button("Show in Vault") {
                            viewModel.selectItem(id: finding.itemID)
                            dismiss()
                        }
                        .buttonStyle(.vaultLink)
                        .font(.caption)
                        .help("Selects this secret in the vault. The list is kept — reopen it from Vault ▸ Last Scan Results.")
                    }
                    .accessibilityElement(children: .combine)
                }

                if group.hiddenFindingCount > 0 {
                    Text("and \(group.hiddenFindingCount) more in this file")
                        .font(.vaultFootnote)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

}
