import Foundation
import Observation

/// The review queue as the app holds it: an observable list over the store, in
/// the shape `VocabularyList` and `StyleRuleList` already established.
///
/// Accepting is the only way a suggestion takes effect, and it takes effect
/// through the ordinary door — a style rule goes through `StyleRuleStore`, a
/// term through `VocabularyStore` — so every existing rule, cap and refusal
/// applies to a learned entry exactly as it does to a typed one. In particular,
/// the Vocabulary stays a list the person authored: Talkify proposes, they add.
@MainActor
@Observable
final class CleanupSuggestionQueue {
  private let store: CleanupSuggestionStore
  private let styleRules: StyleRuleList
  private let vocabulary: VocabularyList

  private(set) var pending: [CleanupSuggestion] = []
  private(set) var errorMessage: String?

  @ObservationIgnored
  private var appliedRevision = -1

  init(
    store: CleanupSuggestionStore = CleanupSuggestionStore(),
    styleRules: StyleRuleList,
    vocabulary: VocabularyList
  ) {
    self.store = store
    self.styleRules = styleRules
    self.vocabulary = vocabulary
  }

  var count: Int { pending.count }

  func load() async {
    do {
      apply(try await store.load())
      errorMessage = nil
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  /// Files what distillation proposed, minus anything already declined,
  /// already pending, or already in effect.
  func enqueue(_ candidates: [CleanupSuggestion]) async {
    do {
      let admissible = CleanupSuggestions.admissible(
        candidates,
        pending: pending,
        declined: try await store.declinedIDs(),
        existingRuleIDs: Set(styleRules.rules.map(\.id)),
        existingTermKeys: Set(vocabulary.terms.map(\.id))
      )
      guard !admissible.isEmpty else { return }
      apply(try await store.enqueue(admissible))
      errorMessage = nil
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  @discardableResult
  func accept(_ suggestion: CleanupSuggestion) async -> Bool {
    let applied: Bool
    switch suggestion.kind {
    case .styleRule:
      applied = await styleRules.add(
        suggestion.text,
        scope: suggestion.scope,
        source: .learned
      )
    case .vocabularyTerm:
      applied = await vocabulary.add(suggestion.text)
    }

    // A suggestion the ordinary rules refused — a full list, a duplicate —
    // stays in the queue rather than vanishing as if it had been applied.
    guard applied else { return false }

    do {
      apply(try await store.accept(suggestion))
      errorMessage = nil
      return true
    } catch {
      errorMessage = error.localizedDescription
      return false
    }
  }

  func decline(_ suggestion: CleanupSuggestion) async {
    do {
      apply(try await store.decline(suggestion))
      errorMessage = nil
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func clear() async {
    do {
      apply(try await store.clearPending())
      errorMessage = nil
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  private func apply(_ result: CleanupSuggestionRevision) {
    guard result.revision >= appliedRevision else { return }
    appliedRevision = result.revision
    pending = result.pending
  }
}
