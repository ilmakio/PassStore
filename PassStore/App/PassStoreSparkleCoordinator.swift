#if !PASSSTORE_APP_STORE
import AppKit
import Sparkle

/// Holds Sparkle updater for direct-download builds. Define PASSSTORE_APP_STORE for App Store builds to strip Sparkle.
@MainActor
enum PassStoreSparkleCoordinator {
    private static var updaterController: SPUStandardUpdaterController?

    static var isEnabled: Bool { updaterController != nil }

    static func bootstrap(automaticChecks: Bool) {
        guard updaterController == nil else { return }
        updaterController = SPUStandardUpdaterController(
            startingUpdater: automaticChecks,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    static func checkForUpdates() {
        updaterController?.checkForUpdates(nil)
    }
}
#endif
