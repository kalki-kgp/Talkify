/// The Settings navigation model: labeled groups of sections with stable
/// typed IDs (CONTEXT.md: sections are registered in code; no empty or
/// disabled sections render).
enum SettingsSectionGroup: String, CaseIterable, Identifiable {
  case settings

  var id: Self { self }
  var title: String { rawValue.uppercased() }

  var sections: [SettingsSection] {
    SettingsSection.allCases.filter { $0.group == self }
  }
}

enum SettingsSection: String, CaseIterable, Identifiable {
  case appearance
  case sounds
  case dictation
  case dropTranscription
  case readAloud
  case language
  case vocabulary
  case cleanup
  case shortcuts
  case updates
  case insights
  case diagnostics

  var id: Self { self }
  var group: SettingsSectionGroup { .settings }

  var title: String {
    switch self {
    case .appearance: "Appearance"
    case .sounds: "Sounds"
    case .dictation: "Dictation"
    case .dropTranscription: "Drop Transcription"
    case .readAloud: "Read Aloud"
    case .language: "Language"
    case .vocabulary: "Vocabulary"
    case .cleanup: "Cleanup"
    case .shortcuts: "Shortcuts"
    case .updates: "Updates"
    case .insights: "Insights"
    case .diagnostics: "Diagnostics"
    }
  }

  var subtitle: String {
    switch self {
    case .appearance: "Customize the Direct Dictation HUD"
    case .sounds: "Choose and preview the session sounds"
    case .dictation: "Choose where finished dictation text goes"
    case .dropTranscription: "Transcribe audio and video files"
    case .readAloud: "Choose the voice that reads selected text"
    case .language: "Pick your dictation languages and their keys"
    case .vocabulary: "Teach Talkify the words it keeps getting wrong"
    case .cleanup: "Tidy up dictated text before it lands"
    case .shortcuts: "Rebind the Direct Dictation and Read Aloud keys"
    case .updates: "Keep Talkify current"
    case .insights: "Review your local Direct Dictation activity"
    case .diagnostics: "What Talkify can see, and what it last did"
    }
  }

  var icon: String {
    switch self {
    case .appearance: "sparkles"
    case .sounds: "waveform"
    case .dictation: "text.cursor"
    case .dropTranscription: "square.and.arrow.down"
    case .readAloud: "speaker.wave.2"
    case .language: "globe"
    case .vocabulary: "character.book.closed"
    case .cleanup: "wand.and.sparkles"
    case .shortcuts: "keyboard"
    case .updates: "arrow.down.circle"
    case .insights: "chart.bar.xaxis"
    case .diagnostics: "stethoscope"
    }
  }
}
