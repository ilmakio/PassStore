import AppKit
import Carbon.HIToolbox
import Foundation

extension Notification.Name {
    /// Posted when `AppSettingsStore.globalCommandPaletteHotkeyEnabled` changes.
    static let passStoreGlobalHotkeySettingsChanged = Notification.Name("passStoreGlobalHotkeySettingsChanged")
}

/// Registers ⌘⌥P to activate PassStore and open the command palette.
///
/// This used to install an `NSEvent` global monitor, which meant PassStore asked for
/// Accessibility and then received every keystroke typed in every application. For a password
/// manager that is both a bad look and a genuinely large attack surface: a bug in this class
/// would have been a keylogger. `RegisterEventHotKey` asks the window server to deliver one
/// specific chord and nothing else — no permission prompt, no other app's keystrokes.
@MainActor
final class GlobalCommandPaletteHotkey {
    static let shared = GlobalCommandPaletteHotkey()

    /// Kept for the settings pane, which used to offer an "open Accessibility settings"
    /// button. Nothing needs Accessibility any more, so this is always false.
    var isAccessibilityRequiredButMissing: Bool { false }

    /// True when the chord could not be registered — almost always because another app
    /// already owns ⌘⌥P.
    private(set) var isShortcutUnavailable = false

    private weak var viewModel: VaultViewModel?
    private weak var settings: AppSettingsStore?
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private var openMainWindow: (() -> Void)?
    private var lastTrigger = Date.distantPast
    private var settingsObserver: NSObjectProtocol?

    private let throttleInterval: TimeInterval = 0.35
    private static let hotKeySignature = OSType(0x50535448) // 'PSTH'
    private static let hotKeyID: UInt32 = 1

    private init() {}

    func configure(viewModel: VaultViewModel, settings: AppSettingsStore) {
        self.viewModel = viewModel
        self.settings = settings

        settingsObserver = NotificationCenter.default.addObserver(
            forName: .passStoreGlobalHotkeySettingsChanged,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor [weak self] in
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
        unregister()
        if let settingsObserver {
            NotificationCenter.default.removeObserver(settingsObserver)
            self.settingsObserver = nil
        }
        viewModel = nil
        settings = nil
        openMainWindow = nil
    }

    func reinstallMonitors() {
        unregister()
        guard settings?.globalCommandPaletteHotkeyEnabled != false else {
            isShortcutUnavailable = false
            return
        }
        guard !ProcessInfo.processInfo.arguments.contains("--uitesting") else { return }
        register()
    }

    // MARK: - Carbon hot key

    private func register() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let handlerStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, _ -> OSStatus in
                var hotKeyID = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                guard status == noErr, hotKeyID.id == GlobalCommandPaletteHotkey.hotKeyID else {
                    return OSStatus(eventNotHandledErr)
                }
                // The Carbon handler runs on the main thread, but hop explicitly so the
                // isolation is checked rather than assumed.
                Task { @MainActor in
                    GlobalCommandPaletteHotkey.shared.handleHotkey()
                }
                return noErr
            },
            1,
            &eventType,
            nil,
            &eventHandler
        )

        guard handlerStatus == noErr else {
            isShortcutUnavailable = true
            return
        }

        let hotKeyID = EventHotKeyID(signature: Self.hotKeySignature, id: Self.hotKeyID)
        let status = RegisterEventHotKey(
            UInt32(kVK_ANSI_P),
            UInt32(cmdKey | optionKey),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        isShortcutUnavailable = status != noErr
    }

    private func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
        }
        hotKeyRef = nil
        if let eventHandler {
            RemoveEventHandler(eventHandler)
        }
        eventHandler = nil
    }

    private func handleHotkey() {
        // Defer past the current run-loop turn so activation is not nested under event
        // processing — doing it inline can deadlock AppKit ("AppleEvent activation
        // suspension timed out").
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let now = Date()
            guard now.timeIntervalSince(self.lastTrigger) >= self.throttleInterval else { return }
            self.lastTrigger = now

            NSApp.activate(ignoringOtherApps: true)
            self.openMainWindow?()
            self.bringExistingMainWindowForward()

            // Second tick: let SwiftUI/AppKit finish ordering windows before presenting.
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
