import Foundation
import Testing
@testable import PassStore

/// One-time codes are the one feature here where "it looks right" is worthless: a code that is
/// wrong by one time step, one digit or one hash function is indistinguishable from a correct one
/// on screen and fails only at the moment somebody is locked out of their account. So the
/// generator is pinned to the published test vectors of RFC 4226 and RFC 6238 rather than to
/// values this implementation produced.
struct OneTimeCodeTests {

    /// RFC 4226 Appendix D: the ASCII seed every HOTP vector is defined against.
    private static let rfcSeed = Data("12345678901234567890".utf8)
    private static let rfcSeed256 = Data("12345678901234567890123456789012".utf8)
    private static let rfcSeed512 = Data("1234567890123456789012345678901234567890123456789012345678901234".utf8)

    // MARK: - RFC 4226 (HOTP)

    @Test func hotpMatchesTheRFC4226TestVectors() {
        let configuration = OneTimeCodeConfiguration(secret: Self.rfcSeed, digits: 6, algorithm: .sha1)
        let expected = [
            "755224", "287082", "359152", "969429", "338314",
            "254676", "287922", "162583", "399871", "520489"
        ]
        for (counter, code) in expected.enumerated() {
            #expect(OneTimeCodeGenerator.code(for: configuration, counter: UInt64(counter)) == code)
        }
    }

    // MARK: - RFC 6238 (TOTP)

    @Test func totpMatchesTheRFC6238Sha1Vectors() {
        let configuration = OneTimeCodeConfiguration(secret: Self.rfcSeed, digits: 8, period: 30, algorithm: .sha1)
        let expected: [(TimeInterval, String)] = [
            (59, "94287082"),
            (1_111_111_109, "07081804"),
            (1_111_111_111, "14050471"),
            (1_234_567_890, "89005924"),
            (2_000_000_000, "69279037"),
            (20_000_000_000, "65353130")
        ]
        for (seconds, code) in expected {
            let date = Date(timeIntervalSince1970: seconds)
            #expect(OneTimeCodeGenerator.code(for: configuration, at: date) == code)
        }
    }

    @Test func totpMatchesTheRFC6238Sha256Vectors() {
        let configuration = OneTimeCodeConfiguration(secret: Self.rfcSeed256, digits: 8, period: 30, algorithm: .sha256)
        let expected: [(TimeInterval, String)] = [
            (59, "46119246"),
            (1_111_111_109, "68084774"),
            (1_234_567_890, "91819424")
        ]
        for (seconds, code) in expected {
            #expect(OneTimeCodeGenerator.code(for: configuration, at: Date(timeIntervalSince1970: seconds)) == code)
        }
    }

    @Test func totpMatchesTheRFC6238Sha512Vectors() {
        let configuration = OneTimeCodeConfiguration(secret: Self.rfcSeed512, digits: 8, period: 30, algorithm: .sha512)
        let expected: [(TimeInterval, String)] = [
            (59, "90693936"),
            (1_111_111_109, "25091201"),
            (1_234_567_890, "93441116")
        ]
        for (seconds, code) in expected {
            #expect(OneTimeCodeGenerator.code(for: configuration, at: Date(timeIntervalSince1970: seconds)) == code)
        }
    }

    /// A code is padded to its full width. Dropping a leading zero produces a five-digit code
    /// that every site rejects, and it happens roughly one time in ten.
    @Test func codesAreZeroPaddedToTheConfiguredWidth() {
        let configuration = OneTimeCodeConfiguration(secret: Self.rfcSeed, digits: 8, period: 30, algorithm: .sha1)
        let code = OneTimeCodeGenerator.code(for: configuration, at: Date(timeIntervalSince1970: 1_111_111_109))
        #expect(code == "07081804")
        #expect(code.count == 8)
    }

    /// Ten digits cannot be produced by a 31-bit truncation, and the naive `pow`-based modulus
    /// overflowed a `UInt32` trying.
    @Test func tenDigitCodesDoNotTrap() {
        let configuration = OneTimeCodeConfiguration(secret: Self.rfcSeed, digits: 10, period: 30, algorithm: .sha1)
        let code = OneTimeCodeGenerator.code(for: configuration, counter: 1)
        // `allSatisfy` is `rethrows`, which the expectation macro cannot see through.
        let isAllDigits = code.allSatisfy(\.isNumber)
        #expect(code.count == 10)
        #expect(isAllDigits)
    }

    // MARK: - Countdown

