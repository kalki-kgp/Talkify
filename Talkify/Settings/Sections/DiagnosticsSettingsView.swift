import SwiftUI

/// What Talkify can see and what it last did.
///
/// This exists because "nothing happened" has at least four causes that look
/// identical from outside — the key was never seen, nothing was recognized, the
/// text was written somewhere invisible, or it went to the clipboard — and
/// telling them apart by trying things is slow and usually wrong.
struct DiagnosticsSettingsView: View {
  let diagnostics: DictationDiagnostics

  @Environment(\.colorSchemeContrast) private var contrast

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      SettingsCard(title: "Permissions") {
        permissionRow(
          "Accessibility",
          granted: diagnostics.accessibility,
          need: "Without it the trigger key is never seen and nothing at all happens."
        )
        SettingsRow(
          title: "Input Monitoring",
          description: "Not required — Accessibility already covers the trigger key. "
            + "Shown because a leftover grant from an older build is a thing "
            + "people go looking for."
        ) {
          statusText(
            diagnostics.inputMonitoring ? "Granted" : "Not granted",
            isGood: true
          )
        }
        SettingsRow(
          title: "Microphone",
          description: "Without it a session runs and records silence."
        ) {
          statusText(diagnostics.microphone, isGood: diagnostics.microphone == "Granted")
        }
        SettingsRow(
          title: "Speech Recognition",
          description: "Without it audio is captured and never transcribed."
        ) {
          statusText(
            diagnostics.speechRecognition,
            isGood: diagnostics.speechRecognition == "Granted"
          )
        }
      }

      SettingsCard(title: "Last dictation") {
        if let report = diagnostics.lastReport {
          if let failure = report.failure {
            SettingsRow(title: "Failed", description: failure) {
              statusText("Error", isGood: false)
            }
          } else {
            SettingsRow(
              title: title(for: report.outcome),
              description: outcomeDescription(for: report)
            ) {
              statusText(
                report.outcome == .unavailable ? "Failed" : "Done",
                isGood: report.outcome != .unavailable
              )
            }
          }
          SettingsRow(
            title: "When",
            description: report.at.formatted(date: .omitted, time: .standard)
          ) {
            EmptyView()
          }
        } else {
          SettingsRow(
            title: "Nothing recorded yet",
            description: "Hold the dictation key, say something, and let go. "
              + "What happened will show here."
          ) {
            EmptyView()
          }
        }
      }

      Text(
        "Only the shape of a session is recorded — how many characters, which "
          + "application, where the text went. What you said is not kept."
      )
      .font(.system(size: 11))
      .foregroundStyle(.white.opacity(contrast == .increased ? 0.62 : 0.4))
    }
  }

  private func outcomeDescription(for report: DictationDiagnostics.Report) -> String {
    var parts: [String] = []
    parts.append("\(report.characterCount) characters")
    if let name = report.applicationName {
      parts.append("into \(name)")
    }
    parts.append(
      report.hadFocusedElement
        ? "which named its focused field"
        : "which would not name its focused field, so pasting was the only route"
    )

    var description = parts.joined(separator: ", ") + "."
    if let detail = detail(for: report.outcome) {
      description += " " + detail
    }
    return description
  }

  /// The outcome enum is upstream's and carries no prose, so the wording
  /// lives here, where it is a presentation concern rather than a value the
  /// insertion service has to keep in sync.
  private func title(for outcome: TextInsertionService.InsertionOutcome) -> String {
    switch outcome {
    case .inserted: "Inserted"
    case .copiedToClipboard: "Left on the clipboard"
    case .unavailable: "Nowhere to put it"
    }
  }

  private func detail(for outcome: TextInsertionService.InsertionOutcome) -> String? {
    switch outcome {
    case .inserted: nil
    case .copiedToClipboard:
      "The text is on the clipboard, ready to paste."
    case .unavailable:
      "Neither the field nor the clipboard could take it."
    }
  }

  private func permissionRow(_ title: String, granted: Bool, need: String) -> some View {
    SettingsRow(title: title, description: need) {
      statusText(granted ? "Granted" : "Not granted", isGood: granted)
    }
  }

  private func statusText(_ text: String, isGood: Bool) -> some View {
    Text(text)
      .font(.system(size: 12, weight: .medium))
      .foregroundStyle(isGood ? Color.green.opacity(0.9) : Color.orange)
  }
}
