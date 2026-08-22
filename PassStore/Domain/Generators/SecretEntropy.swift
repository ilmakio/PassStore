import Foundation

/// How much randomness a stored secret actually represents.
///
/// The audit used to score a secret by its length and how many character classes it contained,
/// which is the model that calls `Password123!` twelve characters of four classes and therefore
/// respectable. Counting bits instead is both harsher and fairer, and it can be stated: 40 bits is
/// 40 bits whatever it is made of.
nonisolated enum SecretEntropy {
    /// Bits of randomness, estimated conservatively.
    ///
    /// Two models are computed and the *lower* one wins. A character model alone flatters a
    /// passphrase — `correct horse battery staple` is 28 characters, which looks like 130 bits and
    /// is really nearer 50 — and a word model alone cannot describe `7bQ!vz2Lm#94Xr` at all. Taking
    /// the minimum means neither model can be gamed by writing a secret in the shape the other one
    /// misreads.
    static func bits(of secret: String) -> Double {
        guard !secret.isEmpty else { return 0 }
        let characterModel = characterModelBits(secret)
        guard let wordModel = wordModelBits(secret) else { return characterModel }
        return min(characterModel, wordModel)
    }

    /// `length × log2(alphabet)`, where the alphabet is inferred from what the secret uses.
    ///
    /// Only the classes actually present count. Assuming the full 95 printable ASCII for an
    /// all-lowercase secret would credit it with randomness it does not have.
    static func characterModelBits(_ secret: String) -> Double {
        var pool = 0
        if secret.contains(where: \.isLowercase) { pool += 26 }
        if secret.contains(where: \.isUppercase) { pool += 26 }
        if secret.contains(where: \.isNumber) { pool += 10 }
        if secret.contains(where: { $0 == " " }) { pool += 1 }
        // Everything else — punctuation, symbols, anything non-ASCII — as one bucket the size of
        // ASCII punctuation. Counting every Unicode scalar would be arithmetically true and
        // practically absurd.
        if secret.contains(where: { !$0.isLetter && !$0.isNumber && $0 != " " }) { pool += 32 }
        guard pool > 1 else { return 0 }

        // Distinct characters, not length: `aaaaaaaaaaaaaaaa` is sixteen characters of one.
        let distinct = Set(secret).count
        let effectiveLength = Double(min(secret.count, distinct * 2))
        return effectiveLength * log2(Double(pool))
    }

    /// Bits if the secret is read as separated words, or nil when it does not look like one.
    ///
    /// Deliberately pessimistic about the list somebody drew from: eleven bits a word is roughly a
    /// two-thousand-word vocabulary, which is generous for words a person chose themselves and
    /// about right for a generated passphrase.
    static func wordModelBits(_ secret: String) -> Double? {
        let parts = secret
            .split(whereSeparator: { $0 == " " || $0 == "-" || $0 == "_" || $0 == "." })
            .map(String.init)
        // Two separated runs is a hyphenated word, not a passphrase; and a part that is not a
        // plain word means this is a token that happens to contain a dash.
        guard parts.count >= 3, parts.allSatisfy({ $0.allSatisfy(\.isLetter) || $0.allSatisfy(\.isNumber) }) else {
            return nil
        }
        let wordParts = parts.filter { $0.contains(where: \.isLetter) }
        guard wordParts.count >= 3 else { return nil }
        let numberParts = parts.count - wordParts.count
        return Double(wordParts.count) * assumedBitsPerWord + Double(numberParts) * log2(100)
    }

    static let assumedBitsPerWord: Double = 11
}

/// A credential that was issued rather than chosen.
///
/// Worth recognising for two reasons. Scoring a machine-issued token for strength is meaningless —
/// the owner cannot make an AWS key stronger — and naming it in the interface answers the question
/// somebody actually has when they find a 40-character string in an old vault: what is this?
nonisolated enum SecretShape: String, CaseIterable, Sendable {
    case awsAccessKeyID
    case githubToken
    case openAIKey
    case slackToken
    case stripeKey
    case googleAPIKey
    case npmToken
    case jsonWebToken
    case privateKeyBlock
    case uuid

    var title: String {
        switch self {
        case .awsAccessKeyID: "AWS access key ID"
        case .githubToken: "GitHub token"
        case .openAIKey: "OpenAI API key"
        case .slackToken: "Slack token"
        case .stripeKey: "Stripe key"
        case .googleAPIKey: "Google API key"
        case .npmToken: "npm token"
        case .jsonWebToken: "JSON Web Token"
        case .privateKeyBlock: "Private key"
        case .uuid: "UUID"
        }
    }

    /// True where the value was issued by a service, so judging its strength says nothing useful.
    var isIssuedCredential: Bool {
        switch self {
        case .awsAccessKeyID, .githubToken, .openAIKey, .slackToken, .stripeKey,
             .googleAPIKey, .npmToken, .jsonWebToken, .privateKeyBlock:
            true
        case .uuid:
            // A UUID may well be an identifier somebody typed in, and it is not a credential.
            false
        }
    }

    /// The shape of `value`, if it is a recognisable one.
    ///
    /// Prefix matching, not entropy guessing: these are documented formats, and a wrong guess here
    /// would silence a genuinely weak secret in the health report.
    static func detect(in value: String) -> SecretShape? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.hasPrefix("-----BEGIN"), trimmed.contains("PRIVATE KEY") { return .privateKeyBlock }
        if trimmed.hasPrefix("AKIA") || trimmed.hasPrefix("ASIA"),
           trimmed.count == 20,
           trimmed.dropFirst(4).allSatisfy({ $0.isUppercase || $0.isNumber }) {
            return .awsAccessKeyID
        }
        if trimmed.hasPrefix("github_pat_") { return .githubToken }
        for prefix in ["ghp_", "gho_", "ghu_", "ghs_", "ghr_"] where trimmed.hasPrefix(prefix) {
            return .githubToken
        }
        if trimmed.hasPrefix("npm_") { return .npmToken }
        if trimmed.hasPrefix("sk-"), trimmed.count >= 20 { return .openAIKey }
        for prefix in ["xoxb-", "xoxp-", "xoxa-", "xoxr-", "xoxs-", "xapp-"] where trimmed.hasPrefix(prefix) {
            return .slackToken
        }
        for prefix in ["sk_live_", "sk_test_", "pk_live_", "pk_test_", "rk_live_", "whsec_"]
        where trimmed.hasPrefix(prefix) {
            return .stripeKey
        }
        if trimmed.hasPrefix("AIza"), trimmed.count == 39 { return .googleAPIKey }
        if isJSONWebToken(trimmed) { return .jsonWebToken }
        if UUID(uuidString: trimmed) != nil { return .uuid }
        return nil
    }

    /// Three dot-separated base64url runs, the middle of which is a JSON object.
    ///
    /// The header alone is not enough: plenty of values contain two dots.
    private static func isJSONWebToken(_ value: String) -> Bool {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, parts[0].hasPrefix("eyJ"), !parts[1].isEmpty else { return false }
        let alphabet = { (character: Character) in
            character.isLetter || character.isNumber || character == "-" || character == "_"
        }
        return parts[0].allSatisfy(alphabet) && parts[1].allSatisfy(alphabet) && parts[2].allSatisfy(alphabet)
    }
}
