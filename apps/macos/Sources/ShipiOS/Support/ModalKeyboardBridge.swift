import SwiftUI

/// Scope keyboard handling to this window and restore its previous responder.
/// Tab cycles the two dialog actions even when full keyboard access is disabled.
struct ModalKeyboardBridge: NSViewRepresentable {
  enum Key: Equatable { case cancel, activate, next }
  let action: (Key) -> Void
  static func key(for event: NSEvent) -> Key? {
    let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
      .subtracting([.capsLock, .numericPad, .function])
    if flags == .command, event.charactersIgnoringModifiers == "w" { return .cancel }
    guard flags.isEmpty || flags == .shift else { return nil }
    switch event.keyCode {
    case 53: return .cancel
    case 36, 76: return .activate
    case 48: return .next
    default: return nil
    }
  }

  func makeCoordinator() -> Coordinator { Coordinator(action: action) }
  func makeNSView(context: Context) -> Anchor {
    let view = Anchor()
    view.coordinator = context.coordinator
    context.coordinator.install(view)
    return view
  }
  func updateNSView(_ view: Anchor, context: Context) { context.coordinator.action = action }
  static func dismantleNSView(_ view: Anchor, coordinator: Coordinator) { coordinator.stop() }

  final class Anchor: NSView {
    weak var coordinator: Coordinator?
    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      if let window { coordinator?.capture(window) }
    }
  }
  final class Coordinator {
    var action: (Key) -> Void
    private var monitor: Any?
    private weak var window: NSWindow?
    private weak var previousResponder: NSResponder?
    init(action: @escaping (Key) -> Void) { self.action = action }
    func capture(_ window: NSWindow) {
      guard self.window == nil else { return }
      self.window = window
      previousResponder = window.firstResponder
      window.makeFirstResponder(nil)
    }
    func install(_ view: NSView) {
      monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self, weak view] event in
        let handled = MainActor.assumeIsolated {
          guard let self, let window = view?.window, window.isKeyWindow,
            event.window === window, window.attachedSheet == nil,
            let key = ModalKeyboardBridge.key(for: event) else { return false }
          self.action(key)
          return true
        }
        return handled ? nil : event
      }
    }
    func stop() {
      if let monitor { NSEvent.removeMonitor(monitor) }
      monitor = nil
      if let window, let previousResponder,
        (previousResponder as? NSView).map({ $0.window === window }) ?? true {
        window.makeFirstResponder(previousResponder)
      }
      window = nil
      previousResponder = nil
    }
    deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
  }
}
