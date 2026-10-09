import SwiftUI

/// Inline tab-strip editing; the pinned sidebar uses a separate presentation.
@MainActor struct BrowserTabTitleEditor: NSViewRepresentable {
  let session: BrowserSession
  let request: BrowserTabRenameRequest
  var onFinish: () -> Void = {}
  func makeCoordinator() -> Coordinator { Coordinator(session: session, request: request, onFinish: onFinish) }
  func makeNSView(context: Context) -> Field {
    let field = Field()
    field.stringValue = request.initialTitle
    field.placeholderString = request.defaultTitle
    field.font = .systemFont(ofSize: 12)
    field.isBordered = false; field.drawsBackground = false
    field.focusRingType = .none
    field.setAccessibilityLabel("标签页标题")
    field.identifier = NSUserInterfaceItemIdentifier("browser-tab-title-editor")
    field.delegate = context.coordinator; field.coordinator = context.coordinator
    session.titleField = field
    return field
  }
  func updateNSView(_ field: Field, context: Context) {
    context.coordinator.onFinish = onFinish
    field.placeholderString = request.tab.pageTitle
  }
  static func dismantleNSView(_ field: Field, coordinator: Coordinator) {
    if coordinator.session?.titleField === field { coordinator.session?.titleField = nil }
    field.delegate = nil; field.coordinator = nil
  }
  final class Field: NSTextField {
    weak var coordinator: Coordinator?
    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      guard let window else { return }
      DispatchQueue.main.async { [weak self, weak window] in
        guard let self, let window, self.window === window, window.isKeyWindow,
          self.coordinator?.isCurrent == true else { return }
        window.makeFirstResponder(self); self.currentEditor()?.selectAll(nil)
      }
    }
  }
  @MainActor final class Coordinator: NSObject, NSTextFieldDelegate {
    weak var session: BrowserSession?
    let request: BrowserTabRenameRequest
    var onFinish: () -> Void
    var isCurrent: Bool { session?.renameRequest?.id == request.id && !request.tab.closed }
    init(session: BrowserSession, request: BrowserTabRenameRequest, onFinish: @escaping () -> Void) {
      self.session = session; self.request = request; self.onFinish = onFinish
    }
    /// End-editing also fires after Enter; the request guard makes it idempotent.
    func finish(_ value: String, cancel: Bool = false, restoreTabFocus: Bool = false) {
      guard isCurrent, let session else { return }
      if !cancel { _ = session.saveRename(request, title: value) }
      session.endRename(request)
      if restoreTabFocus { onFinish() }
    }
    func controlTextDidEndEditing(_ notification: Notification) {
      guard let field = notification.object as? NSTextField else { return }
      finish(field.stringValue)
    }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
      guard isCurrent, !textView.hasMarkedText(), let field = control as? NSTextField else { return false }
      if selector == #selector(NSResponder.insertNewline(_:)) {
        finish(textView.string, restoreTabFocus: true)
      } else if selector == #selector(NSResponder.cancelOperation(_:)) {
        finish(field.stringValue, cancel: true, restoreTabFocus: true)
      } else { return false }
      return true
    }
  }
}
