import AppKit
import SwiftUI

/// The app's menu bar.
///
/// Menus follow where a Mac user expects to find things: making and importing under File,
/// copying under Edit, moving around under View, and everything specific to the vault in its
/// own menu. Before 1.2.0 the password generator and the health report lived under View, and
/// Lock lived in the app menu next to Settings.
struct PassStoreCommands: Commands {
    @Bindable var viewModel: VaultViewModel

    var body: some Commands {
        appInfoCommands
        fileCommands
        editCommands
        viewCommands
        vaultMenu
        helpCommands
    }

    // MARK: - App menu

    private var appInfoCommands: some Commands {
        CommandGroup(after: .appInfo) {
#if !PASSSTORE_APP_STORE
            Button {
                PassStoreSparkleCoordinator.checkForUpdates()
            } label: {
                Label("Check for Updates…", systemImage: "arrow.down.circle")
            }
#endif
            Button {
                if let url = URL(string: "https://ko-fi.com/ilmakio") {
                    NSWorkspace.shared.open(url)
                }
            } label: {
                Label("Donate / Buy me a coffee", systemImage: "cup.and.saucer.fill")
            }
        }
    }

    private var settingsCommand: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button {
                viewModel.isSettingsPresented = true
            } label: {
                Label("Settings…", systemImage: "gearshape")
            }
            .keyboardShortcut(",", modifiers: [.command])
        }
    }

    // MARK: - File

    /// Replaces the whole New group rather than appending to it.
    ///
    /// SwiftUI puts its own "New Window" item here and claims ⌘N for it — which is the one
    /// shortcut everybody expects to make a new entry.
    private var fileCommands: some Commands {
        CommandGroup(replacing: .newItem) {
            Button {
                viewModel.activeSheet = .newItemFlow
            } label: {
                Label("New Secret Item…", systemImage: "doc.badge.plus")
            }
            .keyboardShortcut("n", modifiers: [.command])
            .disabled(isLocked)

            Button {
                viewModel.activeSheet = .newWorkspace
            } label: {
                Label("New Workspace…", systemImage: "folder.badge.plus")
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])
            .disabled(isLocked)

            Divider()

            Button {
                viewModel.importEnvFileCreatingItem()
            } label: {
                Label("Import .env File…", systemImage: "doc.text.magnifyingglass")
            }
            .keyboardShortcut("o", modifiers: [.command, .shift])
            .disabled(isLocked)

            Divider()

            Button {
                viewModel.activeSheet = .importEncryptedExport
            } label: {
                Label("Restore Backup…", systemImage: "square.and.arrow.down")
            }
            .disabled(isLocked)

            Button {
                viewModel.activeSheet = .export
            } label: {
                Label("Export Backup…", systemImage: "square.and.arrow.up")
            }
            .disabled(isLocked)
        }
    }

    // MARK: - Edit

    private var editCommands: some Commands {
        Group {
            // The system Undo entry does nothing here — there is no text document behind it —
            // but destructive vault actions are worth being able to take back.
            CommandGroup(replacing: .undoRedo) {
                Button {
                    viewModel.undoLastDestructiveAction()
                } label: {
                    Label(
                        viewModel.undoActionLabel.map { "Undo \($0)" } ?? "Undo",
                        systemImage: "arrow.uturn.backward"
                    )
                }
                .keyboardShortcut("z", modifiers: [.command])
                .disabled(viewModel.undoActionLabel == nil)
            }

            CommandGroup(after: .pasteboard) {
                Divider()

                Button {
                    viewModel.copyPrimaryFieldOfSelectedItem()
                } label: {
                    Label("Copy Password", systemImage: "key.horizontal")
                }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .disabled(!canUseClipboardActions)

                Button {
                    viewModel.copyEnv()
                } label: {
                    Label("Copy as .env", systemImage: "doc.plaintext")
                }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(!canUseClipboardActions)

                Button {
                    viewModel.copyJSON()
                } label: {
                    Label("Copy as JSON", systemImage: "curlybraces")
                }
                .keyboardShortcut("j", modifiers: [.command, .shift])
                .disabled(!canUseClipboardActions)

                Button {
                    viewModel.copyConnectionString()
                } label: {
                    Label("Copy Connection String", systemImage: "cylinder.split.1x2")
                }
                .disabled(!canUseClipboardActions || viewModel.selectedItem?.type != .database)

                Divider()

                // Find belongs in Edit on macOS; it used to sit under View.
                Button {
                    viewModel.requestSearchFocus()
                } label: {
                    Label("Find", systemImage: "magnifyingglass")
                }
                .keyboardShortcut("f", modifiers: [.command])
                .disabled(isLocked)
            }
        }
    }

    // MARK: - View

    private var viewCommands: some Commands {
        CommandGroup(after: .sidebar) {
            Button {
                viewModel.presentCommandPalette()
            } label: {
                Label("Command Palette…", systemImage: "command.circle")
            }
            .keyboardShortcut("k", modifiers: [.command])
            .disabled(isLocked)

            Divider()

            // ⌥ arrows rather than bare arrows: the list handles ↑/↓ itself when it has
            // focus, and these keep working from the search field or the detail pane.
            Button {
                viewModel.moveSelection(by: -1)
            } label: {
                Label("Select Previous Item", systemImage: "chevron.up")
            }
            .keyboardShortcut(.upArrow, modifiers: [.option])
            .disabled(isLocked)

            Button {
                viewModel.moveSelection(by: 1)
            } label: {
                Label("Select Next Item", systemImage: "chevron.down")
            }
            .keyboardShortcut(.downArrow, modifiers: [.option])
            .disabled(isLocked)

            Divider()

            Picker("Sort By", selection: $viewModel.sortOrder) {
                ForEach(ItemSortOrder.allCases) { order in
                    Label(order.title, systemImage: order.systemImage).tag(order)
                }
            }
            .disabled(isLocked)
        }
    }

    // MARK: - Vault

    private var vaultMenu: some Commands {
        Group {
            settingsCommand

            CommandMenu("Vault") {
                Button {
                    viewModel.container.sessionManager.lock()
                } label: {
                    Label("Lock Vault", systemImage: "lock.fill")
                }
                .keyboardShortcut("l", modifiers: [.command, .shift])
                .disabled(isLocked)

                Divider()

                Button {
                    viewModel.activeSheet = .passwordGenerator
                } label: {
                    Label("Password Generator…", systemImage: "wand.and.sparkles")
                }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .disabled(isLocked)

                Button {
                    viewModel.activeSheet = .vaultHealth
                } label: {
                    Label("Vault Health…", systemImage: "checkmark.shield")
                }
                .disabled(isLocked)

                Divider()

                Button {
                    guard let item = viewModel.selectedItem else { return }
                    viewModel.activeSheet = .itemHistory(item.id)
                } label: {
                    Label("Item History…", systemImage: "clock.arrow.circlepath")
                }
                .keyboardShortcut("y", modifiers: [.command])
                .disabled(viewModel.selectedItem == nil || isLocked)

                Button {
                    viewModel.updateSelectedItemFromLinkedFile()
                } label: {
                    Label("Update from Linked File", systemImage: "arrow.down.doc")
                }
                .keyboardShortcut("r", modifiers: [.command])
                .disabled(!canUpdateFromLinkedFile)
            }
        }
    }

    // MARK: - Help

    private var helpCommands: some Commands {
        CommandGroup(replacing: .help) {
            Button {
                if let url = URL(string: "https://passstore.makio.app/security") {
                    NSWorkspace.shared.open(url)
                }
            } label: {
                Label("About encryption", systemImage: "lock.shield")
            }

            Button {
                if let url = URL(string: "https://passstore.makio.app/changelog") {
                    NSWorkspace.shared.open(url)
                }
            } label: {
                Label("Changelog", systemImage: "list.bullet")
            }

            Button {
                if let url = URL(string: "mailto:feedback@makio.app") {
                    NSWorkspace.shared.open(url)
                }
            } label: {
                Label("Send Feedback…", systemImage: "envelope")
            }
        }
    }

    // MARK: - Availability

    private var isLocked: Bool {
        viewModel.container.sessionManager.lockState != .unlocked
    }

    private var canUseClipboardActions: Bool {
        viewModel.selectedItem != nil && !isLocked
    }

    private var canUpdateFromLinkedFile: Bool {
        guard !isLocked, let item = viewModel.selectedItem else { return false }
        return item.linkedFile != nil
    }
}
