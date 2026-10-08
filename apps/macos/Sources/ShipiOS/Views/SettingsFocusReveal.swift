import SwiftUI

private struct SettingsFocusRevealKey: EnvironmentKey {
  static let defaultValue: ((UUID) -> Void)? = nil
}
private struct SettingsNativeControlDidFocusKey: EnvironmentKey {
  static let defaultValue: (() -> Void)? = nil
}
extension EnvironmentValues {
  var settingsRevealFocusedControl: ((UUID) -> Void)? {
    get { self[SettingsFocusRevealKey.self] }
    set { self[SettingsFocusRevealKey.self] = newValue }
  }
  var settingsNativeControlDidFocus: (() -> Void)? {
    get { self[SettingsNativeControlDidFocusKey.self] }
    set { self[SettingsNativeControlDidFocusKey.self] = newValue }
  }
}

/// Reveal actual focus without changing the control's key loop or value.
/// Native controls report accepted first-responder changes through the narrow
/// callback; SwiftUI controls use their existing FocusState.
private struct SettingsFocusRevealModifier: ViewModifier {
  let focused: Bool
  @State private var id = UUID()
  @Environment(\.isEnabled) private var enabled
  @Environment(\.settingsRevealFocusedControl) private var reveal

  func body(content: Content) -> some View {
    content.id(id)
      .environment(\.settingsNativeControlDidFocus, revealIfEnabled)
      .onChange(of: focused) { _, value in if value { revealIfEnabled() } }
  }
  private func revealIfEnabled() { if enabled { reveal?(id) } }
}
extension View {
  func settingsFocusReveal(focused: Bool = false) -> some View {
    modifier(SettingsFocusRevealModifier(focused: focused))
  }
}
