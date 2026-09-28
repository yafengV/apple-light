import SwiftUI

/// Owns only modal commands. Native text editing, composition, selection and Tab stay in AppKit.
struct PullRequestKeyboardBridge: NSViewRepresentable {
  enum Key: Equatable { case cancel, activate, move(Int) }
  let action: (Key) -> Void

  static func key(for event: NSEvent, markedText: Bool, multilineText: Bool) -> Key? {
    guard !markedText else { return nil }
    let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
    if flags == .command {
      if event.charactersIgnoringModifiers == "w" { return .cancel }
      if event.keyCode == 36 || event.keyCode == 76 { return .activate }
    }
    guard flags.isEmpty else { return nil }
    if event.keyCode == 53 { return .cancel }
    guard !multilineText else { return nil }
    switch event.keyCode {
    case 36, 76: return .activate
    case 125: return .move(1)
    case 126: return .move(-1)
    default: return nil
    }
  }
  func makeCoordinator() -> Coordinator { Coordinator(action: action) }
  func makeNSView(context: Context) -> NSView {
    let view = NSView()
    context.coordinator.install(view)
    return view
  }
  func updateNSView(_ view: NSView, context: Context) { context.coordinator.action = action }
  static func dismantleNSView(_ view: NSView, coordinator: Coordinator) { coordinator.stop() }

  final class Coordinator {
    var action: (Key) -> Void
    private var monitor: Any?
    init(action: @escaping (Key) -> Void) { self.action = action }
    func install(_ view: NSView) {
      monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self, weak view] event in
        let handled = MainActor.assumeIsolated {
          guard let self, let window = view?.window, window.isKeyWindow,
            event.window === window, window.attachedSheet == nil else { return false }
          let text = window.firstResponder as? NSTextView
          guard let key = PullRequestKeyboardBridge.key(for: event,
            markedText: text?.hasMarkedText() == true,
            multilineText: text != nil && text?.isFieldEditor == false) else { return false }
          self.action(key)
          return true
        }
        return handled ? nil : event
      }
    }
    func stop() { if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil }
    deinit { stop() }
  }
}
