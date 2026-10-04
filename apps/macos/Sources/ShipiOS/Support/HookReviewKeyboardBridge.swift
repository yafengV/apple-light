import AppKit
import SwiftUI

/// Dynamic review controls need both Tab directions, while text selection,
/// copying, and marked text retain the native responder behavior.
struct HookReviewKeyboardBridge: NSViewRepresentable {
  enum Key: Equatable { case cancel, activate, next, previous }
  let ready: () -> Void
  let action: (Key) -> Void
  static func key(_ event: NSEvent) -> Key? {
    let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
    if flags == .command, event.charactersIgnoringModifiers == "w" { return .cancel }
    if event.keyCode == 53, flags.isEmpty { return .cancel }
    if event.keyCode == 48 { return flags.isEmpty ? .next : flags == .shift ? .previous : nil }
    if [36, 49, 76].contains(event.keyCode), flags.isEmpty { return .activate }
    return nil
  }
  func makeCoordinator() -> Coordinator { Coordinator(self) }
  func makeNSView(context: Context) -> NSView {
    let view = NSView(); context.coordinator.install(view); return view
  }
  func updateNSView(_ view: NSView, context: Context) { context.coordinator.parent = self }
  static func dismantleNSView(_ view: NSView, coordinator: Coordinator) { coordinator.stop() }
  final class Coordinator {
    var parent: HookReviewKeyboardBridge
    private var monitor: Any?
    init(_ parent: HookReviewKeyboardBridge) { self.parent = parent }
    func install(_ anchor: NSView) {
      DispatchQueue.main.async { [weak self, weak anchor] in
        guard let self, let window = anchor?.window, self.monitor != nil else { return }
        window.makeFirstResponder(nil); self.parent.ready()
      }
      monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self, weak anchor] event in
        let handled = MainActor.assumeIsolated {
          guard let self, let window = anchor?.window, event.window === window,
            window.isKeyWindow, window.attachedSheet == nil,
            (window.firstResponder as? NSTextView)?.hasMarkedText() != true,
            let key = HookReviewKeyboardBridge.key(event) else { return false }
          // Space and Return in selectable text retain their native behavior.
          if key == .activate, window.firstResponder is NSTextView { return false }
          self.parent.action(key); return true
        }
        return handled ? nil : event
      }
    }
    func stop() { if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil }
    deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
  }
}
