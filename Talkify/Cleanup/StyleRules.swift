import Foundation

/// The pure half of style: normalizing what was typed, the rules for what may
/// join the list, and the projection the cleanup pass consumes. Value
/// transformations only, so `StyleRuleTests` covers them without touching disk
/// or the model.
enum StyleRules {
  /// Every rule in scope is prompt text on the path the deadline is racing, so
  /// the caps here are latency budgets rather than storage limits. A rule needs
  /// to be a sentence, not a policy document.
  static let maximumRuleLength = 200
  static let maximumRulesPerScope = 12
  static let maximumRuleCount = 60

  static func normalize(_ raw: String) -> String {
    raw
      .components(separatedBy: .whitespacesAndNewlines)
      .filter { !$0.isEmpty }
      .joined(separator: " ")
  }

  /// Case-insensitive, like Vocabulary terms: "prefer OK over okay" and
  /// "Prefer ok over Okay" are one instruction, and keeping both would spend a
  /// slot and contradict nothing.
  static func foldedKey(for text: String) -> String {
    normalize(text).lowercased()
  }

  static func adding(
    _ raw: String,
    scope: StyleRuleScope,
    source: StyleRuleSource = .user,
    to rules: [StyleRule]
  ) -> StyleRuleAddOutcome {
    let text = normalize(raw)

    guard !text.isEmpty else { return .rejected(.empty) }
    guard text.count <= maximumRuleLength else { return .rejected(.tooLong) }

    let candidate = StyleRule(
      text: text,
      bundleIdentifier: scope.bundleIdentifier,
      applicationName: applicationName(for: scope),
      source: source
    )
    guard !rules.contains(where: { $0.id == candidate.id }) else {
      return .rejected(.duplicate)
    }
    guard rules.count < maximumRuleCount else { return .rejected(.full) }
    guard inScope(rules, of: scope).count < maximumRulesPerScope else {
      return .rejected(.scopeFull)
    }

    // Newest first, for the same reason Vocabulary terms are: seeing what you
    // just typed appear is the confirmation that it worked.
    return .added([candidate] + rules)
  }

  static func removing(_ rule: StyleRule, from rules: [StyleRule]) -> [StyleRule] {
    rules.filter { $0.id != rule.id }
  }

  /// The list with every rule applied, run over whatever the store decodes
  /// rather than trusting the file: folded duplicates would give the section
  /// repeated `ForEach` identifiers, and removing either would take both.
  static func canonical(_ rules: [StyleRule]) -> [StyleRule] {
    var seen = Set<String>()
    var perScope: [String: Int] = [:]
    var canonical: [StyleRule] = []

    for rule in rules {
      let text = normalize(rule.text)
      guard !text.isEmpty, text.count <= maximumRuleLength else { continue }

      var normalized = rule
      normalized.text = text
      guard seen.insert(normalized.id).inserted else { continue }

      let scopeKey = normalized.bundleIdentifier ?? ""
      let count = perScope[scopeKey, default: 0]
      guard count < maximumRulesPerScope else { continue }
      perScope[scopeKey] = count + 1

      canonical.append(normalized)
      if canonical.count == maximumRuleCount { break }
    }

    return canonical
  }

  static func inScope(_ rules: [StyleRule], of scope: StyleRuleScope) -> [StyleRule] {
    rules.filter { $0.bundleIdentifier == scope.bundleIdentifier }
  }

  /// The rules that always apply. These ride in the model session's standing
  /// instructions, so they are already in a prewarmed session.
  static func globalText(in rules: [StyleRule]) -> [String] {
    canonical(rules).filter { $0.bundleIdentifier == nil }.map(\.text)
  }

  /// The rules for the application about to receive the text. These ride in
  /// the prompt rather than the instructions: the target changes from one
  /// dictation to the next, and rebuilding the session for each app would
  /// throw away the prewarm that keeps cleanup inside its deadline.
  static func applicationText(in rules: [StyleRule], bundleIdentifier: String?) -> [String] {
    guard let bundleIdentifier else { return [] }
    return canonical(rules)
      .filter { $0.bundleIdentifier == bundleIdentifier }
      .map(\.text)
  }

  /// Every scope that has at least one rule, global first and the rest by
  /// name, which is the order the section renders.
  static func scopes(in rules: [StyleRule]) -> [StyleRuleScope] {
    var seen = Set<String>()
    var applications: [StyleRuleScope] = []
    var hasGlobal = false

    for rule in canonical(rules) {
      switch rule.scope {
      case .everywhere:
        hasGlobal = true
      case let .application(bundleIdentifier, _):
        guard seen.insert(bundleIdentifier).inserted else { continue }
        applications.append(rule.scope)
      }
    }

    applications.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    return (hasGlobal ? [.everywhere] : []) + applications
  }

  private static func applicationName(for scope: StyleRuleScope) -> String? {
    switch scope {
    case .everywhere: nil
    case let .application(_, name): name
    }
  }
}
