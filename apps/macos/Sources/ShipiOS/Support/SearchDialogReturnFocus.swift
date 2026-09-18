import AppKit

/// A field editor is shared by all text fields in a window. Save its owning
/// control, not the editor that will soon be reused by the search query.
@MainActor struct SearchDialogReturnFocus {
  weak var view: NSView?
  weak var window: NSWindow?
  let destination: AppDestination

  init(window: NSWindow?, destination: AppDestination) {
    self.window = window
    self.destination = destination
    if let editor = window?.firstResponder as? NSTextView, editor.isFieldEditor {
      view = editor.delegate as? NSView
    } else { view = window?.firstResponder as? NSView }
  }

  func restore(store: WorkspaceStore) {
    DispatchQueue.main.async { [weak store, weak view, weak window, destination] in
      guard let store, store.presentedOverlay == nil, store.destination == destination,
        let view, let window, window.isKeyWindow, view.window === window,
        !view.isHiddenOrHasHiddenAncestor, window.attachedSheet == nil else { return }
      window.makeFirstResponder(view)
    }
  }
}
