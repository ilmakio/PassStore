import AppKit

final class PassStoreAppDelegate: NSObject, NSApplicationDelegate {
    /// Installed from `PassStoreApp.init` so hotkey registration does not happen before
    /// NSApplication is ready (avoids launch freezes).
    static var deferredGlobalHotkeyConfiguration: (() -> Void)?
    /// Writes any coalesced vault changes before the process goes away.
    static var terminationHandler: (() -> Void)?

    func applicationDidFinishLaunching(_ notification: Notification) {
#if !PASSSTORE_APP_STORE
        let automaticUpdates = !ProcessInfo.processInfo.arguments.contains("--uitesting")
        PassStoreSparkleCoordinator.bootstrap(automaticChecks: automaticUpdates)
#endif
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
        // "Last used" timestamps are written on a short delay rather than on every click;
        // quitting straight after opening an item must not drop the pending write.
        Self.terminationHandler?()
        Self.terminationHandler = nil
        GlobalCommandPaletteHotkey.shared.stop()
    }
}
