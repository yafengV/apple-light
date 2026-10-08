import SwiftUI

/// Variants supplied by the appearance page's actual form-trigger calls.
struct SettingsMenuTriggerStyle: Equatable {
  let fontSize: CGFloat
  let lineHeight: CGFloat
  let padding: CGFloat
  let swatchPadding: CGFloat
  let radius: CGFloat
  let backgroundRole: String
  static let toolbar = Self(fontSize: 13, lineHeight: 18, padding: 12, swatchPadding: 3,
    radius: 10, backgroundRole: "elevatedSecondary")
  static let font = Self(fontSize: 12, lineHeight: 16, padding: 8, swatchPadding: 8,
    radius: 9999, backgroundRole: "elevatedSecondary")
  static let accent = Self(fontSize: 12, lineHeight: 16, padding: 8, swatchPadding: 8,
    radius: 9999, backgroundRole: "surface")
  static let codeTheme = Self(fontSize: 13, lineHeight: 18, padding: 12, swatchPadding: 3,
    radius: 9999, backgroundRole: "surface")
}
