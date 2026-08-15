import Foundation
import Testing
@testable import Talkify

struct StyleRulesTests {
  private let slack = StyleRuleScope.application(
    bundleIdentifier: "com.tinyspeck.slackmacgap",
    name: "Slack"
  )
  private let mail = StyleRuleScope.application(
    bundleIdentifier: "com.apple.mail",
    name: "Mail"
  )

  private func added(_ raw: String, scope: StyleRuleScope, to rules: [StyleRule]) -> [StyleRule] {
    guard case let .added(result) = StyleRules.adding(raw, scope: scope, to: rules) else {
      Issue.record("expected \(raw) to be added")
      return rules
    }
    return result
  }

  @Test func normalizeTrimsAndCollapsesWhitespace() {
    #expect(StyleRules.normalize("  keep   it  casual ") == "keep it casual")
    #expect(StyleRules.normalize("   ").isEmpty)
    #expect(StyleRules.normalize("no\ngreeting") == "no greeting")
  }

  @Test func newRulesGoOnTop() {
    var rules = added("keep it casual", scope: .everywhere, to: [])
    rules = added("prefer OK over okay", scope: .everywhere, to: rules)
    #expect(rules.map(\.text) == ["prefer OK over okay", "keep it casual"])
  }

  @Test func rejectsEmptyAndOversizedRules() {
    #expect(StyleRules.adding("   ", scope: .everywhere, to: []) == .rejected(.empty))
    let long = String(repeating: "a", count: StyleRules.maximumRuleLength + 1)
    #expect(StyleRules.adding(long, scope: .everywhere, to: []) == .rejected(.tooLong))
  }

  /// The same sentence is one rule however it was capitalized, matching how
  /// Vocabulary terms fold.
  @Test func rejectsADuplicateInTheSameScope() {
    let rules = added("keep it casual", scope: .everywhere, to: [])
    #expect(StyleRules.adding("Keep It Casual", scope: .everywhere, to: rules) == .rejected(.duplicate))
  }

  /// The same sentence in two apps is two rules: scope is part of identity.
  @Test func allowsTheSameRuleInDifferentScopes() {
    var rules = added("keep it casual", scope: .everywhere, to: [])
    rules = added("keep it casual", scope: slack, to: rules)
    rules = added("keep it casual", scope: mail, to: rules)
    #expect(rules.count == 3)
    #expect(Set(rules.map(\.id)).count == 3)
  }

  @Test func rejectsOnceAScopeIsFull() {
    var rules: [StyleRule] = []
    for index in 0..<StyleRules.maximumRulesPerScope {
      rules = added("rule number \(index)", scope: slack, to: rules)
    }
    #expect(StyleRules.adding("one more", scope: slack, to: rules) == .rejected(.scopeFull))
    // A different scope still has room — the cap is per scope, not global.
    #expect(StyleRules.adding("one more", scope: .everywhere, to: rules) != .rejected(.scopeFull))
  }

  @Test func removalMatchesOnScopeAndFoldedText() {
    var rules = added("keep it casual", scope: .everywhere, to: [])
    rules = added("keep it casual", scope: slack, to: rules)
    let global = try! #require(rules.first { $0.bundleIdentifier == nil })

    let remaining = StyleRules.removing(global, from: rules)
    #expect(remaining.count == 1)
    #expect(remaining[0].bundleIdentifier == "com.tinyspeck.slackmacgap")
  }

  /// Run over whatever the file holds rather than trusting it: two folded
  /// duplicates would give the section repeated ForEach identifiers, and
  /// removing either would take both.
  @Test func canonicalRepairsADocumentWrittenUnderDifferentRules() {
    let rules = [
      StyleRule(text: "  keep  it casual "),
      StyleRule(text: "Keep It Casual"),
      StyleRule(text: "   "),
      StyleRule(text: String(repeating: "a", count: StyleRules.maximumRuleLength + 1)),
      StyleRule(text: "no greeting", bundleIdentifier: "com.apple.mail", applicationName: "Mail"),
    ]
    let canonical = StyleRules.canonical(rules)
    #expect(canonical.map(\.text) == ["keep it casual", "no greeting"])
    #expect(Set(canonical.map(\.id)).count == canonical.count)
  }

  @Test func canonicalEnforcesThePerScopeCap() {
    let rules = (0..<(StyleRules.maximumRulesPerScope + 5)).map {
      StyleRule(text: "rule number \($0)", bundleIdentifier: "com.apple.mail")
    }
    #expect(StyleRules.canonical(rules).count == StyleRules.maximumRulesPerScope)
  }

  @Test func globalAndApplicationRulesAreSelectedSeparately() {
    var rules = added("keep it casual", scope: .everywhere, to: [])
    rules = added("no greeting", scope: slack, to: rules)
    rules = added("sign off with thanks", scope: mail, to: rules)

    #expect(StyleRules.globalText(in: rules) == ["keep it casual"])
    #expect(StyleRules.applicationText(
      in: rules,
      bundleIdentifier: "com.tinyspeck.slackmacgap"
    ) == ["no greeting"])
    #expect(StyleRules.applicationText(in: rules, bundleIdentifier: nil).isEmpty)
    #expect(StyleRules.applicationText(in: rules, bundleIdentifier: "com.unknown.app").isEmpty)
  }

  @Test func scopesListGlobalFirstThenApplicationsByName() {
    var rules = added("sign off with thanks", scope: mail, to: [])
    rules = added("no greeting", scope: slack, to: rules)
    rules = added("keep it casual", scope: .everywhere, to: rules)
    #expect(StyleRules.scopes(in: rules).map(\.title) == ["Everywhere", "Mail", "Slack"])
  }

  @Test func scopesOmitGlobalWhenNoRuleIsGlobal() {
    let rules = added("no greeting", scope: slack, to: [])
    #expect(StyleRules.scopes(in: rules).map(\.title) == ["Slack"])
  }

  /// Application rules travel in the prompt, not the instructions, so a
  /// prewarmed session survives a switch between apps.
  @Test func applicationRulesReachThePromptAndNothingElseDoes() {
    #expect(TextCleanup.prompt(for: "ship it friday", applicationRules: []) == "ship it friday")

    let prompt = TextCleanup.prompt(for: "ship it friday", applicationRules: ["no greeting"])
    #expect(prompt.contains("- no greeting"))
    #expect(prompt.contains("ship it friday"))
  }
}
