import Foundation
import Testing
@testable import Talkify

struct CorrectionStoreTests {
  private func temporaryURL() -> URL {
    FileManager.default.temporaryDirectory
      .appending(path: "TalkifyCorrectionStoreTests-\(UUID().uuidString)")
      .appending(path: "cleanup-corrections.json")
  }

  private func pair(_ inserted: String, _ corrected: String) -> CorrectionPair {
    CorrectionPair(
      bundleIdentifier: "com.apple.TextEdit",
      applicationName: "TextEdit",
      inserted: inserted,
      corrected: corrected
    )
  }

  @Test func aMissingFileIsAnEmptyBufferRatherThanAnError() async throws {
    let store = CorrectionStore(fileURL: temporaryURL())
    #expect(try await store.load().isEmpty)
  }

  @Test func correctionsSurviveAWriteAndARead() async throws {
    let url = temporaryURL()
    let store = CorrectionStore(fileURL: url)
    let pairs = [pair("its ready", "it's ready"), pair("ok", "OK")]

    try await store.replace(pairs: pairs)
    #expect(try await CorrectionStore(fileURL: url).load() == pairs)
  }

  /// "Forget these" has to leave nothing on disk to find, not an empty file
  /// where the corrections used to be.
  @Test func forgettingRemovesTheFileEntirely() async throws {
    let url = temporaryURL()
    let store = CorrectionStore(fileURL: url)
    try await store.replace(pairs: [pair("a", "b")])
    #expect(FileManager.default.fileExists(atPath: url.path))

    try await store.replace(pairs: [])
    #expect(!FileManager.default.fileExists(atPath: url.path))
    #expect(try await store.load().isEmpty)
  }

  @Test func aFileFromALaterVersionIsRefusedRatherThanGuessedAt() async throws {
    let url = temporaryURL()
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try Data(#"{"version":99,"pairs":[]}"#.utf8).write(to: url)

    await #expect(throws: CorrectionStoreError.self) {
      try await CorrectionStore(fileURL: url).load()
    }
  }
}

struct CorrectionBufferPersistenceTests {
  private func temporaryURL() -> URL {
    FileManager.default.temporaryDirectory
      .appending(path: "TalkifyCorrectionBufferTests-\(UUID().uuidString)")
      .appending(path: "cleanup-corrections.json")
  }

  private func pair(_ index: Int) -> CorrectionPair {
    CorrectionPair(
      bundleIdentifier: nil,
      applicationName: nil,
      inserted: "draft \(index)",
      corrected: "fixed \(index)"
    )
  }

  /// The whole reason the file exists: twenty corrections is more than one
  /// sitting's worth, so a buffer that emptied on quit never reached the
  /// threshold that makes learning run at all.
  @Test func capturedCorrectionsSurviveARelaunch() async {
    let url = temporaryURL()
    let first = CorrectionBuffer(store: CorrectionStore(fileURL: url))
    await first.record(pair(1))
    await first.record(pair(2))

    let second = CorrectionBuffer(store: CorrectionStore(fileURL: url))
    await second.load()
    #expect(await second.count == 2)
    #expect(await second.snapshot().first?.inserted == "draft 1")
  }

  @Test func drainingClearsWhatIsOnDiskTooNotJustMemory() async {
    let url = temporaryURL()
    let buffer = CorrectionBuffer(store: CorrectionStore(fileURL: url))
    await buffer.record(pair(1))
    _ = await buffer.drain()

    let reloaded = CorrectionBuffer(store: CorrectionStore(fileURL: url))
    await reloaded.load()
    #expect(await reloaded.count == 0)
    #expect(!FileManager.default.fileExists(atPath: url.path))
  }

  @Test func forgettingClearsWhatIsOnDiskToo() async {
    let url = temporaryURL()
    let buffer = CorrectionBuffer(store: CorrectionStore(fileURL: url))
    await buffer.record(pair(1))
    await buffer.clear()

    #expect(!FileManager.default.fileExists(atPath: url.path))
  }

  /// A file written by a build with a larger capacity must not push the buffer
  /// past what this build distils in one pass.
  @Test func anOversizedFileIsTrimmedToCapacityOnLoad() async throws {
    let url = temporaryURL()
    let store = CorrectionStore(fileURL: url)
    try await store.replace(pairs: (0..<(CorrectionBuffer.capacity + 5)).map(pair))

    let buffer = CorrectionBuffer(store: store)
    await buffer.load()
    #expect(await buffer.count == CorrectionBuffer.capacity)
    #expect(await buffer.snapshot().first?.inserted == "draft 5")
  }

  /// Without a store nothing is written, which is what keeps previews and
  /// tests from leaving recognized text behind.
  @Test func aBufferWithoutAStoreWritesNothing() async {
    let buffer = CorrectionBuffer()
    await buffer.record(pair(1))
    #expect(await buffer.count == 1)
  }
}
