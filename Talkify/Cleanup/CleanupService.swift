import Foundation
import FoundationModels

/// Text Cleanup's impure half: the only file in Talkify that imports
/// FoundationModels, in the same way `Talkify/Updates/` is the only place that
/// imports Sparkle.
///
/// Two rules shape everything here.
///
/// **It never throws.** Cleanup is a nicety on the path between the recognizer
/// finishing and the text landing. A model that is unavailable, refuses under
/// its guardrails, does not speak the dictation language, or simply takes too
/// long must cost the person nothing but the polish, so every failure resolves
/// to "insert what was actually said".
///
/// **A session is spent once.** `LanguageModelSession` accumulates a multi-turn
/// transcript, so reusing one would carry the last dictation into the next
/// one's context — both a quality problem and a privacy one. Each request takes
/// the warm session, discards it, and warms a fresh one behind it, mirroring
/// how `SpeechRecognitionService` re-prewarms after every session.
actor CleanupService {
  enum Pacing: Equatable, Sendable {
    /// Race the model; insert the raw draft if it has not answered in time.
    case deadline(Duration)
    /// Wait however long the model needs.
    case waitForQuality
  }

  private var protectedTerms: [String] = []
  private var styleRules: [String] = []
  private var session: LanguageModelSession?

  /// Readable without entering the actor, and cheap: Settings renders this on
  /// every appearance and the answer changes only when the person changes it
  /// in System Settings.
  nonisolated static var availability: CleanupAvailability {
    switch SystemLanguageModel.default.availability {
    case .available:
      .available
    case .unavailable(.appleIntelligenceNotEnabled):
      .appleIntelligenceOff
    case .unavailable(.deviceNotEligible):
      .deviceNotEligible
    case .unavailable(.modelNotReady):
      .modelNotReady
    case .unavailable:
      .modelNotReady
    }
  }

  /// The words the Vocabulary told Apple Speech to expect. Cleanup is handed
  /// the same list so it cannot "correct" a term back into the ordinary word
  /// the person added it to avoid.
  func setProtectedTerms(_ terms: [String]) {
    guard terms != protectedTerms else { return }
    protectedTerms = terms
    renew()
  }

  func setStyleRules(_ rules: [String]) {
    guard rules != styleRules else { return }
    styleRules = rules
    renew()
  }

  /// Builds and warms the session ahead of the first dictation, so the first
  /// cleanup is not the slow one.
  func prepare() {
    guard session == nil else { return }
    renew()
  }

  func shutDown() {
    session = nil
  }

  /// Returns the text to insert: cleaned when everything went right, and the
  /// original draft in every other case.
  func clean(_ text: String, locale: Locale, pacing: Pacing) async -> String {
    guard TextCleanup.shouldAttempt(text) else { return text }
    guard SystemLanguageModel.default.isAvailable else { return text }
    guard Self.supportsLanguage(of: locale) else { return text }

    let limit = TextCleanup.responseTokenLimit(for: text)
    let candidate: String?
    switch pacing {
    case .waitForQuality:
      candidate = await respond(to: text, tokenLimit: limit)
    case let .deadline(duration):
      candidate = await respond(to: text, tokenLimit: limit, within: duration)
    }

    guard let candidate, let accepted = TextCleanup.accept(candidate, for: text) else {
      return text
    }
    return accepted
  }

  /// Apple Speech transcribes far more languages than the system model writes,
  /// and asking it to clean one it does not speak returns confident nonsense
  /// rather than an error. Matched on the language alone: the model lists
  /// en-US and en-GB, and an en-IN dictation is still English.
  private static func supportsLanguage(of locale: Locale) -> Bool {
    guard let code = locale.language.languageCode else { return false }
    return SystemLanguageModel.default.supportedLanguages.contains { $0.languageCode == code }
  }

  private func respond(
    to text: String,
    tokenLimit: Int,
    within duration: Duration
  ) async -> String? {
    await withTaskGroup(of: String?.self) { group in
      group.addTask { await self.respond(to: text, tokenLimit: tokenLimit) }
      group.addTask {
        try? await Task.sleep(for: duration)
        return nil
      }
      // Whichever finishes first decides: the model's answer, or the deadline's
      // nil. A model that fails early also lands here, which is the same
      // outcome by a different route.
      let first = await group.next() ?? nil
      group.cancelAll()
      return first
    }
  }

  private func respond(to text: String, tokenLimit: Int) async -> String? {
    let session = session ?? makeSession()
    // Spent before the first suspension, so a second request cannot pick up a
    // session that is already carrying someone's last dictation.
    self.session = nil
    defer { renew() }

    do {
      let response = try await session.respond(
        to: text,
        options: GenerationOptions(sampling: .greedy, maximumResponseTokens: tokenLimit)
      )
      return response.content
    } catch {
      // Guardrail refusals on ordinary dictated speech, an unsupported locale,
      // a context window overrun, and cancellation by the deadline all mean the
      // same thing to the caller.
      return nil
    }
  }

  private func renew() {
    guard SystemLanguageModel.default.isAvailable else {
      session = nil
      return
    }
    let session = makeSession()
    self.session = session
    session.prewarm()
  }

  private func makeSession() -> LanguageModelSession {
    LanguageModelSession(
      instructions: TextCleanup.instructions(
        protectedTerms: protectedTerms,
        styleRules: styleRules
      )
    )
  }
}
