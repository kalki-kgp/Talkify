import Foundation

/// One thing Talkify inserted and what the person turned it into.
struct CorrectionPair: Equatable, Sendable {
  let bundleIdentifier: String?
  let inserted: String
  let corrected: String
}

/// The correction pairs waiting to be distilled into style rules.
///
/// **This is never written to disk and never will be.** Talkify persists no
/// recognized text, and a correction pair is recognized text twice over. It
/// lives in memory, it is capped, and quitting the app throws it away — which
/// costs a little learning speed and is the entire reason the feature can exist
/// without changing what Talkify stores.
///
/// An actor rather than a plain array so nothing can hold a reference to the
/// pairs while they are being cleared.
actor CorrectionBuffer {
  /// Enough to see a habit, few enough that the distilling pass stays short.
  static let capacity = 20

  private var pairs: [CorrectionPair] = []

  var count: Int { pairs.count }
  var isFull: Bool { pairs.count >= Self.capacity }

  func record(_ pair: CorrectionPair) {
    guard pair.inserted != pair.corrected else { return }
    pairs.append(pair)
    if pairs.count > Self.capacity {
      pairs.removeFirst(pairs.count - Self.capacity)
    }
  }

  func snapshot() -> [CorrectionPair] {
    pairs
  }

  /// Takes everything and leaves nothing. Distillation calls this rather than
  /// reading and clearing separately, so a pair cannot be both consumed and
  /// left behind.
  func drain() -> [CorrectionPair] {
    defer { pairs.removeAll() }
    return pairs
  }

  func clear() {
    pairs.removeAll()
  }
}
