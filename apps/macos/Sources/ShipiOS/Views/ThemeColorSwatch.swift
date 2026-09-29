import AppKit
import SwiftUI

struct ThemeColorSwatch: View {
  let swatch: SettingsMenuSwatch
  var size: CGFloat = 24
  var body: some View {
    Text("Aa").appFont(size: 12, weight: .semibold)
      .foregroundStyle(CodeSyntaxText.color(swatch.accent) ?? .accentColor)
      .frame(width: size, height: size)
      .background(CodeSyntaxText.color(swatch.background) ?? .clear, in: RoundedRectangle(cornerRadius: 6))
      .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: swatch.borderColor), lineWidth: 1))
      .accessibilityHidden(true)
  }
}

extension SettingsMenuSwatch {
  @MainActor var borderColor: NSColor {
    let ink = NSColor(CodeSyntaxText.color(foreground) ?? .primary).usingColorSpace(.sRGB) ?? .black
    let surface = NSColor(CodeSyntaxText.color(background) ?? .clear).usingColorSpace(.sRGB) ?? .white
    return NSColor(srgbRed: ink.redComponent * 0.16 + surface.redComponent * 0.84,
      green: ink.greenComponent * 0.16 + surface.greenComponent * 0.84,
      blue: ink.blueComponent * 0.16 + surface.blueComponent * 0.84, alpha: 1)
  }
}
