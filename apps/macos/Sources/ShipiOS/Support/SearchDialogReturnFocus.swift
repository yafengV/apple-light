import AppKit

/// A field editor is shared by all text fields in a window. Save its owning
/// control, not the editor that will soon be reused by the search query.
@MainActor struct SearchDialogReturnFocus {
  weak var view: NSView?
  weak var window: NSWindow?
  let destination: AppDestination
  let hadSourceView: Bool
  private let fieldSelection: (range: NSRange, fingerprint: Int)?
  private weak var fileWorkspace: DeveloperWorkspace?
  private let fileRoot: URL?
  private let filePath: String?
  private let workspaceScope: (owner: String, root: URL?)?

  init(window: NSWindow?, destination: AppDestination, store: WorkspaceStore? = nil) {
    self.window = window
    self.destination = destination
    workspaceScope = destination == .workspace ? store.map { ($0.currentWorkspaceTabOwner, $0.project) } : nil
    if let editor = window?.firstResponder as? NSTextView, editor.isFieldEditor {
      view = editor.delegate as? NSView
      fieldSelection = view is NSSecureTextField ? nil : (editor.selectedRange(), editor.string.hashValue)
    } else {
      view = window?.firstResponder as? NSView
      fieldSelection = nil
    }
    hadSourceView = view != nil
    let source = (view as? FilePreviewTextView)?.workspace
    fileWorkspace = source
    fileRoot = source?.root
    filePath = source?.selectedFile
  }

  var isFileSource: Bool { fileRoot != nil && filePath != nil }

  /// File previews may be recreated while a modal is visible. Route a fresh
  /// request through the original editor's model instead of retaining its view.
  func restoreFileFocus(store: WorkspaceStore) -> Bool {
    guard destination == .workspace, store.destination == destination,
      store.presentedOverlay == nil, matchesWorkspaceScope(store), let window, window.isKeyWindow,
      window.attachedSheet == nil, let source = fileWorkspace,
      let fileRoot, let filePath, source.root == fileRoot, source.selectedFile == filePath,
      (source === store.workspace ? store.filesVisible : store.commandFileWorkspace === source) else { return false }
    source.fileFocusRequest = UUID()
    return true
  }

  @discardableResult func restore(store: WorkspaceStore) -> Bool {
    let revision = store.searchDialogFocusRevision
    let allowed: @MainActor () -> Bool = { [weak store] in
      guard let store, store.searchDialogFocusRevision == revision,
        store.presentedOverlay == nil, store.destination == destination,
        !store.libraryRecoveryBlocksInteraction, !store.shuttingDown,
        !store.hasSettingsConfirmation, store.appshotIntroRequest == nil,
        !store.showingModelPicker, !store.showingBranchPicker else { return false }
      return matchesWorkspaceScope(store)
    }
    guard allowed(), let view, let window, window.isKeyWindow,
      view.window === window, !view.isHiddenOrHasHiddenAncestor,
      window.attachedSheet == nil, NSApp.modalWindow == nil else { return false }
    if let editor = view as? ComposerNativeTextView,
      let coordinator = editor.coordinator, coordinator.active {
      coordinator.restoreFocus(in: editor, when: allowed)
    } else { restore(when: allowed) }
    return true
  }

  func restore(when allowed: @escaping @MainActor () -> Bool) {
    DispatchQueue.main.async { [weak view, weak window, fieldSelection] in
      guard allowed(), let view, let window, window.isKeyWindow, view.window === window,
        !view.isHiddenOrHasHiddenAncestor, window.attachedSheet == nil else { return }
      guard window.makeFirstResponder(view) else { return }
      // AppKit reuses one field editor and selects the entire value on return.
      // Restore its original range only while the source value is unchanged;
      // keep an ephemeral fingerprint, never another copy of the field value.
      if let fieldSelection, let field = view as? NSTextField,
        let editor = field.currentEditor(), editor.string.hashValue == fieldSelection.fingerprint {
        editor.selectedRange = fieldSelection.range
      }
    }
  }

  private func matchesWorkspaceScope(_ store: WorkspaceStore) -> Bool {
    workspaceScope == nil || (store.currentWorkspaceTabOwner == workspaceScope?.owner
      && store.project == workspaceScope?.root)
  }
}
