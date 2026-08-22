import AppKit

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  private var settings: AppSettings?
  private var statusItemController: StatusItemController?
  private var hudStage: HUDStage?
  private var hudController: DictationHUDController?
  private var dropTranscriptionController: DropTranscriptionController?
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
  private let launchAtLoginService = LaunchAtLoginService()

  static func main() {
    let application = NSApplication.shared
    let delegate = AppDelegate()
    application.delegate = delegate
    application.run()
  }
 
 

  /// True while this process hosts the test suite rather than a user.
  ///
  /// The live launch path requests microphone and speech permissions and
  /// installs the event tap, which pops system permission dialogs over every
  /// automated test run on a machine that has not granted them. Hosting
  /// tests skips the launch entirely: tests build the objects they exercise,
  /// and a test that means to see a permission prompt drives
  /// PermissionService itself, on purpose.
  private static var isHostingTests: Bool {
    let environment = ProcessInfo.processInfo.environment
    return environment["XCTestSessionIdentifier"] != nil
      || environment["XCTestConfigurationFilePath"] != nil
      || environment["XCTestBundlePath"] != nil
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    guard !Self.isHostingTests else { return }

    // Before anything can be staged: a crash or a force-quit while a
    // transcript card was on screen leaves the user's speech in cleartext
    // under $TMPDIR, and nothing else ever removes it.
    StagedTranscript.sweep()

    let settings = AppSettings()
    self.settings = settings
    // One shape, two features. The stage owns the window and hands it out;
    // each feature's HUD controller only decides what its surface says.
    let stage = HUDStage(settings: settings)
    self.hudStage = stage
    let hudController = DictationHUDController(stage: stage, settings: settings)
    let usageTracker = UsageTracker()
    let vocabulary = VocabularyList()
    let styleRules = StyleRuleList()
    let suggestions = CleanupSuggestionQueue(styleRules: styleRules, vocabulary: vocabulary)
    let cleanupService = CleanupService()
    let corrections = CorrectionBuffer(store: CorrectionStore())
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
    dictationController.onCorrectionCaptured = { [weak learningController] in
      learningController?.refresh()
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

    let dropTranscriptionController = DropTranscriptionController(
      settings: settings,
      hud: DropHUDController(stage: stage)
    )
    self.dropTranscriptionController = dropTranscriptionController
    dropTranscriptionController.start()
    dropTranscriptionController.onProgressChange = { [weak self, weak settings] fraction in
      self?.statusItemController?.setTranscriptionProgress(
        fraction,
        accent: settings?.sessionSettings.dropAccent ?? SettingsTheme.accentColor
      )
    }

    let statusItemController = StatusItemController(
      toggleDictation: { dictationController.toggleFromMenu() },
      toggleReadAloud: { readAloudController.toggle() },
      transcribeFile: { dropTranscriptionController.pickFile() },
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

    // Compiles the HUD's shaders now, so the cost does not land on the first
    // frames of the first dictation.
    HUDShaderWarmUp.start()

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
    learningController.load()

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

  /// A released trigger whose text has not landed yet is the one thing worth
  /// delaying a quit for: the user spoke it and expects to see it. AppKit's
  /// deferred termination is the only way to wait, because
  /// `applicationWillTerminate` is synchronous and the finish needs the main
  /// actor to make progress.
  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard let dictationController, dictationController.isFinishing else {
      return .terminateNow
    }
    Task { @MainActor in
      await dictationController.waitForFinish(timeout: .seconds(2))
      sender.reply(toApplicationShouldTerminate: true)
    }
    return .terminateLater
  }

  func applicationWillTerminate(_ notification: Notification) {
    dictationController?.stop()
    learningController?.cancel()
    calibrator?.cancel()
    // A transcript the HUD is still offering only exists in its staging folder,
    // so quitting writes it out rather than losing it.
    dropTranscriptionController?.commitOfferedTranscript()
  }

  private func showSettings() {
    guard let settings, let usageTracker, let vocabulary, let styleRules, let suggestions,
      let calibrator, let learningController, let dictationController
    else { return }
    if settingsWindowController == nil {
      settingsWindowController = SettingsWindowController(
        settings: settings,
        sounds: HUDSounds(),
        runtimeState: settingsRuntimeState,
        usageTracker: usageTracker,
        vocabulary: vocabulary,
        styleRules: styleRules,
        suggestions: suggestions,
        calibrator: calibrator,
        learning: learningController,
        diagnostics: dictationController.diagnostics,
        updater: updaterService,
        launchAtLogin: launchAtLoginService
      )
    }
    settingsWindowController?.show()
  }
}
