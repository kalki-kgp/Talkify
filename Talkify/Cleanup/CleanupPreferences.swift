import Foundation

/// What happens when cleanup is slower than the person is willing to wait.
///
/// The model runs between the recognizer finishing and the text landing, so
/// every millisecond it takes is a millisecond of nothing happening after the
/// key comes up. `.deadline` is the default because a dictation app that
/// sometimes stalls is a worse app than one that sometimes skips the polish.
enum CleanupPacing: String, CaseIterable, Sendable {
  case deadline
  case waitForQuality

  var title: String {
    switch self {
    case .deadline: "Insert the raw text"
    case .waitForQuality: "Wait for the cleaned text"
    }
  }

  /// The stored pick paired with its stored time limit, as the service takes
  /// it. The limit is meaningless for `.waitForQuality` and is dropped rather
  /// than carried along.
  func pacing(deadlineMilliseconds: Int) -> CleanupService.Pacing {
    switch self {
    case .deadline: .deadline(.milliseconds(deadlineMilliseconds))
    case .waitForQuality: .waitForQuality
    }
  }
}

/// The time limits offered for `.deadline`, in milliseconds. Whole steps
/// rather than a slider: the difference between 900 and 1000 ms is not a
/// choice anyone can make, and the picker matches every other Settings row.
///
/// The range reaches as far as it does because the model is slow. Measured on
/// an M1 Air with `--benchmark-cleanup`: 10 seconds for a short draft, 13.5 for
/// a long one. Anything under that on this hardware means cleanup never
/// finishes and the feature quietly does nothing — which is worse than an
/// honest wait, because it looks like it is working.
enum CleanupDeadline {
  static let choices = [1000, 2000, 3000, 5000, 8000, 12000, 20000]
  static let `default` = 8000
  /// Any value in here is allowed, not just the presets — the Speed card takes
  /// a typed number and `CleanupCalibration` produces measured ones. The bounds
  /// only keep a stored value sane: below the floor nothing ever finishes, and
  /// above the ceiling this is no longer dictation.
  static let range = 500...60000

  static func title(forMilliseconds milliseconds: Int) -> String {
    let seconds = Double(milliseconds) / 1000
    guard seconds != 1 else { return "1 second" }
    return seconds == seconds.rounded()
      ? "\(Int(seconds)) seconds"
      : String(format: "%.1f seconds", seconds)
  }

  /// The nearest preset. Used to decide which preset a value corresponds to,
  /// not to force it onto one — a custom or measured value stays as typed.
  static func nearestChoice(to milliseconds: Int) -> Int {
    choices.min { abs($0 - milliseconds) < abs($1 - milliseconds) } ?? `default`
  }

  static func clamped(_ milliseconds: Int) -> Int {
    min(max(milliseconds, range.lowerBound), range.upperBound)
  }

  static func isPreset(_ milliseconds: Int) -> Bool {
    choices.contains(milliseconds)
  }
}

/// Why cleanup is or is not available, in Talkify's own terms.
///
/// FoundationModels' own reasons stay behind this so nothing outside
/// `Talkify/Cleanup/` has to import the framework to render a Settings row —
/// the same containment Sparkle gets in `Talkify/Updates/`.
enum CleanupAvailability: Equatable, Sendable {
  case available
  case appleIntelligenceOff
  case deviceNotEligible
  case modelNotReady

  var isAvailable: Bool { self == .available }

  var message: String {
    switch self {
    case .available:
      "Apple Intelligence is ready on this Mac."
    case .appleIntelligenceOff:
      "Turn on Apple Intelligence in System Settings to use cleanup. "
        + "Until then, Talkify inserts the raw text."
    case .deviceNotEligible:
      "This Mac cannot run Apple Intelligence, so cleanup is unavailable. "
        + "Talkify inserts the raw text."
    case .modelNotReady:
      "Apple Intelligence is still preparing its model. Cleanup starts working "
        + "once it finishes."
    }
  }
}
