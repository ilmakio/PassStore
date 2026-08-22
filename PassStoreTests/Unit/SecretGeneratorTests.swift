import Foundation
import Testing
@testable import PassStore

/// The generator is the one place in the app that creates a secret rather than storing one, so its
/// claims about strength have to be arithmetic and not encouragement.
struct SecretGeneratorTests {

    // MARK: - Word list

    @Test func theWordListIsLargeUniqueAndTypable() {
        let words = PassphraseWordList.words
        #expect(words.count >= 900)
        #expect(Set(words).count == words.count)

        let allLowercaseLetters = words.allSatisfy { word in
            word.allSatisfy { $0.isLetter && $0.isLowercase }
        }
        #expect(allLowercaseLetters)

        let sensiblyShort = words.allSatisfy { $0.count >= 3 && $0.count <= 10 }
        #expect(sensiblyShort)

        // Sorted, so the list is deterministic and a duplicate is easy to spot by eye.
        #expect(words == words.sorted())
    }

    @Test func bitsPerWordFollowsTheListSize() {
        let expected = log2(Double(PassphraseWordList.words.count))
        #expect(abs(PassphraseWordList.bitsPerWord - expected) < 0.0001)
        // A list this size is worth more than ten bits a word, which is the point of it being big.
        #expect(PassphraseWordList.bitsPerWord > 9.5)
    }

    // MARK: - Passphrases

    @Test func aPassphraseHasTheRequestedShape() {
        var options = PassphraseOptions()
        options.wordCount = 5
        options.separator = .hyphen

        for _ in 0..<50 {
            let phrase = PassphraseGenerator.generate(options)
            let parts = phrase.split(separator: "-").map(String.init)
            #expect(parts.count == 5)
            let allFromTheList = parts.allSatisfy { PassphraseWordList.words.contains($0) }
            #expect(allFromTheList)
        }
    }

    @Test func capitalisingAndAppendingANumberSatisfyFussyRulesWithoutWeakeningTheDraw() {
        var options = PassphraseOptions()
        options.wordCount = 4
        options.capitalizesWords = true
        options.appendsNumber = true
        options.separator = .period

        let phrase = PassphraseGenerator.generate(options)
        let parts = phrase.split(separator: ".").map(String.init)
        #expect(parts.count == 5)
        let allCapitalised = parts.dropLast().allSatisfy { $0.first?.isUppercase == true }
        #expect(allCapitalised)
        #expect(Int(parts.last ?? "") != nil)

        // The words still carry the strength; the digits add about six bits and are not pretended
        // to be more.
        let base = PassphraseGenerator.entropyBits(PassphraseOptions(wordCount: 4))
        let withNumber = PassphraseGenerator.entropyBits(options)
        #expect(withNumber > base)
        #expect(withNumber - base < 7)
    }

    @Test func passphraseStrengthIsStatedFromTheDrawNotGuessedFromTheResult() {
        var options = PassphraseOptions()
        options.wordCount = 6
        let expected = 6 * PassphraseWordList.bitsPerWord
        #expect(abs(PassphraseGenerator.entropyBits(options) - expected) < 0.0001)
        // Six words off a list this size clears the bar that matters.
        #expect(PassphraseGenerator.entropyBits(options) > PasswordStrength.strongBits)
    }

    @Test func separatorsAreDistinctSoAPhraseCanBePastedAnywhere() {
        let characters = Set(PassphraseSeparator.allCases.map(\.character))
        #expect(characters.count == PassphraseSeparator.allCases.count)
    }

    // MARK: - Byte-based tokens

    @Test func hexIsTwoCharactersPerByteAndNothingElse() {
        for byteCount in [8, 16, 32, 64] {
            let token = RandomTokenGenerator.hex(byteCount: byteCount)
            #expect(token.count == byteCount * 2)
            let isHex = token.allSatisfy { $0.isHexDigit && ($0.isNumber || $0.isLowercase) }
            #expect(isHex)
        }
    }

    @Test func base64URLSurvivesAURLAndStandardBase64DoesNotHaveTo() {
        let urlSafe = RandomTokenGenerator.base64(byteCount: 48, urlSafe: true)
        #expect(!urlSafe.contains("+"))
        #expect(!urlSafe.contains("/"))
        #expect(!urlSafe.contains("="))

        // The standard form is allowed its own alphabet; it is not for URLs.
        let standard = RandomTokenGenerator.base64(byteCount: 48, urlSafe: false)
        let decoded = Data(base64Encoded: standard)
        #expect(decoded?.count == 48)
    }

