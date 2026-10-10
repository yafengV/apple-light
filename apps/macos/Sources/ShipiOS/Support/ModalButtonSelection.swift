/// Native event monitors may process several keys before SwiftUI refreshes a
/// FocusState snapshot. Keep their selection synchronous; FocusState renders it.
@MainActor final class ModalButtonSelection<Action: Equatable> {
  var current: Action
  init(_ initial: Action) { current = initial }
  func advance(between first: Action, and second: Action) -> Action {
    current = current == first ? second : first
    return current
  }
}
