import SwiftUI

/// The Appearance section: the live preview first, then the Voice visual
/// and Motion and layout groups (CONTEXT.md). Waveform and Glow rows are
/// conditional on the selected visual; hidden values stay persisted.
struct AppearanceSettingsView: View {
  @Bindable var settings: AppSettings

  /// Which conditional rows the selected visual exposes; hidden values
  /// stay persisted (CONTEXT.md).
  static func showsWaveformOptions(for visual: HUDVoiceVisualStyle) -> Bool {
    visual == .waveform
  }

  static func showsGlowOptions(for visual: HUDVoiceVisualStyle) -> Bool {
    visual == .glow
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      SettingsPreviewCard(settings: settings)

      SettingsCard(title: "Voice visual") {
        SettingsPickerRow(
          title: "While listening",
          description: "The visual shown during Direct Dictation",
          options: HUDVoiceVisualStyle.allCases,
          optionLabel: { $0.rawValue },
          selection: $settings.voiceVisual
        )

        if Self.showsWaveformOptions(for: settings.voiceVisual) {
          SettingsPickerRow(
            title: "Waveform style",
            description: "The shape and motion of the waveform",
            options: HUDWaveformStyle.allCases,
            optionLabel: { $0.rawValue },
            selection: $settings.waveformStyle
          )
        }

        if Self.showsGlowOptions(for: settings.voiceVisual) {
          SettingsPickerRow(
            title: "Glow palette",
            description: "The colors used by the edge beam",
            options: HUDGlowPalette.allCases,
            optionLabel: { $0.rawValue },
            selection: $settings.glowPalette
          )

          SettingsPickerRow(
            title: "Glow center",
            description: "The visual inside the edge beam",
            options: HUDGlowCenterStyle.settingsCases,
            optionLabel: { $0.rawValue },
            selection: $settings.glowCenter
          )
        }
      }

      notchCard

      SettingsCard(title: "Motion and layout") {
        SettingsPickerRow(
          title: "Reveal style",
          description: "How the HUD appears when Direct Dictation starts",
          options: HUDRevealStyle.allCases,
          optionLabel: { $0.rawValue },
          selection: $settings.revealStyle
        )

        SettingsPickerRow(
          title: "Long draft behavior",
          description: "How the HUD handles longer dictated text",
          options: HUDLongDraftStyle.allCases,
          optionLabel: { $0.rawValue },
          selection: $settings.longDraftStyle
        )
      }
    }
  }

  /// Only the simulated notch is adjustable, and the card says so on a Mac
  /// where it does not apply rather than offering a control that does nothing.
  private var notchCard: some View {
    SettingsCard(title: "Notch") {
      if hasRealNotch {
        SettingsRow(
          title: "This display has its own notch",
          description: "The HUD hugs the housing your Mac reports and flares "
            + "into the bezel around it. Resizing it would leave the curve "
            + "hanging in open screen, so the size is fixed here. Connect a "
            + "display without a notch to adjust the simulated one."
        ) {
          EmptyView()
        }
      } else {
        sizeRow(
          title: "Width",
          value: $settings.notchWidth,
          range: HUDNotchSize.widthRange
        )
        sizeRow(
          title: "Height",
          value: $settings.notchHeight,
          range: HUDNotchSize.heightRange
        )

        SettingsRow(
          title: "Reset",
          description: "Back to \(Int(HUDNotchSize.defaultWidth)) × "
            + "\(Int(HUDNotchSize.defaultHeight)), the footprint a 14-inch "
            + "MacBook Pro measures."
        ) {
          Button("Reset") {
            settings.notchWidth = HUDNotchSize.defaultWidth
            settings.notchHeight = HUDNotchSize.defaultHeight
          }
          .buttonStyle(SettingsButtonStyle())
          .disabled(
            HUDNotchSize.isDefault(
              width: settings.notchWidth,
              height: settings.notchHeight
            )
          )
        }
      }
    }
  }

  private func sizeRow(
    title: String,
    value: Binding<Double>,
    range: ClosedRange<Double>
  ) -> some View {
    SettingsRow(
      title: title,
      description: "\(Int(value.wrappedValue)) points"
    ) {
      Slider(value: value, in: range)
        .frame(width: 190)
    }
  }

  private var hasRealNotch: Bool {
    guard let screen = NSScreen.main, let id = screen.cgDirectDisplayID else { return false }
    return HUDNotchGeometry.hasMeasuredNotch(
      for: HUDScreenSnapshot(
        id: id,
        frame: screen.frame,
        safeAreaTop: screen.safeAreaInsets.top,
        auxiliaryTopLeftArea: screen.auxiliaryTopLeftArea,
        auxiliaryTopRightArea: screen.auxiliaryTopRightArea
      )
    )
  }
}
