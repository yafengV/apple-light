import SwiftUI

struct BrowserAddressField: NSViewRepresentable {
  @Environment(\.isEnabled) private var isEnabled
  let tab: BrowserTab
  let session: BrowserSession
  let canFocus: () -> Bool
  func makeCoordinator() -> Coordinator { Coordinator(self) }
  func makeNSView(context: Context) -> NSTextField {
    let field = NSTextField()
    field.placeholderString = "网址或 localhost 地址"
    field.bezelStyle = .roundedBezel
    field.setAccessibilityLabel("浏览器地址")
    field.delegate = context.coordinator
    field.target = context.coordinator; field.action = #selector(Coordinator.submit(_:))
    session.addressField = field
    return field
  }
  func updateNSView(_ field: NSTextField, context: Context) {
    context.coordinator.parent = self
    field.isEnabled = isEnabled
    if field.stringValue != tab.address, field.currentEditor() == nil { field.stringValue = tab.address }
    let request = session.addressFocus
    if session.addressFocusTarget == tab.id, context.coordinator.handled != request {
      context.coordinator.handled = request
      DispatchQueue.main.async {
        guard isEnabled, canFocus(), field.window?.isKeyWindow == true, session.selection == tab.id, session.addressFocusTarget == tab.id,
          session.addressFocus == request, field.window?.attachedSheet == nil else { return }
        field.window?.makeFirstResponder(field)
        field.selectText(nil)
      }
    }
  }
  @MainActor final class Coordinator: NSObject, NSTextFieldDelegate {
    var parent: BrowserAddressField
    var handled: UUID?
    init(_ parent: BrowserAddressField) { self.parent = parent }
    func controlTextDidBeginEditing(_ notification: Notification) {
      parent.tab.editingAddress = true
      parent.session.addressField = notification.object as? NSTextField
      parent.session.select(parent.tab.id, focus: false)
    }
    func controlTextDidEndEditing(_ notification: Notification) { parent.tab.editingAddress = false }
    func controlTextDidChange(_ notification: Notification) {
      if let field = notification.object as? NSTextField { parent.tab.address = field.stringValue }
    }
    @objc func submit(_ field: NSTextField) {
      parent.tab.address = field.stringValue
      parent.tab.navigate()
      if parent.tab.error == nil { field.window?.makeFirstResponder(parent.tab.view) }
    }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
      guard commandSelector == #selector(NSResponder.cancelOperation(_:)) else { return false }
      parent.tab.restoreAddress()
      (control as? NSTextField)?.stringValue = parent.tab.address
      textView.string = parent.tab.address
      control.window?.makeFirstResponder(parent.tab.view)
      return true
    }
  }
}