    @Test func theCountdownRunsFromTheFullPeriodDownToOne() {
        let configuration = OneTimeCodeConfiguration(secret: Self.rfcSeed, period: 30)
        #expect(OneTimeCodeGenerator.secondsRemaining(for: configuration, at: Date(timeIntervalSince1970: 0)) == 30)
        #expect(OneTimeCodeGenerator.secondsRemaining(for: configuration, at: Date(timeIntervalSince1970: 29)) == 1)
        #expect(OneTimeCodeGenerator.secondsRemaining(for: configuration, at: Date(timeIntervalSince1970: 29.5)) == 1)
        // A new step restarts at the top rather than reading zero.
        #expect(OneTimeCodeGenerator.secondsRemaining(for: configuration, at: Date(timeIntervalSince1970: 30)) == 30)
    }

    @Test func progressAdvancesWithinTheStepAndResetsAtTheBoundary() {
        let configuration = OneTimeCodeConfiguration(secret: Self.rfcSeed, period: 30)
        #expect(OneTimeCodeGenerator.progress(for: configuration, at: Date(timeIntervalSince1970: 0)) == 0)
        #expect(abs(OneTimeCodeGenerator.progress(for: configuration, at: Date(timeIntervalSince1970: 15)) - 0.5) < 0.0001)
        #expect(OneTimeCodeGenerator.progress(for: configuration, at: Date(timeIntervalSince1970: 30)) == 0)
    }

    /// A clock behind 1970 would otherwise turn a negative interval into an enormous counter.
    @Test func datesBeforeTheEpochClampInsteadOfWrapping() {
        let configuration = OneTimeCodeConfiguration(secret: Self.rfcSeed, period: 30)
        let date = Date(timeIntervalSince1970: -5_000)
        #expect(OneTimeCodeGenerator.counter(for: configuration, at: date) == 0)
        #expect(OneTimeCodeGenerator.secondsRemaining(for: configuration, at: date) == 30)
    }

    // MARK: - Base32

    /// RFC 4648 section 10.
    @Test func base32DecodingMatchesTheRFC4648Vectors() throws {
        let vectors = [
            ("MY======", "f"),
            ("MZXQ====", "fo"),
            ("MZXW6===", "foo"),
            ("MZXW6YQ=", "foob"),
            ("MZXW6YTB", "fooba"),
            ("MZXW6YTBOI======", "foobar")
        ]
        for (encoded, decoded) in vectors {
            let data = try OneTimeCodeParser.decodeBase32(encoded)
            #expect(String(decoding: data, as: UTF8.self) == decoded)
        }
    }

    /// Padding is optional in the wild, and sites print setup keys in lowercase, in groups
    /// separated by spaces, and sometimes hyphenated. All of those are the same key.
    @Test func setupKeysAreAcceptedHoweverTheSiteFormatsThem() throws {
        let canonical = try OneTimeCodeParser.decodeBase32("MZXW6YTBOI")
        let lowercased = try OneTimeCodeParser.decodeBase32("mzxw6ytboi")
        let spaced = try OneTimeCodeParser.decodeBase32("MZXW 6YTB OI")
        let hyphenated = try OneTimeCodeParser.decodeBase32("MZXW-6YTB-OI")
        let padded = try OneTimeCodeParser.decodeBase32("MZXW6YTBOI======")

        #expect(lowercased == canonical)
        #expect(spaced == canonical)
        #expect(hyphenated == canonical)
        #expect(padded == canonical)
    }

    @Test func base32RejectsCharactersOutsideTheAlphabet() {
        // 0, 1, 8 and 9 are deliberately absent from base32.
        #expect(throws: OneTimeCodeError.invalidBase32) { try OneTimeCodeParser.decodeBase32("MZXW6YTB01") }
        #expect(throws: OneTimeCodeError.invalidBase32) { try OneTimeCodeParser.decodeBase32("NOT BASE32!!") }
        // Symbols after the padding mean characters went missing somewhere.
        #expect(throws: OneTimeCodeError.invalidBase32) { try OneTimeCodeParser.decodeBase32("MZXW6===YTB") }
    }

    @Test func base32RejectsAnEmptyKey() {
        #expect(throws: OneTimeCodeError.missingSecret) { try OneTimeCodeParser.decodeBase32("======") }
    }

    // MARK: - otpauth:// parsing

    @Test func parsesTheUsualIssuerProvidedURI() throws {
        let configuration = try OneTimeCodeParser.parse(
            "otpauth://totp/GitHub:developer@example.invalid?secret=JBSWY3DPEHPK3PXP&issuer=GitHub"
        )
        #expect(configuration.digits == 6)
        #expect(configuration.period == 30)
        #expect(configuration.algorithm == .sha1)
        #expect(configuration.issuer == "GitHub")
        #expect(configuration.account == "GitHub:developer@example.invalid")
        // The label already names the issuer, so the subtitle must not say it twice.
        #expect(configuration.subtitle == "GitHub:developer@example.invalid")
        #expect(!configuration.hasNonDefaultParameters)
    }

