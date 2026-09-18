import SwiftUI

struct SearchDialogKeyboardBridge: NSViewRepresentable {
  enum Key: Equatable { case cancel, submit, move(Int), tab(reverse: Bool), taskSlot(Int) }
  let onReady: () -> Void
  let action: (Key) -> Void
  var shortcuts: ShortcutPreferences? = nil

  static func key(for event: NSEvent, markedText: Bool, shortcuts: ShortcutPreferences? = nil) -> Key? {
    guard !markedText else { return nil }
    if let shortcuts, let binding = ShortcutBinding(event: event),
      let slot = TaskSearchPresentation.shortcutSlot(binding, preferences: shortcuts) { return .taskSlot(slot) }
    let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
    if flags == .command, event.charactersIgnoringModifiers == "w" { return .cancel }
    if event.keyCode == 48, flags.isEmpty || flags == .shift { return .tab(reverse: flags == .shift) }
    guard flags.isEmpty else { return nil }
    if event.keyCode == 125 { return .move(1) }
    if event.keyCode == 126 { return .move(-1) }
    if event.keyCode == 53 { return .cancel }
    if event.keyCode == 36 || event.keyCode == 76 { return .submit }
    return nil
  }
  func makeCoordinator() -> Coordinator { Coordinator(onReady: onReady, action: action, shortcuts: shortcuts) }
  func makeNSView(context: Context) -> Anchor {
    let view = Anchor()
    view.coordinator = context.coordinator
    context.coordinator.install(view)
    return view
  }
  func updateNSView(_ view: Anchor, context: Context) {
    context.coordinator.onReady = onReady
    context.coordinator.action = action
    context.coordinator.shortcuts = shortcuts
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
    var shortcuts: ShortcutPreferences?
    private var monitor: Any?
    init(onReady: @escaping () -> Void, action: @escaping (Key) -> Void, shortcuts: ShortcutPreferences?) {
      self.onReady = onReady; self.action = action; self.shortcuts = shortcuts
    }
    func capture(_ window: NSWindow) {
      window.makeFirstResponder(nil)
      DispatchQueue.main.async { [weak self, weak window] in
        guard let self, let window, window.isKeyWindow, self.monitor != nil else { return }
        self.onReady()
      }
    }
    func install(_ view: NSView) {
      monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self, weak view] event in
        MainActor.assumeIsolated {
          guard let self, let window = view?.window, window.isKeyWindow, event.window === window,
            window.attachedSheet == nil,
            let key = SearchDialogKeyboardBridge.key(for: event,
              markedText: (window.firstResponder as? NSTextView)?.hasMarkedText() == true,
              shortcuts: self.shortcuts) else { return event }
          self.action(key)
          return nil
        }
      }
    }
    func stop() { if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil }
    deinit { stop() }
  }
}
