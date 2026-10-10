import AppKit

/// Capture before disabling the settings page. A shared field editor cannot
/// identify its original control once the confirmation has taken focus.
@MainActor struct SettingsDiscardReturnFocus {
  private let target: SearchDialogReturnFocus
  private let page: SettingsPage
  private let navigationRevision: UUID
  private let focusRevision: UUID
  private let restoreControl: (() -> Void)?
  private let confirmControl: (() -> Void)?

  init(window: NSWindow?, store: WorkspaceStore, restoreControl: (() -> Void)?,
    confirmControl: (() -> Void)?) {
    target = SearchDialogReturnFocus(window: window, destination: .settings)
    page = store.settingsPage
    navigationRevision = store.environmentSettingsNavigationRevision
    focusRevision = store.settingsDiscardFocusRevision
    self.restoreControl = restoreControl
    self.confirmControl = confirmControl
  }

  func restore(store: WorkspaceStore, afterNavigation: Bool = false) {
    let page = afterNavigation ? store.settingsPage : self.page
    let navigationRevision = afterNavigation ? store.environmentSettingsNavigationRevision : self.navigationRevision
    let focusRevision = afterNavigation ? store.settingsDiscardFocusRevision : self.focusRevision
    let restoreControl = afterNavigation ? confirmControl : self.restoreControl
    let allowed: @MainActor () -> Bool = { [weak store, weak window = target.window] in
      guard let store, let window else { return false }
      return store.destination == .settings && store.settingsPage == page
        && store.environmentSettingsNavigationRevision == navigationRevision
        && store.settingsDiscardFocusRevision == focusRevision
        && !store.hasSettingsConfirmation && store.presentedOverlay == nil
        && store.appshotIntroRequest == nil && !store.libraryRecoveryBlocksInteraction
        && !store.shuttingDown && window.isKeyWindow && window.isVisible
        && window.attachedSheet == nil && NSApp.modalWindow == nil
        && !SettingsPopupMenuButton.hasOpenMenu(in: window)
    }
    // Let the retained page become enabled before restoring its SwiftUI focus.
    DispatchQueue.main.async {
      guard allowed() else { return }
      if let restoreControl { restoreControl() }
      else { target.restore(when: allowed) }
    }
  }
}
