import AppKit
import Foundation

extension Notification.Name {
    /// Posted when `AppSettingsStore.globalCommandPaletteHotkeyEnabled` changes.
    static let passStoreGlobalHotkeySettingsChanged = Notification.Name("passStoreGlobalHotkeySettingsChanged")
}

/// Registers ⌘⌥P to activate PassStore and open the command palette (requires Accessibility for the global monitor).
@MainActor
final class GlobalCommandPaletteHotkey {
    static let shared = GlobalCommandPaletteHotkey()

    private(set) var isAccessibilityRequiredButMissing = false

    private weak var viewModel: VaultViewModel?
    private weak var settings: AppSettingsStore?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var openMainWindow: (() -> Void)?
    private var lastTrigger = Date.distantPast
    private var settingsObserver: NSObjectProtocol?

    private let throttleInterval: TimeInterval = 0.35

    private init() {}

    func configure(viewModel: VaultViewModel, settings: AppSettingsStore) {
        self.viewModel = viewModel
        self.settings = settings

        settingsObserver = NotificationCenter.default.addObserver(
            forName: .passStoreGlobalHotkeySettingsChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.reinstallMonitors()
            }
        }

        reinstallMonitors()
    }

    /// Call from any scene that has `openWindow` in environment (main window and menu bar).
    func setOpenMainWindowAction(_ action: @escaping () -> Void) {
        openMainWindow = action
    }

    func stop() {
        removeMonitors()
        if let settingsObserver {
            NotificationCenter.default.removeObserver(settingsObserver)
            self.settingsObserver = nil
        }
        viewModel = nil
        settings = nil
        openMainWindow = nil
    }

    func reinstallMonitors() {
        removeMonitors()
        guard settings?.globalCommandPaletteHotkeyEnabled != false else {
            isAccessibilityRequiredButMissing = false
            return
        }
        guard !ProcessInfo.processInfo.arguments.contains("--uitesting") else { return }

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return }
            Task { @MainActor in
                self.handleKeyEventIfShortcut(event)
            }
        }

        // Never call activation or openWindow synchronously from inside this callback — it can deadlock
        // AppKit event processing and trigger "AppleEvent activation suspension timed out".
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            guard self.matchesShortcut(event) else { return event }
            Task { @MainActor [weak self] in
                self?.handleHotkeyFromMainActor()
            }
            return nil
        }

        isAccessibilityRequiredButMissing = globalMonitor == nil
    }

    private func removeMonitors() {
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
        }
        globalMonitor = nil
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
        }
        localMonitor = nil
    }

    private func handleKeyEventIfShortcut(_ event: NSEvent) {
        guard matchesShortcut(event) else { return }
        handleHotkeyFromMainActor()
    }

    private func matchesShortcut(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command), flags.contains(.option) else { return false }
        guard !flags.contains(.control), !flags.contains(.shift) else { return false }
        guard let chars = event.charactersIgnoringModifiers?.lowercased(), chars == "p" else { return false }
        return true
    }

    private func handleHotkeyFromMainActor() {
        // Defer past the current run-loop turn so activation is not nested under NSEvent processing.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let now = Date()
            guard now.timeIntervalSince(self.lastTrigger) >= self.throttleInterval else { return }
            self.lastTrigger = now

            NSApp.activate(ignoringOtherApps: true)
            self.openMainWindow?()
            self.bringExistingMainWindowForward()

            // Second tick: let SwiftUI/AppKit finish ordering windows before presenting the palette.
            DispatchQueue.main.async { [weak self] in
                self?.viewModel?.presentCommandPalette()
            }
        }
    }

    private func bringExistingMainWindowForward() {
        let candidates = NSApp.windows.filter { !$0.isSheet && $0.level == .normal && $0.canBecomeKey }
        if let main = candidates.first(where: \.isMainWindow) {
            main.makeKeyAndOrderFront(nil)
            return
        }
        candidates.max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height })?.makeKeyAndOrderFront(nil)
    }
}
