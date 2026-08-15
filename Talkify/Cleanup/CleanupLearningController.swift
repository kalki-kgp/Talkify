import Foundation

/// Turns a full buffer of corrections into a review queue.
///
/// It runs between sessions and never during one. Distillation is a second
/// model pass over twenty pairs; putting it anywhere near the trigger key would
/// spend the prewarm that Direct Dictation depends on, to produce something
/// nobody is waiting for.
///
/// It also owns what Settings shows about the buffer. Corrections are kept on
/// disk, so how many are held and how to erase them cannot be a detail only the
/// code knows.
@MainActor
@Observable
final class CleanupLearningController {
  /// How many corrections are waiting, and how many it takes to learn from
  /// them. Settings reads both.
  private(set) var capturedCount = 0
  let threshold = CorrectionBuffer.capacity

  @ObservationIgnored private let buffer: CorrectionBuffer
  @ObservationIgnored private let cleanupService: CleanupService
  @ObservationIgnored private let queue: CleanupSuggestionQueue

  @ObservationIgnored private var distillTask: Task<Void, Never>?

  init(
    buffer: CorrectionBuffer,
    cleanupService: CleanupService,
    queue: CleanupSuggestionQueue
  ) {
    self.buffer = buffer
    self.cleanupService = cleanupService
    self.queue = queue
  }

  /// Reads back what earlier runs captured. Called once at launch.
  func load() {
    Task { [weak self] in
      guard let self else { return }
      await buffer.load()
      capturedCount = await buffer.count
    }
  }

  /// Called after a correction is captured, so the count in Settings is not a
  /// number that only changes when the window is reopened.
  func refresh() {
    Task { [weak self] in
      guard let self else { return }
      capturedCount = await buffer.count
    }
  }

  /// Throws away every captured correction, on disk and in memory. The rules
  /// already distilled from them are not touched — those are in the Rules list,
  /// where they can be deleted one at a time.
  func forgetCaptured() {
    Task { [weak self] in
      guard let self else { return }
      await buffer.clear()
      capturedCount = await buffer.count
    }
  }

  /// Called when a session ends. Does nothing until enough corrections have
  /// piled up, so a single fixed typo never becomes a rule.
  func distillIfReady() {
    guard distillTask == nil else { return }

    distillTask = Task { [weak self] in
      defer { self?.distillTask = nil }
      guard let self else { return }
      guard await buffer.isFull else {
        capturedCount = await buffer.count
        return
      }

      // Drained rather than read and cleared separately: a pair must not be
      // able to be both consumed and left behind for the next pass.
      let pairs = await buffer.drain()
      capturedCount = await buffer.count
      guard !pairs.isEmpty else { return }

      let suggestions = await cleanupService.distill(pairs)
      guard !suggestions.isEmpty else { return }
      await queue.enqueue(suggestions)
    }
  }

  func cancel() {
    distillTask?.cancel()
    distillTask = nil
  }
}
