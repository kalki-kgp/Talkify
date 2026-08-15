import Foundation
import Observation

/// The style rules as the app holds them: an observable list over the store,
/// in the shape `VocabularyList` already established — the section calls
/// through it, the composition root observes it, and the actor behind it owns
/// both the file and the rules.
///
/// It decides nothing about the list's contents. It forwards the edit and
/// adopts what came back, so no rule is applied to a snapshot another edit has
/// already moved past.
@MainActor
@Observable
final class StyleRuleList {
  private let store: StyleRuleStore

  private(set) var rules: [StyleRule] = []
  private(set) var errorMessage: String?
  /// Why the last add was refused, cleared as soon as the person types again.
  private(set) var rejection: StyleRuleRejection?

  @ObservationIgnored
  private var appliedRevision = -1

  init(store: StyleRuleStore = StyleRuleStore()) {
    self.store = store
  }

  /// The rules that ride in the model session's standing instructions.
  var globalText: [String] {
    StyleRules.globalText(in: rules)
  }

  func text(forBundleIdentifier bundleIdentifier: String?) -> [String] {
    StyleRules.applicationText(in: rules, bundleIdentifier: bundleIdentifier)
  }

  func rules(in scope: StyleRuleScope) -> [StyleRule] {
    StyleRules.inScope(rules, of: scope)
  }

  var scopes: [StyleRuleScope] {
    StyleRules.scopes(in: rules)
  }

  func load() async {
    do {
      apply(try await store.load())
      errorMessage = nil
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  @discardableResult
  func add(
    _ raw: String,
    scope: StyleRuleScope,
    source: StyleRuleSource = .user
  ) async -> Bool {
    do {
      switch try await store.add(raw, scope: scope, source: source) {
      case let .added(result):
        rejection = nil
        errorMessage = nil
        apply(result)
        return true
      case let .rejected(reason):
        rejection = reason
        return false
      }
    } catch {
      errorMessage = error.localizedDescription
      return false
    }
  }

  func remove(_ rule: StyleRule) async {
    rejection = nil
    do {
      apply(try await store.remove(rule))
      errorMessage = nil
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func clearRejection() {
    rejection = nil
  }

  private func apply(_ result: StyleRuleRevision) {
    guard result.revision >= appliedRevision else { return }
    appliedRevision = result.revision
    rules = result.rules
  }
}
