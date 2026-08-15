import Foundation
import Testing
@testable import Talkify

struct CleanupPreferencesTests {
  @Test func deadlineTitlesReadAsTimes() {
    #expect(CleanupDeadline.title(forMilliseconds: 500) == "0.5 seconds")
    #expect(CleanupDeadline.title(forMilliseconds: 1000) == "1 second")
    #expect(CleanupDeadline.title(forMilliseconds: 1500) == "1.5 seconds")
    #expect(CleanupDeadline.title(forMilliseconds: 3000) == "3 seconds")
  }

  /// A stored number from another build must land on one of the offered
  /// steps, or the picker renders with nothing selected.
  @Test func storedDeadlinesSnapToAnOfferedChoice() {
    #expect(CleanupDeadline.nearestChoice(to: 8000) == 8000)
    #expect(CleanupDeadline.nearestChoice(to: 1200) == 1000)
    #expect(CleanupDeadline.nearestChoice(to: 1700) == 2000)
    #expect(CleanupDeadline.nearestChoice(to: 99) == 1000)
    #expect(CleanupDeadline.nearestChoice(to: 99_000) == 20000)
    #expect(CleanupDeadline.choices.contains(CleanupDeadline.default))
  }

  /// The default has to be long enough that the model can actually finish,
  /// or turning cleanup on changes nothing and looks broken. Measured on an
  /// M1 Air: 10 seconds short, 13.5 long.
  @Test func theDefaultDeadlineOutlastsASlowModel() {
    #expect(CleanupDeadline.default >= 5000)
  }

  @Test func pacingCarriesTheLimitOnlyWhenItMeansSomething() {
    #expect(
      CleanupPacing.deadline.pacing(deadlineMilliseconds: 8000)
        == .deadline(.milliseconds(8000))
    )
    #expect(CleanupPacing.waitForQuality.pacing(deadlineMilliseconds: 8000) == .waitForQuality)
  }

  @Test func onlyAvailableMeansAvailable() {
    #expect(CleanupAvailability.available.isAvailable)
    #expect(!CleanupAvailability.appleIntelligenceOff.isAvailable)
    #expect(!CleanupAvailability.deviceNotEligible.isAvailable)
    #expect(!CleanupAvailability.modelNotReady.isAvailable)
    for state in [
      CleanupAvailability.available, .appleIntelligenceOff, .deviceNotEligible, .modelNotReady,
    ] {
      #expect(!state.message.isEmpty)
    }
  }
}

@MainActor
struct CleanupSettingsStorageTests {
  private func freshDefaults() -> UserDefaults {
    let name = "CleanupSettingsTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
  }

  @Test func cleanupIsOffUntilItIsAskedFor() {
    let settings = AppSettings(defaults: freshDefaults())
    #expect(!settings.isCleanupEnabled)
    #expect(settings.cleanupPacing == .deadline)
    #expect(settings.cleanupDeadlineMilliseconds == CleanupDeadline.default)
  }

  @Test func cleanupPreferencesRoundTrip() {
    let defaults = freshDefaults()
    let settings = AppSettings(defaults: defaults)
    settings.isCleanupEnabled = true
    settings.cleanupPacing = .waitForQuality
    settings.cleanupDeadlineMilliseconds = 3000

    let reloaded = AppSettings(defaults: defaults)
    #expect(reloaded.isCleanupEnabled)
    #expect(reloaded.cleanupPacing == .waitForQuality)
    #expect(reloaded.cleanupDeadlineMilliseconds == 3000)
  }

  /// A stored value may have been typed or measured rather than picked, so it
  /// is kept as it is and only pulled into range.
  @Test func anOffPresetStoredDeadlineIsKept() {
    let defaults = freshDefaults()
    defaults.set(1234, forKey: "cleanupDeadlineMilliseconds")
    #expect(AppSettings(defaults: defaults).cleanupDeadlineMilliseconds == 1234)

    defaults.set(10_000_000, forKey: "cleanupDeadlineMilliseconds")
    #expect(
      AppSettings(defaults: defaults).cleanupDeadlineMilliseconds
        == CleanupDeadline.range.upperBound
    )
  }
}
