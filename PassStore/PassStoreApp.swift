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
        // `--ui-onboarding` starts on a throwaway container with no vault, so setup can be
        // driven without erasing anybody's real one.
        let startsInSetup = arguments.contains("--ui-onboarding")
        let isUITesting = startsInSetup || arguments.contains("--uitesting")
        let container: AppContainer = if startsInSetup {
            .uiTestingSetupRequired()
        } else if isUITesting {
            .uiTesting()
        } else {
            .live
        }
        _container = State(initialValue: container)
        let viewModel = VaultViewModel(container: container)
        _viewModel = State(initialValue: viewModel)
        _menuBarViewModel = State(initialValue: MenuBarViewModel(vault: viewModel))
        // A test instance must never claim the system-wide shortcut out from under the
        // installed app.
        if !isUITesting {
            PassStoreAppDelegate.deferredGlobalHotkeyConfiguration = {
                GlobalCommandPaletteHotkey.shared.configure(viewModel: viewModel, settings: container.settings)
            }
        }
        PassStoreAppDelegate.terminationHandler = {
            MainActor.assumeIsolated { container.memoryStore.flushPendingPersist() }
        }
    }

    var body: some Scene {
        // A single `Window`, not a `WindowGroup`. There is one vault, so there is one window:
        // a group let ⌘⌥P and "Open Main Window" spawn a fresh copy of the app every time
        // they fired, and SwiftUI hung its own "New Window" item on ⌘N — which is the
        // shortcut people expect to create a new entry.
        Window("PassStore", id: PassStoreScene.mainWindowID) {
            AppView(viewModel: viewModel)
                .background(MainWindowIdentifierMarker().frame(width: 0, height: 0))
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

enum PassStoreScene {
    static let mainWindowID = "main"
}

// MARK: - Menu bar extra

private struct MenuBarExtraOpenWindowBridge: View {
    @Environment(\.openWindow) private var openWindow
    var viewModel: MenuBarViewModel

    var body: some View {
        MenuBarPanelView(
            viewModel: viewModel,
            onOpenMainWindow: { MainWindowPresenter.present() }
        )
        .onAppear {
            MainWindowPresenter.setOpenAction { openWindow(id: PassStoreScene.mainWindowID) }
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
