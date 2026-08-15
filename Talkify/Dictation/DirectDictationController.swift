import AppKit

/// The impure half of Direct Dictation: owns the services, translates
/// trigger-monitor events into DictationSessionMachine actions, runs the
/// begin guards, and executes the machine's effects. Every state transition
/// lives in the machine; async completions come back to it as new actions.
@MainActor
final class DirectDictationController {
  /// Carries the session's captured settings while recording so the shell
  /// can mirror session-scoped looks (the status ghost's palette tint);
  /// nil when the session ends.
  var onRecordingStateChange: ((Bool, DictationSessionSettings?) -> Void)?
  /// Fired by the Read Aloud shortcut, only while no dictation session is
  /// active — speaking through the speaker path mid-dictation would feed
  /// the recognizer its own audio.
  var onReadAloudTriggered: (() -> Void)?
  /// A language model downloading, as a locale identifier and progress (0…1),
  /// or nil progress once it finishes. Settings shows it on the language row.
  var onLanguageDownloadChange: ((String, Double?) -> Void)?
  /// A session has ended and its correction watch has been started. The
  /// composition root uses this to distil a full buffer while nothing is
  /// listening.
  var onSessionEnded: (() -> Void)?
  /// A correction was captured from the field Talkify wrote into. Settings
  /// shows how many are held, so the count has to move as they arrive.
  var onCorrectionCaptured: (() -> Void)?

  private static let noSpeechTimeout = Duration.seconds(15)

  private let settings: AppSettings
  private let speechService = SpeechRecognitionService()
  private let hudController: DictationHUDController
  private let textInsertionService = TextInsertionService()
  private let usageTracker: UsageTracker
  private let vocabulary: VocabularyList
  private let styleRules: StyleRuleList
  private let cleanupService: CleanupService
  private lazy var correctionWatcher: CorrectionWatcher = {
    let watcher = CorrectionWatcher(
      insertionService: textInsertionService,
      buffer: corrections
    )
    watcher.onCapture = { [weak self] in self?.onCorrectionCaptured?() }
    return watcher
  }()
  private let corrections: CorrectionBuffer
  let diagnostics = DictationDiagnostics()

  private var keyEventMonitor: GlobalKeyEventMonitor?
  private var machine = DictationSessionMachine()
  private var focusedTarget: TextInsertionService.Target?
  private var noSpeechTask: Task<Void, Never>?
  private var permissionTask: Task<Void, Never>?
  private var permissionWatchTask: Task<Void, Never>?
  private var sessionStartTask: Task<Void, Never>?
  private var isPrepared = false
  private var preparationFailureMessage: String?
  private var currentSessionSettings: DictationSessionSettings?
  /// The languages behind the two trigger keys, resolved to locales Apple
  /// Speech supports. `secondary` is nil unless a second language is chosen.
  private var primaryLocale: Locale?
  private var secondaryLocale: Locale?
  /// Which slot's key began the session in flight, so the session runs in
  /// the language of the key that started it even if Settings change.
  private var activeSlot: GlobalKeyEventMonitor.TriggerSlot = .primary

  init(
    settings: AppSettings,
    hudController: DictationHUDController,
    usageTracker: UsageTracker,
    vocabulary: VocabularyList,
    styleRules: StyleRuleList,
    cleanupService: CleanupService,
    corrections: CorrectionBuffer
  ) {
    self.settings = settings
    self.hudController = hudController
    self.usageTracker = usageTracker
    self.vocabulary = vocabulary
    self.styleRules = styleRules
    self.cleanupService = cleanupService
    self.corrections = corrections
    keyEventMonitor = GlobalKeyEventMonitor { [weak self] event in
      Task { @MainActor [weak self] in
        self?.handle(event)
      }
    }
  }

  func start() {
    applyKeyBindings()
    observeModelDownloads()
    requestPermissionsAndPrepare()
  }

  /// Routes model downloads to both places they matter: the Language section,
  /// and the HUD when a session is already waiting on that very language.
  private func observeModelDownloads() {
    let handler: @Sendable (SpeechRecognitionService.ModelDownload) -> Void = { [weak self] download in
      Task { @MainActor in
        self?.receive(download)
      }
    }

    Task { [speechService] in
      await speechService.setDownloadHandler(handler)
    }
  }

