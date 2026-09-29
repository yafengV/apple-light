import Foundation

struct AppearanceRGBA: Codable, Equatable, Sendable {
  let red: Int
  let green: Int
  let blue: Int
  var alpha: Double = 1
  init(red: Int, green: Int, blue: Int, alpha: Double = 1) {
    self.red = red; self.green = green; self.blue = blue; self.alpha = alpha
  }
  init(hex: String) {
    let value = UInt32(hex.dropFirst(), radix: 16) ?? 0
    self.init(red: Int((value >> 16) & 255), green: Int((value >> 8) & 255), blue: Int(value & 255))
  }
  static let black = Self(red: 0, green: 0, blue: 0)
  static let white = Self(red: 255, green: 255, blue: 255)
  var hex: String { String(format: "#%02x%02x%02x", red, green, blue) }
  func mixed(with target: Self, amount: Double) -> Self {
    let fraction = min(1, max(0, amount))
    func channel(_ from: Int, _ to: Int) -> Int { Int(floor(Double(from) + Double(to - from) * fraction + 0.5)) }
    return .init(red: channel(red, target.red), green: channel(green, target.green), blue: channel(blue, target.blue))
  }
  func opacity(_ value: Double) -> Self {
    var result = self; result.alpha = Self.fixedAlpha(value); return result
  }
  /// Number.toFixed(3) rounds the exact binary input, with positive ties upward.
  /// Multiplication followed by rounded() loses that distinction near a decimal tie.
  static func fixedAlpha(_ value: Double) -> Double {
    let value = min(1, max(0, value)); guard value > 0 else { return 0 }
    let bits = value.bitPattern, exponent = Int((bits >> 52) & 0x7ff)
    let significand = (bits & 0x000f_ffff_ffff_ffff) | (exponent == 0 ? 0 : 1 << 52)
    let shift = 1075 - max(1, exponent), product = significand * 1000
    guard shift < 64 else { return 0 }
    let whole = product >> shift, remainder = product & ((UInt64(1) << shift) - 1)
    return Double(whole + (remainder >= UInt64(1) << (shift - 1) ? 1 : 0)) / 1000
  }
  var luminance: Double {
    func linear(_ value: Int) -> Double { let n = Double(value) / 255; return n <= 0.04045 ? n / 12.92 : pow((n + 0.055) / 1.055, 2.4) }
    return linear(red) * 0.2126 + linear(green) * 0.7152 + linear(blue) * 0.0722
  }
  var textOnAccent: Self {
    if blue > red && blue > green {
      let delta = Double(blue - min(red, green)), hue = (Double(red - green) / delta + 4) * 60
      let saturation = delta / Double(blue)
      if (saturation >= 0.8 && hue >= 205 && hue <= 212)
        || (saturation >= 0.6 && hue >= 218 && hue <= 233 && luminance <= 0.21) { return .white }
    }
    return luminance > 0.179 ? .black : .white
  }
}

