import SwiftUI

private struct SettingsConfirmationReturnFocus: ViewModifier {
  let presented: Bool
  let store: WorkspaceStore
  let page: SettingsPage
  let restore: () -> Void
  @State private var generation = UUID()

  func body(content: Content) -> some View {
    content
      .onChange(of: presented) { previous, current in
        let token = UUID()
        generation = token
        guard previous, !current else { return }
        // The parent must finish enabling its retained controls before focus
        // can return. Opening another modal or removing this page invalidates it.
        DispatchQueue.main.async {
          guard generation == token, store.destination == .settings,
            store.settingsPage == page, !store.hasSettingsConfirmation,
            store.presentedOverlay == nil else { return }
          restore()
        }
      }
      .onDisappear { generation = UUID() }
  }
}

private struct SettingsActionFocus<Value: Hashable>: ViewModifier {
  let focus: FocusState<Value?>.Binding
  let value: Value
  let activate: (() -> Void)?
  @Environment(\.isEnabled) private var isEnabled
  @Environment(\.appAppearance) private var appearance

  func body(content: Content) -> some View {
    content.focusable(isEnabled).focused(focus, equals: value).focusEffectDisabled()
      .onKeyPress(keys: [.space, .return], phases: .down) { press in
        guard isEnabled, focus.wrappedValue == value, press.modifiers.isEmpty,
          let activate else { return .ignored }
        activate()
        return .handled
      }
      .overlay {
        if isEnabled && focus.wrappedValue == value {
          RoundedRectangle(cornerRadius: 5)
            .strokeBorder(appearance.accentColor, lineWidth: 2)
            .padding(-3).allowsHitTesting(false)
        }
      }
  }
}

extension View {
  func onSettingsConfirmationDismissal(_ presented: Bool, store: WorkspaceStore,
    page: SettingsPage, restore: @escaping () -> Void) -> some View {
    modifier(SettingsConfirmationReturnFocus(presented: presented, store: store, page: page, restore: restore))
  }

  func settingsActionFocus<Value: Hashable>(_ focus: FocusState<Value?>.Binding,
    equals value: Value, activate: (() -> Void)? = nil) -> some View {
    modifier(SettingsActionFocus(focus: focus, value: value, activate: activate))
  }
}
