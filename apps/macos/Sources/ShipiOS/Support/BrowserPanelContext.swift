import SwiftUI

@MainActor struct BrowserPanelContext {
  let taskID: String
  let canFocus: () -> Bool
  let newTab: () -> Void
  let closeTab: (UUID) -> Void
  let reopen: () -> Void
  let openSettings: () -> Void
  let focusComposer: () -> Void
  var independentFocus = false
  var canReopen: Bool? = nil
}

private struct MessageBrowserRouteKey: EnvironmentKey {
  static let defaultValue: ((URL, MessageWebLinkPresentation) -> Void)? = nil
}
extension EnvironmentValues {
  var messageBrowserRoute: ((URL, MessageWebLinkPresentation) -> Void)? {
    get { self[MessageBrowserRouteKey.self] }
    set { self[MessageBrowserRouteKey.self] = newValue }
  }
}
