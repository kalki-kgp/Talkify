import AppKit
import ApplicationServices
import Testing
@testable import Talkify

@MainActor
struct TextInsertionServiceTests {
  @Test func everyFocusedTargetUsesPasteInsertion() async {
    let pasteboard = makePasteboard()
    pasteboard.clearContents()
    pasteboard.setString("previous clipboard", forType: .string)
    var textAvailableWhileTargetReads: String?

    let service = TextInsertionService(dependencies: .init(
      pasteboard: pasteboard,
      focusedElement: { nil },
      frontmostApplication: { nil },
      isProcessRunning: { _ in true },
      isTargetFocused: { _ in true },
      postPasteShortcut: { true },
      waitForPasteRead: {
        textAvailableWhileTargetReads = pasteboard.string(forType: .string)
      }
    ))
    await service.insert("dictated text", into: makeTarget())

    #expect(textAvailableWhileTargetReads == "dictated text")
    #expect(pasteboard.string(forType: .string) == "previous clipboard")
  }

  @Test func clipboardChangeDuringPasteIsNeverOverwritten() async {
    let pasteboard = makePasteboard()
    pasteboard.clearContents()
    pasteboard.setString("previous clipboard", forType: .string)

    let service = TextInsertionService(dependencies: .init(
      pasteboard: pasteboard,
      focusedElement: { nil },
      frontmostApplication: { nil },
      isProcessRunning: { _ in true },
      isTargetFocused: { _ in true },
      postPasteShortcut: { true },
      waitForPasteRead: {
        pasteboard.clearContents()
        pasteboard.setString("new clipboard", forType: .string)
      }
    ))
    await service.insert("dictated text", into: makeTarget())

    #expect(pasteboard.string(forType: .string) == "new clipboard")
  }

  @Test func failedPasteShortcutLeavesTranscriptOnClipboard() async {
    let pasteboard = makePasteboard()
    pasteboard.clearContents()
    pasteboard.setString("previous clipboard", forType: .string)
    var waitedForPasteRead = false

    let service = TextInsertionService(dependencies: .init(
      pasteboard: pasteboard,
      focusedElement: { nil },
      frontmostApplication: { nil },
      isProcessRunning: { _ in true },
      isTargetFocused: { _ in true },
      postPasteShortcut: { false },
      waitForPasteRead: {
        waitedForPasteRead = true
      }
    ))
    await service.insert("dictated text", into: makeTarget())

    #expect(pasteboard.string(forType: .string) == "dictated text")
    #expect(!waitedForPasteRead)
  }

  @Test func changedTargetReceivesNoPasteEvent() async {
    let pasteboard = makePasteboard()
    var postedPaste = false
    let service = TextInsertionService(dependencies: .init(
      pasteboard: pasteboard,
      focusedElement: { nil },
      frontmostApplication: { nil },
      isProcessRunning: { _ in true },
      isTargetFocused: { _ in false },
      postPasteShortcut: {
        postedPaste = true
        return true
      },
      waitForPasteRead: {}
    ))
    await service.insert("dictated text", into: makeTarget())

    #expect(!postedPaste)
    #expect(pasteboard.string(forType: .string) == "dictated text")
  }

  @Test func targetChangedWhileStagingReceivesNoPasteEvent() async {
    let pasteboard = makePasteboard()
    var focusCheckCount = 0
    var postedPaste = false
    let service = TextInsertionService(dependencies: .init(
      pasteboard: pasteboard,
      focusedElement: { nil },
      frontmostApplication: { nil },
      isProcessRunning: { _ in true },
      isTargetFocused: { _ in
        focusCheckCount += 1
        return focusCheckCount == 1
      },
      postPasteShortcut: {
        postedPaste = true
        return true
      },
      waitForPasteRead: {}
    ))
    await service.insert("dictated text", into: makeTarget())

    #expect(focusCheckCount == 2)
    #expect(!postedPaste)
    #expect(pasteboard.string(forType: .string) == "dictated text")
  }

  @Test func missingFocusedElementCapturesFrontmostApplication() async {
    let pasteboard = makePasteboard()
    let application = NSRunningApplication.current
    var checkedProcessIdentifier: pid_t?
    let service = TextInsertionService(dependencies: .init(
      pasteboard: pasteboard,
      focusedElement: { nil },
      frontmostApplication: { application },
      isProcessRunning: { processIdentifier in
        checkedProcessIdentifier = processIdentifier
        return false
      },
      isTargetFocused: { _ in true },
      postPasteShortcut: { true },
      waitForPasteRead: {}
    ))

    let target = service.captureFocusedTarget()
    #expect(target != nil)
    await service.insert("dictated text", into: target)
    #expect(checkedProcessIdentifier == application.processIdentifier)
  }

