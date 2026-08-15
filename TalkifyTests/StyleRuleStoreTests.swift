import Foundation
import Testing
@testable import Talkify

struct StyleRuleStoreTests {
  private let slack = StyleRuleScope.application(
    bundleIdentifier: "com.tinyspeck.slackmacgap",
    name: "Slack"
  )

  private func temporaryURL() -> URL {
    FileManager.default.temporaryDirectory
      .appending(path: "TalkifyStyleRuleStoreTests-\(UUID().uuidString).json")
  }

  @Test func returnsAnEmptyDocumentBeforeAnythingIsSaved() async throws {
    let store = StyleRuleStore(fileURL: temporaryURL())
    #expect(try await store.load().rules.isEmpty)
  }

  @Test func persistsRulesAcrossStoreInstances() async throws {
    let url = temporaryURL()
    defer { try? FileManager.default.removeItem(at: url) }

    let store = StyleRuleStore(fileURL: url)
    _ = try await store.add("keep it casual", scope: .everywhere)
    _ = try await store.add("no greeting", scope: slack)

    let reloaded = try await StyleRuleStore(fileURL: url).load()
    #expect(reloaded.rules.map(\.text) == ["no greeting", "keep it casual"])
    #expect(reloaded.rules[0].bundleIdentifier == "com.tinyspeck.slackmacgap")
    #expect(reloaded.rules[0].applicationName == "Slack")
  }

  @Test func addAppliesTheRulesAndReportsRefusals() async throws {
    let url = temporaryURL()
    defer { try? FileManager.default.removeItem(at: url) }
    let store = StyleRuleStore(fileURL: url)

    #expect(try await store.add("   ", scope: .everywhere) == .rejected(.empty))
    _ = try await store.add("keep it casual", scope: .everywhere)
    #expect(try await store.add("Keep It Casual", scope: .everywhere) == .rejected(.duplicate))
  }

  @Test func aRefusedAddLeavesTheRevisionAlone() async throws {
    let url = temporaryURL()
    defer { try? FileManager.default.removeItem(at: url) }
    let store = StyleRuleStore(fileURL: url)

    guard case let .added(first) = try await store.add("keep it casual", scope: .everywhere) else {
      Issue.record("expected the first rule to be added")
      return
    }
    _ = try await store.add("keep it casual", scope: .everywhere)
    #expect(try await store.load().revision == first.revision)
  }

  @Test func everyMutationAdvancesTheRevision() async throws {
    let url = temporaryURL()
    defer { try? FileManager.default.removeItem(at: url) }
    let store = StyleRuleStore(fileURL: url)

    guard case let .added(first) = try await store.add("keep it casual", scope: .everywhere),
      case let .added(second) = try await store.add("no greeting", scope: slack)
    else {
      Issue.record("expected both rules to be added")
      return
    }
    #expect(second.revision > first.revision)

    let removed = try await store.remove(second.rules[0])
    #expect(removed.revision > second.revision)
  }

  @Test func rejectsADocumentFromAFutureVersion() async throws {
    let url = temporaryURL()
    defer { try? FileManager.default.removeItem(at: url) }
    try Data(#"{"version":99,"rules":[]}"#.utf8).write(to: url)

    await #expect(throws: StyleRuleStoreError.self) {
      _ = try await StyleRuleStore(fileURL: url).load()
    }
  }

  @Test func canonicalizesADocumentWrittenUnderDifferentRules() async throws {
    let url = temporaryURL()
    defer { try? FileManager.default.removeItem(at: url) }
    let document = #"""
      {"version":1,"rules":[
        {"source":"user","text":"  keep  it casual "},
        {"source":"user","text":"KEEP IT CASUAL"}
      ]}
      """#
    try Data(document.utf8).write(to: url)

    let loaded = try await StyleRuleStore(fileURL: url).load()
    #expect(loaded.rules.map(\.text) == ["keep it casual"])
  }

  @Test func replaceOverwritesRatherThanAppends() async throws {
    let url = temporaryURL()
    defer { try? FileManager.default.removeItem(at: url) }
    let store = StyleRuleStore(fileURL: url)
    _ = try await store.add("keep it casual", scope: .everywhere)

    let result = try await store.replace(rules: [StyleRule(text: "no greeting")])
    #expect(result.rules.map(\.text) == ["no greeting"])
  }

  /// Two edits landing at once must both survive: every mutation reads,
  /// applies the rule, and writes without suspending in between.
  @Test func concurrentAddsAllSurvive() async throws {
    let url = temporaryURL()
    defer { try? FileManager.default.removeItem(at: url) }
    let store = StyleRuleStore(fileURL: url)

    await withTaskGroup(of: Void.self) { group in
      for index in 0..<8 {
        group.addTask {
          _ = try? await store.add("rule number \(index)", scope: .everywhere)
        }
      }
    }

    #expect(try await store.load().rules.count == 8)
  }

  /// The store holds rules and nothing else — never a transcript, never a
  /// correction pair.
  @Test func storesOnlyRulesAndTheVersion() async throws {
    let url = temporaryURL()
    defer { try? FileManager.default.removeItem(at: url) }
    let store = StyleRuleStore(fileURL: url)
    _ = try await store.add("keep it casual", scope: slack)

    let json = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
    let object = try #require(json as? [String: Any])
    #expect(Set(object.keys) == ["version", "rules"])

    let rules = try #require(object["rules"] as? [[String: Any]])
    #expect(Set(rules[0].keys) == ["text", "bundleIdentifier", "applicationName", "source"])
  }
}
