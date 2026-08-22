import AppKit
import SwiftUI

/// Brings the one main window to the front, opening it only if it is not already there.
///
/// Every caller used to invoke `openWindow(id:)` straight away. Against the old `WindowGroup`
/// that created an *additional* window each time, so pressing the global shortcut a few times
/// left a pile of identical windows behind. The scene is a single `Window` now, and this owns
/// the remaining edge cases: minimised, closed, or reopened from the Dock.
@MainActor
enum MainWindowPresenter {
    static let windowIdentifier = NSUserInterfaceItemIdentifier("app.makio.PassStore.main-window")
    /// Set by whichever scene currently has `openWindow` in its environment.
    private static var openAction: (() -> Void)?

    static func setOpenAction(_ action: @escaping () -> Void) {
        openAction = action
    }

    static func present() {
        // A Dock-less app owns no menu bar. Becoming regular before the window appears means it
        // arrives with File, Edit and Vault where they belong.
        ActivationPolicyController.prepareForWindow()
        NSApp.activate(ignoringOtherApps: true)

        if let window = existingMainWindow() {
            if window.isMiniaturized {
                window.deminiaturize(nil)
            }
            window.makeKeyAndOrderFront(nil)
            return
        }

        openAction?()
    }

    /// The app's own window, ignoring sheets, panels and the menu bar extra's host window.
    static func existingMainWindow() -> NSWindow? {
        NSApp.windows.first { $0.identifier == windowIdentifier }
    }
}

/// SwiftUI's scene id is not guaranteed to become `NSWindow.identifier`. Install an explicit
/// marker so a menu-bar panel or helper window can never be mistaken for the vault window.
struct MainWindowIdentifierMarker: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async { view.window?.identifier = MainWindowPresenter.windowIdentifier }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { nsView.window?.identifier = MainWindowPresenter.windowIdentifier }
    }
}
