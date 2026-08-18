import AppKit
import Foundation
import SwiftUI

struct PasswordGeneratorOptions: Equatable {
    var length: Int = 24
    var includeLowercase = true
    var includeUppercase = true
    var includeDigits = true
    var includeSymbols = true
    /// Drops characters that are easy to misread when a secret has to be typed or dictated.
    var excludeAmbiguous = false

    /// At least one class has to stay on, otherwise there is nothing to draw from.
    var hasUsableCharacterSet: Bool {
        includeLowercase || includeUppercase || includeDigits || includeSymbols
    }
}

enum PasswordGenerator {
    static let minimumLength = 8
    static let maximumLength = 128

    private static let lowercase = Array("abcdefghijklmnopqrstuvwxyz")
    private static let uppercase = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")
    private static let digits = Array("0123456789")
    private static let symbols = Array("!@#$%^&*()-_=+[]{};:,.?/")
    private static let ambiguous: Set<Character> = ["0", "O", "o", "1", "l", "I", "|", "`", "'", "\"", "5", "S", "2", "Z", "8", "B"]

    /// Kept for callers that only care about length; uses the default character classes.
    static func generate(length: Int = 24) -> String {
        generate(options: PasswordGeneratorOptions(length: length))
    }

    /// Draws from every enabled class at least once, then fills the remainder and shuffles, so a
    /// generated secret always satisfies "must contain a digit/symbol" style policies.
    /// `randomElement()` is backed by `SystemRandomNumberGenerator`, which is a CSPRNG on Apple platforms.
    static func generate(options: PasswordGeneratorOptions) -> String {
        let pools = enabledPools(for: options)
        guard let combined = pools.flatMap({ $0 }).nilIfEmpty else { return "" }

        let length = max(options.length, 1)
        var characters: [Character] = []
        characters.reserveCapacity(length)

        for pool in pools.prefix(length) {
            if let pick = pool.randomElement() { characters.append(pick) }
        }
        while characters.count < length {
            if let pick = combined.randomElement() { characters.append(pick) }
        }
        characters.shuffle()
        return String(characters.prefix(length))
    }

    private static func enabledPools(for options: PasswordGeneratorOptions) -> [[Character]] {
        var pools: [[Character]] = []
        if options.includeLowercase { pools.append(lowercase) }
        if options.includeUppercase { pools.append(uppercase) }
        if options.includeDigits { pools.append(digits) }
        if options.includeSymbols { pools.append(symbols) }
        if pools.isEmpty { pools = [lowercase] }
        guard options.excludeAmbiguous else { return pools }
        // Filtering can empty a pool (digits are mostly ambiguous), so drop the empties.
        return pools.map { $0.filter { !ambiguous.contains($0) } }.filter { !$0.isEmpty }
    }
}

private extension Array where Element == Character {
    var nilIfEmpty: [Character]? { isEmpty ? nil : self }
}

// MARK: - Field URLs

enum FieldURLSupport {
    /// Builds an openable URL from a stored field value.
    ///
    /// Only `http`/`https` are accepted on purpose: vault contents can come from an imported
    /// backup, and handing an arbitrary scheme (`file:`, `x-apple-…`, a custom app scheme) to
    /// `NSWorkspace` would let a crafted file trigger actions just because the user clicked a link.
    static func url(from rawValue: String) -> URL? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(where: \.isNewline) else { return nil }

        let candidate: String
        if trimmed.contains("://") {
            candidate = trimmed
        } else {
            // Bare "example.com/path" is the common case in a URL field.
            guard !trimmed.hasPrefix("//"), trimmed.contains(".") else { return nil }
            candidate = "https://\(trimmed)"
        }

        guard let url = URL(string: candidate),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host?.isEmpty == false else {
            return nil
        }
        return url
    }
}

// MARK: - Password strength

