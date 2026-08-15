import Foundation

/// What reading a field back after insertion told us.
enum CorrectionReading: Equatable, Sendable {
  /// The text is still there, exactly as inserted. Worth knowing — it is the
  /// difference between "nothing to learn" and "we learned nothing".
  case unchanged
  /// The text is there and was edited. `corrected` is the inserted text with
  /// the person's edit applied, and nothing else.
  case corrected(String)
  /// Nothing usable. A sent message, a closed view, a field that cannot be
  /// read, or an edit whose boundaries cannot be pinned down.
  case noSignal
}

/// Talkify inserts text and lets go, so it has never seen what anyone did with
/// it. This is the one place a correction signal can come from: read the field
/// back a moment later and compare.
///
/// The job here is mostly to refuse. A wrong pair is worse than no pair —
/// it teaches the model a rule the person never held — so every reading that
/// cannot be pinned to the inserted span exactly returns `.noSignal`.
enum CorrectionDiff {
  /// Below this the "correction" is someone deleting the draft and typing
  /// something else, which says nothing about how they want dictation written.
  static let minimumRetainedRatio = 0.4
  static let maximumGrowthRatio = 2.0
  /// How much of what was said has to survive the edit for it to count as a
  /// correction rather than a replacement.
  static let minimumRetainedWordRatio = 0.5

  /// - Parameters:
  ///   - inserted: what Talkify put into the field.
  ///   - baseline: the whole field, read immediately after insertion. It may
  ///     hold text the person had already written around ours.
  ///   - current: the whole field, read again later.
  static func reading(
    inserted: String,
    baseline: String,
    current: String
  ) -> CorrectionReading {
    guard !inserted.isEmpty else { return .noSignal }
    // The insertion did not land where we think it did, so nothing downstream
    // can be trusted to be ours.
    guard baseline.contains(inserted) else { return .noSignal }
    guard baseline != current else { return .unchanged }

    let baselineCharacters = Array(baseline)
    let currentCharacters = Array(current)

    let prefix = commonPrefixLength(baselineCharacters, currentCharacters)
    let suffix = commonSuffixLength(
      baselineCharacters,
      currentCharacters,
      notCrossing: prefix
    )

    let baselineChange = prefix..<(baselineCharacters.count - suffix)
    let currentChange = prefix..<(currentCharacters.count - suffix)

    // Where our text sits inside the field we read back.
    guard let insertedRange = range(of: Array(inserted), in: baselineCharacters) else {
      return .noSignal
    }

    // An edit that reaches outside our span is the person working on their own
    // sentence as well as ours, and there is no honest way to split it.
    guard baselineChange.lowerBound >= insertedRange.lowerBound,
      baselineChange.upperBound <= insertedRange.upperBound
    else { return .noSignal }

    // Text added at either edge of our span without touching it — the person
    // carrying on writing. Indistinguishable from prepending a word to our
    // sentence, so both are refused rather than one being guessed at.
    if baselineChange.isEmpty,
      baselineChange.lowerBound == insertedRange.lowerBound
        || baselineChange.lowerBound == insertedRange.upperBound {
      return .noSignal
    }

    var corrected = Array(inserted)
    let start = baselineChange.lowerBound - insertedRange.lowerBound
    let end = baselineChange.upperBound - insertedRange.lowerBound
    corrected.replaceSubrange(start..<end, with: currentCharacters[currentChange])

    let result = String(corrected)
    guard !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return .noSignal
    }
    guard withinRewriteBounds(corrected: result, inserted: inserted) else { return .noSignal }
    guard retainedWordRatio(corrected: result, inserted: inserted) >= minimumRetainedWordRatio
    else { return .noSignal }
    return result == inserted ? .unchanged : .corrected(result)
  }

  /// A correction keeps most of what was said. Past these bounds the person
  /// threw the draft away and wrote something new, which is a different event.
  static func withinRewriteBounds(corrected: String, inserted: String) -> Bool {
    let insertedCount = Double(inserted.count)
    guard insertedCount > 0 else { return false }
    let ratio = Double(corrected.count) / insertedCount
    return ratio >= minimumRetainedRatio && ratio <= maximumGrowthRatio
  }

  /// Length alone is not enough: a field replaced with an unrelated sentence of
  /// a similar length passes every size check. What tells a correction from a
  /// replacement is how much of what was said survived it. Folded the same way
  /// `TextCleanup` folds, so casing and punctuation fixes count as survivals.
  static func retainedWordRatio(corrected: String, inserted: String) -> Double {
    let insertedWords = TextCleanup.words(in: inserted)
    guard !insertedWords.isEmpty else { return 0 }
    let remaining = Set(TextCleanup.words(in: corrected))
    let retained = insertedWords.filter { remaining.contains($0) }.count
    return Double(retained) / Double(insertedWords.count)
  }

  static func commonPrefixLength(_ left: [Character], _ right: [Character]) -> Int {
    var index = 0
    while index < left.count, index < right.count, left[index] == right[index] {
      index += 1
    }
    return index
  }

  /// Counted from the end, and stopped before it can overlap the common prefix
  /// — otherwise a repeated character makes the two ranges cross and the
  /// arithmetic below goes backwards.
  static func commonSuffixLength(
    _ left: [Character],
    _ right: [Character],
    notCrossing prefix: Int
  ) -> Int {
    var count = 0
    let limit = min(left.count, right.count) - prefix
    while count < limit, left[left.count - 1 - count] == right[right.count - 1 - count] {
      count += 1
    }
    return count
  }

  /// The first occurrence of `needle` in `haystack`, as an index range.
  /// Written over characters rather than String.range(of:) so it lines up with
  /// the prefix and suffix arithmetic, which counts the same way.
  static func range(of needle: [Character], in haystack: [Character]) -> Range<Int>? {
    guard !needle.isEmpty, needle.count <= haystack.count else { return nil }
    for start in 0...(haystack.count - needle.count) {
      if Array(haystack[start..<(start + needle.count)]) == needle {
        return start..<(start + needle.count)
      }
    }
    return nil
  }
}
