import Foundation

/// Turns a full buffer of corrections into a review queue.
///
/// It runs between sessions and never during one. Distillation is a second
/// model pass over twenty pairs; putting it anywhere near the trigger key would
/// spend the prewarm that Direct Dictation depends on, to produce something
/// nobody is waiting for.
@MainActor
final class CleanupLearningController {
  private let buffer: CorrectionBuffer
  private let cleanupService: CleanupService
  private let queue: CleanupSuggestionQueue

  private var distillTask: Task<Void, Never>?

  init(
    buffer: CorrectionBuffer,
    cleanupService: CleanupService,
    queue: CleanupSuggestionQueue
  ) {
    self.buffer = buffer
    self.cleanupService = cleanupService
    self.queue = queue
  }

  /// Called when a session ends. Does nothing until enough corrections have
  /// piled up, so a single fixed typo never becomes a rule.
  func distillIfReady() {
    guard distillTask == nil else { return }

    distillTask = Task { [weak self] in
      defer { self?.distillTask = nil }
      guard let self, await buffer.isFull else { return }

      // Drained rather than read and cleared separately: a pair must not be
      // able to be both consumed and left behind for the next pass.
      let pairs = await buffer.drain()
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
