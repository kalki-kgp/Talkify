import AppKit
import ApplicationServices

@MainActor
final class TextInsertionService {
  struct Target {
    /// Nil when the application refuses to name its focused element. Chromium
    /// does this for everything drawn by the renderer — a YouTube search box, a
    /// Gmail compose window — and it cannot be talked out of it:
    /// `AXManualAccessibility` answers "attribute unsupported" and
    /// `AXEnhancedUserInterface` answers "not implemented".
    ///
    /// A nil element is not a dead end, because the paste route never needed
    /// the element. It needs the right application to be frontmost, and that is
    /// knowable.
    fileprivate let element: AXUIElement?
    fileprivate let processIdentifier: pid_t
    /// Readable outside insertion because Text Cleanup scopes its style rules
    /// by application — the app about to receive the text is the app whose
    /// rules apply.
    let bundleIdentifier: String?

    let isSecure: Bool
    let displayID: CGDirectDisplayID?

    /// False when the application would not name its focused element, which is
    /// the difference between "pasting is the only option here" and "the field
    /// was there and something else went wrong".
    var hasFocusedElement: Bool { element != nil }

    var applicationName: String? {
      NSRunningApplication(processIdentifier: processIdentifier)?.localizedName
    }

    init(
      element: AXUIElement?,
      processIdentifier: pid_t,
      bundleIdentifier: String? = nil,
      isSecure: Bool,
      displayID: CGDirectDisplayID?
    ) {
      self.element = element
      self.processIdentifier = processIdentifier
      self.bundleIdentifier = bundleIdentifier
      self.isSecure = isSecure
      self.displayID = displayID
    }
  }

  private enum Route {
    case accessibility
    case paste
  }

  /// Where the text ended up. Reported in Settings, because "nothing happened"
  /// covers four different failures and they need different answers.
  enum Outcome: Equatable {
    case nothingToInsert
    case setInPlace
    case pasted
    case leftOnClipboard(reason: String)

    var title: String {
      switch self {
      case .nothingToInsert: "Nothing to insert"
      case .setInPlace: "Written straight into the field"
      case .pasted: "Pasted"
      case .leftOnClipboard: "Left on the clipboard"
      }
    }

    var detail: String? {
      switch self {
      case let .leftOnClipboard(reason): reason
      default: nil
      }
    }
  }

  struct Dependencies {
    let pasteboard: NSPasteboard
    let focusedElement: @MainActor () -> AXUIElement?
    let frontmostApplication: @MainActor () -> NSRunningApplication?
    let isProcessRunning: @MainActor (pid_t) -> Bool
    let isTargetFocused: @MainActor (Target) -> Bool
    let postPasteShortcut: @MainActor () -> Bool
    let waitForPasteRead: @MainActor () async -> Void
    /// The three halves of the Accessibility write, separated so the
    /// verification around them can be tested against an app that lies.
    let isSelectedTextSettable: @MainActor (AXUIElement) -> Bool
    let readElementValue: @MainActor (AXUIElement) -> String?
    let setSelectedText: @MainActor (AXUIElement, String) -> Bool
    let waitForAccessibilitySettle: @MainActor () async -> Void

    /// The Accessibility seams default to "this field cannot be written",
    /// which is the universal paste route and nothing else. A test that cares
    /// about the write says so; every other one describes pasting.
    init(
      pasteboard: NSPasteboard,
      focusedElement: @escaping @MainActor () -> AXUIElement?,
      frontmostApplication: @escaping @MainActor () -> NSRunningApplication?,
      isProcessRunning: @escaping @MainActor (pid_t) -> Bool,
      isTargetFocused: @escaping @MainActor (Target) -> Bool,
      postPasteShortcut: @escaping @MainActor () -> Bool,
      waitForPasteRead: @escaping @MainActor () async -> Void,
      isSelectedTextSettable: @escaping @MainActor (AXUIElement) -> Bool = { _ in false },
      readElementValue: @escaping @MainActor (AXUIElement) -> String? = { _ in nil },
      setSelectedText: @escaping @MainActor (AXUIElement, String) -> Bool = { _, _ in false },
      waitForAccessibilitySettle: @escaping @MainActor () async -> Void = {}
    ) {
      self.pasteboard = pasteboard
      self.focusedElement = focusedElement
      self.frontmostApplication = frontmostApplication
      self.isProcessRunning = isProcessRunning
      self.isTargetFocused = isTargetFocused
      self.postPasteShortcut = postPasteShortcut
      self.waitForPasteRead = waitForPasteRead
      self.isSelectedTextSettable = isSelectedTextSettable
      self.readElementValue = readElementValue
      self.setSelectedText = setSelectedText
      self.waitForAccessibilitySettle = waitForAccessibilitySettle
    }

