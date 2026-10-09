import SwiftUI

/// Compact Cvo dialog metrics from the pinned desktop components and CSS.
/// Continuous native curves/material still need paired foreground acceptance.
enum RenameDialogMetrics {
  static let width: CGFloat = 420
  static let padding: CGFloat = 20
  static let sectionGap: CGFloat = 12
  static let headerGap: CGFloat = 4
  static let headingFont: CGFloat = 20
  static let headingLineHeight: CGFloat = 28
  static let descriptionFont: CGFloat = 14
  static let descriptionLineHeight: CGFloat = 21
  static let inputHeight: CGFloat = 36
  static let inputPadding: CGFloat = 10
  static let inputFont: CGFloat = 13
  static let buttonHeight: CGFloat = 32
  static let buttonPadding: CGFloat = 16
  static let buttonFont: CGFloat = 14
  static let buttonLineHeight: CGFloat = 18
  static let buttonGap: CGFloat = 12
  static let closeSize: CGFloat = 24
  static let closeInset: CGFloat = 16
  static let borderWidth: CGFloat = 1
  static let surfaceRadius: CGFloat = 20
  static let buttonRadius: CGFloat = 10
  static let inputRadius: CGFloat = 8
  static let overlayOpacity = 2.0 / 15
  static let disabledOpacity = 0.4
}

struct RenameDialogSurface<Header: View, Input: View, Footer: View, Close: View>: View {
  let availableWidth: CGFloat
  @ViewBuilder var header: () -> Header
  @ViewBuilder var input: () -> Input
  @ViewBuilder var footer: () -> Footer
  @ViewBuilder var close: () -> Close
  @Environment(\.appAppearance) private var appearance

  var body: some View {
    VStack(alignment: .leading, spacing: RenameDialogMetrics.sectionGap) {
      header().frame(maxWidth: .infinity, alignment: .leading)
      input()
      footer()
    }
    .padding(RenameDialogMetrics.padding)
    .frame(width: min(RenameDialogMetrics.width, availableWidth * 0.92), alignment: .leading)
    .background {
      let shape = RoundedRectangle(cornerRadius: RenameDialogMetrics.surfaceRadius, style: .continuous)
      shape.fill(.regularMaterial)
        .overlay(shape.fill(appearance.resolvedColors["elevatedSecondaryOpaque"].color.opacity(0.9)))
    }
    .overlay {
      RoundedRectangle(cornerRadius: RenameDialogMetrics.surfaceRadius, style: .continuous)
        .strokeBorder(appearance.resolvedColors["border"].color, lineWidth: 0.5).allowsHitTesting(false)
    }
    .shadow(color: .black.opacity(0.2), radius: 20, y: 8)
    // The reference's close button follows the form in DOM order and uses
    // physical right, including RTL. It must not consume the header's width.
    .overlay {
      GeometryReader { geometry in
        close().frame(width: RenameDialogMetrics.closeSize, height: RenameDialogMetrics.closeSize)
          .position(x: geometry.size.width - RenameDialogMetrics.closeInset - RenameDialogMetrics.closeSize / 2,
            y: RenameDialogMetrics.closeInset + RenameDialogMetrics.closeSize / 2)
      }.environment(\.layoutDirection, .leftToRight)
    }
  }
}

struct RenameDialogButtonStyle: ButtonStyle {
  enum ColorRole { case outline, primary, close }
  var role: ColorRole
  var focused: Bool
  @Environment(\.isEnabled) private var enabled
  @Environment(\.appAppearance) private var appearance
  @State private var hovered = false

  private var shape: RoundedRectangle {
    RoundedRectangle(cornerRadius: role == .close ? 4 : RenameDialogMetrics.buttonRadius, style: .continuous)
  }
  private var background: Color {
    switch role {
    case .primary: appearance.foregroundColor.opacity(hovered ? 0.8 : 1)
    case .outline: hovered ? appearance.resolvedColors["buttonSecondaryBackgroundHover"].color
        : appearance.resolvedColors["elevatedSecondary"].color
    case .close: hovered ? appearance.resolvedColors["buttonSecondaryBackgroundHover"].color : .clear
    }
  }
  func makeBody(configuration: Configuration) -> some View {
    configuration.label.appFont(size: RenameDialogMetrics.buttonFont)
      .lineLimit(1).fixedSize(horizontal: true, vertical: true)
      .frame(minHeight: role == .close ? 16 : RenameDialogMetrics.buttonLineHeight)
      .padding(.horizontal, role == .close ? 4 : RenameDialogMetrics.buttonPadding + RenameDialogMetrics.borderWidth)
      .frame(height: role == .close ? RenameDialogMetrics.closeSize : RenameDialogMetrics.buttonHeight)
      .foregroundStyle(role == .primary ? appearance.resolvedColors["controlBackgroundOpaque"].color : appearance.foregroundColor)
      .background(background, in: shape).contentShape(shape)
      .overlay {
        if role != .close { shape.strokeBorder(appearance.resolvedColors["border"].color, lineWidth: 1) }
        if focused && enabled {
          shape.stroke(appearance.resolvedColors["borderFocus"].color, lineWidth: 2)
            .padding(-1).allowsHitTesting(false)
        }
      }
      .opacity(enabled ? 1 : RenameDialogMetrics.disabledOpacity)
      .onHover { hovered = enabled && $0 }
  }
}

struct RenameDialogHeader: View {
  let title: String
  let subtitle: String
  @Environment(\.appAppearance) private var appearance
  var body: some View {
    VStack(alignment: .leading, spacing: RenameDialogMetrics.headerGap) {
      Text(title).appFont(size: RenameDialogMetrics.headingFont, weight: .semibold)
        .settingsTextLineHeight(text: title, fontSize: RenameDialogMetrics.headingFont,
          lineHeight: RenameDialogMetrics.headingLineHeight, weight: .semibold)
        .accessibilityAddTraits(.isHeader)
      Text(subtitle).appFont(size: RenameDialogMetrics.descriptionFont)
        .settingsTextLineHeight(text: subtitle, fontSize: RenameDialogMetrics.descriptionFont,
          lineHeight: RenameDialogMetrics.descriptionLineHeight)
        .foregroundStyle(appearance.resolvedColors["textForegroundTertiary"].color)
    }.frame(maxWidth: .infinity, alignment: .leading)
  }
}
