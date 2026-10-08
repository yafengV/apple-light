import SwiftUI

struct BrowserAddressField: NSViewRepresentable {
  @Environment(\.isEnabled) private var isEnabled
  let tab: BrowserTab
  let session: BrowserSession
  let canFocus: () -> Bool
  var independentFocus = false
  var onBeginEditing: () -> Void = {}
  var onEndEditing: () -> Void = {}
  var onChange: () -> Void = {}
  var onMoveSuggestion: (Int) -> Void = { _ in }
  var onSubmit: (String) -> Void = { _ in }
  var onCancel: () -> Void = {}
  func makeCoordinator() -> Coordinator { Coordinator(self) }
  func makeNSView(context: Context) -> NSTextField {
    let field = BrowserNativeAddressField()
    field.didAttach = { [weak field, weak coordinator = context.coordinator] in
      if let field { coordinator?.attached(field) }
    }
    field.placeholderString = "搜索或输入网址"
    field.bezelStyle = .roundedBezel
    field.setAccessibilityLabel("浏览器地址")
    field.delegate = context.coordinator
    field.target = context.coordinator; field.action = #selector(Coordinator.submit(_:))
    return field
  }
  func updateNSView(_ field: NSTextField, context: Context) {
    context.coordinator.parent = self
    field.isEnabled = isEnabled
    if field.stringValue != tab.address, field.currentEditor() == nil { field.stringValue = tab.address }
    context.coordinator.requestFocus(in: field)
  }
  static func dismantleNSView(_ field: NSTextField, coordinator: Coordinator) {
    coordinator.active = false
    (field as? BrowserNativeAddressField)?.didAttach = nil
    field.delegate = nil
  }
  @MainActor final class Coordinator: NSObject, NSTextFieldDelegate {
    var parent: BrowserAddressField
    var handled: UUID?
    var active = true
    init(_ parent: BrowserAddressField) { self.parent = parent }
    func attached(_ field: NSTextField) {
      guard active, field.window != nil else { return }
      if parent.independentFocus || parent.session.selection == parent.tab.id { parent.session.addressField = field }
      requestFocus(in: field)
    }
    func requestFocus(in field: NSTextField) {
      let request = parent.session.addressFocus
      guard active, parent.session.addressFocusTarget == parent.tab.id, handled != request else { return }
      DispatchQueue.main.async { [weak self, weak field] in
        guard let self, self.active, let field, self.handled != request,
          self.parent.isEnabled, self.parent.canFocus(), !self.parent.tab.closed,
          let window = field.window, window.isKeyWindow, window.attachedSheet == nil,
          !field.isHiddenOrHasHiddenAncestor,
          (self.parent.independentFocus || self.parent.session.selection == self.parent.tab.id),
          self.parent.session.addressFocusTarget == self.parent.tab.id,
          self.parent.session.addressFocus == request else { return }
        // A request remains pending while SwiftUI is still attaching the field.
        // Reattachment only retries requests that have never acquired focus.
        guard window.makeFirstResponder(field) else { return }
        self.handled = request
        field.selectText(nil)
      }
    }
    func controlTextDidBeginEditing(_ notification: Notification) {
      parent.tab.editingAddress = true
      parent.session.addressField = notification.object as? NSTextField
      if !parent.independentFocus { parent.session.select(parent.tab.id, focus: false) }
      parent.onBeginEditing()
    }
    func controlTextDidEndEditing(_ notification: Notification) {
      parent.tab.editingAddress = false
      parent.onEndEditing()
    }
    func controlTextDidChange(_ notification: Notification) {
      if let field = notification.object as? NSTextField {
        parent.tab.address = field.stringValue
        parent.onChange()
      }
    }
    @objc func submit(_ field: NSTextField) {
      parent.onSubmit(field.stringValue)
      if parent.tab.error == nil { field.window?.makeFirstResponder(parent.tab.view) }
    }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
      if commandSelector == #selector(NSResponder.moveDown(_:)) {
        parent.onMoveSuggestion(1)
        return true
      }
      if commandSelector == #selector(NSResponder.moveUp(_:)) {
        parent.onMoveSuggestion(-1)
        return true
      }
      guard commandSelector == #selector(NSResponder.cancelOperation(_:)) else { return false }
      parent.tab.restoreAddress()
      (control as? NSTextField)?.stringValue = parent.tab.address
      textView.string = parent.tab.address
      parent.onCancel()
      control.window?.makeFirstResponder(parent.tab.view)
      return true
    }
  }
}

@MainActor final class BrowserNativeAddressField: NSTextField {
  var didAttach: (() -> Void)?
  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    if window != nil { didAttach?() }
  }
}
