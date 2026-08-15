import Foundation
import Testing
@testable import Talkify

struct CleanupSuggestionTests {
  private let slack = "com.tinyspeck.slackmacgap"

  private func admissible(
    _ candidates: [CleanupSuggestion],
    pending: [CleanupSuggestion] = [],
    declined: Set<String> = [],
    existingRuleIDs: Set<String> = [],
    existingTermKeys: Set<String> = []
  ) -> [CleanupSuggestion] {
    CleanupSuggestions.admissible(
      candidates,
      pending: pending,
      declined: declined,
      existingRuleIDs: existingRuleIDs,
      existingTermKeys: existingTermKeys
    )
  }

  @Test func normalizesAndDropsEmptyOrOversizedText() {
    let candidates = [
      CleanupSuggestion(kind: .styleRule, text: "  keep  it casual "),
      CleanupSuggestion(kind: .styleRule, text: "   "),
      CleanupSuggestion(
        kind: .styleRule,
        text: String(repeating: "a", count: StyleRules.maximumRuleLength + 1)
      ),
    ]
    #expect(admissible(candidates).map(\.text) == ["keep it casual"])
  }

  /// A term long enough for a style rule is still too long to spend one of the
  /// hundred contextual phrases on.
  @Test func holdsVocabularyTermsToTheVocabularyLimit() {
    let long = String(repeating: "a", count: Vocabulary.maximumTermLength + 1)
    #expect(admissible([CleanupSuggestion(kind: .vocabularyTerm, text: long)]).isEmpty)
    #expect(admissible([CleanupSuggestion(kind: .styleRule, text: long)]).count == 1)
  }

  @Test func dropsWhatIsAlreadyPending() {
    let pending = [CleanupSuggestion(kind: .styleRule, text: "keep it casual")]
    #expect(admissible(
      [CleanupSuggestion(kind: .styleRule, text: "Keep It Casual")],
      pending: pending
    ).isEmpty)
  }

  /// A review queue that keeps asking about something already turned down is
  /// one people stop opening.
  @Test func dropsWhatWasAlreadyDeclined() {
    let suggestion = CleanupSuggestion(kind: .styleRule, text: "keep it casual")
    #expect(admissible([suggestion], declined: [suggestion.id]).isEmpty)
  }

  @Test func dropsWhatIsAlreadyInEffect() {
    let rule = StyleRule(text: "keep it casual", source: .learned)
    #expect(admissible(
      [CleanupSuggestion(kind: .styleRule, text: "Keep it casual")],
      existingRuleIDs: [rule.id]
    ).isEmpty)

    #expect(admissible(
      [CleanupSuggestion(kind: .vocabularyTerm, text: "Talkify")],
      existingTermKeys: [Vocabulary.foldedKey(for: "talkify")]
    ).isEmpty)
  }

  /// The same sentence for two different apps is two suggestions; the same
  /// sentence twice for one app is one.
  @Test func scopeIsPartOfASuggestionsIdentity() {
    let candidates = [
      CleanupSuggestion(kind: .styleRule, text: "no greeting"),
      CleanupSuggestion(kind: .styleRule, text: "no greeting", bundleIdentifier: slack),
      CleanupSuggestion(kind: .styleRule, text: "No Greeting", bundleIdentifier: slack),
    ]
    #expect(admissible(candidates).count == 2)
  }

  /// A name is spelled the same way wherever it is said, so a term never
  /// carries a scope even if one was handed in.
  @Test func vocabularyTermsAreNeverScoped() {
    let term = CleanupSuggestion(
      kind: .vocabularyTerm,
      text: "Talkify",
      bundleIdentifier: slack,
      applicationName: "Slack"
    )
    #expect(term.bundleIdentifier == nil)
    #expect(term.scope == .everywhere)
  }

  @Test func stopsAtTheQueueCap() {
    let candidates = (0..<(CleanupSuggestions.maximumPendingCount + 5)).map {
      CleanupSuggestion(kind: .styleRule, text: "rule number \($0)")
    }
    #expect(admissible(candidates).count == CleanupSuggestions.maximumPendingCount)

    let pending = [CleanupSuggestion(kind: .styleRule, text: "already here")]
    #expect(
      admissible(candidates, pending: pending).count
        == CleanupSuggestions.maximumPendingCount - 1
    )
  }

  @Test func declinedIDsAreTrimmedToACeiling() {
    let ids = (0..<(CleanupSuggestions.maximumDeclinedCount + 10)).map { "id-\($0)" }
    let trimmed = CleanupSuggestions.trimmedDeclined(ids)
    #expect(trimmed.count == CleanupSuggestions.maximumDeclinedCount)
    // The oldest go, so a recent decline is the one that keeps working.
    #expect(trimmed.last == ids.last)
  }

  @Test func anAcceptedSuggestionBecomesALearnedRule() {
    let suggestion = CleanupSuggestion(
      kind: .styleRule,
      text: "no greeting",
      bundleIdentifier: slack,
      applicationName: "Slack"
    )
    let rule = CleanupSuggestions.rule(for: suggestion)
    #expect(rule.text == "no greeting")
    #expect(rule.source == .learned)
    #expect(rule.scope == .application(bundleIdentifier: slack, name: "Slack"))
  }
}

