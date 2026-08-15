import Foundation

enum CleanupSuggestionStoreError: LocalizedError {
  case unsupportedVersion(Int)

  var errorDescription: String? {
    switch self {
    case let .unsupportedVersion(version):
      "Unsupported cleanup suggestion data version: \(version)"
    }
  }
}

struct CleanupSuggestionRevision: Equatable, Sendable {
  let pending: [CleanupSuggestion]
  let revision: Int
}

/// The review queue on disk, written like the Vocabulary and the style rules:
/// one versioned JSON file in Application Support, replaced atomically, with
/// each mutation a single transaction.
///
/// What it holds is derived, not recorded. A pending suggestion is a sentence
/// about how someone writes; a declined one is an id. The correction pairs they
/// came from were never written anywhere and are gone by the time this file is
/// touched (`CorrectionBuffer`).
actor CleanupSuggestionStore {
  static var defaultFileURL: URL {
    FileManager.default.urls(
      for: .applicationSupportDirectory,
      in: .userDomainMask
    )[0]
    .appending(path: "Talkify", directoryHint: .isDirectory)
    .appending(path: "cleanup-suggestions.json")
  }

  private let fileURL: URL
  private var cachedDocument: CleanupSuggestionDocument?
  private var revision = 0

  init(fileURL: URL = CleanupSuggestionStore.defaultFileURL) {
    self.fileURL = fileURL
  }

  func load() throws -> CleanupSuggestionRevision {
    CleanupSuggestionRevision(pending: try document().pending, revision: revision)
  }

  func declinedIDs() throws -> Set<String> {
    Set(try document().declined)
  }

  /// Adds what survived `CleanupSuggestions.admissible`. Returns the queue as
  /// of this turn, so a caller resuming out of order can tell a stale answer
  /// from a current one.
  @discardableResult
  func enqueue(_ suggestions: [CleanupSuggestion]) throws -> CleanupSuggestionRevision {
    var document = try document()
    document.pending += suggestions
    return try commit(document)
  }

  /// Removes a suggestion that was acted on. Accepting does not decline it —
  /// it is in effect, and the rule or term itself now keeps it from coming back.
  @discardableResult
  func accept(_ suggestion: CleanupSuggestion) throws -> CleanupSuggestionRevision {
    var document = try document()
    document.pending.removeAll { $0.id == suggestion.id }
    return try commit(document)
  }

  @discardableResult
  func decline(_ suggestion: CleanupSuggestion) throws -> CleanupSuggestionRevision {
    var document = try document()
    document.pending.removeAll { $0.id == suggestion.id }
    document.declined = CleanupSuggestions.trimmedDeclined(document.declined + [suggestion.id])
    return try commit(document)
  }

  @discardableResult
  func clearPending() throws -> CleanupSuggestionRevision {
    var document = try document()
    document.pending.removeAll()
    return try commit(document)
  }

  private func document() throws -> CleanupSuggestionDocument {
    if let cachedDocument {
      return cachedDocument
    }

    guard FileManager.default.fileExists(atPath: fileURL.path) else {
      let document = CleanupSuggestionDocument()
      cachedDocument = document
      return document
    }

    let data = try Data(contentsOf: fileURL)
    var document = try JSONDecoder().decode(CleanupSuggestionDocument.self, from: data)
    guard document.version == CleanupSuggestionDocument.currentVersion else {
      throw CleanupSuggestionStoreError.unsupportedVersion(document.version)
    }
    // Canonicalized on the way in rather than trusted: folded duplicates would
    // give the review queue repeated ForEach identifiers.
    document.pending = CleanupSuggestions.admissible(
      document.pending,
      pending: [],
      declined: Set(document.declined),
      existingRuleIDs: [],
      existingTermKeys: []
    )
    document.declined = CleanupSuggestions.trimmedDeclined(document.declined)
    cachedDocument = document
    return document
  }

  private func commit(_ document: CleanupSuggestionDocument) throws -> CleanupSuggestionRevision {
    try save(document)
    cachedDocument = document
    revision += 1
    return CleanupSuggestionRevision(pending: document.pending, revision: revision)
  }

  private func save(_ document: CleanupSuggestionDocument) throws {
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