nonisolated enum PasswordStrength: Equatable, CaseIterable, Sendable {
    case empty
    case tooShort
    case weak
    case fair
    case strong
    case veryStrong

    var label: String {
        switch self {
        case .empty: "At least 8 characters"
        case .tooShort: "Too short"
        case .weak: "Weak"
        case .fair: "Fair"
        case .strong: "Strong"
        case .veryStrong: "Very strong"
        }
    }

    /// Fair is the brand yellow rather than the system one: this bar sits a few points from a
    /// yellow button on half the sheets it appears in, and two yellows that close together
    /// read as a mistake.
    var color: Color {
        switch self {
        case .empty: .clear
        case .tooShort: .red
        case .weak: .orange
        case .fair: .vaultAccent
        case .strong: .green
        case .veryStrong: .green
        }
    }

    var fill: CGFloat {
        switch self {
        case .empty: 0
        case .tooShort: 0.1
        case .weak: 0.25
        case .fair: 0.5
        case .strong: 0.75
        case .veryStrong: 1.0
        }
    }

    /// True for secrets weak enough to surface in the vault health audit.
    var needsAttention: Bool {
        switch self {
        case .empty, .tooShort, .weak: true
        case .fair, .strong, .veryStrong: false
        }
    }

    static func evaluate(_ password: String) -> PasswordStrength {
        guard !password.isEmpty else { return .empty }
        guard password.count >= 8 else { return .tooShort }

        // Length and character classes alone were far too generous: "password1234" is twelve
        // characters with two classes, which used to score Fair — good enough that the vault
        // health audit stayed quiet about it. Obvious structure is now checked first.
        if isObviouslyGuessable(password) { return .weak }

        let hasUpper = password.contains(where: \.isUppercase)
        let hasLower = password.contains(where: \.isLowercase)
        let hasDigit = password.contains(where: \.isNumber)
        let hasSymbol = password.contains(where: { !$0.isLetter && !$0.isNumber })
        let classes = [hasUpper, hasLower, hasDigit, hasSymbol].filter(\.self).count

        if password.count >= 20, classes >= 4 { return .veryStrong }
        if password.count >= 16, classes >= 3 { return .strong }
        if password.count >= 12, classes >= 2 { return .fair }
        if classes >= 3 { return .fair }
        return .weak
    }

    /// Cheap local checks for the shapes that make a long password worthless.
    ///
    /// Deliberately offline and deliberately small — no wordlist ships with the app and
    /// nothing is sent anywhere. It catches the common cases, not every bad password.
    static func isObviouslyGuessable(_ password: String) -> Bool {
        let lower = password.lowercased()

        // A common base word with digits or punctuation bolted on is still that word.
        let stripped = lower.drop(while: { !$0.isLetter })
            .prefix(while: { $0.isLetter })
        if commonBaseWords.contains(String(stripped)) { return true }
        if commonBaseWords.contains(where: { lower.hasPrefix($0) && lower.count - $0.count <= 4 }) { return true }

        // A handful of distinct characters, however long the string.
        if Set(lower).count <= max(3, password.count / 6) { return true }

        // Straight runs like 123456, abcdef, qwerty.
        if hasLongRun(lower) { return true }
        if keyboardRuns.contains(where: { lower.contains($0) }) { return true }

        // One short block repeated: "abcabcabcabc".
        for blockLength in 1...4 where password.count >= blockLength * 3 && password.count % blockLength == 0 {
            let block = String(lower.prefix(blockLength))
            if String(repeating: block, count: password.count / blockLength) == lower { return true }
        }

        return false
    }

    private static let commonBaseWords: Set<String> = [
        "password", "passwd", "letmein", "welcome", "admin", "administrator", "root",
        "secret", "changeme", "qwerty", "azerty", "iloveyou", "dragon", "monkey",
        "sunshine", "princess", "football", "baseball", "master", "login", "test",
        "guest", "default", "temp", "hello", "abc"
    ]

    private static let keyboardRuns = ["qwerty", "asdf", "zxcv", "1234", "0987", "abcdef"]

    /// True when six or more consecutive characters step by a constant ±1.
    private static func hasLongRun(_ value: String) -> Bool {
        let scalars = Array(value.unicodeScalars.map(\.value))
        guard scalars.count >= 6 else { return false }
        var run = 1
        var direction = 0
        for index in 1..<scalars.count {
            let delta = Int(scalars[index]) - Int(scalars[index - 1])
            if delta == direction, delta == 1 || delta == -1 {
                run += 1
                if run >= 6 { return true }
            } else if delta == 1 || delta == -1 {
                direction = delta
                run = 2
            } else {
                direction = 0
                run = 1
            }
        }
        return false
    }
}

struct PasswordStrengthBar: View {
    let password: String

    @Environment(\.isOnVaultHero) private var isOnHero

    private var strength: PasswordStrength {
        PasswordStrength.evaluate(password)
    }

    var body: some View {
        VStack(spacing: 4) {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(isOnHero ? VaultHeroPalette.surfaceActive : VaultChrome.mutedFill)
                        .frame(height: 4)

                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(strength.color)
                        .frame(width: geometry.size.width * strength.fill, height: 4)
                        .animation(.spring(response: 0.32, dampingFraction: 0.82), value: strength)
                }
            }
            .frame(height: 4)

