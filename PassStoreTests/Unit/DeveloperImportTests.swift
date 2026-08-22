import Foundation
import Testing
@testable import PassStore

/// An `~/.aws/credentials` and a `.netrc` are plaintext credential stores everybody has and nobody
/// thinks about. Reading them is the first step to being able to delete them — which only works if
/// the parse is faithful, because a half-imported credential is worse than none.
///
/// Every fixture here is invented.
struct DeveloperImportTests {

    // MARK: - Format detection

    @Test func detectsEachFormatFromItsContents() {
        #expect(
            DeveloperCredentialImporter.detectFormat(
                contents: "[default]\naws_access_key_id = AKIAEXAMPLE0000000AA\n",
                fileName: "credentials"
            ) == .awsCredentials
        )
        #expect(
            DeveloperCredentialImporter.detectFormat(
                contents: "machine git.example.invalid login someone password hunter2\n",
                fileName: "whatever"
            ) == .netrc
        )
        #expect(
            DeveloperCredentialImporter.detectFormat(
                contents: "{\"auths\":{\"registry.example.invalid\":{}}}",
                fileName: "config.json"
            ) == .dockerConfig
        )
        #expect(
            DeveloperCredentialImporter.detectFormat(
                contents: "{\"encrypted\":false,\"items\":[]}",
                fileName: "export.json"
            ) == .bitwardenExport
        )
    }

    /// `config.json` is the most reused filename in software, so contents decide — and a JSON file
    /// with nothing credential-shaped in it is not a credential store, however flat it is.
    @Test func anUnrelatedJSONFileIsNotMistakenForACredentialStore() {
        #expect(
            DeveloperCredentialImporter.detectFormat(
                contents: "{\"name\":\"my-package\",\"version\":\"1.0.0\"}",
                fileName: "config.json"
            ) == nil
        )
        // The same file with one credential in it is worth offering.
        #expect(
            DeveloperCredentialImporter.detectFormat(
                contents: "{\"name\":\"my-package\",\"api_key\":\"abc123def456\"}",
                fileName: "config.json"
            ) == .flatJSON
        )
    }

    @Test func anUnknownFileIsRejectedWithAnExplanation() {
        #expect(throws: DeveloperCredentialImportError.unrecognisedFormat) {
            try DeveloperCredentialImporter.parse(contents: "hello world", fileName: "notes.txt")
        }
    }

    // MARK: - AWS

    @Test func readsOneItemPerAWSProfile() throws {
        let contents = """
        # work account
        [default]
        aws_access_key_id = AKIAEXAMPLE0000000AA
        aws_secret_access_key = wJalrXUtnFEMIexampleKEYexampleKEYexample
        region = eu-west-1

        [staging]
        aws_access_key_id = AKIAEXAMPLE0000000BB
        aws_secret_access_key = zTfoOPQrstUVexampleKEYexampleKEYexample
        aws_session_token = FwoGZXIvYXdzEXAMPLETOKEN
        """
        let parsed = try DeveloperCredentialImporter.parse(contents: contents, fileName: "credentials")
        #expect(parsed.format == .awsCredentials)
        #expect(parsed.credentials.count == 2)

        let first = try #require(parsed.credentials.first)
        // "default" is a poor item name, so it is spelled out.
        #expect(first.title == "AWS (default profile)")
        #expect(first.fields.contains { $0.key == "aws_secret_access_key" && $0.isSensitive })
        // A region is not a secret and must not be stored as one.
        let region = try #require(first.fields.first { $0.key == "region" })
        #expect(!region.isSensitive)
        #expect(region.value == "eu-west-1")

        let staging = try #require(parsed.credentials.last)
        #expect(staging.title == "AWS (staging)")
        #expect(staging.fields.contains { $0.key == "aws_session_token" && $0.isSensitive })
    }

    /// `~/.aws/config` writes `[profile name]`; the prefix is not part of the name.
    @Test func theProfilePrefixIsNotPartOfTheName() throws {
        let parsed = try DeveloperCredentialImporter.parse(
            contents: "[profile production]\naws_access_key_id = AKIAEXAMPLE0000000CC\n",
            fileName: "config"
        )
        #expect(parsed.credentials.first?.title == "AWS (production)")
    }

    /// Guessing that an unrecognised key is harmless is the more dangerous mistake.
    @Test func anUnknownAWSKeyIsTreatedAsSensitive() throws {
        let parsed = try DeveloperCredentialImporter.parse(
            contents: "[default]\naws_access_key_id = AKIAEXAMPLE0000000DD\nsome_new_token = abc123def456\n",
            fileName: "credentials"
        )
        let field = try #require(parsed.credentials.first?.fields.first { $0.key == "some_new_token" })
        #expect(field.isSensitive)
    }

    @Test func commentsAndBlankLinesAreIgnored() throws {
        let parsed = try DeveloperCredentialImporter.parse(
            contents: "; a comment\n\n[default]\n# another\naws_access_key_id = AKIAEXAMPLE0000000EE\n",
            fileName: "credentials"
        )
        #expect(parsed.credentials.count == 1)
        #expect(parsed.credentials.first?.fields.count == 1)
    }

    // MARK: - .netrc

    @Test func readsOneItemPerNetrcMachine() throws {
        let contents = """
        machine git.example.invalid
          login developer
          password s3cr3t-token-value

        machine api.example.invalid login robot password another-token account billing
        """
        let parsed = try DeveloperCredentialImporter.parse(contents: contents, fileName: ".netrc")
        #expect(parsed.format == .netrc)
        #expect(parsed.credentials.count == 2)

        let git = try #require(parsed.credentials.first { $0.title == "git.example.invalid" })
        #expect(git.fields.first { $0.key == "username" }?.value == "developer")
        let password = try #require(git.fields.first { $0.key == "password" })
        #expect(password.isSensitive)
        #expect(password.value == "s3cr3t-token-value")

        let api = try #require(parsed.credentials.first { $0.title == "api.example.invalid" })
        #expect(api.fields.first { $0.key == "account" }?.value == "billing")
    }

    /// `.netrc` is tokens, not lines: everything on one line is as valid as one entry per line.
    @Test func aNetrcWrittenOnOneLineParsesTheSame() throws {
        let parsed = try DeveloperCredentialImporter.parse(
            contents: "machine one.invalid login a password aaaaaaaa machine two.invalid login b password bbbbbbbb",
            fileName: ".netrc"
        )
        #expect(parsed.credentials.count == 2)
    }

    @Test func aDefaultNetrcEntryIsKept() throws {
        let parsed = try DeveloperCredentialImporter.parse(
            contents: "default login anyone password fallback-token\n",
            fileName: ".netrc"
        )
        #expect(parsed.credentials.first?.title == "default")
    }

    // MARK: - Docker

    @Test func decodesTheBase64DockerAuthIntoAUsernameAndPassword() throws {
        let auth = Data("robot:registry-token-value".utf8).base64EncodedString()
        let contents = """
        {"auths":{"registry.example.invalid":{"auth":"\(auth)","email":"ops@example.invalid"}}}
        """
        let parsed = try DeveloperCredentialImporter.parse(contents: contents, fileName: "config.json")
        #expect(parsed.format == .dockerConfig)

        let credential = try #require(parsed.credentials.first)
        #expect(credential.title == "Docker — registry.example.invalid")
        #expect(credential.fields.first { $0.key == "username" }?.value == "robot")
        let password = try #require(credential.fields.first { $0.key == "password" })
        #expect(password.value == "registry-token-value")
        #expect(password.isSensitive)
        // Worth saying out loud: base64 is not encryption.
        #expect(credential.notes.contains("not encryption"))
    }

    @Test func aRegistryEntryWithNoCredentialIsSkipped() throws {
        // A credential helper leaves the entry empty; there is nothing to import.
        #expect(throws: DeveloperCredentialImportError.nothingToImport(.dockerConfig)) {
            try DeveloperCredentialImporter.parse(
                contents: "{\"auths\":{\"registry.example.invalid\":{}},\"credsStore\":\"osxkeychain\"}",
                fileName: "config.json"
            )
        }
    }

    // MARK: - Bitwarden

    @Test func readsLoginsAndCustomFieldsFromABitwardenExport() throws {
        let contents = """
        {"encrypted":false,"items":[
          {"name":"Example Service","notes":"seat paid annually",
           "login":{"username":"someone@example.invalid","password":"correct-horse-battery",
                    "totp":"JBSWY3DPEHPK3PXP","uris":[{"uri":"https://example.invalid"}]},
           "fields":[{"name":"Recovery Code","value":"aaaa-bbbb","type":1},
                     {"name":"Account Number","value":"12345","type":0}]},
          {"name":"No Fields"}
        ]}
        """
        let parsed = try DeveloperCredentialImporter.parse(contents: contents, fileName: "bitwarden.json")
        #expect(parsed.format == .bitwardenExport)
        // The item with nothing in it is not worth creating.
        #expect(parsed.credentials.count == 1)

        let credential = try #require(parsed.credentials.first)
        #expect(credential.title == "Example Service")
        #expect(credential.type == .websiteService)
        #expect(credential.notes == "seat paid annually")
        #expect(credential.fields.first { $0.key == "url" }?.value == "https://example.invalid")

        // A hidden custom field stays hidden; a visible one stays visible.
        let recovery = try #require(credential.fields.first { $0.label == "Recovery Code" })
        #expect(recovery.isSensitive)
        #expect(recovery.key == "recovery_code")
        let accountNumber = try #require(credential.fields.first { $0.label == "Account Number" })
        #expect(!accountNumber.isSensitive)
    }

    /// Importing an encrypted export cannot work, and saying why beats reporting nothing found.
    @Test func anEncryptedBitwardenExportIsRefusedWithAReason() {
        #expect(throws: DeveloperCredentialImportError.encryptedExport) {
            try DeveloperCredentialImporter.parse(
                contents: "{\"encrypted\":true,\"data\":\"...\"}",
                fileName: "bitwarden.json"
            )
        }
    }

    // MARK: - The catch-alls

    /// A plain env-shaped file used to be a dead end here, which is the opposite of helpful when it
    /// is the commonest thing anybody has.
    @Test func anyFileOfAssignmentsIsImportedAsOneItem() throws {
        let parsed = try DeveloperCredentialImporter.parse(
            contents: """
            # staging
            API_KEY=abc123def456
            DB_HOST=db.example.invalid
            DB_PASSWORD=hunter2-and-then-some
            """,
            fileName: ".env.staging"
        )
        #expect(parsed.format == .dotenv)
        #expect(parsed.credentials.count == 1)

        let credential = try #require(parsed.credentials.first)
        #expect(credential.type == .envGroup)
        #expect(credential.fields.count == 3)
        // Sensitivity comes from the .env rules rather than a second opinion invented here.
        #expect(credential.fields.first { $0.key == "DB_PASSWORD" }?.isSensitive == true)
        #expect(credential.fields.first { $0.key == "DB_HOST" }?.isSensitive == false)
    }

    @Test func aJSONObjectOfNamesAndValuesIsImported() throws {
        let parsed = try DeveloperCredentialImporter.parse(
            contents: "{\"API_KEY\":\"abc123def456\",\"PORT\":8080,\"REGION\":\"eu-west-1\"}",
            fileName: "service.json"
        )
        #expect(parsed.format == .flatJSON)
        let credential = try #require(parsed.credentials.first)
        #expect(credential.fields.count == 3)
        #expect(credential.fields.first { $0.label == "API_KEY" }?.isSensitive == true)
        #expect(credential.fields.first { $0.label == "PORT" }?.value == "8080")
    }

    /// Guessing a name for `a.b[2].c` would be wrong often enough to be worse than declining.
    @Test func nestedJSONIsNotFlattenedIntoNonsense() {
        #expect(DeveloperCredentialImporter.flatJSONValues("{\"outer\":{\"inner\":\"x\"}}").isEmpty)
        #expect(
            DeveloperCredentialImporter.detectFormat(
                contents: "{\"outer\":{\"inner\":\"x\"}}",
                fileName: "nested.json"
            ) == nil
        )
    }

    /// The generic readers are the fallback: a file that is recognisably one of the named formats
    /// must never be read as a bag of key/value pairs.
    @Test func aRecognisedFormatIsNeverReadAsAGenericOne() throws {
        let aws = try DeveloperCredentialImporter.parse(
            contents: "[default]\naws_access_key_id = AKIAEXAMPLE0000000GG\n",
            fileName: "credentials"
        )
        #expect(aws.format == .awsCredentials)

        let docker = try DeveloperCredentialImporter.parse(
            contents: "{\"auths\":{\"r.invalid\":{\"username\":\"u\",\"password\":\"pp\"}}}",
            fileName: "config.json"
        )
        #expect(docker.format == .dockerConfig)
    }

    @Test func itemNamesComeFromTheFile() {
        #expect(DeveloperCredentialImporter.titleFromFileName(".env.staging", fallback: "x") == "env")
        #expect(DeveloperCredentialImporter.titleFromFileName("service.json", fallback: "x") == "service")
        #expect(DeveloperCredentialImporter.titleFromFileName("", fallback: "Fallback") == "Fallback")
    }

    @Test func everyFormatIsListedForTheInterface() {
        // A format nobody is told about might as well not be supported.
        #expect(DeveloperCredentialFormat.supportedSummary.count == DeveloperCredentialFormat.allCases.count)
    }

    @Test func labelsBecomeUsableStorageKeys() {
        #expect(DeveloperCredentialImporter.slug("Recovery Code") == "recovery_code")
        #expect(DeveloperCredentialImporter.slug("API  Key!!") == "api_key")
        #expect(DeveloperCredentialImporter.slug("???") == "field")
    }
}