  private func receive(_ download: SpeechRecognitionService.ModelDownload) {
    onLanguageDownloadChange?(download.locale.identifier, download.fraction)

    // Only speak up in the HUD for the language this session is waiting on.
    guard machine.isSessionActive, locale(for: activeSlot) == download.locale else { return }

    guard let fraction = download.fraction else {
      hudController.showModelDownload(nil)
      return
    }
    let name = SpeechLanguageCatalog.shortName(for: download.locale)
    hudController.showModelDownload(
      "Downloading \(name)… \(Int(fraction * 100))%"
    )
  }

  /// Pushes the recorded Settings bindings into the event tap; called at
  /// start and whenever the Shortcuts section changes them.
  func applyKeyBindings() {
    keyEventMonitor?.setBindings(
      trigger: settings.dictationTriggerBinding,
      secondaryTrigger: settings.isSecondLanguageEnabled
        ? settings.secondaryTriggerBinding
        : nil,
      readAloud: settings.readAloudBinding
    )
    keyEventMonitor?.setEventHandlingSuspended(settings.isRecordingKeybind)
  }

  /// Re-resolves both languages and warms them. Called whenever the Language
  /// section changes a pick, so the key you press next is already prepared
  /// rather than building its analyzer on the keypress.
  func applyLanguages() {
    Task { [weak self] in
      guard let self else { return }
      do {
        try await prepareLanguages()
        isPrepared = true
        preparationFailureMessage = nil
      } catch {
        isPrepared = false
        preparationFailed(message: error.localizedDescription)
      }
    }
  }

  /// Re-biases the warm analyzers after the Vocabulary section edits the list.
  /// Cheap and off the keypress path, so it runs on every edit rather than
  /// waiting for the next session.
  func applyVocabulary() {
    Task { [weak self] in
      guard let self else { return }
      let terms = vocabulary.contextualStrings
      await speechService.setVocabulary(terms)
      // The same list, for the opposite reason: Speech is biased toward these
      // spellings, and cleanup is told not to undo them.
      await cleanupService.setProtectedTerms(terms)
    }
  }

  /// Resolves both picks, drops anything no longer bound to a key, then warms
  /// the primary language. The second warms behind it and never throws: a
  /// model that still needs downloading must not delay the primary key.
  private func prepareLanguages() async throws {
    let primary = try await speechService.resolveLocale(
      identifier: settings.recognitionLocaleIdentifier
    )
    primaryLocale = primary

    // Resolved strictly: a stored pick this Mac cannot transcribe drops the
    // second language instead of quietly becoming the system default, which
    // would dictate in a language the user never chose.
    var secondary: Locale?
    if settings.isSecondLanguageEnabled {
      secondary = await speechService.supportedLocale(
        identifier: settings.secondaryRecognitionLocaleIdentifier
      )
    }
    // A second language equal to the first is not a second language.
    secondaryLocale = secondary == primary ? nil : secondary

    let bound = [primary, secondaryLocale].compactMap(\.self)
    // Before the warm-up, not after: a session prepared without the Vocabulary
    // would have to be re-biased, and both languages should be warmed once,
    // already biased.
    await speechService.setVocabulary(vocabulary.contextualStrings)
    await cleanupService.setProtectedTerms(vocabulary.contextualStrings)
    await cleanupService.setStyleRules(styleRules.globalText)
    // Warmed alongside the analyzers and for the same reason: the model is
    // asked for the first time at the end of a session, not the start of one.
    await cleanupService.prepare()
    await speechService.retainOnly(locales: bound)
    try await speechService.prewarm(locale: primary)

    if let secondaryLocale {
      try? await speechService.prewarm(locale: secondaryLocale)
    }
  }

  private func locale(for slot: GlobalKeyEventMonitor.TriggerSlot) -> Locale? {
    switch slot {
    case .primary: primaryLocale
    case .secondary: secondaryLocale ?? primaryLocale
    }
  }

  /// The HUD's language tag, shown only once a second language exists: with
  /// one language there is nothing to disambiguate.
  private var activeLanguageTag: String? {
    guard secondaryLocale != nil, let locale = locale(for: activeSlot) else { return nil }
    return SpeechLanguageCatalog.tag(for: locale)
  }

