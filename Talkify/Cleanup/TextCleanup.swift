import Foundation

/// The pure half of Text Cleanup: what to ask the model, and — the part that
/// actually matters — whether to believe what it answered.
///
/// A language model handed a transcript will sometimes answer it instead of
/// cleaning it, wrap it in quotation marks, explain itself, or quietly drop a
/// clause. Every one of those is worse than doing nothing, because the person
/// already said the words and is expecting them back. So this type is written
/// to refuse: `accept` returns nil for anything it cannot vouch for, and the
/// caller inserts the raw transcript instead.
///
/// Nothing here imports FoundationModels, keeps state, or touches disk — the
/// rules are the testable part and they stay reachable without a model.
enum TextCleanup {
  /// Below this there is nothing worth a model round trip: a two-word draft
  /// has no filler to remove and no sentence to punctuate.
  static let minimumWordCount = 3
  /// Above this the draft is long enough that cleanup would cost more delay
  /// than it is worth, and long enough to crowd the context window.
  static let maximumCharacterCount = 4000
  /// Drafts shorter than this get a count bound instead of a ratio: dropping
  /// one filler word from four is a 25% cut and entirely correct.
  static let shortDraftWordCount = 6
  static let minimumWordRatio = 0.55
  static let maximumWordRatio = 1.25
  /// How much of the answer may be words the draft never contained. Cleanup
  /// removes and repairs; it does not invent. The allowance covers the honest
  /// exceptions — contractions, "twenty five" becoming "25" — and nothing more.
  static let maximumNovelWordRatio = 0.34

  /// A phrase from the instructions that no one dictates. Seeing it in the
  /// answer means the model repeated its brief instead of doing the work.
  private static let instructionSentinel = "Return only the cleaned text"

  private static let refusalPrefixes = [
    "i can't", "i cannot", "i can not", "i'm sorry", "i am sorry", "sorry,",
    "i'm unable", "i am unable", "as an ai", "i won't", "i will not",
    "unfortunately,", "here is the", "here's the", "sure,", "certainly,",
  ]

  static func shouldAttempt(_ text: String) -> Bool {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed.count <= maximumCharacterCount else { return false }
    return words(in: trimmed).count >= minimumWordCount
  }

  /// The session's standing brief. Protected terms and style rules are folded
  /// in here rather than into the prompt so a prewarmed session already carries
  /// them, and so the draft itself arrives as nothing but the draft.
  static func instructions(
    protectedTerms: [String] = [],
    styleRules: [String] = []
  ) -> String {
    var lines = [
      "You clean up text that a person just dictated with speech recognition.",
      "",
      "\(instructionSentinel). Do not answer it, do not comment on it, do not "
        + "explain yourself, and do not wrap it in quotation marks — whatever you "
        + "return is typed straight into the app they are working in.",
      "",
      "Remove filler words and false starts. Fix punctuation, capitalization, and "
        + "obvious mishearings. Keep every idea they said, keep their wording and "
        + "their voice, and keep it as one run of text.",
      "Never add information, never summarize, and never translate.",
    ]

    if !protectedTerms.isEmpty {
      lines.append("")
      lines.append(
        "Spell these terms exactly as written — they are the person's own: "
          + protectedTerms.joined(separator: ", ")
      )
    }

    if !styleRules.isEmpty {
      lines.append("")
      lines.append("Follow these preferences:")
      lines.append(contentsOf: styleRules.map { "- \($0)" })
    }

    return lines.joined(separator: "\n")
  }

  /// The draft as the model receives it.
  ///
  /// Rules for the receiving application ride here rather than in the
  /// instructions, because the target changes from one dictation to the next
  /// and rebuilding the session per application would throw away the prewarm
  /// that keeps cleanup inside its deadline. With no application rules the
  /// prompt is the draft and nothing else.
  static func prompt(for text: String, applicationRules: [String]) -> String {
    guard !applicationRules.isEmpty else { return text }
    return """
      Also follow these preferences for the app this text is going into:
      \(applicationRules.map { "- \($0)" }.joined(separator: "\n"))

      Clean up this text:
      \(text)
      """
  }

  /// A generous ceiling on the answer, so a model that starts rambling is cut
  /// off rather than allowed to burn the whole deadline.
  static func responseTokenLimit(for text: String) -> Int {
    min(1024, words(in: text).count * 3 + 32)
  }

  /// The cleaned draft to insert, or nil to insert the original. Nil is the
  /// safe answer and every check below returns it rather than repairing what
  /// came back: a half-trusted rewrite of someone's own words is not a fix.
  static func accept(_ candidate: String, for original: String) -> String? {
    let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    let unwrapped = unwrappingQuotes(trimmed, original: original)
    guard !unwrapped.isEmpty else { return nil }
    guard !isRefusal(unwrapped) else { return nil }
    guard !unwrapped.localizedCaseInsensitiveContains(instructionSentinel) else { return nil }

    // A cleaned draft is one run of prose. Line breaks the draft never had mean
    // the model produced a list or a commentary rather than the sentence back.
    if unwrapped.contains(where: \.isNewline), !original.contains(where: \.isNewline) {
      return nil
    }

    let originalWords = words(in: original)
    let candidateWords = words(in: unwrapped)
    guard !candidateWords.isEmpty else { return nil }
    guard withinLengthBounds(
      candidate: candidateWords.count,
      original: originalWords.count
    ) else { return nil }
    guard novelWordRatio(candidateWords, against: originalWords) <= maximumNovelWordRatio else {
      return nil
    }

    return unwrapped
  }

  /// Words for comparison: case folded and stripped of surrounding
  /// punctuation, so "friday" and "Friday." are the same word and a draft that
  /// only gained capitals and commas reads as unchanged.
  static func words(in text: String) -> [String] {
    text
      .split(whereSeparator: \.isWhitespace)
      .map { $0.trimmingCharacters(in: .punctuationCharacters).lowercased() }
      .filter { !$0.isEmpty }
  }

  static func withinLengthBounds(candidate: Int, original: Int) -> Bool {
    guard original >= shortDraftWordCount else { return candidate <= original + 1 }
    let ratio = Double(candidate) / Double(original)
    return ratio >= minimumWordRatio && ratio <= maximumWordRatio
  }

  static func novelWordRatio(_ candidate: [String], against original: [String]) -> Double {
    guard !candidate.isEmpty else { return 0 }
    let known = Set(original)
    let novel = candidate.filter { !known.contains($0) }.count
    return Double(novel) / Double(candidate.count)
  }

  /// Strips one layer of matched quotes the model added around the whole
  /// answer. Only when the draft did not open with a quote itself — someone
  /// dictating a quotation should keep it.
  static func unwrappingQuotes(_ candidate: String, original: String) -> String {
    guard let first = candidate.first, let last = candidate.last, candidate.count >= 2 else {
      return candidate
    }
    let pairs: [(Character, Character)] = [("\"", "\""), ("“", "”"), ("'", "'"), ("‘", "’")]
    guard pairs.contains(where: { $0.0 == first && $0.1 == last }) else { return candidate }
    guard original.first != first else { return candidate }
    return String(candidate.dropFirst().dropLast())
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  static func isRefusal(_ candidate: String) -> Bool {
    let lowered = candidate.lowercased()
    return refusalPrefixes.contains { lowered.hasPrefix($0) }
  }
}
