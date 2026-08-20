import AppKit
import ApplicationServices

/// Writing text into the focused field directly, when the field can be proven
/// to have taken it.
///
/// Pasting works everywhere and is the route every failure here falls back to.
/// This one exists because pasting has a cost the README now states plainly:
/// the text sits on the system clipboard for up to half a second, where a
/// clipboard manager or Universal Clipboard can read it. A direct write never
/// puts it there at all, and never fires the receiving app's paste handling.
///
/// It lives beside `TextInsertionService+Clipboard` rather than inside the
/// service so the paste route stays one file that merges cleanly.
extension TextInsertionService {
  /// The whole contents of a target field, or nil when it cannot be read.
  ///
  /// Strictly read-only, and nil is an ordinary answer: plenty of fields,
  /// anything drawn rather than built from AX controls, expose no value at
  /// all. Text Cleanup uses this to notice corrections, and treats nil as "no
  /// signal from this app" rather than as a failure.
  func readValue(of target: Target) -> String? {
    guard let element = target.accessibilityElement else { return nil }
    return dependencies.readElementValue(element)
  }

  /// Writes into the field, and returns whether the text is actually in it.
  ///
  /// The distinction is the whole point. Chromium and Electron accept this
  /// write, answer `.success`, and drop it on the floor. A YouTube search box
  /// and a terminal inside Cursor both do. Taking that answer at face value
  /// meant reporting text as delivered while nothing appeared anywhere, and
  /// never falling back to the paste that would have worked.
  ///
  /// So success means observed, not reported.
  func insertThroughAccessibility(_ text: String, target: Target) async -> Bool {
    guard let element = target.accessibilityElement else { return false }
    guard dependencies.isSelectedTextSettable(element) else { return false }

    // Nothing is written into a field that cannot be read back, because the
    // result could not be told apart from the silent drop above, and a write
    // followed by a fallback paste inserts the text twice.
    guard let before = dependencies.readElementValue(element) else { return false }
    guard dependencies.setSelectedText(element, text) else { return false }
    if dependencies.readElementValue(element) != before { return true }

    // One unchanged read is not proof: a renderer can answer before it has
    // applied the write. A second, after a beat, is. This only costs anything
    // on the path that is already failing.
    await dependencies.waitForAccessibilitySettle()
    return dependencies.readElementValue(element) != before
  }

  /// The live Accessibility boundaries, for `Dependencies.live` to install.
  nonisolated static var accessibilitySeams: (
    isSelectedTextSettable: @MainActor (AXUIElement) -> Bool,
    readElementValue: @MainActor (AXUIElement) -> String?,
    setSelectedText: @MainActor (AXUIElement, String) -> Bool,
    waitForAccessibilitySettle: @MainActor () async -> Void
  ) {
    (
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