    @Test func honoursDigitsPeriodAndAlgorithmOverrides() throws {
        let configuration = try OneTimeCodeParser.parse(
            "otpauth://totp/Example?secret=JBSWY3DPEHPK3PXP&digits=8&period=60&algorithm=SHA512"
        )
        #expect(configuration.digits == 8)
        #expect(configuration.period == 60)
        #expect(configuration.algorithm == .sha512)
        #expect(configuration.hasNonDefaultParameters)
        #expect(configuration.parameterSummary == "8 digits · 60s · SHA-512")
    }

    @Test func acceptsTheSpellingsIssuersActuallyUseForAlgorithms() {
        #expect(OneTimeCodeConfiguration.Algorithm(issuerSpelling: "SHA1") == .sha1)
        #expect(OneTimeCodeConfiguration.Algorithm(issuerSpelling: "sha-256") == .sha256)
        #expect(OneTimeCodeConfiguration.Algorithm(issuerSpelling: "SHA 512") == .sha512)
        #expect(OneTimeCodeConfiguration.Algorithm(issuerSpelling: "md5") == nil)
    }

    @Test func aBareSetupKeyIsAValidField() throws {
        let configuration = try OneTimeCodeParser.parse("jbsw y3dp ehpk 3pxp")
        #expect(configuration.digits == 6)
        #expect(configuration.algorithm == .sha1)
        #expect(configuration.issuer == nil)
        #expect(configuration.subtitle == nil)
    }

    /// Counter-based codes need somewhere to keep the counter and would silently produce a code
    /// that is already spent. Saying so is better than generating nonsense.
    @Test func counterBasedLinksAreRefusedExplicitly() {
        #expect(throws: OneTimeCodeError.counterBasedNotSupported) {
            try OneTimeCodeParser.parse("otpauth://hotp/Example?secret=JBSWY3DPEHPK3PXP&counter=1")
        }
    }

    @Test func rejectsLinksThatAreNotOneTimeCodeLinks() {
        #expect(throws: OneTimeCodeError.unsupportedScheme("https")) {
            try OneTimeCodeParser.parse("https://example.invalid/totp?secret=JBSWY3DPEHPK3PXP")
        }
    }

    @Test func rejectsAURIWithNoSecret() {
        #expect(throws: OneTimeCodeError.missingSecret) {
            try OneTimeCodeParser.parse("otpauth://totp/Example?issuer=Example")
        }
    }

    @Test func rejectsOutOfRangeParameters() {
        #expect(throws: OneTimeCodeError.invalidDigits) {
            try OneTimeCodeParser.parse("otpauth://totp/Example?secret=JBSWY3DPEHPK3PXP&digits=99")
        }
        #expect(throws: OneTimeCodeError.invalidPeriod) {
            try OneTimeCodeParser.parse("otpauth://totp/Example?secret=JBSWY3DPEHPK3PXP&period=0")
        }
    }

    @Test func rejectsAnEmptyValue() {
        #expect(throws: OneTimeCodeError.empty) { try OneTimeCodeParser.parse("   ") }
    }

    /// A setup key containing a colon must not be mistaken for a URI and reported as a bad
    /// scheme when the real problem is the key itself.
    @Test func aTypedKeyIsDiagnosedAsAKeyNotAsALink() {
        #expect(throws: OneTimeCodeError.invalidBase32) { try OneTimeCodeParser.parse("github:my-secret-key") }
    }

    // MARK: - Display

    @Test func codesAreGroupedInHalvesForReading() {
        #expect(OneTimeCodeGenerator.grouped("123456") == "123 456")
        #expect(OneTimeCodeGenerator.grouped("12345678") == "1234 5678")
        // An odd width has no sensible halves; leave it alone rather than group it badly.
        #expect(OneTimeCodeGenerator.grouped("1234567") == "1234567")
    }

    // MARK: - Field handling

    @Test func aOneTimeCodeFieldIsSensitiveByDefinition() {
        #expect(FieldKind.totp.isInherentlySecret)
        #expect(FieldKind.totp.title == "One-time code")

        var field = FieldDraft(key: "twofactor", label: "Two-factor", kind: .text, isSensitive: false)
        field.applyKind(.totp)
        #expect(field.isSensitive)
        #expect(field.isMasked)
    }

    /// The password generator belongs to passwords. Offering it on a seed the issuer chose
    /// would let one click destroy the pairing.
    @Test func theGeneratorIsNotOfferedForAOneTimeCodeField() {
        let field = FieldDraft(key: "password", label: "Password", kind: .totp, isSensitive: true)
        #expect(!field.supportsGeneratedPassword)
    }
}

/// The health audit and the view model, which need a live container.
@MainActor
struct OneTimeCodeVaultTests {

