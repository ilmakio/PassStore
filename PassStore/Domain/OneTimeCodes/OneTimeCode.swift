import CryptoKit
import Foundation

/// Everything needed to produce a time-based one-time code, parsed out of what the owner stored.
///
/// A TOTP field holds either a bare base32 seed or the whole `otpauth://` URI an issuer's QR
/// code encodes. Both are kept verbatim in the field's value, so adding one-time codes needed no
/// change to the vault format and a vault written here still opens in an older build — the field
/// simply reads back as text.
nonisolated struct OneTimeCodeConfiguration: Equatable, Sendable {
    enum Algorithm: String, CaseIterable, Sendable {
        case sha1
        case sha256
        case sha512

        /// Accepts what issuers actually write: `SHA1`, `sha-256`, `SHA512`.
        init?(issuerSpelling raw: String) {
            let normalized = raw.lowercased()
                .replacingOccurrences(of: "-", with: "")
                .replacingOccurrences(of: " ", with: "")
            switch normalized {
            case "sha1": self = .sha1
            case "sha256": self = .sha256
            case "sha512": self = .sha512
            default: return nil
            }
        }

        var title: String {
            switch self {
            case .sha1: "SHA-1"
            case .sha256: "SHA-256"
            case .sha512: "SHA-512"
            }
        }
    }

    /// The shared secret, decoded. Never rendered.
    let secret: Data
    let digits: Int
    /// Seconds each code is valid for.
    let period: Int
    let algorithm: Algorithm
    /// Who issued it, when the URI said so. Display only.
    let issuer: String?
    /// The account the code belongs to, when the URI said so. Display only.
    let account: String?

    static let defaultDigits = 6
    static let defaultPeriod = 30
    /// RFC 6238 specifies 6 to 8; a few issuers step outside that, so the bound is generous
    /// rather than strict — a code that does not match is the owner's problem to see, not a
    /// reason to refuse to store what their provider gave them.
    static let digitsRange = 4...10
    static let periodRange = 1...300

    init(
        secret: Data,
        digits: Int = Self.defaultDigits,
        period: Int = Self.defaultPeriod,
        algorithm: Algorithm = .sha1,
        issuer: String? = nil,
        account: String? = nil
    ) {
        self.secret = secret
        self.digits = digits
        self.period = period
        self.algorithm = algorithm
        self.issuer = issuer
        self.account = account
    }

    /// What to show above the code when the URI named an account.
    var subtitle: String? {
        switch (issuer?.nilIfBlank, account?.nilIfBlank) {
        case let (issuer?, account?):
            // `otpauth://totp/GitHub:you@example.com?issuer=GitHub` is the common shape, and
            // repeating the issuer in the label is not worth a line of the detail pane.
            account.hasPrefix("\(issuer):") ? account : "\(issuer) · \(account)"
        case let (issuer?, nil): issuer
        case let (nil, account?): account
        case (nil, nil): nil
        }
    }

    /// True when the parameters are anything other than the near-universal defaults, which is
    /// the only time they are worth spending screen space on.
    var hasNonDefaultParameters: Bool {
        digits != Self.defaultDigits || period != Self.defaultPeriod || algorithm != .sha1
    }

    var parameterSummary: String {
        "\(digits) digits · \(period)s · \(algorithm.title)"
    }
}

nonisolated enum OneTimeCodeError: LocalizedError, Equatable, Sendable {
    case empty
    case unsupportedScheme(String)
    case counterBasedNotSupported
    case missingSecret
    case invalidBase32
    case invalidDigits
    case invalidPeriod
    case unsupportedAlgorithm(String)

    var errorDescription: String? {
        switch self {
        case .empty:
            "Paste the setup key or the otpauth:// link from the service."
        case let .unsupportedScheme(scheme):
            "\(scheme):// links are not one-time code links. Expected otpauth://."
        case .counterBasedNotSupported:
            "This is a counter-based (HOTP) link. PassStore supports time-based codes."
        case .missingSecret:
            "That link carries no secret."
        case .invalidBase32:
            "That setup key is not valid base32. It should only contain A–Z and 2–7."
        case .invalidDigits:
            "The number of digits has to be between \(OneTimeCodeConfiguration.digitsRange.lowerBound) and \(OneTimeCodeConfiguration.digitsRange.upperBound)."
        case .invalidPeriod:
            "The period has to be between \(OneTimeCodeConfiguration.periodRange.lowerBound) and \(OneTimeCodeConfiguration.periodRange.upperBound) seconds."
        case let .unsupportedAlgorithm(name):
            "\(name) is not a supported algorithm. Expected SHA1, SHA256 or SHA512."
        }
    }
}

// MARK: - Parsing

