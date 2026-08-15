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
  func clean(
    _ text: String,
    locale: Locale,
    applicationRules: [String] = [],
    pacing: Pacing
  ) async -> String {
    guard TextCleanup.shouldAttempt(text) else { return text }
    guard SystemLanguageModel.default.isAvailable else { return text }
    guard Self.supportsLanguage(of: locale) else { return text }

    let prompt = TextCleanup.prompt(for: text, applicationRules: applicationRules)
    let limit = TextCleanup.responseTokenLimit(for: text)
    let candidate: String?
    switch pacing {
    case .waitForQuality:
      candidate = await respond(to: prompt, tokenLimit: limit)
    case let .deadline(duration):
      candidate = await respond(to: prompt, tokenLimit: limit, within: duration)
    }

    guard let candidate, let accepted = TextCleanup.accept(candidate, for: text) else {
      return text
    }
    return accepted
  }

  /// Turns a batch of correction pairs into things worth proposing: short
  /// style rules, and Vocabulary terms for words the recognizer misspelled.
  ///
  /// Nothing here is applied. The answer becomes a review queue, because a
  /// model reading a handful of edits will sometimes find a habit that is
  /// really a coincidence, and the person is the one who knows which.
  ///
  /// This runs on its own throwaway session rather than the cleanup one: it is
  /// a different job with a different brief, and the cleanup session's warm
  /// state is worth more than reusing it here.
  func distill(_ pairs: [CorrectionPair]) async -> [CleanupSuggestion] {
    guard !pairs.isEmpty, SystemLanguageModel.default.isAvailable else { return [] }

    let session = LanguageModelSession(instructions: Self.distillationInstructions)
    do {
      let response = try await session.respond(
        to: Self.distillationPrompt(for: pairs),
        schema: try Self.distillationSchema(),
        options: GenerationOptions(sampling: .greedy, maximumResponseTokens: 512)
      )
      let styleRules = (try? response.content.value([String].self, forProperty: "styleRules")) ?? []
      let terms = (try? response.content.value([String].self, forProperty: "vocabularyTerms")) ?? []

      // A style rule is scoped to one application only when every correction it
      // could have come from was in that application. Otherwise it is a habit,
      // not an app-specific one.
      let scope = Self.sharedScope(of: pairs)
      return styleRules.map {
        CleanupSuggestion(
          kind: .styleRule,
          text: $0,
          bundleIdentifier: scope?.bundleIdentifier,
          applicationName: scope.map(\.title)
        )
      } + terms.map { CleanupSuggestion(kind: .vocabularyTerm, text: $0) }
    } catch {
      return []
    }
  }

  private static let distillationInstructions = """
    You are given pairs of text: what a dictation app inserted, and what the \
    person edited it into. Find the habits behind the edits.

    Report two kinds of thing, and nothing else.

    Style rules: short instructions in plain language, the way one person would \
    describe a preference to another — "prefer OK over okay", "no greeting", \
    "keep sentences short". Only report a habit you can see more than once. \
    Do not report a one-off fix as a rule.

    Vocabulary terms: words the recognizer clearly misheard, given in the \
    spelling the person corrected them to. Names, acronyms and jargon. One or \
    two words each, never a sentence.

    Report nothing at all rather than guessing. An empty answer is a good answer.
    """

  private static func distillationPrompt(for pairs: [CorrectionPair]) -> String {
    pairs
      .enumerated()
      .map { index, pair in
        """
        \(index + 1).
        Inserted: \(pair.inserted)
        Edited to: \(pair.corrected)
        """
      }
      .joined(separator: "\n\n")
  }

  /// Built at runtime rather than with `@Generable`, which needs a macro plugin
  /// the Command Line Tools do not ship (docs/local-build.md).
  private static func distillationSchema() throws -> GenerationSchema {
    let line = DynamicGenerationSchema(type: String.self)
    let root = DynamicGenerationSchema(
      name: "CorrectionHabits",
      properties: [
        DynamicGenerationSchema.Property(
          name: "styleRules",
          description: "Short plain-language writing preferences seen more than once.",
          schema: DynamicGenerationSchema(arrayOf: line, maximumElements: 5)
        ),
        DynamicGenerationSchema.Property(
          name: "vocabularyTerms",
          description: "Words the recognizer misheard, in their corrected spelling.",
          schema: DynamicGenerationSchema(arrayOf: line, maximumElements: 5)
        ),
      ]
    )
    return try GenerationSchema(root: root, dependencies: [])
  }

  private static func sharedScope(of pairs: [CorrectionPair]) -> StyleRuleScope? {
    let identifiers = Set(pairs.map(\.bundleIdentifier))
    guard identifiers.count == 1, let identifier = identifiers.first ?? nil else { return nil }
    let name = pairs.first { $0.bundleIdentifier == identifier }?.applicationName
    return .application(bundleIdentifier: identifier, name: name ?? identifier)
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
