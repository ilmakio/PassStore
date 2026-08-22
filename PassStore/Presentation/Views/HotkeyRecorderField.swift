import AppKit
import SwiftUI

/// Records the global shortcut by listening for the next chord.
///
/// Reading the chord from a real key press rather than offering a list of keys is the only way to
/// get this right on a keyboard that is not US ANSI: what is printed on the key comes from the
/// active layout, and the layout knows.
struct HotkeyRecorderField: View {
    @Bindable var settings: AppSettingsStore

    @State private var isRecording = false
    @State private var monitor: Any?
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: VaultSpacing.xs) {
            HStack(spacing: VaultSpacing.s) {
                Text(isRecording ? "Press the keys…" : settings.globalHotkeyDisplay)
                    .font(.system(.body, design: .rounded).weight(.medium))
                    .monospacedDigit()
                    .foregroundStyle(isRecording ? Color.secondary : Color.primary)
                    .frame(minWidth: 90, alignment: .leading)
                    .padding(.horizontal, VaultSpacing.s)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: VaultRadius.control, style: .continuous)
                            .fill(Color(nsColor: .controlBackgroundColor))
                            .overlay(
                                RoundedRectangle(cornerRadius: VaultRadius.control, style: .continuous)
                                    .strokeBorder(
                                        isRecording ? Color.vaultAccentStrong : VaultChrome.hairline,
                                        lineWidth: isRecording ? 1.5 : 0.5
                                    )
                            )
                    )
                    .accessibilityLabel("Current shortcut: \(settings.globalHotkeyDisplay)")
                    .accessibilityIdentifier("settings-hotkey-display")

                Button(isRecording ? "Cancel" : "Change…") {
                    isRecording ? stopRecording() : startRecording()
                }
                .buttonStyle(VaultButtonStyle(.secondary))
                .controlSize(.small)
                .accessibilityIdentifier("settings-hotkey-record")

                if !settings.isUsingDefaultHotkey {
                    Button("Reset") {
                        stopRecording()
                        settings.resetHotkeyToDefault()
                        problem = nil
                    }
                    .buttonStyle(.vaultLink)
                    .accessibilityIdentifier("settings-hotkey-reset")
                }

                Spacer(minLength: 0)
            }

            if let problem {
                Text(problem)
                    .font(.vaultFootnote)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onDisappear(perform: stopRecording)
    }

    private func startRecording() {
        problem = nil
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handle(event)
            // Swallowed either way: while recording, a key press is the answer to a question and
            // not text for whatever field had focus.
            return nil
        }
    }

    private func stopRecording() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        isRecording = false
    }

    private func handle(_ event: NSEvent) {
        // Escape gets out without changing anything.
        if event.keyCode == 53, !event.modifierFlags.contains(.command) {
            stopRecording()
            return
        }

        let carbon = Self.carbonModifiers(from: event.modifierFlags)
        guard let display = Self.display(for: event) else {
            problem = "That key cannot be used as a shortcut."
            return
        }
        guard settings.setHotkey(keyCode: Int(event.keyCode), modifiers: carbon, display: display) else {
            problem = "Add Command, Option or Control. A shortcut without one of those would intercept that key in every app."
            return
        }
        stopRecording()
    }

    /// AppKit flags to the Carbon mask `RegisterEventHotKey` wants.
    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> Int {
        var mask = 0
        if flags.contains(.command) { mask |= AppSettingsStore.cmdKeyMask }
        if flags.contains(.option) { mask |= AppSettingsStore.optionKeyMask }
        if flags.contains(.control) { mask |= AppSettingsStore.controlKeyMask }
        if flags.contains(.shift) { mask |= AppSettingsStore.shiftKeyMask }
        return mask
    }

    /// How to write the chord, in the order macOS writes it.
    static func display(for event: NSEvent) -> String? {
        var glyphs = ""
        if event.modifierFlags.contains(.control) { glyphs += "⌃" }
        if event.modifierFlags.contains(.option) { glyphs += "⌥" }
        if event.modifierFlags.contains(.shift) { glyphs += "⇧" }
        if event.modifierFlags.contains(.command) { glyphs += "⌘" }

        if let named = Self.namedKeys[event.keyCode] {
            return glyphs + named
        }
        guard let characters = event.charactersIgnoringModifiers?.uppercased(),
              let character = characters.first,
              character.isLetter || character.isNumber || character.isPunctuation || character.isSymbol else {
            return nil
        }
        return glyphs + String(character)
    }

    /// The keys with no printable character of their own.
    private static let namedKeys: [UInt16: String] = [
        36: "↩", 48: "⇥", 49: "Space", 51: "⌫", 53: "⎋",
        116: "⇞", 121: "⇟", 115: "↖", 119: "↘",
        123: "←", 124: "→", 125: "↓", 126: "↑",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
        98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12"
    ]
}