@MainActor
struct DeveloperImportViewModelTests {

    @Test func confirmingCreatesOneItemPerCredentialInTheChosenWorkspace() throws {
        let container = AppContainer.preview()
        let viewModel = VaultViewModel(container: container)
        let workspace = try #require(container.workspaceRepository.fetchAll(includeArchived: false).first)

        let parsed = try DeveloperCredentialImporter.parse(
            contents: """
            [default]
            aws_access_key_id = AKIAEXAMPLE0000000FF
            aws_secret_access_key = exampleSECRETkeyEXAMPLEsecretKEY1234
            region = eu-north-1
            """,
            fileName: "credentials"
        )
        viewModel.pendingDeveloperImport = parsed.credentials
        viewModel.pendingDeveloperImportFormat = parsed.format
        viewModel.developerImportWorkspaceID = workspace.id

        viewModel.confirmDeveloperImport()

        let created = try #require(viewModel.items.first { $0.title == "AWS (default profile)" })
        #expect(created.workspace?.id == workspace.id)
        let fields = try container.itemRepository.resolveFields(for: created)
        #expect(fields.first { $0.key == "aws_secret_access_key" }?.isSensitive == true)
        #expect(fields.first { $0.key == "region" }?.isSensitive == false)

        // The pending state is cleared, so reopening the sheet cannot import the same file twice.
        #expect(viewModel.pendingDeveloperImport.isEmpty)
    }

    /// It writes to the vault in bulk, so it takes an undo step like every other action of that
    /// shape here.
    @Test func anImportCanBeUndone() throws {
        let container = AppContainer.preview()
        let viewModel = VaultViewModel(container: container)

        let parsed = try DeveloperCredentialImporter.parse(
            contents: "machine undo.example.invalid login someone password undo-me-token\n",
            fileName: ".netrc"
        )
        viewModel.pendingDeveloperImport = parsed.credentials
        viewModel.pendingDeveloperImportFormat = parsed.format
        viewModel.confirmDeveloperImport()
        #expect(viewModel.items.contains { $0.title == "undo.example.invalid" })

        #expect(viewModel.undoActionLabel != nil)
        viewModel.undoLastDestructiveAction()
        #expect(!viewModel.items.contains { $0.title == "undo.example.invalid" })
    }
}