  func stop() {
    noSpeechTask?.cancel()
    permissionTask?.cancel()
    permissionWatchTask?.cancel()
    sessionStartTask?.cancel()
    keyEventMonitor?.stop()
    isPrepared = false

    correctionWatcher.cancel()

    Task { [speechService, cleanupService] in
      await speechService.shutDown()
      await cleanupService.shutDown()
    }
  }

  func toggleFromMenu() {
    // The menu item has no language of its own, so it dictates in the first.
    if !machine.isSessionActive {
      activeSlot = .primary
    }
    send(.menuToggled(now: .now))
  }

  func requestPermissionsAndPrepare() {
    permissionTask?.cancel()
    isPrepared = false
    preparationFailureMessage = nil
    PermissionService.requestAccessibilityAccess()
    PermissionService.requestInputMonitoringAccess()

    permissionTask = Task { [weak self] in
      guard let self else { return }

      let microphoneGranted = await PermissionService.requestMicrophoneAccess()
      guard !Task.isCancelled else { return }
      guard microphoneGranted else {
        preparationFailed(message: "Microphone permission required")
        return
      }

      let speechGranted = await PermissionService.requestSpeechAccess()
      guard !Task.isCancelled else { return }
      guard speechGranted else {
        preparationFailed(message: "Speech permission required")
        return
      }

      do {
        try await prepareLanguages()
      } catch {
        guard !Task.isCancelled else { return }
        preparationFailed(message: error.localizedDescription)
        return
      }

      isPrepared = true
      installTriggerMonitor()
    }
  }

  /// Watches for a permission the user is granting right now.
  ///
  /// Both permissions are granted in System Settings while Talkify is already
  /// running, and macOS tells the app nothing when they change. Checking once at
  /// launch meant the trigger key stayed dead after the user had done everything
  /// right, with no hint that a relaunch was needed. This polls instead, and
  /// installs the tap the moment it is allowed to.
  private func startPermissionWatch() {
    guard permissionWatchTask == nil else { return }

    permissionWatchTask = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(1))
        guard !Task.isCancelled, let self else { return }
        // Never interrupt the dialog the user is reading.
        guard !PermissionAlert.isPresenting else { continue }
        guard PermissionService.hasAccessibilityAccess,
           PermissionService.hasInputMonitoringAccess else { continue }

