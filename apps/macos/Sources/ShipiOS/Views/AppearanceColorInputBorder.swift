import SwiftUI

/// The public color input is transparent. Only its swatch contains the value;
/// focus anywhere in the native field/swatch pair outlines the whole capsule.
struct AppearanceColorInputBorder: View {
  let border: Color
  let focus: Color
  let focused: Bool
  var body: some View {
    Capsule().strokeBorder(border, lineWidth: 1)
      .overlay {
        if focused { Capsule().stroke(focus, lineWidth: 2).padding(-1) }
      }
      .accessibilityHidden(true).allowsHitTesting(false)
  }
}