    static var live: Self {
      Self(
        pasteboard: .general,
        focusedElement: TextInsertionService.focusedElement,
        frontmostApplication: { NSWorkspace.shared.frontmostApplication },
        isProcessRunning: { processIdentifier in
          guard let application = NSRunningApplication(
            processIdentifier: processIdentifier
          ) else {
            return false
          }
          return !application.isTerminated
        },
        isTargetFocused: TextInsertionService.isStillFocused,
        postPasteShortcut: TextInsertionService.postPasteShortcut,
        waitForPasteRead: {
          try? await Task.sleep(for: .milliseconds(500))
        },
        isSelectedTextSettable: { element in
          var isSettable: DarwinBoolean = false
          let result = AXUIElementIsAttributeSettable(
            element,
            kAXSelectedTextAttribute as CFString,
            &isSettable
          )
          return result == .success && isSettable.boolValue
        },
        readElementValue: { element in
          var value: CFTypeRef?
          guard AXUIElementCopyAttributeValue(
            element,
            kAXValueAttribute as CFString,
            &value
          ) == .success else { return nil }
          return value as? String
        },
        setSelectedText: { element, text in
          AXUIElementSetAttributeValue(
            element,
            kAXSelectedTextAttribute as CFString,
            text as CFString
          ) == .success
        },
        waitForAccessibilitySettle: {
          try? await Task.sleep(for: .milliseconds(150))
        }
      )
    }
  }

  private let dependencies: Dependencies
  private var routesByBundleIdentifier: [String: Route] = [:]

  init(dependencies: Dependencies = .live) {
    self.dependencies = dependencies
  }

  func captureFocusedTarget() -> Target? {
    if let element = dependencies.focusedElement() {
      var processIdentifier: pid_t = 0
      AXUIElementGetPid(element, &processIdentifier)

      let application = NSRunningApplication(processIdentifier: processIdentifier)
      return Target(
        element: element,
        processIdentifier: processIdentifier,
        bundleIdentifier: application?.bundleIdentifier,
        isSecure: isSecureTextField(element),
        displayID: displayID(for: element)
      )
    }

    return frontmostApplicationTarget()
  }

  /// The application in front, for when it will not say what is focused inside
  /// it. Insertion falls back to pasting, which lands wherever the caret is.
  ///
  /// The cost is stated rather than hidden: with no element there is no way to
  /// ask whether the field is secure, so the secure-field refusal cannot run
  /// here. That is not a step backwards — before this, the text went to the
  /// clipboard and stayed there, which leaves it lying around for longer than
  /// pasting it does.
  private func frontmostApplicationTarget() -> Target? {
    guard let application = dependencies.frontmostApplication() else { return nil }

    // The window is usually still readable even when its contents are not,
    // which is enough to put the HUD on the right screen.
    let applicationElement = AXUIElementCreateApplication(application.processIdentifier)
    var focusedWindow: CFTypeRef?
    let window = AXUIElementCopyAttributeValue(
      applicationElement,
      kAXFocusedWindowAttribute as CFString,
      &focusedWindow
    ) == .success ? focusedWindow.map { $0 as! AXUIElement } : nil

    return Target(
      element: nil,
      processIdentifier: application.processIdentifier,
      bundleIdentifier: application.bundleIdentifier,
      isSecure: false,
      displayID: window.flatMap { displayID(for: $0) }
    )
  }

