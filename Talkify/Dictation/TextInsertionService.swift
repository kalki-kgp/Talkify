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
  }

  private enum Route {
    case accessibility
    case paste
  }

  private var routesByBundleIdentifier: [String: Route] = [:]

  func captureFocusedTarget() -> Target? {
    let systemWideElement = AXUIElementCreateSystemWide()
    var value: CFTypeRef?

    guard AXUIElementCopyAttributeValue(
      systemWideElement,
      kAXFocusedUIElementAttribute as CFString,
      &value
    ) == .success,
    let value else {
      return frontmostApplicationTarget()
    }

    let element = value as! AXUIElement
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

  /// The application in front, for when it will not say what is focused inside
  /// it. Insertion falls back to pasting, which lands wherever the caret is.
  ///
  /// The cost is stated rather than hidden: with no element there is no way to
  /// ask whether the field is secure, so the secure-field refusal cannot run
  /// here. That is not a step backwards — before this, the text went to the
  /// clipboard and stayed there, which leaves it lying around for longer than
  /// pasting it does.
  private func frontmostApplicationTarget() -> Target? {
    guard let application = NSWorkspace.shared.frontmostApplication else { return nil }

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

  func insert(_ text: String, into target: Target?) async {
    guard !text.isEmpty else { return }
    guard let target else {
      copyToClipboard(text)
      return
    }

    guard let application = NSRunningApplication(
      processIdentifier: target.processIdentifier
    ), !application.isTerminated else {
      copyToClipboard(text)
      return
    }

    let route = target.bundleIdentifier.flatMap { routesByBundleIdentifier[$0] }
    if route != .paste, insertThroughAccessibility(text, target: target) {
      remember(.accessibility, for: target.bundleIdentifier)
      return
    }

    // Only a real element proves anything about the route. An application that
    // hid its focused element this once may well expose the next field, and
    // one refusal must not condemn every field it owns to pasting.
    if target.element != nil {
      remember(.paste, for: target.bundleIdentifier)
    }

    guard isStillFocused(target) else {
      copyToClipboard(text)
      return
    }
    await pasteAndRestoreClipboard(text)
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

    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(
      element,
      kAXValueAttribute as CFString,
      &value
    ) == .success else { return nil }
    return value as? String
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

  private func insertThroughAccessibility(_ text: String, target: Target) -> Bool {
    guard let element = target.element else { return false }

    var isSettable: DarwinBoolean = false
    let settableResult = AXUIElementIsAttributeSettable(
      element,
      kAXSelectedTextAttribute as CFString,
      &isSettable
    )

    guard settableResult == .success, isSettable.boolValue else { return false }

    return AXUIElementSetAttributeValue(
      element,
      kAXSelectedTextAttribute as CFString,
      text as CFString
    ) == .success
  }

  /// Whether the paste is still going where it was meant to go.
  ///
  /// With an element, that means the very same field. Without one, it means the
  /// same application is still in front — which is the whole of what a
  /// synthesized ⌘V depends on, since the keystroke goes to whoever has focus.
  private func isStillFocused(_ target: Target) -> Bool {
    guard let element = target.element else {
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

    return CFEqual(value, element)
  }

  private func pasteAndRestoreClipboard(_ text: String) async {
    let pasteboard = NSPasteboard.general
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

    postPasteShortcut()
    try? await Task.sleep(for: .milliseconds(150))

    guard pasteboard.changeCount == insertedChangeCount else { return }
    pasteboard.clearContents()
    if !savedItems.isEmpty {
      pasteboard.writeObjects(savedItems)
    }
  }

  private func copyToClipboard(_ text: String) {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(text, forType: .string)
  }

  private func postPasteShortcut() {
    guard let source = CGEventSource(stateID: .combinedSessionState),
       let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
       let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else {
      return
    }

    keyDown.flags = .maskCommand
    keyUp.flags = .maskCommand
    keyDown.post(tap: .cghidEventTap)
    keyUp.post(tap: .cghidEventTap)
  }

  private func remember(_ route: Route, for bundleIdentifier: String?) {
    guard let bundleIdentifier else { return }
    routesByBundleIdentifier[bundleIdentifier] = route
  }
}

private extension CGRect {
  var area: CGFloat {
    guard !isNull else { return 0 }
    return width * height
  }
}