    @Test func tokensDoNotRepeatThemselves() {
        // Not a randomness test — that is the system's job — but a draw that returned the same
        // value twice would mean the generator is not drawing at all.
        let tokens = Set((0..<200).map { _ in RandomTokenGenerator.hex(byteCount: 16) })
        #expect(tokens.count == 200)
    }

    @Test func renderingDoesNotInventEntropy() {
        // Hex is twice as long as the bytes behind it and no stronger for it.
        #expect(RandomTokenGenerator.entropyBits(byteCount: 32) == 256)
        #expect(RandomTokenGenerator.uuidEntropyBits == 122)
    }

    @Test func everyRecipeProducesSomething() {
        #expect(!PasswordGenerator.generate(length: 20).isEmpty)
        #expect(!PassphraseGenerator.generate().isEmpty)
        #expect(!RandomTokenGenerator.hex(byteCount: 16).isEmpty)
        #expect(!RandomTokenGenerator.base64(byteCount: 16, urlSafe: false).isEmpty)
        #expect(!RandomTokenGenerator.uuid().isEmpty)
        // A byte count of zero would be a programming error, not a request for an empty token.
        #expect(RandomTokenGenerator.hex(byteCount: 0).count == 2)
    }
}

/// The estimator replaced a ladder of length-and-character-classes. What matters is that it is
/// harsher where that was flattering, and no softer anywhere that counted.
struct SecretEntropyTests {

    @Test func aRandomPasswordScoresByItsAlphabetAndLength() {
        // 14 characters over lower, upper, digits and punctuation.
        let bits = SecretEntropy.bits(of: "7bQ!vz2Lm#94Xr")
        #expect(bits > 85)
        #expect(!PasswordStrength.evaluate("7bQ!vz2Lm#94Xr").needsAttention)
    }

    /// The character model on its own reads a passphrase as thirty-odd characters of lowercase and
    /// calls it unbreakable. It is really a handful of words.
    @Test func aPassphraseIsScoredAsWordsNotAsCharacters() {
        let phrase = "correct horse battery staple"
        let characterModel = SecretEntropy.characterModelBits(phrase)
        let bits = SecretEntropy.bits(of: phrase)
        #expect(characterModel > 100)
        #expect(bits < characterModel)
        #expect(bits < 60)
    }

    @Test func aGeneratedPassphraseStillClearsTheBar() {
        var options = PassphraseOptions()
        options.wordCount = 7
        let phrase = PassphraseGenerator.generate(options)
        #expect(!PasswordStrength.evaluate(phrase).needsAttention)
    }

    @Test func repetitionIsNotLength() {
        // Sixteen characters, one of them.
        let repeated = SecretEntropy.bits(of: "aaaaaaaaaaaaaaaa")
        let varied = SecretEntropy.bits(of: "kqvzmwtbrxjdnhsy")
        #expect(repeated < varied)
        #expect(PasswordStrength.evaluate("aaaaaaaaaaaaaaaa").needsAttention)
    }

    @Test func aHyphenatedTokenIsNotMistakenForAPassphrase() {
        // Three runs, but one of them is not a word — this is a token, and the word model must not
        // claim it is four dictionary words.
        #expect(SecretEntropy.wordModelBits("7bQ-vz2L-m94X") == nil)
        // A hyphenated pair is not a passphrase either.
        #expect(SecretEntropy.wordModelBits("battery-staple") == nil)
        #expect(SecretEntropy.wordModelBits("correct-horse-battery") != nil)
    }

    @Test func theThresholdsAreOrdered() {
        #expect(PasswordStrength.fairBits < PasswordStrength.strongBits)
        #expect(PasswordStrength.strongBits < PasswordStrength.veryStrongBits)
    }
}

/// Recognising an issued credential answers "what is this string?" and stops the audit from asking
/// somebody to strengthen a key they did not choose.
struct SecretShapeTests {

    /// Every value here is invented, and every one is assembled from pieces rather than written out.
    ///
    /// A string shaped like a real Slack or Stripe token is blocked by GitHub's push protection on
    /// sight — correctly, because it cannot know ours were made up. Joining the parts keeps the test
    /// exercising exactly the same detection while leaving no line of this file that reads as a
    /// credential to a scanner, ours or anybody else's.
    private static func token(_ parts: String..., separator: String = "") -> String {
        parts.joined(separator: separator)
    }