struct CleanupSuggestionStoreTests {
  private func temporaryURL() -> URL {
    FileManager.default.temporaryDirectory
      .appending(path: "TalkifyCleanupSuggestionTests-\(UUID().uuidString).json")
  }

  @Test func returnsAnEmptyQueueBeforeAnythingIsSaved() async throws {
    let store = CleanupSuggestionStore(fileURL: temporaryURL())
    #expect(try await store.load().pending.isEmpty)
    #expect(try await store.declinedIDs().isEmpty)
  }

  @Test func enqueuedSuggestionsSurviveARelaunch() async throws {
    let url = temporaryURL()
    defer { try? FileManager.default.removeItem(at: url) }

    let store = CleanupSuggestionStore(fileURL: url)
    try await store.enqueue([
      CleanupSuggestion(kind: .styleRule, text: "keep it casual"),
      CleanupSuggestion(kind: .vocabularyTerm, text: "Talkify"),
    ])

    let reloaded = try await CleanupSuggestionStore(fileURL: url).load()
    #expect(reloaded.pending.map(\.text) == ["keep it casual", "Talkify"])
  }

  /// Accepting does not decline: the rule or term itself is now what keeps the
  /// suggestion from coming back.
  @Test func acceptingRemovesWithoutDeclining() async throws {
    let url = temporaryURL()
    defer { try? FileManager.default.removeItem(at: url) }
    let store = CleanupSuggestionStore(fileURL: url)
    let suggestion = CleanupSuggestion(kind: .styleRule, text: "keep it casual")

    try await store.enqueue([suggestion])
    let result = try await store.accept(suggestion)
    #expect(result.pending.isEmpty)
    #expect(try await store.declinedIDs().isEmpty)
  }

  @Test func decliningRemembersItAcrossRelaunches() async throws {
    let url = temporaryURL()
    defer { try? FileManager.default.removeItem(at: url) }
    let store = CleanupSuggestionStore(fileURL: url)
    let suggestion = CleanupSuggestion(kind: .styleRule, text: "keep it casual")

    try await store.enqueue([suggestion])
    let result = try await store.decline(suggestion)
    #expect(result.pending.isEmpty)

    let reloaded = CleanupSuggestionStore(fileURL: url)
    #expect(try await reloaded.declinedIDs() == [suggestion.id])
  }

  @Test func everyMutationAdvancesTheRevision() async throws {
    let url = temporaryURL()
    defer { try? FileManager.default.removeItem(at: url) }
    let store = CleanupSuggestionStore(fileURL: url)
    let suggestion = CleanupSuggestion(kind: .styleRule, text: "keep it casual")

    let first = try await store.enqueue([suggestion])
    let second = try await store.decline(suggestion)
    #expect(second.revision > first.revision)
  }

  @Test func rejectsADocumentFromAFutureVersion() async throws {
    let url = temporaryURL()
    defer { try? FileManager.default.removeItem(at: url) }
    try Data(#"{"version":99,"pending":[],"declined":[]}"#.utf8).write(to: url)

    await #expect(throws: CleanupSuggestionStoreError.self) {
      _ = try await CleanupSuggestionStore(fileURL: url).load()
    }
  }

  @Test func canonicalizesADocumentWrittenUnderDifferentRules() async throws {
    let url = temporaryURL()
    defer { try? FileManager.default.removeItem(at: url) }
    let document = #"""
      {"version":1,"declined":[],"pending":[
        {"kind":"styleRule","text":"  keep  it casual "},
        {"kind":"styleRule","text":"KEEP IT CASUAL"}
      ]}
      """#
    try Data(document.utf8).write(to: url)

    let loaded = try await CleanupSuggestionStore(fileURL: url).load()
    #expect(loaded.pending.map(\.text) == ["keep it casual"])
  }

  /// The queue holds derived sentences and ids. The correction pairs behind
  /// them were never written anywhere.
  @Test func storesOnlySuggestionsAndDeclinedIDs() async throws {
    let url = temporaryURL()
    defer { try? FileManager.default.removeItem(at: url) }
    let store = CleanupSuggestionStore(fileURL: url)
    try await store.enqueue([CleanupSuggestion(kind: .styleRule, text: "keep it casual")])

    let json = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
    let object = try #require(json as? [String: Any])
    #expect(Set(object.keys) == ["version", "pending", "declined"])

    let pending = try #require(object["pending"] as? [[String: Any]])
    #expect(Set(pending[0].keys) == ["kind", "text"])
  }
}
