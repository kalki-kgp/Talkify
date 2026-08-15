import Foundation
import Testing
@testable import Talkify

struct TextCleanupTests {
  private let draft =
    "um so i was thinking we could uh ship it on friday if that works for everyone"

  @Test func attemptsOnlyDraftsWorthAModelPass() {
    #expect(TextCleanup.shouldAttempt(draft))
    #expect(!TextCleanup.shouldAttempt(""))
    #expect(!TextCleanup.shouldAttempt("   \n  "))
    #expect(!TextCleanup.shouldAttempt("yes please"))
    #expect(TextCleanup.shouldAttempt("yes please do"))
    #expect(!TextCleanup.shouldAttempt(
      String(repeating: "word ", count: TextCleanup.maximumCharacterCount)
    ))
  }

  @Test func acceptsAnHonestCleanup() {
    let cleaned = "So I was thinking we could ship it on Friday if that works for everyone."
    #expect(TextCleanup.accept(cleaned, for: draft) == cleaned)
  }

  @Test func acceptsPunctuationAndCapitalizationAlone() {
    let original = "we ship on friday and monday is the review"
    let cleaned = "We ship on Friday, and Monday is the review."
    #expect(TextCleanup.accept(cleaned, for: original) == cleaned)
  }

  @Test func rejectsAnEmptyOrBlankAnswer() {
    #expect(TextCleanup.accept("", for: draft) == nil)
    #expect(TextCleanup.accept("   \n ", for: draft) == nil)
  }

  /// The failure that matters most: the model treats the draft as a question
  /// and answers it. What comes back is fluent, plausible, and not what the
  /// person said.
  @Test func rejectsAnAnswerToTheDraftInsteadOfACleanup() {
    let question = "um what time does the review start on friday"
    let answered = "The review starts at 2pm on Friday."
    #expect(TextCleanup.accept(answered, for: question) == nil)
  }

  @Test func rejectsARefusal() {
    #expect(TextCleanup.accept("I can't help with that.", for: draft) == nil)
    #expect(TextCleanup.accept("Sorry, I'm unable to assist.", for: draft) == nil)
    #expect(TextCleanup.accept("Here's the cleaned text: ship it.", for: draft) == nil)
  }

  @Test func rejectsAnAnswerThatRepeatsItsOwnBrief() {
    let leaked = "Return only the cleaned text. So I was thinking we could ship it on Friday."
    #expect(TextCleanup.accept(leaked, for: draft) == nil)
  }

  @Test func rejectsLineBreaksTheDraftNeverHad() {
    let listed = "- Ship it on Friday\n- Check with everyone first"
    #expect(TextCleanup.accept(listed, for: draft) == nil)
  }

  @Test func keepsLineBreaksWhenTheDraftAlreadyHadThem() {
    let original = "first point is friday\nsecond point is the review"
    let cleaned = "First point is Friday.\nSecond point is the review."
    #expect(TextCleanup.accept(cleaned, for: original) == cleaned)
  }

  @Test func rejectsAnAnswerThatDroppedHalfTheDraft() {
    #expect(TextCleanup.accept("Ship it Friday.", for: draft) == nil)
  }

  @Test func rejectsAnAnswerThatPaddedTheDraft() {
    let padded = "So I was thinking that we could probably go ahead and ship it on "
      + "Friday, assuming of course that this works for absolutely everyone on the team."
    #expect(TextCleanup.accept(padded, for: draft) == nil)
  }

  @Test func stripsQuotesTheModelAddedAroundTheWholeAnswer() {
    let quoted = "\"So I was thinking we could ship it on Friday if that works for everyone.\""
    let expected = "So I was thinking we could ship it on Friday if that works for everyone."
    #expect(TextCleanup.accept(quoted, for: draft) == expected)
  }

  @Test func keepsQuotesTheDraftOpenedWith() {
    let original = "\"we ship on friday\" is what he said to me"
    let cleaned = "\"We ship on Friday\" is what he said to me."
    #expect(TextCleanup.accept(cleaned, for: original) == cleaned)
  }

  /// Short drafts get a count bound rather than a ratio: dropping one filler
  /// word from four is a 25% cut and entirely correct.
  @Test func boundsShortDraftsByCountRatherThanRatio() {
    #expect(TextCleanup.withinLengthBounds(candidate: 3, original: 4))
    #expect(TextCleanup.withinLengthBounds(candidate: 2, original: 4))
    #expect(TextCleanup.withinLengthBounds(candidate: 5, original: 4))
    #expect(!TextCleanup.withinLengthBounds(candidate: 6, original: 4))
  }

  @Test func boundsLongerDraftsByRatio() {
    #expect(TextCleanup.withinLengthBounds(candidate: 16, original: 20))
    #expect(TextCleanup.withinLengthBounds(candidate: 24, original: 20))
    #expect(!TextCleanup.withinLengthBounds(candidate: 10, original: 20))
    #expect(!TextCleanup.withinLengthBounds(candidate: 26, original: 20))
  }

  @Test func foldsCaseAndPunctuationWhenComparingWords() {
    #expect(TextCleanup.words(in: "Friday, we ship!") == ["friday", "we", "ship"])
    #expect(TextCleanup.words(in: "  spaced   out  ") == ["spaced", "out"])
    #expect(TextCleanup.words(in: "— … —").isEmpty)
  }

  @Test func countsOnlyWordsTheDraftNeverContained() {
    let original = TextCleanup.words(in: "we ship on friday")
    #expect(TextCleanup.novelWordRatio(TextCleanup.words(in: "We ship on Friday."), against: original) == 0)
    #expect(TextCleanup.novelWordRatio(
      TextCleanup.words(in: "we ship tomorrow"),
      against: original
    ) > 0.3)
  }

  /// Contractions and spelled-out numbers are the honest exceptions: they are
  /// new tokens produced by a correct cleanup, and the allowance covers them.
  @Test func toleratesContractionsAndNumerals() {
    let original = "we will meet on the twenty fifth and we will review it then"
    let cleaned = "We'll meet on the 25th, and we'll review it then."
    #expect(TextCleanup.accept(cleaned, for: original) == cleaned)
  }

  @Test func protectedTermsAndStyleRulesReachTheInstructions() {
    let instructions = TextCleanup.instructions(
      protectedTerms: ["Talkify", "SwiftPM"],
      styleRules: ["Prefer OK over okay"]
    )
    #expect(instructions.contains("Talkify, SwiftPM"))
    #expect(instructions.contains("- Prefer OK over okay"))
    #expect(instructions.contains("Return only the cleaned text"))
  }

  @Test func instructionsStaySilentAboutEmptyLists() {
    let instructions = TextCleanup.instructions()
    #expect(!instructions.contains("Spell these terms"))
    #expect(!instructions.contains("Follow these preferences"))
  }

  @Test func boundsTheAnswerLengthByTheDraftLength() {
    #expect(TextCleanup.responseTokenLimit(for: draft) == TextCleanup.words(in: draft).count * 3 + 32)
    #expect(TextCleanup.responseTokenLimit(
      for: String(repeating: "word ", count: 2000)
    ) == 1024)
  }
}
