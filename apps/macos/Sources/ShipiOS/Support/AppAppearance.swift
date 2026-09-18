import AppKit
import SwiftUI

private struct AppearanceKey: EnvironmentKey {
  static let defaultValue = AppearancePreferences()
}
extension EnvironmentValues {
  var appAppearance: AppearancePreferences {
    get { self[AppearanceKey.self] }
    set { self[AppearanceKey.self] = newValue }
  }
}

extension AppearancePreferences {
  var colorScheme: ColorScheme? { theme == "system" ? nil : theme == "dark" ? .dark : .light }
  var isDark: Bool {
    if theme != "system" { return theme == "dark" }
    return NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
  }
  var activePalette: AppearancePalette { isDark ? dark : light }
  var accentHex: String? { activePalette.accent ?? accent }
  var backgroundHex: String? { activePalette.background ?? background }
  var foregroundHex: String? { activePalette.foreground ?? foreground }
  var translucentSidebar: Bool { activePalette.translucentSidebar }
  var accentColor: Color { accentHex.flatMap(Self.color) ?? .accentColor }
  var backgroundColor: Color {
    let base = backgroundHex.flatMap(Self.color) ?? Color(nsColor: .windowBackgroundColor)
    return Self.adjusted(base, contrast: activePalette.contrast, dark: isDark)
  }
  var foregroundColor: Color { foregroundHex.flatMap(Self.color) ?? .primary }
  var selectionOpacity: Double { 0.045 + activePalette.contrast * 0.0011 }
  var shouldReduceMotion: Bool {
    reduceMotion.resolved(systemValue: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
  }
  func paletteColor(_ value: String?, fallback: Color, dark: Bool) -> Color {
    Self.adjusted(value.flatMap(Self.color) ?? fallback, contrast: (dark ? self.dark : light).contrast, dark: dark)
  }
  static func color(_ hex: String) -> Color? {
    guard let hex = validHex(hex), let rgb = UInt32(hex.dropFirst(), radix: 16) else { return nil }
    return Color(
      .sRGB, red: Double((rgb >> 16) & 255) / 255, green: Double((rgb >> 8) & 255) / 255,
      blue: Double(rgb & 255) / 255, opacity: 1)
  }
  static func hex(_ color: Color) -> String? {
    guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return nil }
    return String(
      format: "#%02X%02X%02X", Int((rgb.redComponent * 255).rounded()),
      Int((rgb.greenComponent * 255).rounded()), Int((rgb.blueComponent * 255).rounded()))
  }
  private static func adjusted(_ color: Color, contrast: Double, dark: Bool) -> Color {
    guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return color }
    let amount = (min(100, max(0, contrast)) - 50) / 500
    func channel(_ value: CGFloat) -> CGFloat {
      dark ? max(0, value * (1 - amount)) : min(1, value + (1 - value) * amount)
    }
    return Color(
      .sRGB, red: channel(rgb.redComponent), green: channel(rgb.greenComponent),
      blue: channel(rgb.blueComponent), opacity: rgb.alphaComponent)
  }
  func nativeFont(size: CGFloat, code: Bool = false) -> NSFont {
    let family = code ? codeFont : uiFont
    let pointSize = code ? CGFloat(codeSize) + size - 12 : size * CGFloat(uiSize) / 13
    if !family.isEmpty,
      let font = NSFontManager.shared.font(
        withFamily: family, traits: [], weight: 5, size: pointSize)
    {
      return font
    }
    return code
      ? .monospacedSystemFont(ofSize: pointSize, weight: .regular) : .systemFont(ofSize: pointSize)
  }
  func font(size: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default) -> Font {
    let native = nativeFont(size: size, code: design == .monospaced)
    if (design == .monospaced ? codeFont : uiFont).isEmpty {
      return .system(size: native.pointSize, weight: weight, design: design)
    }
    return Font.custom(native.fontName, size: native.pointSize).weight(weight)
  }
}

private struct AppFontModifier: ViewModifier {
  @Environment(\.appAppearance) private var appearance
  var size: CGFloat
  var weight: Font.Weight
  var design: Font.Design
  func body(content: Content) -> some View {
    content.font(appearance.font(size: size, weight: weight, design: design))
  }
}

private struct AppSurfaceModifier: ViewModifier {
  @Environment(\.appAppearance) private var appearance
  func body(content: Content) -> some View {
    content
      .scrollContentBackground(appearance.backgroundHex == nil ? .automatic : .hidden)
      .background(appearance.backgroundHex == nil ? .clear : appearance.backgroundColor)
  }
}

private struct AppSidebarSurfaceModifier: ViewModifier {
  @Environment(\.appAppearance) private var appearance
  func body(content: Content) -> some View {
    content
      .scrollContentBackground(appearance.backgroundHex == nil ? .automatic : .hidden)
      .background {
        Rectangle().fill(
          appearance.translucentSidebar
            ? AnyShapeStyle(.bar) : AnyShapeStyle(appearance.backgroundColor))
      }
  }
}
extension View {
  /// Native containers paint their own background unless explicitly made transparent.
  func appSurface() -> some View { modifier(AppSurfaceModifier()) }
  func appSidebarSurface() -> some View { modifier(AppSidebarSurfaceModifier()) }

  func appFont(size: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default)
    -> some View
  {
    modifier(AppFontModifier(size: size, weight: weight, design: design))
  }
  func appFont(_ style: Font.TextStyle, weight: Font.Weight? = nil, design: Font.Design = .default)
    -> some View
  {
    let size: CGFloat
    switch style {
    case .largeTitle: size = 26
    case .title: size = 22
    case .title2: size = 17
    case .title3: size = 15
    case .headline, .body: size = 13
    case .callout: size = 12
    case .subheadline: size = 12
    case .footnote: size = 10
    case .caption: size = 10
    case .caption2: size = 10
    @unknown default: size = 13
    }
    return appFont(
      size: size, weight: weight ?? (style == .headline ? .semibold : .regular), design: design)
  }
}
