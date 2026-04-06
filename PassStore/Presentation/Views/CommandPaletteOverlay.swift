import AppKit
import SwiftUI

struct CommandPaletteEntry: Identifiable {
    let id: String
    let title: String
    let subtitle: String?
    let keywords: [String]
    let isEnabled: Bool
    let perform: () -> Void

    func matches(query: String) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return true }
        let bundle = ([title, subtitle].compactMap(\.self) + keywords).joined(separator: " ")
        return bundle.localizedCaseInsensitiveContains(trimmed)
    }
}

struct CommandPaletteOverlay: View {
    @Bindable var viewModel: VaultViewModel
    @FocusState private var searchFocused: Bool
    @State private var selectedIndex: Int = 0
    @State private var escapeKeyMonitor: Any?

    private var allEntries: [CommandPaletteEntry] {
        viewModel.makeCommandPaletteEntries()
    }

    private var filteredEntries: [CommandPaletteEntry] {
        let q = viewModel.commandPaletteQuery
        return allEntries.filter { $0.matches(query: q) }
    }

    var body: some View {
        ZStack {
            Button {
                viewModel.dismissCommandPalette()
            } label: {
                Color.black.opacity(0.35)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("command-palette-scrim")
            .accessibilityLabel("Dismiss command palette")

            VStack(spacing: 0) {
                TextField("Search commands and items…", text: $viewModel.commandPaletteQuery)
                    .textFieldStyle(.plain)
                    .font(.body)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .accessibilityIdentifier("command-palette-search")
                    .focused($searchFocused)
                    .onSubmit {
                        runSelectedEntry()
                    }
                    .onKeyPress(.upArrow) {
                        moveSelection(-1)
                        return .handled
                    }
                    .onKeyPress(.downArrow) {
                        moveSelection(1)
                        return .handled
                    }
                    .onKeyPress(.escape) {
                        viewModel.dismissCommandPalette()
                        return .handled
                    }
                    .onChange(of: viewModel.commandPaletteQuery) { _, _ in
                        clampSelection()
                    }

                Divider()

                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            if filteredEntries.isEmpty {
                                Text("No matches")
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 20)
                            } else {
                                ForEach(Array(filteredEntries.enumerated()), id: \.element.id) { index, entry in
                                    paletteRow(entry: entry, index: index)
                                        .id(entry.id)
                                }
                            }
                        }
                        .padding(.vertical, 6)
                    }
                    .frame(maxHeight: 320)
                    .accessibilityIdentifier("command-palette-list")
                    .onChange(of: selectedIndex) { _, newValue in
                        guard newValue >= 0, newValue < filteredEntries.count else { return }
                        proxy.scrollTo(filteredEntries[newValue].id, anchor: .center)
                    }
                }
            }
            .frame(width: 520)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(.separator.opacity(0.45), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.2), radius: 24, y: 12)
        }
        .onAppear {
            clampSelection()
            searchFocused = true
            escapeKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                guard event.keyCode == 53 else { return event }
                viewModel.dismissCommandPalette()
                return nil
            }
        }
        .onDisappear {
            if let escapeKeyMonitor {
                NSEvent.removeMonitor(escapeKeyMonitor)
            }
            escapeKeyMonitor = nil
        }
        .onExitCommand {
            viewModel.dismissCommandPalette()
        }
    }

    @ViewBuilder
    private func paletteRow(entry: CommandPaletteEntry, index: Int) -> some View {
        let isSelected = index == selectedIndex
        Button {
            run(entry: entry)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.title)
                        .foregroundStyle(entry.isEnabled ? .primary : .tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if let subtitle = entry.subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? Color.accentColor.opacity(0.18) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!entry.isEnabled)
    }

    private func moveSelection(_ delta: Int) {
        let rows = filteredEntries
        guard !rows.isEmpty, rows.contains(where: \.isEnabled) else { return }
        var next = selectedIndex
        var attempts = 0
        repeat {
            next = (next + delta + rows.count) % rows.count
            attempts += 1
            if attempts > rows.count { return }
        } while !rows[next].isEnabled
        selectedIndex = next
    }

    private func clampSelection() {
        let rows = filteredEntries
        guard !rows.isEmpty else {
            selectedIndex = 0
            return
        }
        if let firstEnabled = rows.firstIndex(where: \.isEnabled) {
            if selectedIndex >= rows.count || !rows[selectedIndex].isEnabled {
                selectedIndex = firstEnabled
            }
        } else {
            selectedIndex = 0
        }
    }

    private func runSelectedEntry() {
        guard selectedIndex >= 0, selectedIndex < filteredEntries.count else { return }
        let entry = filteredEntries[selectedIndex]
        run(entry: entry)
    }

    private func run(entry: CommandPaletteEntry) {
        guard entry.isEnabled else { return }
        entry.perform()
    }
}

