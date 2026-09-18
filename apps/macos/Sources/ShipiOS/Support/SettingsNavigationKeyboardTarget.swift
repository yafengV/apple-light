import AppKit
import SwiftUI

/// Keeps arrow navigation in the sidebar without making a hidden text editor
/// the window's first responder. Form controls retain their own keyboard input.
struct SettingsNavigationKeyboardTarget: NSViewRepresentable {
  let request: UUID?
  let visible: Bool
  let onMove: (MoveCommandDirection) -> Void
  @Environment(\.isEnabled) private var isEnabled

  func makeNSView(context: Context) -> TargetView {
    let view = TargetView()
    view.setAccessibilityHidden(true)
    return view
  }

  func updateNSView(_ view: TargetView, context: Context) {
    view.onMove = onMove
    view.available = visible && isEnabled
    guard view.request != request else { return }
    view.request = request
    guard let request else { return }
    DispatchQueue.main.async { [weak view] in
      guard let view, view.available, view.request == request,
        let window = view.window, window.isKeyWindow,
        window.attachedSheet == nil, NSApp.modalWindow == nil else { return }
      window.makeFirstResponder(view)
    }
  }

  static func dismantleNSView(_ view: TargetView, coordinator: ()) {
    view.available = false
    view.request = nil
  }

  final class TargetView: NSView {
    var available = false
    var request: UUID?
    var onMove: ((MoveCommandDirection) -> Void)?
    override var acceptsFirstResponder: Bool { available }

    @discardableResult func handle(_ event: NSEvent) -> Bool {
      guard available,
        event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty else { return false }
      switch event.keyCode {
      case 125: onMove?(.down)
      case 126: onMove?(.up)
      default: return false
      }
      return true
    }

    override func keyDown(with event: NSEvent) {
      if handle(event) { return }
      if available, event.keyCode == 48,
        event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
        if event.modifierFlags.contains(.shift) { window?.selectPreviousKeyView(self) }
        else { window?.selectNextKeyView(self) }
        return
      }
      super.keyDown(with: event)
    }
  }
}
