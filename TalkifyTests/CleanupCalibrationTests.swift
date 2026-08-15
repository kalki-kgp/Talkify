import Foundation
import Testing
@testable import Talkify

struct CleanupCalibrationTests {
  @Test func recommendsFromTheSlowestSampleNotTheAverage() {
    // The long drafts are the ones worth cleaning and the ones a short limit
    // would cut off, so they set the number.
    let recommended = CleanupCalibration.recommendedMilliseconds(from: [
      .milliseconds(2000), .milliseconds(3000), .milliseconds(10000),
    ])
    #expect(recommended != nil)
    #expect(recommended! > 10000)
  }

  /// The model is not consistent run to run, so a limit set to exactly what
  /// was measured would miss about half the time.
  @Test func leavesHeadroomOverWhatWasMeasured() {
    let measured = 10000
    let recommended = try! #require(
      CleanupCalibration.recommendedMilliseconds(from: [.milliseconds(measured)])
    )
    #expect(Double(recommended) >= Double(measured) * CleanupCalibration.headroom)
  }

  @Test func roundsToANumberAPersonWouldSay() {
    #expect(CleanupCalibration.roundedUpToStep(1234) == 1500)
    #expect(CleanupCalibration.roundedUpToStep(1500) == 1500)
    #expect(CleanupCalibration.roundedUpToStep(13_487) == 14_000)
    #expect(CleanupCalibration.roundedUpToStep(14_000) == 14_000)
  }

  @Test func staysInsideTheAllowedRange() {
    let huge = CleanupCalibration.recommendedMilliseconds(from: [.seconds(600)])
    #expect(huge == CleanupDeadline.range.upperBound)

    let tiny = try! #require(
      CleanupCalibration.recommendedMilliseconds(from: [.milliseconds(1)])
    )
    #expect(CleanupDeadline.range.contains(tiny))
  }

  @Test func reportsNothingWithoutASample() {
    #expect(CleanupCalibration.recommendedMilliseconds(from: []) == nil)
  }

  @Test func convertsDurationsToWholeMilliseconds() {
    #expect(CleanupCalibration.milliseconds(of: .milliseconds(1500)) == 1500)
    #expect(CleanupCalibration.milliseconds(of: .seconds(12)) == 12000)
  }

  /// A measured limit is rarely one of the presets, so a stored value must be
  /// kept as it is rather than snapped onto the menu.
  @Test func anyValueInRangeIsAllowedNotJustThePresets() {
    #expect(CleanupDeadline.clamped(13_500) == 13_500)
    #expect(!CleanupDeadline.isPreset(13_500))
    #expect(CleanupDeadline.isPreset(CleanupDeadline.default))
    #expect(CleanupDeadline.clamped(1) == CleanupDeadline.range.lowerBound)
    #expect(CleanupDeadline.clamped(10_000_000) == CleanupDeadline.range.upperBound)
  }
}

@MainActor
struct CleanupDeadlineStorageTests {
  private func freshDefaults() -> UserDefaults {
    let name = "CleanupDeadlineTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
  }

  @Test func aMeasuredValueSurvivesARelaunchUnsnapped() {
    let defaults = freshDefaults()
    let settings = AppSettings(defaults: defaults)
    settings.cleanupDeadlineMilliseconds = 13_500

    #expect(AppSettings(defaults: defaults).cleanupDeadlineMilliseconds == 13_500)
  }

  @Test func aValueOutsideTheRangeIsClampedOnTheWayIn() {
    let settings = AppSettings(defaults: freshDefaults())
    settings.cleanupDeadlineMilliseconds = 10_000_000
    #expect(settings.cleanupDeadlineMilliseconds == CleanupDeadline.range.upperBound)

    settings.cleanupDeadlineMilliseconds = 1
    #expect(settings.cleanupDeadlineMilliseconds == CleanupDeadline.range.lowerBound)
  }
}
