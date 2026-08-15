import AppKit

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  private var settings: AppSettings?
  private var statusItemController: StatusItemController?
  private var hudController: DictationHUDController?
  private var dictationController: DirectDictationController?
  private var readAloudController: ReadAloudController?
  private var settingsWindowController: SettingsWindowController?
  private var usageTracker: UsageTracker?
  private var vocabulary: VocabularyList?
  private var styleRules: StyleRuleList?
  private var suggestions: CleanupSuggestionQueue?
  private var learningController: CleanupLearningController?
  private var calibrator: CleanupCalibrator?
  private let settingsRuntimeState = SettingsRuntimeState()
  private let updaterService = SparkleUpdaterService()

  static func main() {
    let application = NSApplication.shared
    let delegate = AppDelegate()
    application.delegate = delegate
    application.run()
  }
 
 

  func applicationDidFinishLaunching(_ notification: Notification) {
    let settings = AppSettings()
    self.settings = settings
    let hudController = DictationHUDController(settings: settings)
    let usageTracker = UsageTracker()
    let vocabulary = VocabularyList()
    let styleRules = StyleRuleList()
    let suggestions = CleanupSuggestionQueue(styleRules: styleRules, vocabulary: vocabulary)
    let cleanupService = CleanupService()
    let corrections = CorrectionBuffer()
    let dictationController = DirectDictationController(
      settings: settings,
      hudController: hudController,
      usageTracker: usageTracker,
      vocabulary: vocabulary,
      styleRules: styleRules,
      cleanupService: cleanupService,
      corrections: corrections
    )
    let learningController = CleanupLearningController(
      buffer: corrections,
      cleanupService: cleanupService,
      queue: suggestions
    )
    let calibrator = CleanupCalibrator(service: cleanupService)
    dictationController.onSessionEnded = { [weak learningController] in
      learningController?.distillIfReady()
    }
    self.hudController = hudController
    self.dictationController = dictationController
    self.usageTracker = usageTracker
    self.vocabulary = vocabulary
    self.styleRules = styleRules
    self.suggestions = suggestions
    self.learningController = learningController
    self.calibrator = calibrator

    let readAloudController = ReadAloudController(
      settings: settings,
      hudController: hudController
    )
    self.readAloudController = readAloudController

    let statusItemController = StatusItemController(
      toggleDictation: { dictationController.toggleFromMenu() },
      toggleReadAloud: { readAloudController.toggle() },
      openSettings: { [weak self] in self?.showSettings() },
      checkForUpdates: { [weak self] in self?.updaterService.checkForUpdates() }
    )
    self.statusItemController = statusItemController

    dictationController.onRecordingStateChange = {
      [weak statusItemController, weak settingsRuntimeState] isRecording, session in
      let accent = session.flatMap {
        $0.voiceVisual == .glow ? $0.glowPalette.statusAccent : nil
      }
      statusItemController?.setRecording(isRecording, accent: accent)
      settingsRuntimeState?.isDictating = isRecording
    }
    dictationController.onLanguageDownloadChange = {
      [weak settingsRuntimeState] identifier, fraction in
      settingsRuntimeState?.setDownload(identifier: identifier, fraction: fraction)
    }
    readAloudController.onSpeakingStateChange = {
      [weak statusItemController] isSpeaking in
      statusItemController?.setSpeaking(isSpeaking)
    }
    // Option+Escape toggles Read Aloud; the dictation controller owns
    // the event tap and fires this only while no session is active.
    dictationController.onReadAloudTriggered = { [weak readAloudController] in
      readAloudController?.toggle()
    }

    // Requests permissions and prepares the selected Speech Model
    // shortly after launch (CONTEXT.md).
    dictationController.start()

    applyKeyBindings()
    observeKeyBindings()
    observeLanguages()
    observeVocabulary()
    observeStyleRules()

    // Loaded behind the prewarm rather than delaying it, and only once the
    // loops above are watching: what each file holds arrives as a change,
    // which re-biases the analyzers and the cleanup session already warm.
    Task { await vocabulary.load() }
    Task { await styleRules.load() }
    Task { await suggestions.load() }

    // A background check is postponed while a session is running, so an update
    // window can never take focus mid-dictation and move the insertion target.
    updaterService.isBusy = { [weak settingsRuntimeState] in
      settingsRuntimeState?.isDictating ?? false
    }

    // Last: a scheduled check can show a window, and it must never land
    // before the status item and dictation are wired.
    updaterService.start()
  }

  /// Rebinding in Settings updates the event tap and the status menu
  /// hints immediately; Observation re-arms after every change. The same
  /// loop pauses trigger handling while a key recorder is armed.
  private func observeKeyBindings() {
    guard let settings else { return }
    withObservationTracking {
      _ = settings.dictationTriggerBinding
      _ = settings.secondaryTriggerBinding
      _ = settings.readAloudBinding
      _ = settings.isRecordingKeybind
      // The second trigger is only installed once a second language exists,
      // so the pick that enables it belongs in this loop too.
      _ = settings.secondaryRecognitionLocaleIdentifier
    } onChange: { [weak self] in
      Task { @MainActor [weak self] in
        self?.applyKeyBindings()
        self?.observeKeyBindings()
      }
    }
  }

  /// Changing a language in Settings re-resolves and re-warms both, so the
  /// next keypress meets a prepared analyzer rather than a cold one.
  private func observeLanguages() {
    guard let settings else { return }
    withObservationTracking {
      _ = settings.recognitionLocaleIdentifier
      _ = settings.secondaryRecognitionLocaleIdentifier
    } onChange: { [weak self] in
      Task { @MainActor [weak self] in
        self?.dictationController?.applyLanguages()
        self?.observeLanguages()
      }
    }
  }

  /// Editing the Vocabulary re-biases the warm analyzers immediately, so the
  /// next session picks up a term added seconds earlier without a relaunch.
  private func observeVocabulary() {
    guard let vocabulary else { return }
    withObservationTracking {
      _ = vocabulary.terms
    } onChange: { [weak self] in
      Task { @MainActor [weak self] in
        self?.dictationController?.applyVocabulary()
        self?.observeVocabulary()
      }
    }
  }

  /// Editing a Cleanup style rule rebuilds the warm model session around the
  /// new standing instructions, so the next dictation is polished the new way
  /// without a relaunch.
  private func observeStyleRules() {
    guard let styleRules else { return }
    withObservationTracking {
      _ = styleRules.rules
    } onChange: { [weak self] in
      Task { @MainActor [weak self] in
        self?.dictationController?.applyStyleRules()
        self?.observeStyleRules()
      }
    }
  }

  private func applyKeyBindings() {
    guard let settings else { return }
    dictationController?.applyKeyBindings()
    statusItemController?.setKeyBindings(
      trigger: settings.dictationTriggerBinding,
      readAloud: settings.readAloudBinding
    )
  }

  func applicationWillTerminate(_ notification: Notification) {
    dictationController?.stop()
    learningController?.cancel()
    calibrator?.cancel()
  }

  private func showSettings() {
    guard let settings, let usageTracker, let vocabulary, let styleRules, let suggestions,
      let calibrator
    else { return }
    if settingsWindowController == nil {
      settingsWindowController = SettingsWindowController(
        settings: settings,
        sounds: DictationHUDSounds(),
        runtimeState: settingsRuntimeState,
        usageTracker: usageTracker,
        vocabulary: vocabulary,
        styleRules: styleRules,
        suggestions: suggestions,
        calibrator: calibrator,
        updater: updaterService
      )
    }
    settingsWindowController?.show()
  }
}