  /// Pasting is the route that works everywhere, so it is the one every
  /// failure falls back to. The Accessibility write is tried first only where
  /// it can be proven to have worked, because it leaves the clipboard alone
  /// and does not fire the receiving app's paste handling.
  @discardableResult
  func insert(_ text: String, into target: Target?) async -> Outcome {
    guard !text.isEmpty else { return .nothingToInsert }
    guard let target else {
      copyToClipboard(text)
      return .leftOnClipboard(reason: "No application was in front to insert into.")
    }

    guard dependencies.isProcessRunning(target.processIdentifier) else {
      copyToClipboard(text)
      return .leftOnClipboard(reason: "The application quit during the session.")
    }

    let route = target.bundleIdentifier.flatMap { routesByBundleIdentifier[$0] }
    DictationLog.insertion.notice(
      """
      route: remembered=\(String(describing: route), privacy: .public) \
      element=\(target.element != nil, privacy: .public)
      """
    )
    if route != .paste, await insertThroughAccessibility(text, target: target) {
      remember(.accessibility, for: target.bundleIdentifier)
      return .setInPlace
    }

    // Only a real element proves anything about the route. An application that
    // hid its focused element this once may well expose the next field, and
    // one refusal must not condemn every field it owns to pasting.
    if target.element != nil {
      remember(.paste, for: target.bundleIdentifier)
    }

    let stillFocused = dependencies.isTargetFocused(target)
    DictationLog.insertion.notice("stillFocused: \(stillFocused, privacy: .public)")
    guard stillFocused else {
      copyToClipboard(text)
      return .leftOnClipboard(
        reason: target.element == nil
          ? "\(target.applicationName ?? "The application") was no longer in front."
          : "The field that was focused when the session began no longer is."
      )
    }
    await pasteAndRestoreClipboard(text, into: target)
    return .pasted
  }

  /// The whole contents of a target field, or nil when it cannot be read.
  ///
  /// Strictly read-only, and nil is an ordinary answer: plenty of fields —
  /// anything drawn rather than built from AX controls, and most of what a
  /// paste route was needed for — expose no value at all. Text Cleanup uses
  /// this to notice corrections, and treats nil as "no signal from this app"
  /// rather than as a failure.
  func readValue(of target: Target) -> String? {
    guard let element = target.element else { return nil }
    return dependencies.readElementValue(element)
  }

  private static func focusedElement() -> AXUIElement? {
    let systemWideElement = AXUIElementCreateSystemWide()
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(
      systemWideElement,
      kAXFocusedUIElementAttribute as CFString,
      &value
    ) == .success,
    let value else {
      return nil
    }
    return (value as! AXUIElement)
  }

  private func isSecureTextField(_ element: AXUIElement) -> Bool {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(
      element,
      kAXSubroleAttribute as CFString,
      &value
    ) == .success else {
      return false
    }

    return value as? String == kAXSecureTextFieldSubrole as String
  }

  private func displayID(for element: AXUIElement) -> CGDirectDisplayID? {
    let frameElement = window(for: element) ?? element
    guard let frame = frame(of: frameElement) else { return nil }

    let displays = NSScreen.screens.compactMap { screen -> (CGDirectDisplayID, CGRect)? in
      guard let displayID = screen.cgDirectDisplayID else { return nil }
      return (displayID, CGDisplayBounds(displayID))
    }

    let center = CGPoint(x: frame.midX, y: frame.midY)
    if let containingDisplay = displays.first(where: { $0.1.contains(center) }) {
      return containingDisplay.0
    }

    return displays.max { lhs, rhs in
      lhs.1.intersection(frame).area < rhs.1.intersection(frame).area
    }?.0
  }

  private func window(for element: AXUIElement) -> AXUIElement? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(
      element,
      kAXWindowAttribute as CFString,
      &value
    ) == .success,
    let value else {
      return nil
    }

