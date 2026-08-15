import Foundation
import Testing
@testable import Talkify

/// Most of these assert that nothing was learned. That is the point: a wrong
/// correction pair teaches a rule the person never held, and there is no way
/// to notice that later.
struct CorrectionDiffTests {
  private let inserted = "Lets ship it on friday if that works."

  @Test func anUntouchedFieldIsUnchanged() {
    #expect(
      CorrectionDiff.reading(inserted: inserted, baseline: inserted, current: inserted)
        == .unchanged
    )
  }

  @Test func anEditInsideTheInsertedTextIsACorrection() {
    let corrected = "Let's ship it on Friday if that works."
    #expect(
      CorrectionDiff.reading(inserted: inserted, baseline: inserted, current: corrected)
        == .corrected(corrected)
    )
  }

  /// The field already held the person's own writing. Our span is found inside
  /// it, and the correction is reported as our text alone — not the paragraph
  /// around it.
  @Test func reportsOnlyTheInsertedSpanWhenTheFieldHeldMore() {
    let baseline = "Hi team — \(inserted) Thanks!"
    let current = "Hi team — Let's ship it on Friday if that works. Thanks!"
    #expect(
      CorrectionDiff.reading(inserted: inserted, baseline: baseline, current: current)
        == .corrected("Let's ship it on Friday if that works.")
    )
  }

  /// The person kept typing after our text. That is composition, not a
  /// correction, and it must not be read as one.
  @Test func textAppendedAfterOursIsNotACorrection() {
    let current = inserted + " I'll book the room."
    #expect(
      CorrectionDiff.reading(inserted: inserted, baseline: inserted, current: current)
        == .noSignal
    )
  }

  @Test func textTypedBeforeOursIsNotACorrection() {
    let current = "Hi team — " + inserted
    #expect(
      CorrectionDiff.reading(inserted: inserted, baseline: inserted, current: current)
        == .noSignal
    )
  }

  /// The single most common ending: the message is sent and the field empties.
  /// That is an absence of signal, never a deletion to learn from.
  @Test func aSentMessageIsNoSignal() {
    #expect(
      CorrectionDiff.reading(inserted: inserted, baseline: inserted, current: "")
        == .noSignal
    )
  }

  @Test func aFieldThatMovedOnEntirelyIsNoSignal() {
    #expect(
      CorrectionDiff.reading(
        inserted: inserted,
        baseline: inserted,
        current: "totally different text about something else"
      ) == .noSignal
    )
  }

  /// Deleting the draft and writing something new says nothing about how
  /// someone wants dictation written.
  @Test func aWholesaleRewriteIsNoSignal() {
    #expect(
      CorrectionDiff.reading(inserted: inserted, baseline: inserted, current: "no")
        == .noSignal
    )
  }

  @Test func anEditReachingOutsideOurSpanIsNoSignal() {
    let baseline = "Hi team — \(inserted) Thanks!"
    let current = "Hello everyone — Let's ship it on Friday if that works. Thanks!"
    #expect(
      CorrectionDiff.reading(inserted: inserted, baseline: baseline, current: current)
        == .noSignal
    )
  }

  /// The baseline read did not find our text where we put it, so nothing
  /// downstream can be trusted to be ours.
  @Test func aBaselineWithoutOurTextIsNoSignal() {
    #expect(
      CorrectionDiff.reading(
        inserted: inserted,
        baseline: "something else entirely",
        current: "something else entirely!"
      ) == .noSignal
    )
    #expect(CorrectionDiff.reading(inserted: "", baseline: "", current: "") == .noSignal)
  }

  /// A one-word fix in the middle of a long draft: the smallest useful signal
  /// and the one most likely to be a habit worth learning.
  @Test func aSingleWordFixIsACorrection() {
    let original = "The kubernetes cluster is up and the deploy finished cleanly."
    let fixed = "The Kubernetes cluster is up and the deploy finished cleanly."
    #expect(
      CorrectionDiff.reading(inserted: original, baseline: original, current: fixed)
        == .corrected(fixed)
    )
  }

  /// Repeated characters at both ends make a naive prefix and suffix scan
  /// overlap and the arithmetic run backwards.
  @Test func overlappingPrefixAndSuffixDoNotCross() {
    #expect(
      CorrectionDiff.reading(inserted: "aaaa bbbb", baseline: "aaaa bbbb", current: "aaaa bbb")
        == .corrected("aaaa bbb")
    )
    #expect(CorrectionDiff.commonSuffixLength(
      Array("aaaa"), Array("aaa"), notCrossing: 3
    ) == 0)
  }

  @Test func rewriteBoundsRejectBothExtremes() {
    #expect(CorrectionDiff.withinRewriteBounds(corrected: "abcde", inserted: "abcdef"))
    #expect(!CorrectionDiff.withinRewriteBounds(corrected: "ab", inserted: "abcdefghij"))
    #expect(!CorrectionDiff.withinRewriteBounds(
      corrected: String(repeating: "x", count: 30),
      inserted: "abcdefghij"
    ))
    #expect(!CorrectionDiff.withinRewriteBounds(corrected: "anything", inserted: ""))
  }
}

struct CorrectionBufferTests {
  @Test func recordsOnlyRealChanges() async {
    let buffer = CorrectionBuffer()
    await buffer.record(CorrectionPair(bundleIdentifier: nil, applicationName: nil, inserted: "a", corrected: "a"))
    #expect(await buffer.count == 0)

    await buffer.record(CorrectionPair(bundleIdentifier: nil, applicationName: nil, inserted: "a", corrected: "b"))
    #expect(await buffer.count == 1)
  }

  @Test func dropsTheOldestPastCapacity() async {
    let buffer = CorrectionBuffer()
    for index in 0..<(CorrectionBuffer.capacity + 5) {
      await buffer.record(CorrectionPair(
        bundleIdentifier: nil,
        applicationName: nil,
        inserted: "draft \(index)",
        corrected: "fixed \(index)"
      ))
    }
    let pairs = await buffer.snapshot()
    #expect(pairs.count == CorrectionBuffer.capacity)
    #expect(pairs.first?.inserted == "draft 5")
    #expect(await buffer.isFull)
  }

  /// Distillation drains rather than reading and clearing separately, so a
  /// pair cannot be both consumed and left behind.
  @Test func drainingTakesEverythingAndLeavesNothing() async {
    let buffer = CorrectionBuffer()
    await buffer.record(CorrectionPair(bundleIdentifier: nil, applicationName: nil, inserted: "a", corrected: "b"))
    await buffer.record(CorrectionPair(bundleIdentifier: nil, applicationName: nil, inserted: "c", corrected: "d"))

    #expect(await buffer.drain().count == 2)
    #expect(await buffer.count == 0)
    #expect(await buffer.drain().isEmpty)
  }
}
