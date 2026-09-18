import SwiftUI

/// Scope keyboard handling to this window; the owning page restores its trigger.
/// Tab cycles the two dialog actions even when full keyboard access is disabled.
struct ModalKeyboardBridge: NSViewRepresentable {
  enum Key: Equatable { case cancel, activate, next }
  let onReady: () -> Void
  let action: (Key) -> Void
  static func key(for event: NSEvent) -> Key? {
    let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
      .subtracting([.capsLock, .numericPad, .function])
    if flags == .command, event.charactersIgnoringModifiers == "w" { return .cancel }
    guard flags.isEmpty || flags == .shift else { return nil }
    switch event.keyCode {
    case 53: return .cancel
    case 36, 49, 76: return .activate
    case 48: return .next
    default: return nil
    }
  }

  func makeCoordinator() -> Coordinator { Coordinator(onReady: onReady, action: action) }
  func makeNSView(context: Context) -> Anchor {
    let view = Anchor()
    view.coordinator = context.coordinator
    context.coordinator.install(view)
    return view
  }
  func updateNSView(_ view: Anchor, context: Context) {
    context.coordinator.onReady = onReady
    context.coordinator.action = action
  }
  static func dismantleNSView(_ view: Anchor, coordinator: Coordinator) { coordinator.stop() }

  final class Anchor: NSView {
    weak var coordinator: Coordinator?
    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      if let window { coordinator?.capture(window) }
    }
  }
  final class Coordinator {
    var onReady: () -> Void
    var action: (Key) -> Void
    private var monitor: Any?
    private weak var window: NSWindow?
    init(onReady: @escaping () -> Void, action: @escaping (Key) -> Void) {
      self.onReady = onReady
      self.action = action
    }
    func capture(_ window: NSWindow) {
      guard self.window == nil else { return }
      self.window = window
      window.makeFirstResponder(nil)
      // SwiftUI's onAppear can focus a button before this native anchor has
      // captured the responder. Hand focus back only after capture completes.
      DispatchQueue.main.async { [weak self, weak window] in
        guard let self, let window, self.window === window, self.monitor != nil else { return }
        self.onReady()
      }
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
      window = nil
    }
    deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
  }
}
