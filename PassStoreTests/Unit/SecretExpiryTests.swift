import Foundation
import Testing
@testable import PassStore

/// An API key with a lifetime, a certificate, a rotation deadline: the things that stop working on
/// a date somebody else chose. The vault knows the date, so it should be the one to say so — and it
/// should say it once, early enough to act on, and then stop being asked.
@MainActor
struct SecretExpiryTests {

    private func draft(_ title: String, expiresAt: Date? = nil) -> SecretItemDraft {
        var draft = SecretItemDraft.empty
        draft.title = title
        draft.expiresAt = expiresAt
        draft.fieldDrafts = [
            FieldDraft(
                key: "token",
                label: "Token",
                // Unique per item: a shared value would be reported as reuse and confuse every
                // assertion here about what the report contains.
                value: "Zx9-\(title)-unguessable-value",
                kind: .secret,
                isSensitive: true,
                isMasked: true,
                sortOrder: 0
            )
        ]
        return draft
    }

    private func date(daysFromNow days: Int) -> Date {
        Calendar.current.date(byAdding: .day, value: days, to: Date())!
    }

    // MARK: - State

    @Test func anItemWithNoExpiryHasNothingToSay() throws {
        let container = AppContainer.preview()
        let item = try container.itemRepository.saveItem(draft("No Expiry"))
        #expect(item.expiryState == .none)
        #expect(!item.expiryState.needsAttention)
    }

    @Test func anExpiryFarAwayIsRecordedButNotRaised() throws {
        let container = AppContainer.preview()
        let expiry = date(daysFromNow: 200)
        let item = try container.itemRepository.saveItem(draft("Later", expiresAt: expiry))
        #expect(item.expiryState == .current(expiry))
        #expect(!item.expiryState.needsAttention)
    }

    @Test func anExpiryInsideTheWarningWindowIsRaised() throws {
        let container = AppContainer.preview()
        let expiry = date(daysFromNow: 10)
        let item = try container.itemRepository.saveItem(draft("Soon", expiresAt: expiry))
        #expect(item.expiryState == .expiring(expiry))
        #expect(item.expiryState.needsAttention)
    }

    @Test func aPastExpiryReadsAsExpired() throws {
        let container = AppContainer.preview()
        let expiry = date(daysFromNow: -3)
        let item = try container.itemRepository.saveItem(draft("Gone", expiresAt: expiry))
        #expect(item.expiryState == .expired(expiry))
        #expect(item.expiryState.needsAttention)
    }

    // MARK: - The health report

    @Test func theReportListsExpiredAndExpiringSecrets() {
        let container = AppContainer.preview()
        let viewModel = VaultViewModel(container: container)
        viewModel.saveItem(draft("Dead Key", expiresAt: date(daysFromNow: -1)))
        viewModel.saveItem(draft("Nearly Dead Key", expiresAt: date(daysFromNow: 5)))
        viewModel.saveItem(draft("Healthy Key", expiresAt: date(daysFromNow: 300)))

        let report = viewModel.vaultHealthReport()
        #expect(report.findings.contains { $0.itemTitle == "Dead Key" && $0.kind == .expired })
        #expect(report.findings.contains { $0.itemTitle == "Nearly Dead Key" && $0.kind == .expiring })
        #expect(!report.findings.contains { $0.itemTitle == "Healthy Key" })
    }

    /// An expired credential has already stopped working. Everything else in the report is a
    /// judgement about how good a secret is; this one is a fact, so it goes first.
    @Test func expiredSortsAboveEverythingElse() {
        let container = AppContainer.preview()
        let viewModel = VaultViewModel(container: container)

        var weak = draft("Weak One")
        weak.fieldDrafts[0].value = "abc"
        viewModel.saveItem(weak)
        viewModel.saveItem(draft("Expired One", expiresAt: date(daysFromNow: -2)))

        let findings = viewModel.vaultHealthReport().findings
        let expiredIndex = findings.firstIndex { $0.kind == .expired }
        let weakIndex = findings.firstIndex { $0.kind == .weak }
        #expect(expiredIndex != nil)
        #expect(weakIndex != nil)
        if let expiredIndex, let weakIndex { #expect(expiredIndex < weakIndex) }
    }

    /// An item that states when it expires is already tracked by a date its owner chose. Telling
    /// them it is also "not updated in a while" adds nothing.
    @Test func anItemWithAnExpiryIsNotAlsoReportedAsStale() throws {
        let container = AppContainer.preview()
        let viewModel = VaultViewModel(container: container)

        var old = draft("Ancient")
        old.expiresAt = date(daysFromNow: 400)
        viewModel.saveItem(old)

        // Backdate it well past the staleness cutoff.
        let item = try #require(viewModel.items.first { $0.title == "Ancient" })
        item.updatedAt = Calendar.current.date(byAdding: .year, value: -3, to: Date())!

        let report = viewModel.vaultHealthReport()
        #expect(!report.findings.contains { $0.itemTitle == "Ancient" && $0.kind == .stale })
    }

    // MARK: - Dismissing

    @Test func anExpiryWarningCanBeDismissedAndStaysDismissedAcrossAnEdit() throws {
        let container = AppContainer.preview()
        let viewModel = VaultViewModel(container: container)
        let expiry = date(daysFromNow: 7)
        viewModel.saveItem(draft("Acknowledged", expiresAt: expiry))

        let finding = try #require(
            viewModel.vaultHealthReport().findings.first { $0.itemTitle == "Acknowledged" && $0.kind == .expiring }
        )
        viewModel.ignoreHealthFinding(finding)
        #expect(!viewModel.vaultHealthReport().findings.contains { $0.id == finding.id })

        // An unrelated edit must not bring the dismissed warning back — that is the difference
        // between this and a staleness dismissal, which an edit does invalidate.
        let item = try #require(viewModel.items.first { $0.title == "Acknowledged" })
        var edit = draft("Acknowledged", expiresAt: expiry)
        edit.id = item.id
        edit.notes = "Raised a ticket for this"
        viewModel.saveItem(edit)

        #expect(!viewModel.vaultHealthReport().findings.contains { $0.kind == .expiring && $0.itemTitle == "Acknowledged" })
    }

