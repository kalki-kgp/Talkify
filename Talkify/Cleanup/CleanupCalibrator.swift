import Foundation
import Observation

/// Runs the calibration samples through the real cleanup path and reports how
/// long this Mac actually needs.
///
/// It uses `CleanupService` exactly as a dictation would, on a warmed session
/// and with no deadline, so what it measures is what a session would have
/// waited for — not a synthetic number.
@MainActor
@Observable
final class CleanupCalibrator {
  enum State: Equatable {
    case idle
    case running(completed: Int, total: Int)
    /// The slowest sample, and the limit derived from it.
    case finished(measuredMilliseconds: Int, recommendedMilliseconds: Int)
    case unavailable
    case failed
  }

  private(set) var state = State.idle

  private let service: CleanupService
  private var task: Task<Void, Never>?

  var isRunning: Bool {
    if case .running = state { return true }
    return false
  }

  init(service: CleanupService) {
    self.service = service
  }

  /// - Parameter apply: called with the recommended limit so the caller can
  ///   store it. The calibrator does not own the preference.
  func calibrate(apply: @escaping (Int) -> Void) {
    guard task == nil else { return }
    guard CleanupService.availability.isAvailable else {
      state = .unavailable
      return
    }

    state = .running(completed: 0, total: CleanupCalibration.samples.count)
    task = Task { [weak self] in
      defer { self?.task = nil }
      guard let self else { return }

      // Warmed first, and given a moment to finish warming, so the first sample
      // is not measuring a cold start the app would never make you wait for.
      await service.prepare()
      try? await Task.sleep(for: .milliseconds(500))

      var durations: [Duration] = []
      for (index, sample) in CleanupCalibration.samples.enumerated() {
        guard !Task.isCancelled else { return }
        let start = ContinuousClock.now
        _ = await service.clean(
          sample,
          locale: Locale(identifier: "en_US"),
          pacing: .waitForQuality
        )
        durations.append(start.duration(to: .now))
        state = .running(completed: index + 1, total: CleanupCalibration.samples.count)
      }

      guard !Task.isCancelled else { return }
      guard let recommended = CleanupCalibration.recommendedMilliseconds(from: durations) else {
        state = .failed
        return
      }

      let slowest = durations.map(CleanupCalibration.milliseconds(of:)).max() ?? 0
      apply(recommended)
      state = .finished(measuredMilliseconds: slowest, recommendedMilliseconds: recommended)
    }
  }

  func cancel() {
    task?.cancel()
    task = nil
    state = .idle
  }
}
