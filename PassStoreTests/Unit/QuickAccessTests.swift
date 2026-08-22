import AppKit
import Testing
@testable import PassStore

/// The global shortcut was ⌘⌥P and nothing else, which meant an app that already owned that chord
/// left PassStore with no shortcut and no way to move it. Recording one is easy to get wrong in a
/// way that matters: a shortcut with no real modifier is registered system-wide and intercepts that
/// key in every application.
@MainActor
struct HotkeySettingsTests {

    private func makeSettings(_ label: String = #function) -> AppSettingsStore {
        AppSettingsStore(defaults: UserDefaults(suiteName: "HotkeyTests-\(label)-\(UUID().uuidString)")!)
    }

    @Test func theDefaultIsTheChordTheAppHasAlwaysUsed() {
        let settings = makeSettings()
        #expect(settings.globalHotkeyKeyCode == AppSettingsStore.defaultHotkeyKeyCode)
        #expect(settings.globalHotkeyModifiers == AppSettingsStore.defaultHotkeyModifiers)
        #expect(settings.globalHotkeyDisplay == "⌘⌥P")
        #expect(settings.isUsingDefaultHotkey)
    }

    @Test func recordingAChordWithACommandKeyIsAccepted() {
        let settings = makeSettings()
        let accepted = settings.setHotkey(
            keyCode: 11,
            modifiers: AppSettingsStore.cmdKeyMask | AppSettingsStore.shiftKeyMask,
            display: "⇧⌘B"
        )
        #expect(accepted)
        #expect(settings.globalHotkeyKeyCode == 11)
        #expect(settings.globalHotkeyDisplay == "⇧⌘B")
        #expect(!settings.isUsingDefaultHotkey)
    }

    /// The case that matters. A bare key, or one with only Shift, would be swallowed in every app —
    /// which from the outside is indistinguishable from a password manager logging keystrokes.
    @Test func aChordWithoutARealModifierIsRefused() {
        let settings = makeSettings()
        #expect(!settings.setHotkey(keyCode: 11, modifiers: 0, display: "B"))
        #expect(!settings.setHotkey(keyCode: 11, modifiers: AppSettingsStore.shiftKeyMask, display: "⇧B"))
        // Left exactly as it was.
        #expect(settings.isUsingDefaultHotkey)
    }

    @Test func anEmptyDisplayIsRefusedSoTheSettingCannotShowNothing() {
        let settings = makeSettings()
        #expect(!settings.setHotkey(keyCode: 11, modifiers: AppSettingsStore.cmdKeyMask, display: ""))
        #expect(settings.isUsingDefaultHotkey)
    }

    @Test func storedModifiersAreSanitisedOnTheWayBackIn() {
        let suite = "HotkeyTests-persisted-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        // Something wrote a modifier mask with nothing usable in it.
        defaults.set(11, forKey: "settings.globalHotkeyKeyCode")
        defaults.set(AppSettingsStore.shiftKeyMask, forKey: "settings.globalHotkeyModifiers")

        let settings = AppSettingsStore(defaults: defaults)
        #expect(settings.globalHotkeyModifiers == AppSettingsStore.defaultHotkeyModifiers)
    }

    @Test func resettingGoesBackToTheDefault() {
        let settings = makeSettings()
        settings.setHotkey(keyCode: 11, modifiers: AppSettingsStore.controlKeyMask, display: "⌃B")
        #expect(!settings.isUsingDefaultHotkey)

        settings.resetHotkeyToDefault()
        #expect(settings.isUsingDefaultHotkey)
        #expect(settings.globalHotkeyDisplay == "⌘⌥P")
    }

    @Test func aRecordedChordSurvivesANewSettingsStore() {
        let suite = "HotkeyTests-roundtrip-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let first = AppSettingsStore(defaults: defaults)
        first.setHotkey(keyCode: 49, modifiers: AppSettingsStore.cmdKeyMask | AppSettingsStore.optionKeyMask, display: "⌥⌘Space")

        let second = AppSettingsStore(defaults: defaults)
        #expect(second.globalHotkeyKeyCode == 49)
        #expect(second.globalHotkeyDisplay == "⌥⌘Space")
    }

    @Test func resettingEverythingRestoresTheDefaultChordAndTheDockIcon() {
        let settings = makeSettings()
        settings.setHotkey(keyCode: 11, modifiers: AppSettingsStore.cmdKeyMask, display: "⌘B")
        settings.showsInMenuBarOnly = true
        settings.launchesAtLogin = true

        settings.resetToDefaults()

        #expect(settings.isUsingDefaultHotkey)
        #expect(!settings.showsInMenuBarOnly)
        #expect(!settings.launchesAtLogin)
    }
}

/// Turning AppKit's flags into the mask `RegisterEventHotKey` wants, and writing the chord the way
/// macOS writes it.
struct HotkeyDisplayTests {

    @Test func modifiersMapToTheCarbonMask() {
        #expect(HotkeyRecorderField.carbonModifiers(from: [.command]) == AppSettingsStore.cmdKeyMask)
        #expect(HotkeyRecorderField.carbonModifiers(from: [.option]) == AppSettingsStore.optionKeyMask)
        #expect(HotkeyRecorderField.carbonModifiers(from: [.control]) == AppSettingsStore.controlKeyMask)
        #expect(HotkeyRecorderField.carbonModifiers(from: [.shift]) == AppSettingsStore.shiftKeyMask)
        #expect(
            HotkeyRecorderField.carbonModifiers(from: [.command, .option])
                == AppSettingsStore.cmdKeyMask | AppSettingsStore.optionKeyMask
        )
        // Anything else — Caps Lock, Function — is not part of a chord.
        #expect(HotkeyRecorderField.carbonModifiers(from: [.capsLock, .function]) == 0)
    }

    @Test func sanitisingKeepsOnlyTheModifiersAChordCanUse() {
        let mixed = AppSettingsStore.cmdKeyMask | 0x4000
        #expect(AppSettingsStore.sanitizedHotkeyModifiers(mixed) == AppSettingsStore.cmdKeyMask)
        #expect(AppSettingsStore.sanitizedHotkeyModifiers(0) == AppSettingsStore.defaultHotkeyModifiers)
    }
}
