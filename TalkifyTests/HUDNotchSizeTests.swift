import CoreGraphics
import Foundation
import Testing
@testable import Talkify

struct HUDNotchSizeTests {
  @Test func sizesAreHeldInsideWhatTheShapeCanDraw() {
    #expect(HUDNotchSize.clampedWidth(9999) == HUDNotchSize.widthRange.upperBound)
    #expect(HUDNotchSize.clampedWidth(0) == HUDNotchSize.widthRange.lowerBound)
    #expect(HUDNotchSize.clampedHeight(9999) == HUDNotchSize.heightRange.upperBound)
    #expect(HUDNotchSize.clampedHeight(-4) == HUDNotchSize.heightRange.lowerBound)
  }

  @Test func aValueInRangeIsKeptExactlyAsItWasSet() {
    #expect(HUDNotchSize.clampedWidth(237) == 237)
    #expect(HUDNotchSize.clampedHeight(41) == 41)
  }

  /// The default has to stay the footprint the fallback was built from, or a
  /// Mac with a real notch and one without would stop matching.
  @Test func theDefaultIsTheMeasuredMacBookProFootprint() {
    #expect(HUDNotchSize.default == HUDNotchGeometry.fallbackClosedSize)
    #expect(HUDNotchSize.isDefault(width: 185, height: 32))
    #expect(!HUDNotchSize.isDefault(width: 185, height: 33))
  }
}

struct HUDNotchGeometrySizingTests {
  private let external = HUDPreviewScreen.external
  private let notched = HUDPreviewScreen.notched

  @Test func aChosenSizeReplacesTheSimulatedHousing() {
    let chosen = CGSize(width: 300, height: 44)
    #expect(HUDNotchGeometry.closedSize(for: external, simulated: chosen) == chosen)
  }

  /// A display that reports a housing keeps it. The shape flares into that
  /// housing's edges, and a different number would leave the fillets hanging
  /// in open screen.
  @Test func aMeasuredHousingIgnoresTheChosenSize() {
    let chosen = CGSize(width: 300, height: 44)
    #expect(
      HUDNotchGeometry.closedSize(for: notched, simulated: chosen)
        == HUDNotchGeometry.measuredClosedSize(for: notched)
    )
  }

  @Test func aTallerNotchMakesATallerShape() {
    let short = HUDNotchGeometry.contentSize(
      for: external,
      visualBandHeight: 0,
      includesTextBand: true,
      simulated: CGSize(width: 185, height: 32)
    )
    let tall = HUDNotchGeometry.contentSize(
      for: external,
      visualBandHeight: 0,
      includesTextBand: true,
      simulated: CGSize(width: 185, height: 60)
    )
    #expect(tall.height == short.height + 28)
  }

  /// The host window never resizes, so it is sized for the tallest notch the
  /// preference allows rather than the one currently chosen.
  @Test func theHostWindowDoesNotChangeWithTheChosenSize() {
    let small = HUDNotchGeometry.windowFrame(
      for: external,
      simulated: CGSize(width: 130, height: 20)
    )
    let large = HUDNotchGeometry.windowFrame(
      for: external,
      simulated: CGSize(width: 440, height: HUDNotchSize.heightRange.upperBound)
    )
    #expect(small == large)
  }

  @Test func theDefaultArgumentMatchesTheOldBehaviour() {
    #expect(
      HUDNotchGeometry.closedSize(for: external) == HUDNotchGeometry.fallbackClosedSize
    )
  }
}

@MainActor
struct HUDNotchSettingsTests {
  private func freshDefaults() -> UserDefaults {
    let name = "HUDNotchSettingsTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
  }

  @Test func theNotchStartsAtTheMeasuredFootprint() {
    let settings = AppSettings(defaults: freshDefaults())
    #expect(settings.notchSize == HUDNotchSize.default)
  }

  @Test func aChosenSizeSurvivesARelaunch() {
    let defaults = freshDefaults()
    let settings = AppSettings(defaults: defaults)
    settings.notchWidth = 260
    settings.notchHeight = 48

    let reloaded = AppSettings(defaults: defaults)
    #expect(reloaded.notchWidth == 260)
    #expect(reloaded.notchHeight == 48)
  }

  @Test func anOutOfRangeSizeIsPulledBackIn() {
    let settings = AppSettings(defaults: freshDefaults())
    settings.notchWidth = 5000
    settings.notchHeight = 0
    #expect(settings.notchWidth == HUDNotchSize.widthRange.upperBound)
    #expect(settings.notchHeight == HUDNotchSize.heightRange.lowerBound)
  }

  @Test func theSessionSnapshotCarriesTheChosenSize() {
    let settings = AppSettings(defaults: freshDefaults())
    settings.notchWidth = 300
    settings.notchHeight = 40
    #expect(settings.sessionSettings.notchSize == CGSize(width: 300, height: 40))
  }
}
