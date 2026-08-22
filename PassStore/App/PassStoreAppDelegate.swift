import AppKit

final class PassStoreAppDelegate: NSObject, NSApplicationDelegate {
    /// Installed from `PassStoreApp.init` so hotkey registration does not happen before
    /// NSApplication is ready (avoids launch freezes).
    static var deferredGlobalHotkeyConfiguration: (() -> Void)?
    /// Reads the Dock-icon preference. Set from `PassStoreApp.init`, which owns the settings store.
    static var showsInMenuBarOnly: (() -> Bool)?
    private var activationPolicyObserver: NSObjectProtocol?
    private var windowCloseObserver: NSObjectProtocol?
    /// Writes any coalesced vault changes before the process goes away.
    static var terminationHandler: (() -> Void)?

    func applicationDidFinishLaunching(_ notification: Notification) {
#if !PASSSTORE_APP_STORE
        let automaticUpdates = !ProcessInfo.processInfo.arguments.contains("--uitesting")
        PassStoreSparkleCoordinator.bootstrap(automaticChecks: automaticUpdates)
#endif
        ActivationPolicyController.showsInMenuBarOnly = { Self.showsInMenuBarOnly?() ?? false }
        ActivationPolicyController.refresh()
        activationPolicyObserver = NotificationCenter.default.addObserver(
            forName: .passStoreActivationPolicyChanged,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated { ActivationPolicyController.refresh() }
        }
        // Closing the window is what makes a menu-bar-only app menu-bar-only. Deferred a turn
        // because the window is still counted as visible while the notification is being posted.
        windowCloseObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: nil,
            queue: .main
        ) { _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { ActivationPolicyController.refresh() }
            }
        }

        let configure = Self.deferredGlobalHotkeyConfiguration
        Self.deferredGlobalHotkeyConfiguration = nil
        guard let configure else { return }
        // One extra main-queue turn after launch so AppKit/SwiftUI scene activation is not
        // contending with hot key registration.
        DispatchQueue.main.async(execute: configure)
    }

    /// Clicking the Dock icon with the window closed should bring it back.
    ///
    /// The app keeps running with its window closed because of the menu bar extra, so
    /// without this the Dock icon appeared to do nothing.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        guard !hasVisibleWindows else { return true }
        MainWindowPresenter.present()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        for observer in [activationPolicyObserver, windowCloseObserver].compactMap({ $0 }) {
            NotificationCenter.default.removeObserver(observer)
        }
        activationPolicyObserver = nil
        windowCloseObserver = nil
        // "Last used" timestamps are written on a short delay rather than on every click;
        // quitting straight after opening an item must not drop the pending write.
        Self.terminationHandler?()
        Self.terminationHandler = nil
        GlobalCommandPaletteHotkey.shared.stop()
    }
}