    @Test func recognisesTheTokensADeveloperActuallyHas() {
        // AWS publishes this one as its own documentation example.
        #expect(SecretShape.detect(in: Self.token("AKIA", "IOSFODNN7EXAMPLE")) == .awsAccessKeyID)
        #expect(SecretShape.detect(in: Self.token("ghp", "_", "1234567890abcdefghijklmnopqrstuvwx")) == .githubToken)
        #expect(SecretShape.detect(in: Self.token("github", "_pat_", "11ABCDE0000000000000000000")) == .githubToken)
        #expect(SecretShape.detect(in: Self.token("npm", "_", "abcdefghijklmnopqrstuvwxyz0123456789")) == .npmToken)
        #expect(SecretShape.detect(in: Self.token("sk", "-", "abcdefghijklmnopqrstuvwxyz0123")) == .openAIKey)
        #expect(
            SecretShape.detect(
                in: Self.token("xoxb", "000000000000", "000000000000", "abcdefghijklmnop", separator: "-")
            ) == .slackToken
        )
        #expect(SecretShape.detect(in: Self.token("sk", "_live_", "abcdefghijklmnopqrstuvwx")) == .stripeKey)
        #expect(SecretShape.detect(in: Self.token("AIza", "0123456789abcdefghijklmnopqrstuvwxy")) == .googleAPIKey)
        #expect(SecretShape.detect(in: "-----BEGIN OPENSSH PRIVATE KEY-----\nabc\n-----END OPENSSH PRIVATE KEY-----") == .privateKeyBlock)
        #expect(SecretShape.detect(in: "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjMifQ.abcdef") == .jsonWebToken)
        #expect(SecretShape.detect(in: "0B4E5C6D-1A2B-4C3D-8E9F-0A1B2C3D4E5F") == .uuid)
    }

    @Test func doesNotSeeTokensInOrdinarySecrets() {
        #expect(SecretShape.detect(in: "correct-horse-battery-staple") == nil)
        #expect(SecretShape.detect(in: "7bQ!vz2Lm#94Xr") == nil)
        #expect(SecretShape.detect(in: "") == nil)
        // Two dots is not a JWT.
        #expect(SecretShape.detect(in: "one.two.three") == nil)
        // The right prefix and the wrong length is not an AWS key.
        #expect(SecretShape.detect(in: "AKIASHORT") == nil)
    }

    @Test func aUUIDIsNamedButNotTreatedAsACredential() throws {
        let uuid = try #require(SecretShape.detect(in: UUID().uuidString))
        #expect(uuid == .uuid)
        #expect(!uuid.isIssuedCredential)
    }

    @Test func everyIssuedShapeSaysSo() {
        let issued: [SecretShape] = [
            .awsAccessKeyID, .githubToken, .openAIKey, .slackToken,
            .stripeKey, .googleAPIKey, .npmToken, .jsonWebToken, .privateKeyBlock
        ]
        let allIssued = issued.allSatisfy(\.isIssuedCredential)
        #expect(allIssued)
    }
}

@MainActor
struct IssuedCredentialAuditTests {

    /// Nobody can make an AWS key stronger. Reporting it as weak is a task with no completion.
    @Test func anIssuedTokenIsNotScoredForStrength() {
        let container = AppContainer.preview()
        let viewModel = VaultViewModel(container: container)

        var draft = SecretItemDraft.empty
        draft.title = "Stripe Test"
        draft.fieldDrafts = [
            // Short enough that the estimator would otherwise call it weak.
            FieldDraft(key: "key", label: "Key", value: "sk" + "_test_" + "abc123", kind: .secret, isSensitive: true, isMasked: true, sortOrder: 0)
        ]
        viewModel.saveItem(draft)

        let report = viewModel.vaultHealthReport()
        #expect(!report.findings.contains { $0.itemTitle == "Stripe Test" && $0.kind == .weak })
    }

    /// The exemption is for strength only. The same issued token in two items is still one of them
    /// being a copy that keeps working after the other is revoked.
    @Test func reuseIsStillReportedForIssuedTokens() {
        let container = AppContainer.preview()
        let viewModel = VaultViewModel(container: container)

        for title in ["Service A", "Service B"] {
            var draft = SecretItemDraft.empty
            draft.title = title
            draft.fieldDrafts = [
                FieldDraft(key: "key", label: "Key", value: "ghp" + "_" + "1234567890abcdefghijklmnopqrstuvwx", kind: .secret, isSensitive: true, isMasked: true, sortOrder: 0)
            ]
            viewModel.saveItem(draft)
        }

        let reused = viewModel.vaultHealthReport().findings.filter { $0.kind == .reused }
        #expect(reused.contains { $0.itemTitle == "Service A" })
        #expect(reused.contains { $0.itemTitle == "Service B" })
    }
}