nonisolated enum OneTimeCodeParser {
    /// Reads a stored TOTP field value.
    ///
    /// Two shapes arrive in practice: the whole `otpauth://` URI behind a QR code, and the
    /// "setup key" a site shows next to it. Both are accepted, and a setup key is allowed to
    /// carry the spaces and hyphens sites insert to make it readable.
    static func parse(_ rawValue: String) throws -> OneTimeCodeConfiguration {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw OneTimeCodeError.empty }

        if let scheme = Self.scheme(of: trimmed) {
            guard scheme == "otpauth" else { throw OneTimeCodeError.unsupportedScheme(scheme) }
            return try parseURI(trimmed)
        }
        return OneTimeCodeConfiguration(secret: try decodeBase32(trimmed))
    }

    /// True when the value is at least meant to be a one-time code, so the editor can tell
    /// "not filled in yet" from "filled in wrongly".
    static func isPlausible(_ rawValue: String) -> Bool {
        (try? parse(rawValue)) != nil
    }

    /// Only a scheme this deliberately narrow counts. `URL(string:)` treats a bare setup key
    /// with a colon in it as having a scheme, which would send a typo down the URI path and
    /// produce a baffling error instead of "that is not valid base32".
    private static func scheme(of value: String) -> String? {
        guard let separator = value.range(of: "://") else { return nil }
        let candidate = String(value[value.startIndex..<separator.lowerBound]).lowercased()
        guard !candidate.isEmpty,
              candidate.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "+" || $0 == "-" || $0 == "." }) else {
            return nil
        }
        return candidate
    }

    private static func parseURI(_ uri: String) throws -> OneTimeCodeConfiguration {
        guard let components = URLComponents(string: uri) else { throw OneTimeCodeError.missingSecret }
        let kind = (components.host ?? "").lowercased()
        if kind == "hotp" { throw OneTimeCodeError.counterBasedNotSupported }
        guard kind.isEmpty || kind == "totp" else { throw OneTimeCodeError.unsupportedScheme("otpauth://\(kind)") }

        let query = Dictionary(
            (components.queryItems ?? []).compactMap { item -> (String, String)? in
                guard let value = item.value else { return nil }
                return (item.name.lowercased(), value)
            },
            uniquingKeysWith: { first, _ in first }
        )

        guard let rawSecret = query["secret"]?.nilIfBlank else { throw OneTimeCodeError.missingSecret }
        let secret = try decodeBase32(rawSecret)

        let digits = try query["digits"].map { raw -> Int in
            guard let value = Int(raw.trimmingCharacters(in: .whitespaces)),
                  OneTimeCodeConfiguration.digitsRange.contains(value) else {
                throw OneTimeCodeError.invalidDigits
            }
            return value
        } ?? OneTimeCodeConfiguration.defaultDigits

        let period = try query["period"].map { raw -> Int in
            guard let value = Int(raw.trimmingCharacters(in: .whitespaces)),
                  OneTimeCodeConfiguration.periodRange.contains(value) else {
                throw OneTimeCodeError.invalidPeriod
            }
            return value
        } ?? OneTimeCodeConfiguration.defaultPeriod

        let algorithm = try query["algorithm"].map { raw -> OneTimeCodeConfiguration.Algorithm in
            guard let parsed = OneTimeCodeConfiguration.Algorithm(issuerSpelling: raw) else {
                throw OneTimeCodeError.unsupportedAlgorithm(raw)
            }
            return parsed
        } ?? .sha1

        // The path label is `Issuer:account`, percent-encoded, with a leading slash.
        let label = components.path.hasPrefix("/") ? String(components.path.dropFirst()) : components.path
        var issuer = query["issuer"]?.nilIfBlank
        var account = label.nilIfBlank
        if let account, let colon = account.firstIndex(of: ":") {
            let labelIssuer = String(account[account.startIndex..<colon]).trimmingCharacters(in: .whitespaces)
            if issuer == nil, !labelIssuer.isEmpty { issuer = labelIssuer }
        }
        if account == nil, let issuer { account = issuer }

        return OneTimeCodeConfiguration(
            secret: secret,
            digits: digits,
            period: period,
            algorithm: algorithm,
            issuer: issuer,
            account: account
        )
    }

    // MARK: - Base32

    private static let base32Alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")

    /// RFC 4648 base32, case-insensitive, padding optional.
    ///
    /// Spaces and hyphens are stripped first because that is how sites present a setup key,
    /// and asking someone to retype `JBSW Y3DP` without the space is a pointless obstacle.
    static func decodeBase32(_ value: String) throws -> Data {
        var bits = 0
        var accumulator = 0
        var bytes: [UInt8] = []
        var sawPadding = false
        var sawSymbol = false

        var lookup: [Character: Int] = [:]
        for (index, character) in base32Alphabet.enumerated() { lookup[character] = index }

        for character in value.uppercased() {
            if character == " " || character == "-" || character == "\n" || character == "\r" || character == "\t" {
                continue
            }
            if character == "=" {
                sawPadding = true
                continue
            }
            // Anything after padding is malformed, not merely decorative.
            guard !sawPadding, let digit = lookup[character] else { throw OneTimeCodeError.invalidBase32 }
            sawSymbol = true
            accumulator = (accumulator << 5) | digit
            bits += 5
            if bits >= 8 {
                bits -= 8
                bytes.append(UInt8((accumulator >> bits) & 0xFF))
            }
        }

        guard sawSymbol else { throw OneTimeCodeError.missingSecret }
        // Leftover bits are the encoder's padding and must be zero; a non-zero remainder means
        // characters were dropped somewhere.
        guard bits < 5, (accumulator & ((1 << bits) - 1)) == 0 else { throw OneTimeCodeError.invalidBase32 }
        guard !bytes.isEmpty else { throw OneTimeCodeError.missingSecret }
        return Data(bytes)
    }
}

