import Foundation

enum CorrectionStoreError: LocalizedError {
  case unsupportedVersion(Int)

  var errorDescription: String? {
    switch self {
    case let .unsupportedVersion(version):
      "Unsupported cleanup correction data version: \(version)"
    }
  }
}

struct CorrectionDocument: Codable, Equatable, Sendable {
  static let currentVersion = 1

  var version: Int
  var pairs: [CorrectionPair]

  init(version: Int = currentVersion, pairs: [CorrectionPair] = []) {
    self.version = version
    self.pairs = pairs
  }
}

/// The captured corrections on disk.
///
/// This is the one Talkify file that holds recognized text, and it exists for a
/// single reason: learning needs twenty corrections to say anything, and nobody
/// makes twenty in one sitting. Held only in memory the buffer emptied on every
/// quit, so distillation never ran and the learning layer was decorative.
///
/// What that costs is stated plainly rather than hidden: the file keeps at most
/// `CorrectionBuffer.capacity` pairs, it is emptied the moment they are
/// distilled into rules, it is only written while learning is switched on, and
/// Settings can erase it outright. Everything else Talkify stores stays as it
/// was — no transcript, no history, no recording.
actor CorrectionStore {
  static var defaultFileURL: URL {
    FileManager.default.urls(
      for: .applicationSupportDirectory,
      in: .userDomainMask
    )[0]
    .appending(path: "Talkify", directoryHint: .isDirectory)
    .appending(path: "cleanup-corrections.json")
  }

  private let fileURL: URL

  init(fileURL: URL = CorrectionStore.defaultFileURL) {
    self.fileURL = fileURL
  }

  func load() throws -> [CorrectionPair] {
    guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }

    let data = try Data(contentsOf: fileURL)
    let document = try JSONDecoder().decode(CorrectionDocument.self, from: data)
    guard document.version == CorrectionDocument.currentVersion else {
      throw CorrectionStoreError.unsupportedVersion(document.version)
    }
    return document.pairs
  }

  /// Writing an empty list removes the file rather than leaving an empty one.
  /// "Forget these" should leave nothing behind on disk to find.
  func replace(pairs: [CorrectionPair]) throws {
    guard !pairs.isEmpty else {
      try? FileManager.default.removeItem(at: fileURL)
      return
    }

    let directory = fileURL.deletingLastPathComponent()
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(CorrectionDocument(pairs: pairs))
    try data.write(to: fileURL, options: [.atomic, .completeFileProtection])
  }
}
