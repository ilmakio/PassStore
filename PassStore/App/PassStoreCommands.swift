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

    /// Replaces the stock About item so the panel can carry authorship and project links.
    private var appInfoCommands: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button {
                AboutPassStore.show()
            } label: {
                Label("About PassStore", systemImage: "info.circle")
            }

            Divider()

#if !PASSSTORE_APP_STORE
            Button {
                PassStoreSparkleCoordinator.checkForUpdates()
            } label: {
                Label("Check for Updates…", systemImage: "arrow.down.circle")
            }
#endif
            Button {
                PassStoreLinks.open(PassStoreLinks.donate)
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

            // Pointing at a repository is the path most workspaces should take, so it gets the
            // shortcut; an empty one is right below it for a workspace that is not a codebase.
            Button {
                Task { await viewModel.beginWorkspaceFromFolder() }
            } label: {
                Label("New Workspace from Folder…", systemImage: "folder.badge.gearshape")
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])
            .disabled(isLocked)

            Button {
                viewModel.activeSheet = .newWorkspace
            } label: {
                Label("New Empty Workspace…", systemImage: "folder.badge.plus")
            }
            .disabled(isLocked)

            Divider()

            Button {
                viewModel.importEnvFileCreatingItem()
            } label: {
                Label("Import .env File…", systemImage: "doc.text.magnifyingglass")
            }
            .keyboardShortcut("o", modifiers: [.command, .shift])
            .disabled(isLocked)

            Button {
                viewModel.importDeveloperCredentials()
            } label: {
                Label("Import from Developer Tools…", systemImage: "square.and.arrow.down.on.square")
            }
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
            // Preserve native NSTextView undo whenever an editor/search field has focus, and
            // fall back to PassStore's snapshot undo only outside text editing. Replacing the
            // group with a vault-only command made ⌘Z erase an item while the user expected
            // it to undo the last typed character, and removed Redo entirely.
            CommandGroup(replacing: .undoRedo) {
                Button {
                    if let undoManager = activeTextUndoManager {
                        if undoManager.canUndo { undoManager.undo() }
                        return
                    }
                    viewModel.undoLastDestructiveAction()
                } label: {
                    Label(
                        undoMenuTitle,
                        systemImage: "arrow.uturn.backward"
                    )
                }
                .keyboardShortcut("z", modifiers: [.command])
                .disabled(!canUndo)

                Button {
                    activeTextUndoManager?.redo()
                } label: {
                    Label(redoMenuTitle, systemImage: "arrow.uturn.forward")
                }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(!(activeTextUndoManager?.canRedo ?? false))
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
                    viewModel.copyOneTimeCodeOfSelectedItem()
                } label: {
                    Label("Copy One-Time Code", systemImage: "clock.badge.checkmark")
                }
                .keyboardShortcut("t", modifiers: [.command, .shift])
                .disabled(!canUseClipboardActions || !viewModel.selectedItemHasOneTimeCode)

                Button {
                    viewModel.copyEnv()
                } label: {
                    Label("Copy as .env", systemImage: "doc.plaintext")
                }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(!canUseClipboardActions)

                Button {
                    viewModel.copyEnvValuesOnly()
                } label: {
                    Label("Copy as .env (Values Only)", systemImage: "list.bullet.rectangle")
                }
                .keyboardShortcut("e", modifiers: [.command, .shift, .option])
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

    /// SwiftUI text fields use an NSTextView field editor. Restricting this to editable text
    /// views keeps unrelated responders from intercepting the vault's own undo command.
    private var activeTextUndoManager: UndoManager? {
        guard let textView = NSApp.keyWindow?.firstResponder as? NSTextView,
              textView.isEditable else { return nil }
        return textView.undoManager
    }

    private var canUndo: Bool {
        if let manager = activeTextUndoManager { return manager.canUndo }
        return viewModel.undoActionLabel != nil
    }

    private var undoMenuTitle: String {
        if let manager = activeTextUndoManager {
            guard manager.canUndo else { return "Undo" }
            return manager.undoActionName.isEmpty ? "Undo" : "Undo \(manager.undoActionName)"
        }
        return viewModel.undoActionLabel.map { "Undo \($0)" } ?? "Undo"
    }

    private var redoMenuTitle: String {
        guard let manager = activeTextUndoManager, manager.canRedo else { return "Redo" }
        return manager.redoActionName.isEmpty ? "Redo" : "Redo \(manager.redoActionName)"
    }

    // MARK: - View

    private var viewCommands: some Commands {
        CommandGroup(after: .sidebar) {
            // The split view contributes a toolbar button but no menu entry, so the keyboard
            // had no way to reach the sidebar at all.
            Button {
                withAnimation(.easeOut(duration: 0.18)) {
                    viewModel.isSidebarVisible.toggle()
                }
            } label: {
                Label(
                    viewModel.isSidebarVisible ? "Hide Sidebar" : "Show Sidebar",
                    systemImage: "sidebar.left"
                )
            }
            .keyboardShortcut("s", modifiers: [.control, .command])
            .disabled(isLocked)

            Divider()

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

            // Moves along the environment tabs of the workspace being viewed, "All" included.
            // Disabled outside a project view, where there are no tabs to move between.
            Button {
                viewModel.cycleEnvironment(by: -1)
            } label: {
                Label("Previous Environment", systemImage: "chevron.left")
            }
            .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
            .disabled(isLocked || viewModel.environmentBarWorkspaceID == nil)

            Button {
                viewModel.cycleEnvironment(by: 1)
            } label: {
                Label("Next Environment", systemImage: "chevron.right")
            }
            .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
            .disabled(isLocked || viewModel.environmentBarWorkspaceID == nil)

            Divider()

            Picker("Sort By", selection: $viewModel.sortOrder) {
                ForEach(ItemSortOrder.allCases) { order in
                    Label(order.title, systemImage: order.systemImage).tag(order)
                }
            }
            // Recent defines its own order, so the control would otherwise claim a setting
            // that is not being applied.
            .disabled(isLocked || viewModel.isSortOrderFixedByDestination)
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

                Button {
                    viewModel.scanFolderForLeakedSecrets()
                } label: {
                    Label("Scan a Folder for Secrets…", systemImage: "doc.text.magnifyingglass")
                }
                .disabled(isLocked)

                Button {
                    viewModel.showLastSecretScanReport()
                } label: {
                    Label("Last Scan Results…", systemImage: "list.bullet.rectangle")
                }
                .disabled(isLocked || !viewModel.hasSecretScanReport)

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

                Divider()

                Button {
                    viewModel.restoreSelectedItemFromTrash()
                } label: {
                    Label("Put Back", systemImage: "arrow.uturn.backward")
                }
                .disabled(viewModel.selectedItem?.isDeleted != true)

                Button {
                    viewModel.requestEmptyTrash()
                } label: {
                    Label("Empty Recently Deleted…", systemImage: "trash.slash")
                }
                .disabled(isLocked || viewModel.trashCount == 0)
            }
        }
    }

    // MARK: - Help

    private var helpCommands: some Commands {
        CommandGroup(replacing: .help) {
            Button {
                PassStoreLinks.open(PassStoreLinks.security)
            } label: {
                Label("About Encryption", systemImage: "lock.shield")
            }

            Button {
                PassStoreLinks.open(PassStoreLinks.changelog)
            } label: {
                Label("Changelog", systemImage: "list.bullet")
            }

            Divider()

            Button {
                PassStoreLinks.open(PassStoreLinks.repository)
            } label: {
                Label("PassStore on GitHub", systemImage: "chevron.left.forwardslash.chevron.right")
            }

            Button {
                PassStoreLinks.open(PassStoreLinks.contributing)
            } label: {
                Label("Contribute…", systemImage: "hammer")
            }

            Button {
                PassStoreLinks.open(PassStoreLinks.issues)
            } label: {
                Label("Report an Issue…", systemImage: "exclamationmark.bubble")
            }

            Button {
                PassStoreLinks.open(PassStoreLinks.feedback)
            } label: {
                Label("Send Feedback…", systemImage: "envelope")
            }

            Divider()

            Button {
                PassStoreLinks.open(PassStoreLinks.website)
            } label: {
                Label("PassStore Website", systemImage: "globe")
            }

            Button {
                PassStoreLinks.open(PassStoreLinks.author)
            } label: {
                Label("makio.app", systemImage: "person.crop.circle")
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
