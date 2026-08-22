import AppKit
import Foundation
import ServiceManagement

/// Starting PassStore when you log in.
///
/// Handed to `SMAppService` rather than installed as a login item of our own: the system owns the
/// list, the owner can see and revoke it in System Settings, and nothing of ours has to survive in
/// a place they cannot inspect. A password manager should not be the app with a launch agent
/// nobody can find.
@MainActor
enum LoginItemService {
    enum Status: Equatable {
        case enabled
        case disabled
        /// Registered, but the owner has not allowed it in System Settings yet.
        case requiresApproval
        case unavailable

        var isOn: Bool { self == .enabled || self == .requiresApproval }
    }

    static var status: Status {
        switch SMAppService.mainApp.status {
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        case .notRegistered: .disabled
        case .notFound: .unavailable
        @unknown default: .unavailable
        }
    }

    /// Turns it on or off. Throws with whatever the system said, which is usually the useful part.
    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }

    /// What to tell the owner when the state is not simply on or off.
    static var explanation: String? {
        switch status {
        case .requiresApproval:
            "macOS is waiting for you to allow this in System Settings → General → Login Items."
        case .unavailable:
            "Opening at login is unavailable for this build. It works once PassStore is in your Applications folder."
        case .enabled, .disabled:
            nil
        }
    }
}

/// Whether PassStore keeps a Dock icon.
///
/// An `.accessory` app has no Dock icon and no ⌘-Tab entry — and, crucially, does not own the menu
/// bar. Staying `.accessory` while the window was open meant focusing it gave a window with no
/// menus at all, so File, Edit and Vault simply were not there.
///
/// So the policy follows the window rather than the preference alone: `.regular` while the vault
/// window is on screen, `.accessory` once it is closed. That is the behaviour the preference was
/// actually asking for — stay out of the Dock when you are not being used — and it keeps every menu
/// command reachable whenever there is a window to use them on.
@MainActor
enum ActivationPolicyController {
    /// The preference, read live. Set once at launch by the app.
    static var showsInMenuBarOnly: () -> Bool = { false }

    /// Re-evaluates the policy from the preference and whether a window is open.
    static func refresh() {
        let wantsAccessory = showsInMenuBarOnly() && !hasVisibleMainWindow
        apply(wantsAccessory ? .accessory : .regular)
    }

    /// Called before the window is shown, so the menu bar is in place by the time it appears.
    static func prepareForWindow() {
        apply(.regular)
    }

    private static var hasVisibleMainWindow: Bool {
        guard let window = MainWindowPresenter.existingMainWindow() else { return false }
        return window.isVisible || window.isMiniaturized
    }

    private static func apply(_ desired: NSApplication.ActivationPolicy) {
        guard NSApp.activationPolicy() != desired else { return }
        NSApp.setActivationPolicy(desired)
        // Coming back from `.accessory` leaves the app without focus, and whatever it was asked to
        // show behind everything else.
        if desired == .regular {
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}
