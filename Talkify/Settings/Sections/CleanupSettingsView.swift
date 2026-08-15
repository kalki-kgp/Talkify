import SwiftUI

/// The Cleanup section: whether Talkify tidies a dictated draft before it
/// lands, how long it may spend doing that, and the style rules it follows.
///
/// The pane states the model's availability plainly. "Unavailable" is an
/// ordinary condition here — Apple Intelligence is a system-level switch, and
/// a toggle that silently does nothing is worse than one that says why.
struct CleanupSettingsView: View {
  @Bindable var settings: AppSettings
  let styleRules: StyleRuleList
  let suggestions: CleanupSuggestionQueue

  @Environment(\.colorSchemeContrast) private var contrast
  @State private var draft = ""
  @State private var draftScope = StyleRuleScope.everywhere

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
          noticeRow(availability.message, isError: false)
        }
      }

      if settings.isCleanupEnabled {
        speedCard
        learningCard

        if !suggestions.pending.isEmpty {
          reviewCard
        }

        addRuleCard
        rulesCard
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

  private var speedCard: some View {
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

  private var learningCard: some View {
    SettingsCard(title: "Learning") {
      SettingsRow(
        title: "Learn from your corrections",
        description: "After inserting, Talkify reads the field again a few "
          + "seconds later to see what you changed, and turns repeated fixes "
          + "into style rules you approve. Corrections are held in memory only "
          + "and are gone when you quit."
      ) {
        Toggle("", isOn: $settings.isCleanupLearningEnabled)
          .labelsHidden()
          .toggleStyle(.switch)
          .disabled(!availability.isAvailable)
      }
    }
  }

  private var reviewCard: some View {
    SettingsCard(title: "Suggestions (\(suggestions.count))") {
      noticeRow(
        "Talkify noticed these in the edits you made to its output. Nothing is "
          + "in effect until you keep it.",
        isError: false
      )

      ForEach(suggestions.pending) { suggestion in
        SettingsRow(title: suggestion.text, description: description(for: suggestion)) {
          HStack(spacing: 8) {
            Button("Keep") {
              Task { await suggestions.accept(suggestion) }
            }
            .buttonStyle(SettingsButtonStyle())

            Button("Discard") {
              Task { await suggestions.decline(suggestion) }
            }
            .buttonStyle(SettingsButtonStyle())
          }
        }
      }

      if let errorMessage = suggestions.errorMessage {
        noticeRow("Could not update your suggestions: \(errorMessage)", isError: true)
      }
    }
  }

  private func description(for suggestion: CleanupSuggestion) -> String {
    switch suggestion.kind {
    case .styleRule: "Style rule · \(suggestion.scope.title)"
    case .vocabularyTerm: "Vocabulary term"
    }
  }

  private var addRuleCard: some View {
    SettingsCard(title: "Add a style rule") {
      SettingsRow(
        title: "New rule",
        description: "Written the way you would say it to a person: "
          + "\"keep it casual\", \"prefer OK over okay\", \"no greeting\"."
      ) {
        VStack(alignment: .trailing, spacing: 8) {
          Picker("Applies to", selection: $draftScope) {
            ForEach(scopeChoices, id: \.self) { scope in
              Text(scope.title).tag(scope)
            }
          }
          .labelsHidden()
          .pickerStyle(.menu)
          .frame(width: 240, alignment: .trailing)

          HStack(spacing: 8) {
            TextField("Keep it casual", text: $draft)
              .textFieldStyle(.plain)
              .font(.system(size: 13))
              .foregroundStyle(.white)
              .padding(.horizontal, 10)
              .padding(.vertical, 7)
              .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
              .overlay {
                RoundedRectangle(cornerRadius: 8)
                  .stroke(.white.opacity(contrast == .increased ? 0.26 : 0.12), lineWidth: 1)
              }
              .frame(width: 240)
              .onSubmit(submit)
              .onChange(of: draft) { styleRules.clearRejection() }

            Button("Add", action: submit)
              .buttonStyle(SettingsButtonStyle())
              .disabled(StyleRules.normalize(draft).isEmpty)
          }
        }
      }

      if let message = rejectionMessage {
        noticeRow(message, isError: true)
      }

      if let errorMessage = styleRules.errorMessage {
        noticeRow("Could not save your style rules: \(errorMessage)", isError: true)
      }
    }
  }

  private var rulesCard: some View {
    SettingsCard(title: "Style rules") {
      if styleRules.rules.isEmpty {
        noticeRow(
          "No rules yet. Cleanup fixes filler and punctuation on its own — "
            + "rules are for the things only you know, like how you write in "
            + "one particular app.",
          isError: false
        )
      } else {
        ForEach(styleRules.scopes, id: \.self) { scope in
          scopeRows(for: scope)
        }
      }
    }
  }

  @ViewBuilder
  private func scopeRows(for scope: StyleRuleScope) -> some View {
    ForEach(styleRules.rules(in: scope)) { rule in
      SettingsRow(title: rule.text, description: scope.title) {
        HStack(spacing: 10) {
          if rule.source == .learned {
            Text("Learned")
              .font(.system(size: 10, weight: .semibold))
              .foregroundStyle(.white.opacity(0.55))
              .padding(.horizontal, 7)
              .padding(.vertical, 3)
              .background(.white.opacity(0.08), in: Capsule())
          }
          Button {
            Task { await styleRules.remove(rule) }
          } label: {
            Image(systemName: "trash")
              .font(.system(size: 12))
          }
          .buttonStyle(SettingsButtonStyle())
        }
      }
    }
  }

  /// Every scope worth offering: the apps that are open, plus the ones that
  /// already have rules so they stay editable after quitting.
  private var scopeChoices: [StyleRuleScope] {
    RunningApplications.scopes(includingExisting: styleRules.scopes)
  }

  private var rejectionMessage: String? {
    switch styleRules.rejection {
    case .none: nil
    case .empty: "A rule needs some words in it."
    case .tooLong:
      "Keep a rule under \(StyleRules.maximumRuleLength) characters — it is an "
        + "instruction, not a style guide."
    case .duplicate: "That rule is already on the list for \(draftScope.title)."
    case .scopeFull:
      "\(draftScope.title) already has \(StyleRules.maximumRulesPerScope) rules. "
        + "Remove one to add another — every rule is text the model reads before "
        + "your words land."
    case .full:
      "That's all \(StyleRules.maximumRuleCount) rules. Remove one to add another."
    }
  }

  private func submit() {
    let text = draft
    let scope = draftScope
    guard !StyleRules.normalize(text).isEmpty else { return }
    Task {
      if await styleRules.add(text, scope: scope) {
        draft = ""
      }
    }
  }

  private func noticeRow(_ message: String, isError: Bool) -> some View {
    HStack(alignment: .top, spacing: 8) {
      Image(systemName: isError ? "exclamationmark.triangle" : "info.circle")
        .font(.system(size: 12))
        .foregroundStyle(isError ? .orange.opacity(0.85) : .white.opacity(0.5))
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
  CleanupSettingsView(
    settings: AppSettings.previewStore(),
    styleRules: StyleRuleList(store: StyleRuleStore(
      fileURL: FileManager.default.temporaryDirectory
        .appending(path: "TalkifyCleanupPreview-\(UUID().uuidString).json")
    )),
    suggestions: CleanupSuggestionQueue(
      store: CleanupSuggestionStore(
        fileURL: FileManager.default.temporaryDirectory
          .appending(path: "TalkifyCleanupPreview-suggestions-\(UUID().uuidString).json")
      ),
      styleRules: StyleRuleList(),
      vocabulary: VocabularyList()
    )
  )
  .frame(width: 620)
  .padding(30)
  .background(SettingsTheme.background)
  .preferredColorScheme(.dark)
}
