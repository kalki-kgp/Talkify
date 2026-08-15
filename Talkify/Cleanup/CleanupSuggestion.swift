import Foundation

/// Something Talkify noticed and is proposing. Nothing here is in effect: a
/// suggestion changes how dictation is written only once the person accepts it.
///
/// Two kinds, because a correction is usually one of two things. Respelling a
/// word — "talk if I" becoming "Talkify" — is a Vocabulary problem and belongs
/// to the recognizer. Everything else is style.
enum CleanupSuggestionKind: String, Codable, Equatable, Sendable {
  case styleRule
  case vocabularyTerm
}

struct CleanupSuggestion: Codable, Equatable, Hashable, Identifiable, Sendable {
  var kind: CleanupSuggestionKind
  var text: String
  /// The application the corrections came from, for a style rule that only
  /// showed up in one place. Vocabulary terms are never scoped: a name is
  /// spelled the same way wherever it is said.
  var bundleIdentifier: String?
  var applicationName: String?

  init(
    kind: CleanupSuggestionKind,
    text: String,
    bundleIdentifier: String? = nil,
    applicationName: String? = nil
  ) {
    self.kind = kind
    self.text = text
    self.bundleIdentifier = kind == .vocabularyTerm ? nil : bundleIdentifier
    self.applicationName = kind == .vocabularyTerm ? nil : applicationName
  }

  var id: String {
    "\(kind.rawValue)|\(bundleIdentifier ?? "")|\(CleanupSuggestions.foldedKey(for: text))"
  }

  var scope: StyleRuleScope {
    guard let bundleIdentifier else { return .everywhere }
    return .application(
      bundleIdentifier: bundleIdentifier,
      name: applicationName ?? bundleIdentifier
    )
  }
}

struct CleanupSuggestionDocument: Codable, Equatable, Sendable {
  static let currentVersion = 1

  var version: Int
  var pending: [CleanupSuggestion]
  /// The ids of suggestions that were turned down. Kept so a habit the person
  /// has already declined does not come back every time the buffer fills —
  /// a review queue that repeats itself is one people stop opening.
  var declined: [String]

  init(
    version: Int = currentVersion,
    pending: [CleanupSuggestion] = [],
    declined: [String] = []
  ) {
    self.version = version
    self.pending = pending
    self.declined = declined
  }
}

/// The pure rules for the review queue: what a suggestion is worth showing,
/// and what to do with the ones already answered.
enum CleanupSuggestions {
  /// A queue longer than this is a chore rather than a review.
  static let maximumPendingCount = 12
  static let maximumDeclinedCount = 200

  static func foldedKey(for text: String) -> String {
    StyleRules.normalize(text).lowercased()
  }

  /// The suggestions worth adding to the queue: normalized, deduplicated
  /// against each other and what is already pending, stripped of anything
  /// already declined or already in effect, and cut to the cap.
  static func admissible(
    _ candidates: [CleanupSuggestion],
    pending: [CleanupSuggestion],
    declined: Set<String>,
    existingRuleIDs: Set<String>,
    existingTermKeys: Set<String>
  ) -> [CleanupSuggestion] {
    var seen = Set(pending.map(\.id))
    var admitted: [CleanupSuggestion] = []

    for candidate in candidates {
      let text = StyleRules.normalize(candidate.text)
      guard !text.isEmpty, text.count <= StyleRules.maximumRuleLength else { continue }

      var normalized = candidate
      normalized.text = text
      guard !declined.contains(normalized.id) else { continue }
      guard seen.insert(normalized.id).inserted else { continue }

      switch normalized.kind {
      case .styleRule:
        let rule = StyleRule(
          text: text,
          bundleIdentifier: normalized.bundleIdentifier,
          applicationName: normalized.applicationName,
          source: .learned
        )
        guard !existingRuleIDs.contains(rule.id) else { continue }
      case .vocabularyTerm:
        guard text.count <= Vocabulary.maximumTermLength else { continue }
        guard !existingTermKeys.contains(Vocabulary.foldedKey(for: text)) else { continue }
      }

      admitted.append(normalized)
      if pending.count + admitted.count == maximumPendingCount { break }
    }

    return admitted
  }

  static func trimmedDeclined(_ declined: [String]) -> [String] {
    guard declined.count > maximumDeclinedCount else { return declined }
    return Array(declined.suffix(maximumDeclinedCount))
  }

  /// The rule an accepted style suggestion becomes. Marked `.learned`, so the
  /// list can say where it came from.
  static func rule(for suggestion: CleanupSuggestion) -> StyleRule {
    StyleRule(
      text: suggestion.text,
      bundleIdentifier: suggestion.bundleIdentifier,
      applicationName: suggestion.applicationName,
      source: .learned
    )
  }
}