extension VaultViewModel {
    func makeCommandPaletteEntries() -> [CommandPaletteEntry] {
        let canClipboard = selectedItem != nil && container.sessionManager.lockState == .unlocked
        let canConnectionString = canClipboard && selectedItem?.type == .database

        func wrap(_ action: @escaping () -> Void) -> () -> Void {
            {
                self.dismissCommandPalette()
                action()
            }
        }

        let staticCommands: [CommandPaletteEntry] = [
            .init(
                id: "cmd.newItem",
                title: "New Secret Item…",
                subtitle: "Shortcut: ⌘⇧N",
                keywords: ["new", "add", "create", "item"],
                isEnabled: true,
                perform: wrap { self.activeSheet = .newItemFlow }
            ),
            .init(
                id: "cmd.newWorkspace",
                title: "New Workspace…",
                subtitle: nil,
                keywords: ["workspace", "folder"],
                isEnabled: true,
                perform: wrap { self.activeSheet = .newWorkspace }
            ),
            .init(
                id: "cmd.importExport",
                title: "Import .pstore Backup…",
                subtitle: nil,
                keywords: ["import", "backup", "encrypted", "pstore"],
                isEnabled: true,
                perform: wrap { self.activeSheet = .importEncryptedExport }
            ),
            .init(
                id: "cmd.export",
                title: "Export .pstore Backup…",
                subtitle: nil,
                keywords: ["export", "backup", "pstore"],
                isEnabled: true,
                perform: wrap { self.activeSheet = .export }
            ),
            .init(
                id: "cmd.copyEnv",
                title: "Copy as .env",
                subtitle: nil,
                keywords: ["copy", "clipboard", "env"],
                isEnabled: canClipboard,
                perform: wrap { self.copyEnv() }
            ),
            .init(
                id: "cmd.copyJSON",
                title: "Copy as JSON",
                subtitle: nil,
                keywords: ["copy", "clipboard", "json"],
                isEnabled: canClipboard,
                perform: wrap { self.copyJSON() }
            ),
            .init(
                id: "cmd.copyConnection",
                title: "Copy Database Connection String",
                subtitle: nil,
                keywords: ["copy", "database", "connection", "uri"],
                isEnabled: canConnectionString,
                perform: wrap { self.copyConnectionString() }
            ),
            .init(
                id: "cmd.settings",
                title: "Settings…",
                subtitle: nil,
                keywords: ["preferences", "options"],
                isEnabled: true,
                perform: wrap { self.isSettingsPresented = true }
            ),
            .init(
                id: "cmd.lock",
                title: "Lock Vault",
                subtitle: nil,
                keywords: ["lock", "secure"],
                isEnabled: container.sessionManager.lockState == .unlocked,
                perform: wrap { self.container.sessionManager.lock() }
            )
        ]

        var dynamic: [CommandPaletteEntry] = []

        for workspace in workspaces.sorted(by: { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }) {
            let id = workspace.id.uuidString
            dynamic.append(
                .init(
                    id: "go.workspace.\(id)",
                    title: "Go to \(workspace.name)",
                    subtitle: "Workspace",
                    keywords: ["workspace", "folder", workspace.name],
                    isEnabled: true,
                    perform: wrap {
                        self.selectDestination(.workspace(workspace.id))
                        self.setSelectedType(nil)
                    }
                )
            )
        }

        for item in items.sorted(by: { lhs, rhs in
            let t = lhs.title.localizedCaseInsensitiveCompare(rhs.title)
            if t != .orderedSame { return t == .orderedAscending }
            return lhs.id.uuidString < rhs.id.uuidString
        }) {
            let id = item.id.uuidString
            let subtitleParts = [item.type.title, item.workspace?.name].compactMap { $0 }
            dynamic.append(
                .init(
                    id: "open.item.\(id)",
                    title: "Open \(item.title)",
                    subtitle: subtitleParts.joined(separator: " · "),
                    keywords: ["open", "item", item.title, item.type.title] + item.tags + [item.environmentValue.title],
                    isEnabled: true,
                    perform: wrap {
                        self.revealAndSelectItemFromPalette(item)
                    }
                )
            )
        }

        return staticCommands + dynamic
    }
}
