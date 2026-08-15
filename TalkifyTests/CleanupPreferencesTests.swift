import Foundation
import Testing
@testable import Talkify

struct CleanupPreferencesTests {
  @Test func deadlineTitlesReadAsTimes() {
    #expect(CleanupDeadline.title(forMilliseconds: 500) == "0.5 seconds")
    #expect(CleanupDeadline.title(forMilliseconds: 1000) == "1 seconds")
    #expect(CleanupDeadline.title(forMilliseconds: 1500) == "1.5 seconds")
    #expect(CleanupDeadline.title(forMilliseconds: 3000) == "3 seconds")
  }

  /// A stored number from another build must land on one of the offered
  /// steps, or the picker renders with nothing selected.
  @Test func storedDeadlinesSnapToAnOfferedChoice() {
    #expect(CleanupDeadline.nearestChoice(to: 1500) == 1500)
    #expect(CleanupDeadline.nearestChoice(to: 1200) == 1000)
    #expect(CleanupDeadline.nearestChoice(to: 1400) == 1500)
    #expect(CleanupDeadline.nearestChoice(to: 99) == 500)
    #expect(CleanupDeadline.nearestChoice(to: 99_000) == 3000)
    #expect(CleanupDeadline.choices.contains(CleanupDeadline.default))
  }

  @Test func pacingCarriesTheLimitOnlyWhenItMeansSomething() {
    #expect(
      CleanupPacing.deadline.pacing(deadlineMilliseconds: 1500)
        == .deadline(.milliseconds(1500))
    )
    #expect(CleanupPacing.waitForQuality.pacing(deadlineMilliseconds: 1500) == .waitForQuality)
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

  @Test func anOffScaleStoredDeadlineSnapsBackOnLoad() {
    let defaults = freshDefaults()
    defaults.set(1234, forKey: "cleanupDeadlineMilliseconds")
    #expect(AppSettings(defaults: defaults).cleanupDeadlineMilliseconds == 1000)
  }
}
