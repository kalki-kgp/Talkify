import AppKit

/// The applications a style rule can be scoped to, offered as a picker rather
/// than a typed bundle identifier: the apps someone dictates into are the apps
/// they have open, and nobody remembers `com.tinyspeck.slackmacgap`.
enum RunningApplications {
  @MainActor
  static func scopes(includingExisting existing: [StyleRuleScope] = []) -> [StyleRuleScope] {
    var byIdentifier: [String: StyleRuleScope] = [:]

    // Rules already written come first, so a scope stays selectable after its
    // application quits — otherwise editing Slack's rules would need Slack open.
    for scope in existing {
      guard let bundleIdentifier = scope.bundleIdentifier else { continue }
      byIdentifier[bundleIdentifier] = scope
    }

    for application in NSWorkspace.shared.runningApplications {
      guard application.activationPolicy == .regular,
        let bundleIdentifier = application.bundleIdentifier,
        bundleIdentifier != Bundle.main.bundleIdentifier,
        let name = application.localizedName
      else { continue }
      byIdentifier[bundleIdentifier] = .application(
        bundleIdentifier: bundleIdentifier,
        name: name
      )
    }

    let applications = byIdentifier.values.sorted {
      $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
    }
    return [.everywhere] + applications
  }
}
