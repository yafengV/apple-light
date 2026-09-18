import AppKit
import SwiftUI

/// Owns only the native search editor so Find can focus and select the query
/// without selecting text in another settings control or another window.
struct SettingsSearchInput: NSViewRepresentable {
  @Binding var query: String
  let focusRequest: UUID
  let visible: Bool
  let onMove: (MoveCommandDirection) -> Void
  let onSubmit: () -> Void

  func makeCoordinator() -> Coordinator { Coordinator(self) }
  func makeNSView(context: Context) -> NSSearchField {
    let field = NSSearchField()
    field.placeholderString = "搜索设置…"
    field.setAccessibilityLabel("搜索设置")
    field.sendsSearchStringImmediately = true
    field.delegate = context.coordinator
    field.target = context.coordinator
    field.action = #selector(Coordinator.searchChanged(_:))
    return field
  }
  func updateNSView(_ field: NSSearchField, context: Context) {
    let coordinator = context.coordinator
    coordinator.parent = self
    if field.stringValue != query, (field.currentEditor() as? NSTextView)?.hasMarkedText() != true {
      field.stringValue = query
    }
    guard visible, coordinator.focusRequest != focusRequest else { return }
    coordinator.focusRequest = focusRequest
    DispatchQueue.main.async { [weak field, weak coordinator] in
      guard let field, let coordinator, coordinator.active, coordinator.parent.visible,
        coordinator.focusRequest == focusRequest,
        let window = field.window, window.isKeyWindow, window.attachedSheet == nil,
        NSApp.modalWindow == nil,
        (window.firstResponder as? NSTextView)?.hasMarkedText() != true else { return }
      window.makeFirstResponder(field)
      field.currentEditor()?.selectAll(nil)
    }
  }
  static func dismantleNSView(_ field: NSSearchField, coordinator: Coordinator) {
    field.delegate = nil
    field.target = nil
    coordinator.active = false
  }

  final class Coordinator: NSObject, NSSearchFieldDelegate {
    var parent: SettingsSearchInput
    var focusRequest: UUID?
    var active = true
    init(_ parent: SettingsSearchInput) { self.parent = parent }
    @objc func searchChanged(_ field: NSSearchField) {
      guard (field.currentEditor() as? NSTextView)?.hasMarkedText() != true else { return }
      parent.query = field.stringValue
    }
    func controlTextDidChange(_ notification: Notification) {
      guard let field = notification.object as? NSSearchField else { return }
      searchChanged(field)
    }
    func control(_ control: NSControl, textView: NSTextView,
      doCommandBy commandSelector: Selector) -> Bool {
      guard !textView.hasMarkedText() else { return false }
      switch commandSelector {
      case #selector(NSResponder.moveUp(_:)): parent.onMove(.up)
      case #selector(NSResponder.moveDown(_:)): parent.onMove(.down)
      case #selector(NSResponder.insertNewline(_:)): parent.onSubmit()
      case #selector(NSResponder.cancelOperation(_:)):
        parent.query = ""
        control.stringValue = ""
      default: return false
      }
      return true
    }
  }
}