    /// A machine-generated base32 seed scores badly as a "password" and there is nothing the
    /// owner could do about it, so reporting it is noise that buries real findings.
    @Test func aOneTimeCodeSeedIsNotReportedAsAWeakSecret() {
        let container = AppContainer.preview()
        let viewModel = VaultViewModel(container: container)

        var draft = SecretItemDraft.empty
        draft.title = "Has 2FA"
        draft.fieldDrafts = [
            FieldDraft(key: "twofactor", label: "Two-factor", value: "JBSWY3DPEHPK3PXP", kind: .totp, isSensitive: true, isMasked: true, sortOrder: 0)
        ]
        viewModel.saveItem(draft)

        let report = viewModel.vaultHealthReport()
        #expect(!report.findings.contains { $0.itemTitle == "Has 2FA" && $0.kind == .weak })
        #expect(!report.ignoredFindings.contains { $0.itemTitle == "Has 2FA" && $0.kind == .weak })
    }

    /// The same seed in two items is a real problem — one of them is a copy that will keep
    /// working after the other is rotated — so reuse detection still applies.
    @Test func theSameSeedInTwoItemsIsStillReportedAsReuse() {
        let container = AppContainer.preview()
        let viewModel = VaultViewModel(container: container)

        for title in ["Primary 2FA", "Duplicated 2FA"] {
            var draft = SecretItemDraft.empty
            draft.title = title
            draft.fieldDrafts = [
                FieldDraft(key: "twofactor", label: "Two-factor", value: "JBSWY3DPEHPK3PXP", kind: .totp, isSensitive: true, isMasked: true, sortOrder: 0)
            ]
            viewModel.saveItem(draft)
        }

        let reused = viewModel.vaultHealthReport().findings.filter { $0.kind == .reused }
        #expect(reused.contains { $0.itemTitle == "Primary 2FA" })
        #expect(reused.contains { $0.itemTitle == "Duplicated 2FA" })
    }

    @Test func theViewModelFindsAndReadsAnItemsOneTimeCode() throws {
        let container = AppContainer.preview()
        let viewModel = VaultViewModel(container: container)

        var draft = SecretItemDraft.empty
        draft.title = "Console Login"
        draft.fieldDrafts = [
            FieldDraft(key: "password", label: "Password", value: "correct-horse-battery", kind: .secret, isSensitive: true, isMasked: true, sortOrder: 0),
            FieldDraft(key: "twofactor", label: "Two-factor", value: "otpauth://totp/Console:ops@example.invalid?secret=JBSWY3DPEHPK3PXP&issuer=Console", kind: .totp, isSensitive: true, isMasked: true, sortOrder: 1)
        ]
        viewModel.saveItem(draft)

        let item = try #require(viewModel.items.first { $0.title == "Console Login" })
        let field = try #require(viewModel.oneTimeCodeField(for: item))
        #expect(field.key == "twofactor")

        let configuration = try #require(viewModel.oneTimeCodeConfiguration(for: field))
        #expect(configuration.issuer == "Console")

        // What gets copied is six digits, not the seed sitting in the field.
        let code = OneTimeCodeGenerator.code(for: configuration)
        #expect(code.count == 6)
        #expect(code != field.value)
    }

    @Test func anUnreadableSeedYieldsNoConfigurationRatherThanAFabricatedCode() throws {
        let container = AppContainer.preview()
        let viewModel = VaultViewModel(container: container)

        var draft = SecretItemDraft.empty
        draft.title = "Broken 2FA"
        draft.fieldDrafts = [
            FieldDraft(key: "twofactor", label: "Two-factor", value: "not a key!!", kind: .totp, isSensitive: true, isMasked: true, sortOrder: 0)
        ]
        viewModel.saveItem(draft)

        let item = try #require(viewModel.items.first { $0.title == "Broken 2FA" })
        #expect(viewModel.oneTimeCodeField(for: item) == nil)
    }

    /// A TOTP field must survive a full encrypt/decrypt round trip with its kind intact —
    /// coming back as plain text would quietly turn the seed into a visible value.
    @Test func aOneTimeCodeFieldSurvivesASnapshotRoundTrip() throws {
        let container = AppContainer.preview()
        var draft = SecretItemDraft.empty
        draft.title = "Round Trip"
        draft.fieldDrafts = [
            FieldDraft(key: "twofactor", label: "Two-factor", value: "JBSWY3DPEHPK3PXP", kind: .totp, isSensitive: true, isMasked: true, sortOrder: 0)
        ]
        _ = try container.itemRepository.saveItem(draft)

        let snapshot = container.memoryStore.makeSnapshot()
        let encoded = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(VaultSnapshot.self, from: encoded)

        let item = try #require(decoded.items.first { $0.title == "Round Trip" })
        let field = try #require(item.fields.first { $0.fieldKey == "twofactor" })
        #expect(field.kindRawValue == FieldKind.totp.rawValue)
        #expect(field.isSensitive)
    }
}
