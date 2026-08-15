import AppKit

/// Watches the field Talkify just wrote into, to find out what the person
/// changed.
///
/// Talkify inserts text and lets go by design, so it has no correction signal
/// at all. This makes one: read the field back through Accessibility a while
/// after insertion and diff against what was inserted.
///
/// It works where the field is AX-readable and yields nothing where it is not,
/// which is the correct failure mode — an app that reveals nothing simply
/// teaches nothing. Every reading that cannot be pinned to the inserted span is
/// thrown away rather than guessed at (`CorrectionDiff`).
@MainActor
final class CorrectionWatcher {
  /// Two reads rather than one. The first catches the immediate fix — a name,
  /// a wrong word — and the second catches the person coming back to the
  /// sentence before they send it. Whichever last showed an edit wins.
  private static let readDelays: [Duration] = [.seconds(4), .seconds(15)]

  private let insertionService: TextInsertionService
  private let buffer: CorrectionBuffer

  private var watchTask: Task<Void, Never>?

  init(insertionService: TextInsertionService, buffer: CorrectionBuffer) {
    self.insertionService = insertionService
    self.buffer = buffer
  }

  /// Called right after insertion, with the target still in hand. The baseline
  /// read happens now: the whole field including anything the person had
  /// already written around ours, which is what makes it possible to tell an
  /// edit to our text from an edit to theirs.
  func watch(inserted: String, target: TextInsertionService.Target?) {
    cancel()
    guard let target, !inserted.isEmpty else { return }
    guard let baseline = insertionService.readValue(of: target),
      baseline.contains(inserted)
    else { return }

    let bundleIdentifier = target.bundleIdentifier
    watchTask = Task { [weak self] in
      var latest: String?

      reads: for delay in Self.readDelays {
        try? await Task.sleep(for: delay)
        guard !Task.isCancelled, let self else { return }
        guard let current = insertionService.readValue(of: target) else { break reads }

        switch CorrectionDiff.reading(
          inserted: inserted,
          baseline: baseline,
          current: current
        ) {
        case let .corrected(corrected):
          latest = corrected
        case .unchanged:
          continue
        case .noSignal:
          // The field moved on — sent, cleared, or rewritten wholesale. Later
          // reads cannot recover it, so stop rather than keep poking.
          break reads
        }
      }

      guard let latest, let self, !Task.isCancelled else { return }
      await buffer.record(CorrectionPair(
        bundleIdentifier: bundleIdentifier,
        inserted: inserted,
        corrected: latest
      ))
    }
  }

  /// Stops watching. Called when the next session begins: the person has moved
  /// on, and a read against a field they have left is worth nothing.
  func cancel() {
    watchTask?.cancel()
    watchTask = nil
  }
}
