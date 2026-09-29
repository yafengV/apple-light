import AppKit
import SwiftUI

/// Native activation preserves the triggering event's modifiers and focus even
/// when the file header is pinned. SwiftUI owns the layout and expansion state.
struct PullRequestCodeHeaderButton: NSViewRepresentable {
  let identifier: String
  let label: String
  var value = ""
  var symbol: String? = nil
  let activate: (NSEvent.ModifierFlags) -> Void
  let focused: (Bool) -> Void
  func makeNSView(context: Context) -> PullRequestCodeHeaderButtonView { PullRequestCodeHeaderButtonView() }
  func updateNSView(_ view: PullRequestCodeHeaderButtonView, context: Context) {
    view.identifier = NSUserInterfaceItemIdentifier(identifier)
    view.setAccessibilityIdentifier(identifier); view.setAccessibilityLabel(label); view.setAccessibilityValue(value)
    view.toolTip = label; view.image = symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: label) }
    view.isTransparent = symbol == nil
    view.activate = activate; view.focused = focused
  }
  static func dismantleNSView(_ view: PullRequestCodeHeaderButtonView, coordinator: ()) {
    view.activate = nil; view.focused = nil
  }
}

@MainActor final class PullRequestCodeHeaderButtonView: NSButton {
  var activate: ((NSEvent.ModifierFlags) -> Void)?
  var focused: ((Bool) -> Void)?
  private var activationFlags: NSEvent.ModifierFlags = []
  override var acceptsFirstResponder: Bool { true }
  override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric) }
  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    title = ""; isBordered = false; bezelStyle = .smallSquare; imagePosition = .imageOnly
    focusRingType = .exterior; target = self; action = #selector(pressed)
    setAccessibilityRole(.button)
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
  @objc private func pressed() { activate?(activationFlags) }
  override func accessibilityPerformPress() -> Bool {
    guard isEnabled, let activate else { return false }
    activate([]); return true
  }
  override func mouseDown(with event: NSEvent) {
    activationFlags = event.modifierFlags
    defer { activationFlags = [] }
    super.mouseDown(with: event)
  }
  override func keyDown(with event: NSEvent) {
    guard isEnabled else { return }
    if [36, 76, 49].contains(event.keyCode) { activate?(event.modifierFlags); return }
    if event.keyCode == 48 {
      if event.modifierFlags.contains(.shift) { window?.selectPreviousKeyView(self) }
      else { window?.selectNextKeyView(self) }
      return
    }
    super.keyDown(with: event)
  }
  override func becomeFirstResponder() -> Bool {
    let result = super.becomeFirstResponder(); if result { focused?(true) }; return result
  }
  override func resignFirstResponder() -> Bool {
    let result = super.resignFirstResponder(); if result { focused?(false) }; return result
  }
}
