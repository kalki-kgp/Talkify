import SwiftUI

/// The Cleanup section: whether Talkify tidies a dictated draft before it
/// lands, and what happens when tidying it takes longer than you want to wait.
///
/// The pane states the model's availability plainly. "Unavailable" is an
/// ordinary condition here — Apple Intelligence is a system-level switch, and a
/// toggle that silently does nothing is worse than one that says why.
struct CleanupSettingsView: View {
  @Bindable var settings: AppSettings

  @Environment(\.colorSchemeContrast) private var contrast

  private let availability = CleanupService.availability

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      SettingsCard(title: "Cleanup") {
        SettingsRow(
          title: "Clean up dictated text",
          description: "Removes filler words and false starts, and fixes "
            + "punctuation and capitalization, before the text is inserted."
        ) {
          Toggle("", isOn: $settings.isCleanupEnabled)
            .labelsHidden()
            .toggleStyle(.switch)
            .disabled(!availability.isAvailable)
        }

        if !availability.isAvailable {
          noticeRow(availability.message)
        }
      }

      if settings.isCleanupEnabled {
        SettingsCard(title: "Speed") {
          SettingsPickerRow(
            title: "If cleanup is slow",
            description: "Cleanup runs after you release the key and before the "
              + "text lands, so it adds a short wait to every dictation.",
            options: CleanupPacing.allCases,
            optionLabel: \.title,
            selection: $settings.cleanupPacing,
            controlWidth: 210
          )

          if settings.cleanupPacing == .deadline {
            SettingsPickerRow(
              title: "Give up after",
              description: "Past this, Talkify inserts exactly what you said.",
              options: CleanupDeadline.choices,
              optionLabel: CleanupDeadline.title(forMilliseconds:),
              selection: $settings.cleanupDeadlineMilliseconds
            )
          }
        }
      }

      Text(
        "Cleanup runs on this Mac with Apple's on-device model. Nothing is sent "
          + "anywhere, and Talkify stores no part of what you dictated. If the "
          + "model is unavailable, refuses, or does not speak the language you "
          + "are dictating, your words are inserted untouched."
      )
      .font(.caption)
      .foregroundStyle(.white.opacity(contrast == .increased ? 0.7 : 0.45))
      .fixedSize(horizontal: false, vertical: true)
      .padding(.horizontal, 6)
    }
  }

  private func noticeRow(_ message: String) -> some View {
    HStack(alignment: .top, spacing: 8) {
      Image(systemName: "info.circle")
        .font(.system(size: 12))
        .foregroundStyle(.white.opacity(0.5))
      Text(message)
        .font(.caption)
        .foregroundStyle(.white.opacity(contrast == .increased ? 0.78 : 0.55))
        .fixedSize(horizontal: false, vertical: true)
      Spacer(minLength: 0)
    }
    .padding(.vertical, 11)
  }
}

#Preview {
  CleanupSettingsView(settings: AppSettings.previewStore())
    .frame(width: 620)
    .padding(30)
    .background(SettingsTheme.background)
    .preferredColorScheme(.dark)
}
