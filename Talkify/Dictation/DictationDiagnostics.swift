import AVFAudio
import Foundation
import Speech

/// What the last dictation actually did, so a session that produces nothing can
/// be told apart from one that produced text and failed to place it.
///
/// It records the shape of a session, never its content: how many characters
/// were recognized, not what they said. Talkify's rule that recognized text is
/// not stored holds here too.
@MainActor
@Observable
final class DictationDiagnostics {
  struct Report: Equatable {
    var applicationName: String?
    var characterCount: Int
    var hadFocusedElement: Bool
    var outcome: TextInsertionService.Outcome
    var failure: String?
    var at: Date
  }

  private(set) var lastReport: Report?

  /// Read fresh every time the pane appears rather than cached — a permission
  /// granted while Settings is open should show as granted.
  var accessibility: Bool { PermissionService.hasAccessibilityAccess }
  var inputMonitoring: Bool { PermissionService.hasInputMonitoringAccess }

  var microphone: String {
    switch AVAudioApplication.shared.recordPermission {
    case .granted: "Granted"
    case .denied: "Denied"
    case .undetermined: "Not asked yet"
    @unknown default: "Unknown"
    }
  }

  var speechRecognition: String {
    switch SFSpeechRecognizer.authorizationStatus() {
    case .authorized: "Granted"
    case .denied: "Denied"
    case .restricted: "Restricted"
    case .notDetermined: "Not asked yet"
    @unknown default: "Unknown"
    }
  }

  func record(
    applicationName: String?,
    characterCount: Int,
    hadFocusedElement: Bool,
    outcome: TextInsertionService.Outcome
  ) {
    lastReport = Report(
      applicationName: applicationName,
      characterCount: characterCount,
      hadFocusedElement: hadFocusedElement,
      outcome: outcome,
      failure: nil,
      at: Date()
    )
  }

  func recordFailure(_ message: String) {
    lastReport = Report(
      applicationName: nil,
      characterCount: 0,
      hadFocusedElement: false,
      outcome: .nothingToInsert,
      failure: message,
      at: Date()
    )
  }
}
