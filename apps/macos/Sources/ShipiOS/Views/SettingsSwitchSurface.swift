import SwiftUI

struct SettingsSwitchSurface: View {
  let isOn: Bool
  let isEnabled: Bool
  let focused: Bool
  @Environment(\.appAppearance) private var appearance
  private var blue: Color {
    appearance.accentHex == nil ? Color(red: 0.2, green: 156.0 / 255, blue: 1) : appearance.accentColor
  }

  var body: some View {
    Capsule()
        .fill(isOn ? blue : appearance.foregroundColor.opacity(0.1))
        .frame(width: 32, height: 20)
        .overlay(alignment: .leading) {
          Circle().fill(.white)
            .frame(width: 16, height: 16)
            .background {
              Circle().fill(.white).padding(1)
                .shadow(color: .black.opacity(0.08), radius: 1, y: 1)
            }
            // SwiftUI mirrors both leading alignment and offset in RTL.
            .offset(x: isOn ? 14 : 2)
        }
        .overlay {
          if focused && isEnabled {
            Capsule().stroke(appearance.resolvedColors["borderFocus"].color, lineWidth: 2)
              .padding(-1)
          }
        }
        .opacity(isEnabled ? 1 : 0.6)
  }
}
