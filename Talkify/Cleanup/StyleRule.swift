import Foundation

/// Where a style rule applies. Talkify already knows which application is
/// about to receive the text — it captured the target before recording — so
/// "how I write in Slack" is a distinction the app can actually act on.
enum StyleRuleScope: Equatable, Hashable, Sendable {
  case everywhere
  case application(bundleIdentifier: String, name: String)

  var bundleIdentifier: String? {
    switch self {
    case .everywhere: nil
    case let .application(bundleIdentifier, _): bundleIdentifier
    }
  }

  var title: String {
    switch self {
    case .everywhere: "Everywhere"
    case let .application(_, name): name
    }
  }
}

/// Where a rule came from. Rules Talkify proposed from watching corrections
/// are still the person's to keep or drop, but they are worth telling apart
/// from the ones they wrote — a list you cannot audit is a list you stop
/// trusting.
enum StyleRuleSource: String, Codable, Equatable, Sendable {
  case user
  case learned
}

/// One line of guidance handed to the cleanup pass: "prefer OK over okay",
/// "no greeting, no sign-off". Plain language rather than a setting, because
/// what reads it is a language model.
///
/// The scope is stored as flat fields rather than a nested enum so the file
/// format stays boring, and `source` is here from the start so learned rules
/// need no migration to join it later.
struct StyleRule: Codable, Equatable, Hashable, Identifiable, Sendable {
  var text: String
  var bundleIdentifier: String?
  var applicationName: String?
  var source: StyleRuleSource

  init(
    text: String,
    bundleIdentifier: String? = nil,
    applicationName: String? = nil,
    source: StyleRuleSource = .user
  ) {
    self.text = text
    self.bundleIdentifier = bundleIdentifier
    self.applicationName = applicationName
    self.source = source
  }

  /// Identity is the scope plus the folded text, so the same rule cannot be
  /// added twice to one app but can exist for two different apps.
  var id: String {
    "\(bundleIdentifier ?? "")|\(StyleRules.foldedKey(for: text))"
  }

  var scope: StyleRuleScope {
    guard let bundleIdentifier else { return .everywhere }
    return .application(bundleIdentifier: bundleIdentifier, name: applicationName ?? bundleIdentifier)
  }
}

struct StyleRuleDocument: Codable, Equatable, Sendable {
  static let currentVersion = 1

  var version: Int
  var rules: [StyleRule]

  init(version: Int = currentVersion, rules: [StyleRule] = []) {
    self.version = version
    self.rules = rules
  }
}

enum StyleRuleRejection: Equatable, Sendable {
  case empty
  case tooLong
  case duplicate
  case scopeFull
  case full
}

enum StyleRuleAddOutcome: Equatable, Sendable {
  case added([StyleRule])
  case rejected(StyleRuleRejection)
}
