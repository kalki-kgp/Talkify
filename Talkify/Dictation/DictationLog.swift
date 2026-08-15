import os

/// The session's course, in the system log.
///
/// Direct Dictation fails in ways that all look the same from outside — the key
/// unseen, nothing recognized, the text placed somewhere invisible — and the
/// difference between them is only visible from inside. `log show --predicate
/// 'subsystem == "com.tgomareli.Talkify"' --last 10m` prints it.
///
/// Everything logged is marked public, so every value must be one that is safe
/// to read: counts, routes, bundle identifiers, decisions. Recognized text is
/// never logged, in whole or in part.
enum DictationLog {
  static let session = Logger(subsystem: "com.tgomareli.Talkify", category: "dictation")
  static let insertion = Logger(subsystem: "com.tgomareli.Talkify", category: "insertion")
}
