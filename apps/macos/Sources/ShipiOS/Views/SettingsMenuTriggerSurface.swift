import AppKit
import SwiftUI

enum SettingsMenuTriggerMetrics {
  static let height: CGFloat = 28
  static let fontSize: CGFloat = 13
  static let lineHeight: CGFloat = 18
  static let padding: CGFloat = 12
  static let swatchPadding: CGFloat = 3
  static let border: CGFloat = 1
  static let gap: CGFloat = 4
  static let swatchGap: CGFloat = 6
  static let swatchSize: CGFloat = 20
  static let chevronSize: CGFloat = 14
  static let radius: CGFloat = 10
  static let focusRing: CGFloat = 2
  static let disabledOpacity = 0.4
}

struct SettingsMenuTriggerConfiguration {
  let appearance: AppearancePreferences
  let swatch: SettingsMenuSwatch?
  let direction: LayoutDirection
}

/// Only the trigger is drawn here. The existing NSPopUpButton continues to own
/// first responder, accessibility, the selected value and native menu tracking.
struct SettingsMenuTriggerSurface: View {
  let title: String
  var swatch: SettingsMenuSwatch?
  var hovered = false
  var open = false
  var focused = false
  @Environment(\.isEnabled) private var isEnabled
  @Environment(\.appAppearance) private var appearance
  private var shape: RoundedRectangle {
    RoundedRectangle(cornerRadius: SettingsMenuTriggerMetrics.radius, style: .continuous)
  }
  var body: some View {
    HStack(spacing: SettingsMenuTriggerMetrics.gap) {
      HStack(spacing: SettingsMenuTriggerMetrics.swatchGap) {
        if let swatch { ThemeColorSwatch(swatch: swatch, size: SettingsMenuTriggerMetrics.swatchSize) }
        Text(title).appFont(size: SettingsMenuTriggerMetrics.fontSize).lineLimit(1)
          .truncationMode(.tail).frame(maxWidth: .infinity, alignment: .leading)
      }.frame(maxWidth: .infinity, alignment: .leading)
      SettingsMenuChevron().frame(width: SettingsMenuTriggerMetrics.chevronSize,
        height: SettingsMenuTriggerMetrics.chevronSize)
        .foregroundStyle(appearance.resolvedColors["textForegroundTertiary"].color)
    }
    .frame(minHeight: SettingsMenuTriggerMetrics.lineHeight)
    .padding(.leading, (swatch == nil ? SettingsMenuTriggerMetrics.padding : SettingsMenuTriggerMetrics.swatchPadding)
      + SettingsMenuTriggerMetrics.border)
    .padding(.trailing, SettingsMenuTriggerMetrics.padding + SettingsMenuTriggerMetrics.border)
    .frame(height: SettingsMenuTriggerMetrics.height)
    .foregroundStyle(appearance.foregroundColor)
    .background(appearance.resolvedColors[isEnabled && (hovered || open)
      ? "buttonSecondaryBackgroundHover" : "elevatedSecondary"].color, in: shape)
    .overlay { shape.strokeBorder(appearance.resolvedColors["border"].color, lineWidth: SettingsMenuTriggerMetrics.border) }
    .opacity(isEnabled ? 1 : SettingsMenuTriggerMetrics.disabledOpacity)
    .overlay {
      if focused && isEnabled {
        shape.stroke(appearance.resolvedColors["borderFocus"].color, lineWidth: SettingsMenuTriggerMetrics.focusRing)
          .padding(-SettingsMenuTriggerMetrics.focusRing / 2)
      }
    }
    .accessibilityHidden(true).allowsHitTesting(false)
  }
}

/// Public chevron viewBox 0 0 20 21, preserving its aspect ratio in a 14-point icon.
private struct SettingsMenuChevron: View {
  var body: some View {
    SettingsMenuChevronPath().fill()
      .overlay(SettingsMenuChevronPath().stroke(lineWidth: 0.6 * SettingsMenuTriggerMetrics.chevronSize / 21))
  }
}
private struct SettingsMenuChevronPath: Shape {
  func path(in rect: CGRect) -> Path {
    var p = Path()
    p.move(to: .init(x: 15.2793, y: 7.71101))
    p.addCurve(to: .init(x: 16.2207, y: 7.71101), control1: .init(x: 15.539, y: 7.45131), control2: .init(x: 15.961, y: 7.45131))
    p.addCurve(to: .init(x: 16.2207, y: 8.65242), control1: .init(x: 16.4804, y: 7.97071), control2: .init(x: 16.4804, y: 8.39272))
    p.addLine(to: .init(x: 10.4707, y: 14.4024))
    p.addCurve(to: .init(x: 9.52932, y: 14.4024), control1: .init(x: 10.211, y: 14.6621), control2: .init(x: 9.78902, y: 14.6621))
    p.addLine(to: .init(x: 3.77932, y: 8.65242)); p.addLine(to: .init(x: 3.69436, y: 8.54792))
    p.addCurve(to: .init(x: 3.77932, y: 7.71101), control1: .init(x: 3.52385, y: 8.28979), control2: .init(x: 3.55205, y: 7.93828))
    p.addCurve(to: .init(x: 4.61623, y: 7.62605), control1: .init(x: 4.00659, y: 7.48374), control2: .init(x: 4.3581, y: 7.45554))
    p.addLine(to: .init(x: 4.72073, y: 7.71101)); p.addLine(to: .init(x: 10, y: 12.9903))
    p.addLine(to: .init(x: 15.2793, y: 7.71101)); p.closeSubpath()
    let scale = min(rect.width / 20, rect.height / 21)
    return p.applying(.init(a: scale, b: 0, c: 0, d: scale,
      tx: rect.midX - 10 * scale, ty: rect.midY - 10.5 * scale))
  }
}

final class SettingsMenuTriggerHostingView: NSHostingView<AnyView> {
  override var acceptsFirstResponder: Bool { false }
  override var canBecomeKeyView: Bool { false }
  override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