/// Color roles derived from a normalized independent theme. Raw surface/ink stay
/// unchanged; contrast changes the supporting controls, panels, borders and text.
struct AppearanceResolvedColors: Sendable {
  let contrast: Double
  let colors: [String: AppearanceRGBA]
  subscript(_ role: String) -> AppearanceRGBA { colors[role] ?? .black }
  init(theme: AppearanceThemeShare.Theme, dark: Bool) {
    let accent = AppearanceRGBA(hex: theme.accent), ink = AppearanceRGBA(hex: theme.ink), surface = AppearanceRGBA(hex: theme.surface)
    let baseline: Double = dark ? 60 : 45, input = Double(theme.contrast)
    let initial = input / 100 + (input - baseline) / 60 * 0.7
    contrast = input <= baseline ? initial : baseline / 100 + (initial - baseline / 100) * 2
    let c = contrast, white = AppearanceRGBA.white, black = AppearanceRGBA.black
    var roles: [String: AppearanceRGBA] = [
      "accent": accent, "ink": ink, "surface": surface,
      "surfaceUnder": surface.mixed(with: dark ? black : ink, amount: (dark ? 0.16 : 0.04) + (input - baseline) * (dark ? 0.0015 : 0.0012)),
      "editorBackground": surface.mixed(with: dark ? ink : white, amount: dark ? 0.07 : 0.12),
      "panelBackground": surface.mixed(with: dark ? ink : white, amount: (dark ? 0.03 : 0.18) + c * (dark ? 0.03 : 0.008)),
      "border": ink.opacity(0.06 + c * 0.04), "borderHeavy": ink.opacity((dark ? 0.12 : 0.09) + c * 0.06),
      "borderLight": ink.opacity((dark ? 0.03 : 0.04) + c * 0.02),
      "iconSecondary": ink.opacity(0.65 + c * 0.1), "iconTertiary": ink.opacity(0.45 + c * 0.1),
      "textForegroundSecondary": ink.opacity(0.65 + c * 0.1),
      "textForegroundTertiary": ink.opacity((dark ? 0.42 : 0.45) + c * (dark ? 0.13 : 0.1)),
      "textButtonTertiary": ink.opacity(0.45 + c * 0.1), "textOnAccent": accent.textOnAccent,
      "buttonSecondaryBackground": ink.opacity(0.04 + c * 0.02),
      "buttonSecondaryBackgroundActive": ink.opacity((dark ? 0.09 : 0.03) + c * (dark ? 0.05 : 0.02)),
      "buttonSecondaryBackgroundHover": ink.opacity((dark ? 0.06 : 0.04) + c * 0.03),
      "buttonSecondaryBackgroundInactive": ink.opacity((dark ? 0.02 : 0.01) + c * (dark ? 0.03 : 0.02)),
      "buttonTertiaryBackground": ink.opacity(dark ? 0.02 + c * 0.015 : 0),
      "buttonTertiaryBackgroundActive": ink.opacity((dark ? 0.07 : 0.16) + c * (dark ? 0.05 : 0.08)),
      "buttonTertiaryBackgroundHover": ink.opacity((dark ? 0.05 : 0.08) + c * (dark ? 0.03 : 0.04)),
      "simpleScrim": (dark ? ink : black).opacity(0.08 + c * 0.04),
      "editorAdded": AppearanceRGBA(hex: theme.semanticColors.diffAdded).opacity(dark ? 0.23 : 0.15),
      "editorRemoved": AppearanceRGBA(hex: theme.semanticColors.diffRemoved).opacity(dark ? 0.23 : 0.15),
      "diffAdded": AppearanceRGBA(hex: theme.semanticColors.diffAdded), "diffRemoved": AppearanceRGBA(hex: theme.semanticColors.diffRemoved),
      "skill": AppearanceRGBA(hex: theme.semanticColors.skill)
    ]
    let control = surface.mixed(with: dark ? ink : white, amount: dark ? 0.06 + c * 0.05 : 0.09 + c * 0.04)
    roles["controlBackground"] = control.opacity(0.96); roles["controlBackgroundOpaque"] = control
    let primary = surface.mixed(with: dark ? ink : white, amount: dark ? 0.08 + c * 0.08 : 0.16 + c * 0.12)
    roles["elevatedPrimary"] = primary.opacity(0.96); roles["elevatedPrimaryOpaque"] = primary
    if dark {
      let brighterAccent = accent.mixed(with: white, amount: 0.3 + c * 0.15)
      let primaryButton = surface.mixed(with: black, amount: 0.38 + c * 0.12)
      roles["accentBackground"] = black.mixed(with: accent, amount: 0.2 + c * 0.08)
      roles["accentBackgroundActive"] = black.mixed(with: accent, amount: 0.22 + c * 0.12)
      roles["accentBackgroundHover"] = black.mixed(with: accent, amount: 0.21 + c * 0.1)
      roles["borderFocus"] = brighterAccent.opacity(0.7 + c * 0.1)
      roles["buttonPrimaryBackground"] = primaryButton
      roles["buttonPrimaryBackgroundActive"] = ink.opacity(0.07 + c * 0.05)
      roles["buttonPrimaryBackgroundHover"] = ink.opacity(0.04 + c * 0.03)
      roles["buttonPrimaryBackgroundInactive"] = ink.opacity(0.02 + c * 0.02)
      roles["elevatedSecondary"] = ink.opacity(0.02 + c * 0.02)
      roles["elevatedSecondaryOpaque"] = surface.mixed(with: ink, amount: 0.04 + c * 0.05)
      roles["iconAccent"] = brighterAccent; roles["iconPrimary"] = ink.opacity(0.82 + c * 0.14)
      roles["textAccent"] = brighterAccent; roles["textButtonPrimary"] = primaryButton
      roles["textButtonSecondary"] = ink.mixed(with: surface, amount: 0.7 + c * 0.1)
      let defaultTheme = AppearancePreferences().themeShare(dark: true).theme
      let isDefault = theme.accent == defaultTheme.accent && theme.contrast == defaultTheme.contrast
        && theme.ink == defaultTheme.ink && theme.surface == defaultTheme.surface && theme.opaqueWindows == defaultTheme.opaqueWindows
        && theme.semanticColors == defaultTheme.semanticColors && theme.fonts == defaultTheme.fonts
      roles["textForeground"] = isDefault ? .init(hex: "#dfdfdf") : ink
    } else {
      roles["accentBackground"] = surface.mixed(with: accent, amount: 0.11 + c * 0.04)
      roles["accentBackgroundActive"] = surface.mixed(with: accent, amount: 0.13 + c * 0.05)
      roles["accentBackgroundHover"] = surface.mixed(with: accent, amount: 0.12 + c * 0.045)
      roles["borderFocus"] = accent
      roles["buttonPrimaryBackground"] = ink
      roles["buttonPrimaryBackgroundActive"] = ink.opacity(0.1 + c * 0.12)
      roles["buttonPrimaryBackgroundHover"] = ink.opacity(0.05 + c * 0.06)
      roles["buttonPrimaryBackgroundInactive"] = ink.opacity(0.18 + c * 0.14)
      let secondary = surface.mixed(with: white, amount: 0.08 + c * 0.08)
      roles["elevatedSecondary"] = secondary.opacity(0.96); roles["elevatedSecondaryOpaque"] = secondary
      roles["iconAccent"] = accent; roles["iconPrimary"] = ink; roles["textAccent"] = accent
      roles["textButtonPrimary"] = surface; roles["textButtonSecondary"] = ink; roles["textForeground"] = ink
    }
    let menu = surface.mixed(with: ink, amount: 0.02 + c * 0.02)
    roles["applicationMenuBackground"] = menu
    roles["applicationMenuForeground"] = dark ? menu.mixed(with: ink, amount: 0.875) : roles["textForeground"]
    roles["applicationMenuSeparator"] = dark ? menu.mixed(with: ink, amount: 0.28) : roles["borderHeavy"]
    colors = roles
  }
}
