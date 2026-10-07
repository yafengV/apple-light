import AppKit

/// A field editor is shared by all text fields in a window. Save its owning
/// control, not the editor that will soon be reused by the search query.
@MainActor struct SearchDialogReturnFocus {
  weak var view: NSView?
  weak var window: NSWindow?
  let destination: AppDestination
  private weak var fileWorkspace: DeveloperWorkspace?
  private let fileRoot: URL?
  private let filePath: String?

  init(window: NSWindow?, destination: AppDestination) {
    self.window = window
    self.destination = destination
    if let editor = window?.firstResponder as? NSTextView, editor.isFieldEditor {
      view = editor.delegate as? NSView
    } else { view = window?.firstResponder as? NSView }
    let source = (view as? FilePreviewTextView)?.workspace
    fileWorkspace = source
    fileRoot = source?.root
    filePath = source?.selectedFile
  }

  /// File previews may be recreated while a modal is visible. Route a fresh
  /// request through the original editor's model instead of retaining its view.
  func restoreFileFocus(store: WorkspaceStore) -> Bool {
    guard destination == .workspace, store.destination == destination,
      store.presentedOverlay == nil, let window, window.isKeyWindow,
      window.attachedSheet == nil, let source = fileWorkspace,
      let fileRoot, let filePath, source.root == fileRoot, source.selectedFile == filePath,
      store.commandFileWorkspace === source else { return false }
    source.fileFocusRequest = UUID()
    return true
  }

  func restore(store: WorkspaceStore) {
    restore { [weak store, destination] in
      store?.presentedOverlay == nil && store?.destination == destination
    }
  }

  func restore(when allowed: @escaping @MainActor () -> Bool) {
    DispatchQueue.main.async { [weak view, weak window] in
      guard allowed(), let view, let window, window.isKeyWindow, view.window === window,
        !view.isHiddenOrHasHiddenAncestor, window.attachedSheet == nil else { return }
      window.makeFirstResponder(view)
    }
  }
}