    return (value as! AXUIElement)
  }

  private func frame(of element: AXUIElement) -> CGRect? {
    var positionValue: CFTypeRef?
    var sizeValue: CFTypeRef?

    guard AXUIElementCopyAttributeValue(
      element,
      kAXPositionAttribute as CFString,
      &positionValue
    ) == .success,
    AXUIElementCopyAttributeValue(
      element,
      kAXSizeAttribute as CFString,
      &sizeValue
    ) == .success,
    let positionValue,
    let sizeValue,
    CFGetTypeID(positionValue) == AXValueGetTypeID(),
    CFGetTypeID(sizeValue) == AXValueGetTypeID() else {
      return nil
    }

    var position = CGPoint.zero
    var size = CGSize.zero
    guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &position),
       AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else {
      return nil
    }

    return CGRect(origin: position, size: size)
  }

  /// Writes into the field, and returns whether the text is actually in it.
  ///
  /// The distinction is the whole point. Chromium and Electron accept this
  /// write, answer `.success`, and drop it on the floor — a YouTube search box
  /// and a terminal inside Cursor both do. Taking that answer at face value
  /// meant reporting the text as delivered while nothing appeared anywhere, and
  /// never falling back to the paste that would have worked.
  ///
  /// So success now means observed, not reported.
  private func insertThroughAccessibility(_ text: String, target: Target) async -> Bool {
    guard let element = target.element else { return false }
    guard dependencies.isSelectedTextSettable(element) else { return false }

    // Nothing is written into a field that cannot be read back, because the
    // result could not be told apart from the silent drop above. Pasting is no
    // more verifiable, but it does not quietly do nothing.
    guard let before = dependencies.readElementValue(element) else {
      DictationLog.insertion.notice("ax: field cannot be read back, not risking a silent write")
      return false
    }

    guard dependencies.setSelectedText(element, text) else {
      DictationLog.insertion.notice("ax: write refused")
      return false
    }

    if dependencies.readElementValue(element) != before { return true }

    // One unchanged read is not proof: a renderer can answer before it has
    // applied the write. A second, after a beat, is — and this only costs
    // anything on the path that is already failing.
    await dependencies.waitForAccessibilitySettle()
    let landed = dependencies.readElementValue(element) != before
    DictationLog.insertion.notice("ax: verified=\(landed, privacy: .public)")
    return landed
  }

  private func remember(_ route: Route, for bundleIdentifier: String?) {
    guard let bundleIdentifier else { return }
    routesByBundleIdentifier[bundleIdentifier] = route
  }

  /// Whether the paste is still going where it was meant to go.
  ///
  /// With an element, that means the very same field. Without one, it means the
  /// same application is still in front — which is the whole of what a
  /// synthesized ⌘V depends on, since the keystroke goes to whoever has focus.
  private static func isStillFocused(_ target: Target) -> Bool {
    guard let targetElement = target.element else {
      return NSWorkspace.shared.frontmostApplication?.processIdentifier
        == target.processIdentifier
    }

    let systemWideElement = AXUIElementCreateSystemWide()
    var value: CFTypeRef?

    guard AXUIElementCopyAttributeValue(
      systemWideElement,
      kAXFocusedUIElementAttribute as CFString,
      &value
    ) == .success,
    let value else {
      return false
    }

    return CFEqual(value, targetElement)
  }

  private func pasteAndRestoreClipboard(_ text: String, into target: Target) async {
    let pasteboard = dependencies.pasteboard
    let sourceItems = pasteboard.pasteboardItems ?? []
    var savedItems: [NSPasteboardItem] = []
    savedItems.reserveCapacity(sourceItems.count)

    for sourceItem in sourceItems {
      let savedItem = NSPasteboardItem()
      for type in sourceItem.types {
        if let data = sourceItem.data(forType: type) {
          savedItem.setData(data, forType: type)
        }
      }
      savedItems.append(savedItem)
    }

    pasteboard.clearContents()
    pasteboard.setString(text, forType: .string)
    let insertedChangeCount = pasteboard.changeCount

    guard dependencies.isTargetFocused(target),
       dependencies.postPasteShortcut() else { return }
    await dependencies.waitForPasteRead()

    // Reads do not change changeCount. The delay gives asynchronous editors
    // time to read; this guard protects newer clipboard contents.
    guard pasteboard.changeCount == insertedChangeCount else { return }
    pasteboard.clearContents()
    if !savedItems.isEmpty {
      pasteboard.writeObjects(savedItems)
    }
  }

  private func copyToClipboard(_ text: String) {
    let pasteboard = dependencies.pasteboard
    pasteboard.clearContents()
    pasteboard.setString(text, forType: .string)
  }

  private static func postPasteShortcut() -> Bool {
    guard let source = CGEventSource(stateID: .combinedSessionState),
       let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
       let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else {
      return false
    }

    keyDown.flags = .maskCommand
    keyUp.flags = .maskCommand
    keyDown.post(tap: .cghidEventTap)
    keyUp.post(tap: .cghidEventTap)
    return true
  }
}

private extension CGRect {
  var area: CGFloat {
    guard !isNull else { return 0 }
    return width * height
  }
}
