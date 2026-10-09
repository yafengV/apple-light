import AppKit
import SwiftUI

/// Preserve SwiftUI's window delegate while adding a synchronous durability gate.
struct FileRecoveryWindowCloseGuard: NSViewRepresentable {
  let prepare: () -> Bool
  var didClose: () -> Void = {}

  func makeNSView(context: Context) -> Attachment { Attachment(prepare: prepare, didClose: didClose) }
  func updateNSView(_ view: Attachment, context: Context) {
    view.proxy.prepare = prepare; view.proxy.didClose = didClose
    view.attach()
  }
  static func dismantleNSView(_ view: Attachment, coordinator: ()) { view.detach() }

  final class Attachment: NSView {
    let proxy: Delegate
    private weak var attachedWindow: NSWindow?
    init(prepare: @escaping () -> Bool, didClose: @escaping () -> Void) {
      proxy = Delegate(prepare: prepare, didClose: didClose)
      super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); attach() }
    func attach() {
      if attachedWindow !== window { detach(); attachedWindow = window }
      guard let window, window.delegate !== proxy else { return }
      proxy.original = window.delegate
      window.delegate = proxy
    }
    func detach() {
      if let attachedWindow, attachedWindow.delegate === proxy { attachedWindow.delegate = proxy.original }
      attachedWindow = nil; proxy.original = nil
    }
  }

  final class Delegate: NSObject, NSWindowDelegate {
    weak var original: NSWindowDelegate?
    var prepare: () -> Bool
    var didClose: () -> Void
    init(prepare: @escaping () -> Bool, didClose: @escaping () -> Void) {
      self.prepare = prepare; self.didClose = didClose
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
      guard original?.windowShouldClose?(sender) != false else { return false }
      return prepare()
    }
    func windowWillClose(_ notification: Notification) {
      // NSWindow.close() bypasses windowShouldClose. Retain failed drafts in the
      // store before forced teardown, so a later close/quit can retry persistence.
      _ = prepare()
      didClose()
      original?.windowWillClose?(notification)
    }
    override func responds(to selector: Selector!) -> Bool {
      super.responds(to: selector) || original?.responds(to: selector) == true
    }
    override func forwardingTarget(for selector: Selector!) -> Any? {
      if original?.responds(to: selector) == true { return original }
      return super.forwardingTarget(for: selector)
    }
  }
}
