import SwiftUI

enum RenameDialogField: String, CaseIterable {
  case name, cancel, save, close
  static func order(valid: Bool) -> [Self] { valid ? [.name, .cancel, .save, .close] : [.name, .cancel, .close] }
  static func next(after field: Self?, valid: Bool, reverse: Bool) -> Self {
    let fields = order(valid: valid), index = fields.firstIndex(of: field ?? .name) ?? 0
    return fields[(index + (reverse ? fields.count - 1 : 1)) % fields.count]
  }
  var closesOnEnter: Bool { self == .cancel || self == .close }
}

/// HTML buttons activate Space on release; focus loss cancels the pending press.
struct RenameDialogSpacePress {
  private(set) var armed = false
  mutating func down(enabled: Bool, focused: Bool, repeatEvent: Bool = false) {
    if enabled && focused && !repeatEvent { armed = true }
  }
  mutating func up(enabled: Bool, focused: Bool) -> Bool {
    let activate = armed && enabled && focused
    armed = false
    return activate
  }
  mutating func cancel() { armed = false }
}

private struct RenameDialogActionFocus: ViewModifier {
  let focus: FocusState<RenameDialogField?>.Binding
  let field: RenameDialogField
  let activate: () -> Void
  @Environment(\.isEnabled) private var enabled
  @State private var press = RenameDialogSpacePress()
  func body(content: Content) -> some View {
    content.focusable(enabled).focused(focus, equals: field).focusEffectDisabled()
      .onKeyPress(keys: [.space], phases: [.down, .repeat, .up]) { key in
        guard enabled, focus.wrappedValue == field, key.modifiers.isEmpty else {
          press.cancel(); return .ignored
        }
        if key.phase == .up {
          if press.up(enabled: enabled, focused: true) { activate() }
        } else { press.down(enabled: enabled, focused: true, repeatEvent: key.phase == .repeat) }
        return .handled
      }
      .onChange(of: focus.wrappedValue) { _, value in if value != field { press.cancel() } }
      .onChange(of: enabled) { _, value in if !value { press.cancel() } }
      .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in press.cancel() }
      .onDisappear { press.cancel() }
  }
}

extension View {
  func renameDialogActionFocus(_ focus: FocusState<RenameDialogField?>.Binding,
    equals field: RenameDialogField, activate: @escaping () -> Void) -> some View {
    modifier(RenameDialogActionFocus(focus: focus, field: field, activate: activate))
  }
}