// MARK: - Generation

nonisolated enum OneTimeCodeGenerator {
    /// The current code, zero-padded to the configured width.
    static func code(for configuration: OneTimeCodeConfiguration, at date: Date = Date()) -> String {
        code(for: configuration, counter: counter(for: configuration, at: date))
    }

    /// RFC 4226 HOTP. Exposed by counter so the RFC's own test vectors can be run against it.
    static func code(for configuration: OneTimeCodeConfiguration, counter: UInt64) -> String {
        var message = Data(count: 8)
        for index in 0..<8 {
            message[index] = UInt8(truncatingIfNeeded: counter >> UInt64(8 * (7 - index)))
        }

        let key = SymmetricKey(data: configuration.secret)
        let digest: Data = switch configuration.algorithm {
        case .sha1: Data(HMAC<Insecure.SHA1>.authenticationCode(for: message, using: key))
        case .sha256: Data(HMAC<SHA256>.authenticationCode(for: message, using: key))
        case .sha512: Data(HMAC<SHA512>.authenticationCode(for: message, using: key))
        }

        // Dynamic truncation: the low nibble of the last byte picks the 4-byte window.
        let offset = Int(digest[digest.count - 1] & 0x0F)
        let binary = (UInt32(digest[offset] & 0x7F) << 24)
            | (UInt32(digest[offset + 1]) << 16)
            | (UInt32(digest[offset + 2]) << 8)
            | UInt32(digest[offset + 3])

        // Integer math on purpose. `UInt32(pow(10, digits))` overflows at ten digits, and a
        // 31-bit HOTP value cannot fill ten digits anyway, so a modulus wider than the value is
        // the correct no-op rather than a trap.
        var modulus: UInt64 = 1
        for _ in 0..<configuration.digits { modulus *= 10 }
        let value = UInt64(binary) % modulus

        let rendered = String(value)
        guard rendered.count < configuration.digits else {
            return String(rendered.suffix(configuration.digits))
        }
        return String(repeating: "0", count: configuration.digits - rendered.count) + rendered
    }

    /// Which time step `date` falls in. Dates before 1970 clamp to step zero rather than
    /// wrapping a negative interval into an enormous unsigned counter.
    static func counter(for configuration: OneTimeCodeConfiguration, at date: Date = Date()) -> UInt64 {
        let seconds = date.timeIntervalSince1970
        guard seconds > 0 else { return 0 }
        return UInt64(seconds / Double(configuration.period))
    }

    /// Seconds until this code is replaced, always at least 1 so the countdown never reads zero
    /// for a code that is still on screen.
    static func secondsRemaining(for configuration: OneTimeCodeConfiguration, at date: Date = Date()) -> Int {
        let period = Double(configuration.period)
        let seconds = max(date.timeIntervalSince1970, 0)
        let elapsed = seconds - (seconds / period).rounded(.down) * period
        return max(1, Int((period - elapsed).rounded(.up)))
    }

    /// 0 at the start of a step, approaching 1 as it runs out. Drives the countdown ring.
    static func progress(for configuration: OneTimeCodeConfiguration, at date: Date = Date()) -> Double {
        let period = Double(configuration.period)
        let seconds = max(date.timeIntervalSince1970, 0)
        let elapsed = seconds - (seconds / period).rounded(.down) * period
        return min(max(elapsed / period, 0), 1)
    }

    /// Splits the code into two halves so it can be read off the screen without losing your
    /// place. Copying always uses the unspaced form.
    static func grouped(_ code: String) -> String {
        guard code.count >= 6, code.count % 2 == 0 else { return code }
        let midpoint = code.index(code.startIndex, offsetBy: code.count / 2)
        return "\(code[code.startIndex..<midpoint]) \(code[midpoint...])"
    }
}

private nonisolated extension String {
    /// Nil for a string that is empty or only whitespace, which is what "absent" means for
    /// every one of these URI parameters.
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
