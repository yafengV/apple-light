import SwiftUI

/// Settings actions participate in Tab navigation regardless of the system's
/// keyboard-navigation preference, like the reference app's HTML buttons.
struct SettingsActionButtonStyle: PrimitiveButtonStyle {
  var color: SettingsActionButtonColor = .secondary

  func makeBody(configuration: Configuration) -> some View {
    SettingsActionButton(configuration: configuration, color: color)
  }
}

enum SettingsActionButtonColor { case secondary, ghost }

private struct SettingsFocusRevealKey: EnvironmentKey {
  static let defaultValue: ((UUID) -> Void)? = nil
}
extension EnvironmentValues {
  var settingsRevealFocusedControl: ((UUID) -> Void)? {
    get { self[SettingsFocusRevealKey.self] }
    set { self[SettingsFocusRevealKey.self] = newValue }
  }
}

enum SettingsActionButtonMetrics {
  static let height: CGFloat = 28
  static let horizontalPadding: CGFloat = 8
  static let borderWidth: CGFloat = 1
  static let fontSize: CGFloat = 12
  static let lineHeight: CGFloat = 18
  static let radius: CGFloat = 10
  static let focusRing: CGFloat = 2
  static let disabledOpacity = 0.4
}

private struct SettingsActionButton: View {
  let configuration: PrimitiveButtonStyleConfiguration
  let color: SettingsActionButtonColor
  @Environment(\.isEnabled) private var isEnabled
  @Environment(\.appAppearance) private var appearance
  @Environment(\.settingsRevealFocusedControl) private var revealFocusedControl
  @State private var focusID = UUID()
  @FocusState private var focused: Bool

  @ViewBuilder private var control: some View {
    if configuration.role == .destructive {
      // Preserve the existing destructive control until its reference variants
      // are mapped explicitly, rather than render deletion as a neutral action.
      Button(configuration).buttonStyle(.bordered)
    } else {
      Button(configuration).buttonStyle(SettingsActionSurfaceStyle(color: color, focused: focused))
    }
  }
  var body: some View {
    control
      .focusable(isEnabled)
      .focused($focused)
      .focusEffectDisabled()
      .id(focusID)
      .overlay {
        if configuration.role == .destructive && focused && isEnabled {
          RoundedRectangle(cornerRadius: 5).strokeBorder(appearance.accentColor, lineWidth: 2)
            .padding(-3).allowsHitTesting(false)
        }
      }
      .onKeyPress(keys: [.space, .return], phases: .down) { press in
        guard isEnabled, press.modifiers.isEmpty else { return .ignored }
        configuration.trigger()
        return .handled
      }
      .onChange(of: isEnabled) { _, enabled in
        if !enabled { focused = false }
      }
      .onChange(of: focused) { _, value in
        if value && isEnabled { revealFocusedControl?(focusID) }
      }
  }
}

private struct SettingsActionSurfaceStyle: ButtonStyle {
  let color: SettingsActionButtonColor
  let focused: Bool
  @State private var hovered = false

  func makeBody(configuration: Configuration) -> some View {
    SettingsActionButtonSurface(color: color, hovered: hovered, focused: focused) {
      configuration.label
    }.onHover { hovered = $0 }
  }
}

/// Shared rendering is also used by native geometry/pixel verification.
struct SettingsActionButtonSurface<Content: View>: View {
  let color: SettingsActionButtonColor
  var hovered = false
  var focused = false
  @ViewBuilder var content: () -> Content
  @Environment(\.isEnabled) private var isEnabled
  @Environment(\.appAppearance) private var appearance

  private var shape: RoundedRectangle {
    RoundedRectangle(cornerRadius: SettingsActionButtonMetrics.radius, style: .continuous)
  }
  private var background: Color {
    switch color {
    case .secondary: appearance.foregroundColor.opacity(isEnabled && hovered ? 0.1 : 0.05)
    case .ghost: isEnabled && hovered ? appearance.resolvedColors["buttonSecondaryBackgroundHover"].color : .clear
    }
  }
  var body: some View {
    content().appFont(size: SettingsActionButtonMetrics.fontSize).lineLimit(1)
      .fixedSize(horizontal: true, vertical: true)
      .frame(minHeight: SettingsActionButtonMetrics.lineHeight)
      .padding(.horizontal, SettingsActionButtonMetrics.horizontalPadding + SettingsActionButtonMetrics.borderWidth)
      .frame(height: SettingsActionButtonMetrics.height)
      .foregroundStyle(color == .secondary ? appearance.foregroundColor
        : appearance.resolvedColors["textForegroundTertiary"].color)
      .background(background, in: shape)
      .contentShape(shape)
      .opacity(isEnabled ? 1 : SettingsActionButtonMetrics.disabledOpacity)
      .overlay {
        if focused && isEnabled {
          shape.stroke(appearance.resolvedColors["borderFocus"].color,
            lineWidth: SettingsActionButtonMetrics.focusRing)
            .padding(-SettingsActionButtonMetrics.focusRing / 2).allowsHitTesting(false)
        }
      }
  }
}