  /// A field that takes the write and shows it needs no paste, and the
  /// clipboard is left exactly as the user had it.
  @Test func aWriteThatLandsSkipsThePasteEntirely() async {
    let pasteboard = makePasteboard()
    pasteboard.clearContents()
    pasteboard.setString("previous clipboard", forType: .string)
    var postedPaste = false
    var fieldContents = "before"

    let service = TextInsertionService(dependencies: .init(
      pasteboard: pasteboard,
      focusedElement: { nil },
      frontmostApplication: { nil },
      isProcessRunning: { _ in true },
      isTargetFocused: { _ in true },
      postPasteShortcut: {
        postedPaste = true
        return true
      },
      waitForPasteRead: {},
      isSelectedTextSettable: { _ in true },
      readElementValue: { _ in fieldContents },
      setSelectedText: { _, text in
        fieldContents = text
        return true
      }
    ))
    let outcome = await service.insert("dictated text", into: makeTarget())

    #expect(outcome == .setInPlace)
    #expect(!postedPaste)
    #expect(pasteboard.string(forType: .string) == "previous clipboard")
  }

  /// Chromium and Electron answer `.success` and drop the write. Believing the
  /// return value meant reporting text as delivered while the field stayed
  /// empty, and never falling back to the paste that would have worked.
  @Test func aWriteThatReportsSuccessAndChangesNothingFallsBackToPasting() async {
    let pasteboard = makePasteboard()
    var postedPaste = false
    var settled = false

    let service = TextInsertionService(dependencies: .init(
      pasteboard: pasteboard,
      focusedElement: { nil },
      frontmostApplication: { nil },
      isProcessRunning: { _ in true },
      isTargetFocused: { _ in true },
      postPasteShortcut: {
        postedPaste = true
        return true
      },
      waitForPasteRead: {},
      isSelectedTextSettable: { _ in true },
      readElementValue: { _ in "unchanged" },
      setSelectedText: { _, _ in true },
      waitForAccessibilitySettle: { settled = true }
    ))
    let outcome = await service.insert("dictated text", into: makeTarget())

    #expect(outcome == .pasted)
    #expect(postedPaste)
    #expect(settled, "the second read is what tells a slow renderer from a lying one")
  }

  /// A renderer may answer before it has applied the write, so one unchanged
  /// read is not proof — the read after the beat is.
  @Test func aWriteThatLandsLateIsStillCreditedToAccessibility() async {
    let pasteboard = makePasteboard()
    var postedPaste = false
    var fieldContents = "before"

    let service = TextInsertionService(dependencies: .init(
      pasteboard: pasteboard,
      focusedElement: { nil },
      frontmostApplication: { nil },
      isProcessRunning: { _ in true },
      isTargetFocused: { _ in true },
      postPasteShortcut: {
        postedPaste = true
        return true
      },
      waitForPasteRead: {},
      isSelectedTextSettable: { _ in true },
      readElementValue: { _ in fieldContents },
      setSelectedText: { _, _ in true },
      waitForAccessibilitySettle: { fieldContents = "dictated text" }
    ))
    let outcome = await service.insert("dictated text", into: makeTarget())

    #expect(outcome == .setInPlace)
    #expect(!postedPaste)
  }

  /// A field that cannot be read back is never written to: the result would be
  /// indistinguishable from the silent drop, and a write plus a paste inserts
  /// the text twice.
  @Test func anUnreadableFieldIsPastedIntoRatherThanWrittenTo() async {
    let pasteboard = makePasteboard()
    var attemptedWrite = false

    let service = TextInsertionService(dependencies: .init(
      pasteboard: pasteboard,
      focusedElement: { nil },
      frontmostApplication: { nil },
      isProcessRunning: { _ in true },
      isTargetFocused: { _ in true },
      postPasteShortcut: { true },
      waitForPasteRead: {},
      isSelectedTextSettable: { _ in true },
      readElementValue: { _ in nil },
      setSelectedText: { _, _ in
        attemptedWrite = true
        return true
      }
    ))
    let outcome = await service.insert("dictated text", into: makeTarget())

    #expect(!attemptedWrite)
    #expect(outcome == .pasted)
  }

  /// Correction capture reads the field back to notice what the user fixed.
  /// An application that names no focused element gives no signal, and that
  /// has to read as silence rather than as an empty field.
  @Test func readingBackAnElementlessTargetIsSilenceNotAnEmptyString() async {
    let service = TextInsertionService(dependencies: .init(
      pasteboard: makePasteboard(),
      focusedElement: { nil },
      frontmostApplication: { nil },
      isProcessRunning: { _ in true },
      isTargetFocused: { _ in true },
      postPasteShortcut: { true },
      waitForPasteRead: {},
      readElementValue: { _ in "should never be consulted" }
    ))

    let elementless = TextInsertionService.Target(
      element: nil,
      processIdentifier: 42,
      isSecure: false,
      displayID: nil
    )
    #expect(service.readValue(of: elementless) == nil)
  }

  private func makePasteboard() -> NSPasteboard {
    NSPasteboard(
      name: NSPasteboard.Name("TextInsertionServiceTests-\(UUID().uuidString)")
    )
  }

  private func makeTarget() -> TextInsertionService.Target {
    TextInsertionService.Target(
      element: AXUIElementCreateSystemWide(),
      processIdentifier: 42,
      isSecure: false,
      displayID: nil
    )
  }
}
