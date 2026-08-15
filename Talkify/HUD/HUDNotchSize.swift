import CoreGraphics

/// The size of the simulated notch, which is the black housing the HUD is
/// built around on a display that has no notch of its own.
///
/// Only the simulated one is adjustable. Where a display reports a real
/// housing, the HUD hugs what was measured and flares into the bezel with
/// fillets — a housing that did not match the hardware would leave the curve
/// hanging in the middle of the screen (ADR-0001).
enum HUDNotchSize {
  static let widthRange: ClosedRange<Double> = 120...460
  static let heightRange: ClosedRange<Double> = 18...72

  /// The footprint a 14" MacBook Pro measures, which is where the stand-in
  /// numbers came from in the first place.
  static let defaultWidth: Double = 185
  static let defaultHeight: Double = 32

  static func clampedWidth(_ width: Double) -> Double {
    min(max(width, widthRange.lowerBound), widthRange.upperBound)
  }

  static func clampedHeight(_ height: Double) -> Double {
    min(max(height, heightRange.lowerBound), heightRange.upperBound)
  }

  static func size(width: Double, height: Double) -> CGSize {
    CGSize(width: clampedWidth(width), height: clampedHeight(height))
  }

  static var `default`: CGSize {
    size(width: defaultWidth, height: defaultHeight)
  }

  static func isDefault(width: Double, height: Double) -> Bool {
    clampedWidth(width) == defaultWidth && clampedHeight(height) == defaultHeight
  }
}
