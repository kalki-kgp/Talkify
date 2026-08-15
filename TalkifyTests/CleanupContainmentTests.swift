import Foundation
import Testing
@testable import Talkify

struct CleanupContainmentTests {
  /// FoundationModels is Apple's, so it breaks no dependency rule — but it is
  /// the one framework in Talkify that can be unavailable at runtime on a Mac
  /// that is otherwise fine. Keeping it behind `Talkify/Cleanup/` is what lets
  /// every other module ignore that, the same containment Sparkle gets in
  /// `Talkify/Updates/`. This fails the moment another file imports it.
  @Test func onlyTheCleanupModuleImportsFoundationModels() throws {
    let root = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appending(path: "Talkify")

    let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?
      .compactMap { $0 as? URL }
      .filter { $0.pathExtension == "swift" } ?? []
    #expect(!files.isEmpty, "no Swift sources found under \(root.path)")

    let importers = try files
      .filter { url in
        try String(contentsOf: url, encoding: .utf8)
          .split(separator: "\n")
          .contains { $0.trimmingCharacters(in: .whitespaces) == "import FoundationModels" }
      }
      .map { $0.lastPathComponent }
      .sorted()

    #expect(importers == ["CleanupService.swift"])
  }

  @Test func theCleanupSectionIsRegistered() {
    #expect(SettingsSection.allCases.contains(.cleanup))
    #expect(SettingsSection.cleanup.title == "Cleanup")
    #expect(!SettingsSection.cleanup.subtitle.isEmpty)
    #expect(!SettingsSection.cleanup.icon.isEmpty)
  }
}
