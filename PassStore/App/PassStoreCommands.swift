import AppKit
import SwiftUI

struct PassStoreCommands: Commands {
    @Bindable var viewModel: VaultViewModel

    var body: some Commands {
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

        CommandGroup(after: .newItem) {
            Button {
                viewModel.activeSheet = .newItemFlow
            } label: {
                Label("New Secret Item…", systemImage: "doc.badge.plus")
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])

            Button {
                viewModel.activeSheet = .newWorkspace
            } label: {
                Label("New Workspace…", systemImage: "folder.badge.plus")
            }
        }

        CommandGroup(after: .importExport) {
            Button {
                viewModel.activeSheet = .importEncryptedExport
            } label: {
                Label("Import .pstore Backup…", systemImage: "square.and.arrow.down")
            }

            Button {
                viewModel.activeSheet = .export
            } label: {
                Label("Export .pstore Backup…", systemImage: "square.and.arrow.up")
            }
        }

        CommandGroup(after: .pasteboard) {
            Divider()

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
                Label("Copy Database Connection String", systemImage: "cylinder.split.1x2")
            }
            .disabled(!canUseClipboardActions || viewModel.selectedItem?.type != .database)
        }

        CommandGroup(after: .toolbar) {
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
        }

        CommandGroup(replacing: .appSettings) {
            Button {
                viewModel.isSettingsPresented = true
            } label: {
                Label("Settings…", systemImage: "gearshape")
            }
            .keyboardShortcut(",", modifiers: [.command])

            Button {
                viewModel.container.sessionManager.lock()
            } label: {
                Label("Lock Vault", systemImage: "lock.fill")
            }
            .keyboardShortcut("l", modifiers: [.command, .shift])
            .disabled(viewModel.container.sessionManager.lockState != .unlocked)
        }

        CommandGroup(after: .sidebar) {
            Button {
                viewModel.presentCommandPalette()
            } label: {
                Label("Command Palette…", systemImage: "command.circle")
            }
            .keyboardShortcut("k", modifiers: [.command])
            .disabled(isLocked)

            Divider()

            Button {
                viewModel.requestSearchFocus()
            } label: {
                Label("Find", systemImage: "magnifyingglass")
            }
            .keyboardShortcut("f", modifiers: [.command])
            .disabled(isLocked)

            // ⌥ arrows rather than bare arrows so list navigation never steals keys from a focused text field.
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
        }
    }

    private var isLocked: Bool {
        viewModel.container.sessionManager.lockState != .unlocked
    }

    private var canUseClipboardActions: Bool {
        viewModel.selectedItem != nil && viewModel.container.sessionManager.lockState == .unlocked
    }
}
