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
    /// Set by whichever scene currently has `openWindow` in its environment.
    private static var openAction: (() -> Void)?

    static func setOpenAction(_ action: @escaping () -> Void) {
        openAction = action
    }

    static func present() {
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
        let candidates = NSApp.windows.filter { window in
            !window.isSheet
                && window.level == .normal
                && window.canBecomeKey
                && window.contentViewController != nil
        }
        if let main = candidates.first(where: \.isMainWindow) { return main }
        // Fall back to the largest, which is the app window rather than a stray helper.
        return candidates.max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height })
    }
}
