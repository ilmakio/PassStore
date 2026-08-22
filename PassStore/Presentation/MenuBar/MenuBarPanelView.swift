import AppKit
import SwiftUI

struct MenuBarPanelView: View {
    @Bindable var viewModel: MenuBarViewModel
    /// Supplied by the scene that owns `openWindow`; `NSApp.activate` alone cannot
    /// bring back the main window once the user has closed it.
    let onOpenMainWindow: () -> Void

    private var isLocked: Bool {
        viewModel.vault.container.sessionManager.lockState != .unlocked
    }

    var body: some View {
        Group {
            if isLocked {
                lockedContent
            } else {
                unlockedContent
            }

            Divider()

            Button {
                NSApp.activate(ignoringOtherApps: true)
                onOpenMainWindow()
            } label: {
                Label("Open Main Window", systemImage: "macwindow")
            }
        }
    }

    @ViewBuilder
    private var lockedContent: some View {
        Text("PassStore is locked.")

        // Unlocking used to require finding and opening the main window first, even when the
        // Mac could do it with a fingerprint.
        if viewModel.canUnlockWithBiometrics {
            Button {
                Task { await viewModel.unlockWithBiometrics() }
            } label: {
                Label("Unlock with Touch ID", systemImage: "touchid")
            }
        }
    }

    @ViewBuilder
    private var unlockedContent: some View {
        if viewModel.quickItems.isEmpty {
            Text("No favourites yet — star an item to reach it from here.")
        } else {
            ForEach(viewModel.quickItems, id: \.id) { item in
                MenuBarItemRow(
                    item: item,
                    fields: viewModel.quickFields(for: item),
                    onCopy: { field in
                        viewModel.copy(field, from: item)
                    }
                )
            }
        }

        Divider()

        Button {
            viewModel.vault.container.sessionManager.lock()
        } label: {
            Label("Lock Vault", systemImage: "lock.fill")
        }
    }
}

private struct MenuBarItemRow: View {
    let item: SecretItemEntity
    let fields: [FieldResolvedValue]
    let onCopy: (FieldResolvedValue) -> Void

    var body: some View {
        Menu(itemMenuTitle) {
            ForEach(fields) { field in
                Button {
                    onCopy(field)
                } label: {
                    Label(field.label, systemImage: Self.glyph(for: field))
                }
            }
        }
    }

    /// A one-time code copies six digits rather than what is stored, so it should not look like
    /// every other locked value in the list.
    private static func glyph(for field: FieldResolvedValue) -> String {
        if field.kind == .totp { return "clock.badge.checkmark" }
        return field.isSensitive ? "lock.doc" : "doc.on.doc"
    }

    private var itemMenuTitle: String {
        if let workspace = item.workspace?.name {
            return "\(item.title) (\(workspace))"
        }
        return item.title
    }
}