            HStack {
                Text(strength.label)
                    .font(.caption)
                    .foregroundStyle(password.isEmpty ? .tertiary : .secondary)
                Spacer()
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Password strength: \(strength.label)")
    }
}

extension FieldDraft {
    /// Applies a new value kind, along with the handling that kind implies.
    ///
    /// Calling a value "Secret" and leaving it neither sensitive nor masked contradicts itself, so
    /// switching to Secret turns both on — the editor should not need a second trip through the
    /// menu to make a secret behave like one.
    ///
    /// Deliberately one-way. Switching back to Text leaves the flags alone rather than quietly
    /// un-protecting a value that may already be stored and shoulder-surfable; they are two
    /// checkboxes away in the same menu for anyone who really meant it.
    mutating func applyKind(_ newKind: FieldKind) {
        guard kind != newKind else { return }
        kind = newKind
        guard newKind == .secret else { return }
        isSensitive = true
        isMasked = true
    }

    var supportsGeneratedPassword: Bool {
        guard kind == .secret else { return false }
        return SecretFieldClassification.isPasswordLike(key: key, label: label)
    }
}

struct WorkspaceIconPreset: Identifiable, Hashable {
    let id: String
    let systemImage: String
    let label: String

    init(systemImage: String, label: String) {
        self.id = systemImage
        self.systemImage = systemImage
        self.label = label
    }
}

struct WorkspaceColorPreset: Identifiable, Hashable {
    let id: String
    let name: String
    let hex: String

    init(name: String, hex: String) {
        self.id = hex
        self.name = name
        self.hex = hex
    }

    var color: Color {
        Color(hex: hex)
    }
}

enum WorkspaceStylePresets {
    static let icons: [WorkspaceIconPreset] = [
        .init(systemImage: "shippingbox", label: "General"),
        .init(systemImage: "server.rack", label: "Backend"),
        .init(systemImage: "terminal", label: "Infra"),
        .init(systemImage: "globe", label: "Web"),
        .init(systemImage: "iphone", label: "Mobile"),
        .init(systemImage: "key", label: "Security"),
        .init(systemImage: "shippingbox.circle", label: "Platform"),
        .init(systemImage: "bolt.shield", label: "Ops"),
        .init(systemImage: "cloud", label: "Cloud"),
        .init(systemImage: "hammer", label: "Tools")
    ]

    static let colors: [WorkspaceColorPreset] = [
        .init(name: "Cobalt", hex: "#4A7AFF"),
        .init(name: "Ocean", hex: "#2AA198"),
        .init(name: "Mint", hex: "#1FBF8F"),
        .init(name: "Amber", hex: "#E8A317"),
        .init(name: "Coral", hex: "#FF6B57"),
        .init(name: "Ruby", hex: "#D9485F"),
        .init(name: "Plum", hex: "#7C5CFC"),
        .init(name: "Slate", hex: "#5F6B7A")
    ]

    static func color(for hex: String) -> WorkspaceColorPreset? {
        colors.first(where: { $0.hex.caseInsensitiveCompare(hex) == .orderedSame })
    }
}

extension Color {
    init(hex: String) {
        let sanitized = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var value: UInt64 = 0
        Scanner(string: sanitized).scanHexInt64(&value)

        let red, green, blue: UInt64
        switch sanitized.count {
        case 6:
            red = (value >> 16) & 0xFF
            green = (value >> 8) & 0xFF
            blue = value & 0xFF
        default:
            red = 74
            green = 122
            blue = 255
        }

        self.init(
            .sRGB,
            red: Double(red) / 255,
            green: Double(green) / 255,
            blue: Double(blue) / 255,
            opacity: 1
        )
    }

    /// Black or white, whichever a glyph should be when it sits directly on this colour.
    ///
    /// Workspace colours are chosen freely, so a fixed white icon disappears on the pale ones
    /// and a fixed black one disappears on the deep ones. Threshold is WCAG relative luminance,
    /// biased a little towards white: the saturated mid-tones these are usually set to read
    /// better light-on-colour than the raw crossover point suggests, and a bold glyph only
    /// needs 3:1.
    var vaultContrastingGlyph: Color {
        guard let resolved = NSColor(self).usingColorSpace(.sRGB) else { return .white }

        func linear(_ channel: CGFloat) -> Double {
            let value = Double(channel)
            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }

        let luminance = 0.2126 * linear(resolved.redComponent)
            + 0.7152 * linear(resolved.greenComponent)
            + 0.0722 * linear(resolved.blueComponent)

        return luminance > 0.45 ? .black : .white
    }
}
