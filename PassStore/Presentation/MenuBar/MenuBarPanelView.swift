import AppKit
import SwiftUI

struct MenuBarPanelView: View {
    @Bindable var viewModel: MenuBarViewModel

    var body: some View {
        Group {
            if viewModel.vault.container.sessionManager.lockState != .unlocked {
                Text("Unlock PassStore in the main window to copy secrets.")
            } else if viewModel.quickItems.isEmpty {
                Text("No favorite items with filled entries.")
            } else {
                ForEach(viewModel.quickItems, id: \.id) { item in
                    MenuBarItemRow(
                        item: item,
                        fields: viewModel.quickFields(for: item),
                        onCopy: { field in
                            viewModel.vault.container.clipboard.copy(field.value, label: "\(item.title) • \(field.label)")
                        }
                    )
                }
            }
            Divider()
            Button {
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                Label("Open Main Window", systemImage: "macwindow")
            }
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
                    Label(field.label, systemImage: "doc.on.doc")
                }
            }
        }
    }

    private var itemMenuTitle: String {
        if let workspace = item.workspace?.name {
            return "\(item.title) (\(workspace))"
        }
        return item.title
    }
}
