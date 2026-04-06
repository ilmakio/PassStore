import AppKit

final class PassStoreAppDelegate: NSObject, NSApplicationDelegate {
    /// Installed from `PassStoreApp.init` so hotkey monitors are not registered before NSApplication is ready (avoids launch freezes).
    static var deferredGlobalHotkeyConfiguration: (() -> Void)?

    func applicationDidFinishLaunching(_ notification: Notification) {
#if !PASSSTORE_APP_STORE
        let automaticUpdates = !ProcessInfo.processInfo.arguments.contains("--uitesting")
        PassStoreSparkleCoordinator.bootstrap(automaticChecks: automaticUpdates)
#endif
        let configure = Self.deferredGlobalHotkeyConfiguration
        Self.deferredGlobalHotkeyConfiguration = nil
        guard let configure else { return }
        // One extra main-queue turn after launch so AppKit/SwiftUI scene activation is not contending with NSEvent monitor install.
        DispatchQueue.main.async(execute: configure)
    }

    func applicationWillTerminate(_ notification: Notification) {
        GlobalCommandPaletteHotkey.shared.stop()
    }
}