        permissionWatchTask = nil
        if keyEventMonitor?.start() == true {
          hudController.showMessage("Talkify is ready")
        } else {
          PermissionAlert.requestRelaunch()
        }
        return
      }
    }
  }

  private func handle(_ event: GlobalKeyEventMonitor.Event) {
    DictationLog.session.notice("key: \(String(describing: event), privacy: .public)")
    switch event {
    case let .triggerPressed(slot):
      // While a session runs, only the key that started it controls it. The
      // other language's key is inert until this session ends, so a latched
      // German session cannot be stopped by the English key.
      if machine.isSessionActive {
        guard slot == activeSlot else { return }
      } else {
        activeSlot = slot
      }
      send(.triggerPressed(now: .now))
    case let .triggerReleased(slot):
      guard slot == activeSlot else { return }
      send(.triggerReleased(now: .now))
    case .cancelPressed:
      send(.escapePressed)
    case .readAloudPressed:
      send(.readAloudPressed)
    }
  }

  private func send(_ action: DictationSessionMachine.Action) {
    perform(machine.reduce(action))
  }

  private func perform(_ effects: [DictationSessionMachine.Effect]) {
    for effect in effects {
      perform(effect)
    }
  }

  private func perform(_ effect: DictationSessionMachine.Effect) {
    switch effect {
    case .checkAndBegin:
      checkAndBegin()
    case .beginRecognition:
      beginRecognition()
    case let .finishRecognition(speakingDuration):
      finishRecognition(speakingDuration: speakingDuration)
    case .cancelRecognition:
      Task { [weak self] in
        guard let self else { return }
        await speechService.cancel()
        send(.sessionEnded)
      }
    case .cancelStartTask:
      sessionStartTask?.cancel()
    case let .setEscapeCapture(enabled):
      keyEventMonitor?.setEscapeCaptureEnabled(enabled)
    case .startNoSpeechTimer:
      startNoSpeechTimer()
    case .stopNoSpeechTimer:
      stopNoSpeechTimer()
    case let .showListening(latched):
      let session = settings.sessionSettings
      currentSessionSettings = session
      hudController.showListening(
        on: focusedTarget?.displayID,
        isLatched: latched,
        settings: session,
        languageTag: activeLanguageTag
      )
    case .showLatched:
      hudController.showLatched()
    case .showLiveText:
      if let pendingLiveText {
        hudController.showLiveText(pendingLiveText)
      }
    case .showFinalizing:
      hudController.showFinalizing()
    case .hideHUD:
      hudController.hide()
    case let .notifyRecording(isRecording):
      if !isRecording {
        focusedTarget = nil
        sessionStartTask = nil
        currentSessionSettings = nil
      }
      onRecordingStateChange?(isRecording, currentSessionSettings)
    case .triggerReadAloud:
      onReadAloudTriggered?()
    }
  }

  /// The text carried alongside the current `updateReceived` action; the
  /// machine decides whether it shows, the controller remembers what.
  private var pendingLiveText: String?

  private func checkAndBegin() {
    guard isPrepared else {
      hudController.showMessage(preparationFailureMessage ?? "Preparing speech…")
      send(.beginRejected)
      return
    }

    if !PermissionService.hasAccessibilityAccess {
      // One dialog that explains it, not the system prompt again on every press.
      PermissionAlert.requestSetup(for: .accessibility)
      startPermissionWatch()
      send(.beginRejected)
      return
    }

    // The previous session's field is behind them now, and a read against it
    // would land on whatever they typed next.
    correctionWatcher.cancel()

    let target = textInsertionService.captureFocusedTarget()
    DictationLog.session.notice(
      """
      begin: app=\(target?.bundleIdentifier ?? "none", privacy: .public) \
      element=\(target?.hasFocusedElement ?? false, privacy: .public) \
      secure=\(target?.isSecure ?? false, privacy: .public)
      """
    )
    if target?.isSecure == true {
      hudController.showMessage("Secure field", on: target?.displayID)
      send(.beginRejected)
      return
    }

    focusedTarget = target
    send(.beginApproved)
  }

  private func beginRecognition() {
    guard let locale = locale(for: activeSlot) else {
      fail(message: "Preparing speech…", wasCancelled: false)
      return
    }

    sessionStartTask = Task { [weak self] in
      guard let self else { return }
      do {
        try await speechService.start(
          locale: locale,
          updateHandler: { [weak self] update in
            Task { @MainActor [weak self] in
              self?.receive(update)
            }
          },
          failureHandler: { [weak self] message in
            Task { @MainActor [weak self] in
              self?.fail(message: message, wasCancelled: false)
            }
          },
          levelHandler: { [weak self] level in
            Task { @MainActor [weak self] in
              self?.hudController.showAudioLevel(level)
            }
          }
        )
        guard !Task.isCancelled else {
          await speechService.cancel()
          send(.sessionEnded)
          return
        }
        sessionStartTask = nil
        send(.recognitionStarted(now: .now))
      } catch {
        sessionStartTask = nil
        if Task.isCancelled {
          send(.recognitionFailed(wasCancelled: true))
        } else {
          fail(message: error.localizedDescription, wasCancelled: false)
        }
      }
    }
  }

  private func receive(_ update: SpeechRecognitionService.Update) {
    let displayText = update.displayText
    let hasVisibleText = !displayText
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .isEmpty
    pendingLiveText = displayText
    send(.updateReceived(hasVisibleText: hasVisibleText))
    pendingLiveText = nil
  }

  private func finishRecognition(speakingDuration: TimeInterval) {
    Task { [weak self] in
      guard let self else { return }
      do {
        let text = try await speechService.finish()
        DictationLog.session.notice(
          "recognized: \(text.count, privacy: .public) characters"
        )
        // Cleanup runs before the HUD comes down, so the wait it adds reads as
        // the session still working rather than as nothing happening.
        let insertedText = await cleanedText(for: text)
        hudController.hide()
        DictationLog.session.notice(
          "inserting: \(insertedText.count, privacy: .public) characters"
        )
        let outcome = await textInsertionService.insert(insertedText, into: focusedTarget)
        DictationLog.session.notice("outcome: \(outcome.title, privacy: .public)")
        diagnostics.record(
          applicationName: focusedTarget?.applicationName,
          characterCount: insertedText.count,
          hadFocusedElement: focusedTarget?.hasFocusedElement ?? false,
          outcome: outcome
        )
        // Started before the target is released, since the watcher's baseline
        // read needs the element that was just written to.
        if settings.isCleanupLearningEnabled {
          correctionWatcher.watch(inserted: insertedText, target: focusedTarget)
        }
        hudController.playPasteSound()
        send(.sessionEnded)
        onSessionEnded?()
        let wordCount = UsageMetrics.wordCount(in: insertedText)
        await usageTracker.recordSession(
          wordCount: wordCount,
          speakingDuration: speakingDuration
        )
      } catch {
        fail(message: error.localizedDescription, wasCancelled: false)
      }
    }
  }

  /// The finalized draft, polished if the person asked for that and the model
  /// managed it. Every other outcome — cleanup off, no locale, an unavailable
  /// model, a refusal, a missed deadline — returns exactly what was said.
  private func cleanedText(for text: String) async -> String {
    guard settings.isCleanupEnabled, let locale = locale(for: activeSlot) else { return text }
    hudController.showCleaning()
    return await cleanupService.clean(
      text,
      locale: locale,
      applicationRules: styleRules.text(forBundleIdentifier: focusedTarget?.bundleIdentifier),
      pacing: settings.cleanupPacing.pacing(
        deadlineMilliseconds: settings.cleanupDeadlineMilliseconds
      )
    )
  }

  /// Re-applies the always-on style rules after the Cleanup section edits
  /// them. Off the keypress path, like the Vocabulary: the standing
  /// instructions change, so the warm session is rebuilt around them.
  func applyStyleRules() {
    Task { [weak self] in
      guard let self else { return }
      await cleanupService.setStyleRules(styleRules.globalText)
    }
  }

  /// A failure path always ends with the message shown after the reset —
  /// the machine handles the transition, the controller the message.
  private func fail(message: String, wasCancelled: Bool) {
    let effects = machine.reduce(.recognitionFailed(wasCancelled: wasCancelled))
    guard !effects.isEmpty else { return }

    if !wasCancelled {
      diagnostics.recordFailure(message)
      DictationLog.session.error("failed: \(message, privacy: .public)")
    }

    if effects.contains(.cancelRecognition) {
      // Active failure: cancel recognition, reset, then show why.
      for effect in effects where effect != .cancelRecognition {
        perform(effect)
      }
      Task { [weak self] in
        guard let self else { return }
        await speechService.cancel()
        send(.sessionEnded)
        hudController.showMessage(message)
      }
    } else {
      perform(effects)
    }
  }

  private func startNoSpeechTimer() {
    noSpeechTask?.cancel()
    noSpeechTask = Task { [weak self] in
      try? await Task.sleep(for: Self.noSpeechTimeout)
      guard !Task.isCancelled else { return }
      self?.send(.noSpeechTimedOut)
    }
  }

  private func stopNoSpeechTimer() {
    noSpeechTask?.cancel()
    noSpeechTask = nil
  }

  private func installTriggerMonitor() {
    guard PermissionService.hasAccessibilityAccess else {
      PermissionAlert.requestSetup(for: .accessibility)
      startPermissionWatch()
      return
    }

    guard PermissionService.hasInputMonitoringAccess else {
      PermissionService.requestInputMonitoringAccess()
      PermissionAlert.requestSetup(for: .inputMonitoring)
      startPermissionWatch()
      return
    }

    // Granted, but macOS decides what this process may do when it launches, so
    // the tap can still be refused. Only a fresh launch clears that, and saying
    // so is the whole point of the dialog.
    guard keyEventMonitor?.start() == true else {
      PermissionAlert.requestRelaunch()
      return
    }
  }

  private func preparationFailed(message: String) {
    preparationFailureMessage = message
    hudController.showMessage(message)
  }
}
