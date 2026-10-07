import SwiftUI

struct SeededAgentAvatar: View {
  let seed: String
  var palette: AgentAvatarPalette = .codex
  var size: CGFloat = 24
  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    Group {
      if let image = AgentAvatar.image(seed: seed, dark: colorScheme == .dark, palette: palette) {
        Image(nsImage: image).resizable().interpolation(.high)
      } else {
        Color.clear
      }
    }
    .frame(width: size, height: size)
    .fixedSize()
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }
}
