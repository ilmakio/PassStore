import Foundation

/// What kind of secret to make.
///
/// A password manager for developers is asked for more than passwords. `openssl rand -hex 32` is
/// the commonest of these by a wide margin, and until now it meant leaving the app.
nonisolated enum SecretRecipe: String, CaseIterable, Identifiable, Sendable {
    /// Random characters from the chosen classes. What the generator has always made.
    case password
    /// Words drawn from a list — for the secrets that have to be typed, read aloud or dictated.
    case passphrase
    /// Hex, the shape of a signing key or a session secret.
    case hex
    /// Standard base64.
    case base64
    /// base64 with `-` and `_`, safe in a URL or a header.
    case base64URL
    /// A version 4 UUID.
    case uuid

    var id: String { rawValue }

    var title: String {
        switch self {
        case .password: "Password"
        case .passphrase: "Passphrase"
        case .hex: "Hex"
        case .base64: "Base64"
        case .base64URL: "Base64 URL"
        case .uuid: "UUID"
        }
    }

    /// Short enough that six of them fit across a segmented control without being clipped.
    var shortTitle: String {
        switch self {
        case .password: "Password"
        case .passphrase: "Phrase"
        case .hex: "Hex"
        case .base64: "Base64"
        case .base64URL: "URL-safe"
        case .uuid: "UUID"
        }
    }

    /// One line saying what it is for, because the difference between these is the use, not the
    /// alphabet.
    var explanation: String {
        switch self {
        case .password: "Random characters. For anything you paste rather than type."
        case .passphrase: "Words you can read aloud and type on a phone keyboard."
        case .hex: "What `openssl rand -hex` gives you: signing keys, session secrets, salts."
        case .base64: "Compact bytes for a config file or an environment variable."
        case .base64URL: "Base64 without `+` or `/`, so it survives a URL or a header."
        case .uuid: "A random identifier, not a secret in itself."
        }
    }

    /// True where the result is bytes rendered as text, so the control asks for a byte count.
    var isByteBased: Bool {
        switch self {
        case .hex, .base64, .base64URL: true
        case .password, .passphrase, .uuid: false
        }
    }
}

nonisolated struct PassphraseOptions: Equatable, Sendable {
    var wordCount: Int = 6
    var separator: PassphraseSeparator = .hyphen
    /// Capitalises each word. Satisfies "must contain an uppercase letter" without weakening it.
    var capitalizesWords = false
    /// Appends a digit, for the same reason.
    var appendsNumber = false

    static let wordCountRange = 3...16
}

nonisolated enum PassphraseSeparator: String, CaseIterable, Identifiable, Sendable {
    case hyphen
    case space
    case period
    case underscore

    var id: String { rawValue }

    var character: String {
        switch self {
        case .hyphen: "-"
        case .space: " "
        case .period: "."
        case .underscore: "_"
        }
    }

    var title: String {
        switch self {
        case .hyphen: "Hyphen  -"
        case .space: "Space"
        case .period: "Period  ."
        case .underscore: "Underscore  _"
        }
    }
}

nonisolated enum PassphraseGenerator {
    /// Draws words independently and uniformly, which is the only draw whose strength can be
    /// stated: `wordCount × log2(listSize)`.
    ///
    /// `randomElement()` is backed by `SystemRandomNumberGenerator`, a CSPRNG on Apple platforms.
    static func generate(_ options: PassphraseOptions = PassphraseOptions()) -> String {
        let list = PassphraseWordList.words
        guard !list.isEmpty else { return "" }
        let count = max(1, options.wordCount)

        var words: [String] = []
        words.reserveCapacity(count)
        for _ in 0..<count {
            guard let word = list.randomElement() else { continue }
            words.append(options.capitalizesWords ? word.capitalized : word)
        }

        var phrase = words.joined(separator: options.separator.character)
        if options.appendsNumber {
            phrase += options.separator.character + String(Int.random(in: 10...99))
        }
        return phrase
    }

    /// Strength of a phrase these options would produce. Stated rather than guessed at: the
    /// generator knows the draw, so it does not have to be inferred from the result.
    static func entropyBits(_ options: PassphraseOptions) -> Double {
        let words = Double(max(1, options.wordCount)) * PassphraseWordList.bitsPerWord
        // Two digits chosen uniformly add a shade over six bits; claiming more would be flattery.
        return words + (options.appendsNumber ? log2(90) : 0)
    }

    static var wordListSize: Int { PassphraseWordList.words.count }
}

nonisolated struct RandomTokenOptions: Equatable, Sendable {
    /// Bytes of randomness, before rendering. 32 is the usual answer for a signing key.
    var byteCount: Int = 32

    static let byteCountRange = 8...128
}

nonisolated enum RandomTokenGenerator {
    /// `byteCount` bytes from the system CSPRNG.
    static func bytes(_ count: Int) -> [UInt8] {
        var generator = SystemRandomNumberGenerator()
        return (0..<max(1, count)).map { _ in UInt8.random(in: UInt8.min...UInt8.max, using: &generator) }
    }

    static func hex(byteCount: Int) -> String {
        bytes(byteCount).map { String(format: "%02x", $0) }.joined()
    }

    static func base64(byteCount: Int, urlSafe: Bool) -> String {
        let encoded = Data(bytes(byteCount)).base64EncodedString()
        guard urlSafe else { return encoded }
        // The URL alphabet, unpadded — which is what a token in a header or a query wants.
        return encoded
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func uuid() -> String {
        UUID().uuidString
    }

    /// Bits of randomness behind the result. Rendering does not add any: hex is twice as long as
    /// the bytes it shows and no stronger for it.
    static func entropyBits(byteCount: Int) -> Double {
        Double(max(1, byteCount)) * 8
    }

    /// A version 4 UUID spends 122 of its 128 bits on randomness; the rest states the version.
    static let uuidEntropyBits: Double = 122
}
