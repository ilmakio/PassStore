import AppKit
import SwiftUI

@main
struct PassStoreApp: App {
    @NSApplicationDelegateAdaptor(PassStoreAppDelegate.self) private var appDelegate

    @State private var container: AppContainer
    @State private var viewModel: VaultViewModel
    @State private var menuBarViewModel: MenuBarViewModel

    init() {
        let arguments = ProcessInfo.processInfo.arguments
        let container: AppContainer = if arguments.contains("--uitesting") {
            .uiTesting()
        } else {
            .live
        }
        _container = State(initialValue: container)
        let viewModel = VaultViewModel(container: container)
        _viewModel = State(initialValue: viewModel)
        _menuBarViewModel = State(initialValue: MenuBarViewModel(vault: viewModel))
        if !arguments.contains("--uitesting") {
            PassStoreAppDelegate.deferredGlobalHotkeyConfiguration = {
                GlobalCommandPaletteHotkey.shared.configure(viewModel: viewModel, settings: container.settings)
            }
        }
    }

    var body: some Scene {
        WindowGroup(id: "main") {
            AppView(viewModel: viewModel)
        }
        .commands {
            PassStoreCommands(viewModel: viewModel)
        }

        MenuBarExtra {
            MenuBarExtraOpenWindowBridge(viewModel: menuBarViewModel)
        } label: {
            // MenuBarExtra ignores SwiftUI .frame() on vector assets; use a real 14×14pt NSImage.
            Image(nsImage: MenuBarTemplateIcon.nsImage)
                .frame(width: MenuBarIconMetrics.side, height: MenuBarIconMetrics.side)
                .accessibilityLabel("PassStore")
        }
    }
}

// MARK: - Menu bar extra

private struct MenuBarExtraOpenWindowBridge: View {
    @Environment(\.openWindow) private var openWindow
    var viewModel: MenuBarViewModel

    var body: some View {
        MenuBarPanelView(viewModel: viewModel)
            .onAppear {
                GlobalCommandPaletteHotkey.shared.setOpenMainWindowAction {
                    openWindow(id: "main")
                }
            }
    }
}

private enum MenuBarIconMetrics {
    static let side: CGFloat = 14
}

private enum MenuBarTemplateIcon {
    /// Pre-rasterized template image so `MenuBarExtra` cannot expand the SVG to its intrinsic size.
    static let nsImage: NSImage = {
        let target = NSSize(width: MenuBarIconMetrics.side, height: MenuBarIconMetrics.side)
        guard let source = NSImage(named: "icon"), source.size.width > 0, source.size.height > 0 else {
            let empty = NSImage(size: target)
            empty.isTemplate = true
            return empty
        }
        let scaled = NSImage(size: target, flipped: false) { rect in
            let src = NSRect(origin: .zero, size: source.size)
            source.draw(in: rect, from: src, operation: .copy, fraction: 1.0)
            return true
        }
        scaled.isTemplate = true
        return scaled
    }()
}
