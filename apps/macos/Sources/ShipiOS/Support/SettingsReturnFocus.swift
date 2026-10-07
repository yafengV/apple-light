import AppKit

/// Settings replace the main window page. Keep the originating control and
/// workspace scope, rather than the settings field editor shared by that window.
@MainActor struct SettingsReturnFocus {
  let target: SearchDialogReturnFocus
  private let workspaceOwner: String?
  private let workspaceRoot: URL?

  init(target: SearchDialogReturnFocus, store: WorkspaceStore) {
    self.target = target
    workspaceOwner = target.destination == .workspace ? store.currentWorkspaceTabOwner : nil
    workspaceRoot = target.destination == .workspace ? store.project : nil
  }

  func restore(store: WorkspaceStore) -> Bool {
    guard matches(store), store.presentedOverlay == nil else { return false }
    if target.isFileSource { return target.restoreFileFocus(store: store) }
    guard let view = target.view, let window = target.window,
      window.isKeyWindow, window.attachedSheet == nil, view.window === window,
      !view.isHiddenOrHasHiddenAncestor else { return false }
    let revision = store.settingsFocusRevision
    let allowed: @MainActor () -> Bool = { [weak store, weak window, weak view] in
      guard let store else { return false }
      return store.settingsFocusRevision == revision && matches(store)
        && store.presentedOverlay == nil
        && window?.isKeyWindow == true && view?.window === window
    }
    if let editor = view as? ComposerNativeTextView,
      let coordinator = editor.coordinator, coordinator.active {
      coordinator.restoreFocus(in: editor, when: allowed)
    } else { target.restore(when: allowed) }
    return true
  }

  private func matches(_ store: WorkspaceStore) -> Bool {
    guard store.destination == target.destination else { return false }
    return target.destination != .workspace
      || (store.currentWorkspaceTabOwner == workspaceOwner && store.project == workspaceRoot)
  }
}
