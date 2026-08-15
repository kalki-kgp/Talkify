import Foundation

enum StyleRuleStoreError: LocalizedError {
  case unsupportedVersion(Int)

  var errorDescription: String? {
    switch self {
    case let .unsupportedVersion(version):
      "Unsupported cleanup style data version: \(version)"
    }
  }
}

struct StyleRuleRevision: Equatable, Sendable {
  let rules: [StyleRule]
  let revision: Int
}

enum StyleRuleAddResult: Equatable, Sendable {
  case added(StyleRuleRevision)
  case rejected(StyleRuleRejection)
}

/// The style rules on disk, beside the Vocabulary and written the same way:
/// one versioned JSON file in Application Support, replaced atomically, with
/// every mutation as a single transaction that reads, applies the rule, and
/// writes without suspending in between.
///
/// It holds rules, and rules only. Nothing recognized, inserted, or heard
/// reaches this file — a rule distilled from corrections is a sentence about
/// how someone writes, not a record of what they said.
actor StyleRuleStore {
  static var defaultFileURL: URL {
    FileManager.default.urls(
      for: .applicationSupportDirectory,
      in: .userDomainMask
    )[0]
    .appending(path: "Talkify", directoryHint: .isDirectory)
    .appending(path: "cleanup-style.json")
  }

  private let fileURL: URL
  private var cachedDocument: StyleRuleDocument?
  private var revision = 0

  init(fileURL: URL = StyleRuleStore.defaultFileURL) {
    self.fileURL = fileURL
  }

  func load() throws -> StyleRuleRevision {
    StyleRuleRevision(rules: try document().rules, revision: revision)
  }

  func add(
    _ raw: String,
    scope: StyleRuleScope,
    source: StyleRuleSource = .user
  ) throws -> StyleRuleAddResult {
    var document = try document()

    switch StyleRules.adding(raw, scope: scope, source: source, to: document.rules) {
    case let .added(rules):
      document.rules = rules
      return .added(try commit(document))
    case let .rejected(reason):
      return .rejected(reason)
    }
  }

  func remove(_ rule: StyleRule) throws -> StyleRuleRevision {
    var document = try document()
    document.rules = StyleRules.removing(rule, from: document.rules)
    return try commit(document)
  }

  @discardableResult
  func replace(rules: [StyleRule]) throws -> StyleRuleRevision {
    var document = try document()
    document.rules = StyleRules.canonical(rules)
    return try commit(document)
  }

  private func document() throws -> StyleRuleDocument {
    if let cachedDocument {
      return cachedDocument
    }

    guard FileManager.default.fileExists(atPath: fileURL.path) else {
      let document = StyleRuleDocument()
      cachedDocument = document
      return document
    }

    let data = try Data(contentsOf: fileURL)
    var document = try JSONDecoder().decode(StyleRuleDocument.self, from: data)
    guard document.version == StyleRuleDocument.currentVersion else {
      throw StyleRuleStoreError.unsupportedVersion(document.version)
    }
    document.rules = StyleRules.canonical(document.rules)
    cachedDocument = document
    return document
  }

  private func commit(_ document: StyleRuleDocument) throws -> StyleRuleRevision {
    try save(document)
    cachedDocument = document
    revision += 1
    return StyleRuleRevision(rules: document.rules, revision: revision)
  }

  private func save(_ document: StyleRuleDocument) throws {
    let directory = fileURL.deletingLastPathComponent()
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(document)
    try data.write(to: fileURL, options: .atomic)
  }
}
