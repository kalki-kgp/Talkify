import Foundation

/// Working out how long cleanup actually needs on *this* Mac.
///
/// The model's speed varies by more than the presets can cover — measured on an
/// M1 Air it is 7 to 13 seconds, where a current Mac is a fraction of that. A
/// limit set below what the machine can do means cleanup never finishes and the
/// feature silently does nothing, which looks exactly like it working. So
/// rather than guess, measure.
enum CleanupCalibration {
  /// Short, medium and long, because the cost scales with the draft. They are
  /// deliberately messy: a clean sentence gives the model nothing to do and
  /// finishes faster than real dictation would.
  static let samples = [
    "um so i think we should ship it friday",
    "um so i was thinking we could uh ship it on friday if that works for "
      + "everyone otherwise monday is fine too",
    "okay so the the main thing is that we need to finish the migration before "
      + "the end of the quarter um and i think if we split it into two parts "
      + "the first one can land next week and then the second part uh depends "
      + "on whether the review comes back in time",
  ]

  /// Headroom over the slowest sample. The model is not consistent run to run,
  /// and a limit set to exactly what was measured would miss about half the
  /// time — which is the failure this whole exercise exists to avoid.
  static let headroom = 1.35

  /// The limit to use, from what the samples took. Built on the slowest rather
  /// than the average: the long drafts are the ones worth cleaning, and they
  /// are the ones that would be cut off.
  static func recommendedMilliseconds(from durations: [Duration]) -> Int? {
    guard let slowest = durations.map(milliseconds(of:)).max() else { return nil }
    let padded = Int((Double(slowest) * headroom).rounded(.up))
    return clamp(roundedUpToStep(padded))
  }

  static func milliseconds(of duration: Duration) -> Int {
    let components = duration.components
    return Int(components.seconds) * 1000 + Int(components.attoseconds / 1_000_000_000_000_000)
  }

  /// Rounded to something a person would say out loud. "17 seconds" is a
  /// measurement; "16.8 seconds" is a readout.
  static func roundedUpToStep(_ milliseconds: Int) -> Int {
    let step = milliseconds < 10_000 ? 500 : 1000
    return Int((Double(milliseconds) / Double(step)).rounded(.up)) * step
  }

  static func clamp(_ milliseconds: Int) -> Int {
    min(max(milliseconds, CleanupDeadline.range.lowerBound), CleanupDeadline.range.upperBound)
  }
}
