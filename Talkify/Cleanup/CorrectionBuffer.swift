import Foundation

/// One thing Talkify inserted and what the person turned it into.
struct CorrectionPair: Codable, Equatable, Sendable {
  let bundleIdentifier: String?
  /// Resolved when the pair is captured rather than when it is distilled: by
  /// then the application may have quit, and "Slack" reads better than
  /// `com.tinyspeck.slackmacgap` in a suggestion.
  let applicationName: String?
  let inserted: String
  let corrected: String
}

/// The correction pairs waiting to be distilled into style rules.
///
/// Capped at `capacity`, cleared the moment they are distilled, and backed by
/// `CorrectionStore` so they survive a quit — twenty corrections is more than
/// one sitting's worth, and a buffer that empties on every quit never reaches
/// the threshold that makes learning happen at all.
///
/// An actor rather than a plain array so nothing can hold a reference to the
/// pairs while they are being cleared.
actor CorrectionBuffer {
  /// Enough to see a habit, few enough that the distilling pass stays short.
  static let capacity = 20

  private let store: CorrectionStore?
  private var pairs: [CorrectionPair] = []

  init(store: CorrectionStore? = nil) {
    self.store = store
  }

  var count: Int { pairs.count }
  var isFull: Bool { pairs.count >= Self.capacity }

  /// Reads back what the last run captured. Failing to load is not worth
  /// surfacing: it costs some learning speed and nothing else, so it starts
  /// empty and carries on.
  func load() async {
    guard let store, let stored = try? await store.load() else { return }
    pairs = Array(stored.suffix(Self.capacity))
  }

  func record(_ pair: CorrectionPair) async {
    guard pair.inserted != pair.corrected else { return }
    pairs.append(pair)
    if pairs.count > Self.capacity {
      pairs.removeFirst(pairs.count - Self.capacity)
    }
    await persist()
  }

  func snapshot() -> [CorrectionPair] {
    pairs
  }

  /// Takes everything and leaves nothing. Distillation calls this rather than
  /// reading and clearing separately, so a pair cannot be both consumed and
  /// left behind.
  func drain() async -> [CorrectionPair] {
    let drained = pairs
    pairs.removeAll()
    await persist()
    return drained
  }

  func clear() async {
    pairs.removeAll()
    await persist()
  }

  private func persist() async {
    guard let store else { return }
    try? await store.replace(pairs: pairs)
  }
}