    /// Moving the date is a new fact about the credential, so the old acknowledgement expires
    /// with it.
    @Test func movingTheExpiryRevivesADismissedWarning() throws {
        let container = AppContainer.preview()
        let viewModel = VaultViewModel(container: container)
        viewModel.saveItem(draft("Rotated", expiresAt: date(daysFromNow: 7)))

        let finding = try #require(
            viewModel.vaultHealthReport().findings.first { $0.itemTitle == "Rotated" && $0.kind == .expiring }
        )
        viewModel.ignoreHealthFinding(finding)
        #expect(!viewModel.vaultHealthReport().findings.contains { $0.kind == .expiring })

        let item = try #require(viewModel.items.first { $0.title == "Rotated" })
        var edit = draft("Rotated", expiresAt: date(daysFromNow: 3))
        edit.id = item.id
        viewModel.saveItem(edit)

        #expect(viewModel.vaultHealthReport().findings.contains { $0.kind == .expiring && $0.itemTitle == "Rotated" })
    }

    @Test func clearingTheExpiryRemovesTheFindingAndItsDismissal() throws {
        let container = AppContainer.preview()
        let viewModel = VaultViewModel(container: container)
        viewModel.saveItem(draft("Cleared", expiresAt: date(daysFromNow: 4)))

        let finding = try #require(
            viewModel.vaultHealthReport().findings.first { $0.kind == .expiring }
        )
        viewModel.ignoreHealthFinding(finding)

        let item = try #require(viewModel.items.first { $0.title == "Cleared" })
        var edit = draft("Cleared", expiresAt: nil)
        edit.id = item.id
        viewModel.saveItem(edit)

        let refreshed = try #require(viewModel.items.first { $0.title == "Cleared" })
        #expect(refreshed.expiresAt == nil)
        #expect(refreshed.ignoredHealthIssues.isEmpty)
        #expect(!viewModel.vaultHealthReport().findings.contains { $0.kind == .expiring })
    }

    // MARK: - Persistence and history

    @Test func theExpirySurvivesASnapshotRoundTrip() throws {
        let container = AppContainer.preview()
        let expiry = Calendar.current.startOfDay(for: date(daysFromNow: 45))
        _ = try container.itemRepository.saveItem(draft("Round Trip", expiresAt: expiry))

        let encoded = try JSONEncoder().encode(container.memoryStore.makeSnapshot())
        let decoded = try JSONDecoder().decode(VaultSnapshot.self, from: encoded)

        let item = try #require(decoded.items.first { $0.title == "Round Trip" })
        let stored = try #require(item.expiresAt)
        #expect(abs(stored.timeIntervalSince(expiry)) < 1)
    }

    /// A vault written before expiry existed has no such key, and must still decode.
    @Test func anItemFromAnEarlierVaultHasNoExpiry() throws {
        let container = AppContainer.preview()
        _ = try container.itemRepository.saveItem(draft("Legacy"))

        var json = try JSONSerialization.jsonObject(
            with: try JSONEncoder().encode(container.memoryStore.makeSnapshot())
        ) as! [String: Any]
        var items = json["items"] as! [[String: Any]]
        items = items.map { item in
            var item = item
            item.removeValue(forKey: "expiresAt")
            return item
        }
        json["items"] = items

        let stripped = try JSONSerialization.data(withJSONObject: json)
        let decoded = try JSONDecoder().decode(VaultSnapshot.self, from: stripped)
        #expect(decoded.items.allSatisfy { $0.expiresAt == nil })
    }

    @Test func settingAnExpiryIsRecordedInTheAuditTrail() throws {
        let container = AppContainer.preview()
        let saved = try container.itemRepository.saveItem(draft("Audited"))

        var edit = draft("Audited", expiresAt: date(daysFromNow: 30))
        edit.id = saved.id
        let updated = try container.itemRepository.saveItem(edit)

        #expect(updated.changeHistory.contains { $0.kind == .expiryChanged })
        // A date is not a secret, so the trail may name it — and it should, so the log is readable.
        let entry = try #require(updated.changeHistory.first { $0.kind == .expiryChanged })
        #expect(entry.detail?.isEmpty == false)
    }

    @Test func aDuplicateInheritsTheExpiry() throws {
        let container = AppContainer.preview()
        let expiry = date(daysFromNow: 20)
        let original = try container.itemRepository.saveItem(draft("Original", expiresAt: expiry))

        let copy = try container.itemRepository.duplicateItem(original)
        let stored = try #require(copy.expiresAt)
        #expect(abs(stored.timeIntervalSince(expiry)) < 1)
    }

    @Test func anArchivedItemIsNotReportedAsExpired() throws {
        let container = AppContainer.preview()
        let viewModel = VaultViewModel(container: container)
        var archived = draft("Archived Key", expiresAt: date(daysFromNow: -10))
        archived.isArchived = true
        viewModel.saveItem(archived)

        #expect(!viewModel.vaultHealthReport().findings.contains { $0.itemTitle == "Archived Key" })
    }
}
