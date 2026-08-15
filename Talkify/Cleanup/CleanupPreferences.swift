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
enum CleanupDeadline {
  static let choices = [500, 1000, 1500, 2000, 3000]
  static let `default` = 1500

  static func title(forMilliseconds milliseconds: Int) -> String {
    let seconds = Double(milliseconds) / 1000
    return seconds == seconds.rounded()
      ? "\(Int(seconds)) seconds"
      : String(format: "%.1f seconds", seconds)
  }

  /// Clamps a stored value onto the offered choices, so a number left behind
  /// by another build cannot render a picker with no selection.
  static func nearestChoice(to milliseconds: Int) -> Int {
    choices.min { abs($0 - milliseconds) < abs($1 - milliseconds) } ?? `default`
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
