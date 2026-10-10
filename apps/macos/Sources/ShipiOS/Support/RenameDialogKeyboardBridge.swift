import SwiftUI

struct RenameDialogKeyboardBridge: NSViewRepresentable {
  enum Key: Equatable { case cancel, submit, tab(reverse: Bool) }
  let onReady: () -> Void
  let action: (Key) -> Void

  static func key(for event: NSEvent, markedText: Bool) -> Key? {
    guard !markedText else { return nil }
    let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
    if flags == .command, event.charactersIgnoringModifiers == "w" { return .cancel }
    if event.keyCode == 48, flags.isEmpty || flags == .shift { return .tab(reverse: flags == .shift) }
    guard flags.isEmpty else { return nil }
    if event.keyCode == 53 { return .cancel }
    if event.keyCode == 36 || event.keyCode == 76 { return .submit }
    return nil
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
    private weak var anchor: NSView?
    private weak var pendingWindow: NSWindow?
    private var needsInitialFocus = false
    private var keyObserver: NSObjectProtocol?
    init(onReady: @escaping () -> Void, action: @escaping (Key) -> Void) {
      self.onReady = onReady; self.action = action
    }
    func capture(_ window: NSWindow) {
      guard pendingWindow !== window else { return }
      removeKeyObserver()
      pendingWindow = window
      needsInitialFocus = true
      keyObserver = NotificationCenter.default.addObserver(
        forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main
      ) { [weak self, weak window] _ in
        MainActor.assumeIsolated {
          if let window { self?.focusWhenReady(in: window) }
        }
      }
      focusWhenReady(in: window)
    }
    private func focusWhenReady(in window: NSWindow) {
      DispatchQueue.main.async { [weak self, weak window] in
        guard let self, let window, window.isKeyWindow, self.monitor != nil,
          self.needsInitialFocus, self.pendingWindow === window,
          self.anchor?.window === window else { return }
        self.needsInitialFocus = false
        self.removeKeyObserver()
        window.makeFirstResponder(nil)
        self.onReady()
        DispatchQueue.main.async { [weak self, weak window] in
          guard self?.monitor != nil, let window, window.isKeyWindow,
            let editor = window.firstResponder as? NSTextView, editor.isFieldEditor else { return }
          editor.selectAll(nil)
        }
      }
    }
    func install(_ view: NSView) {
      anchor = view
      monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self, weak view] event in
        MainActor.assumeIsolated {
          guard let self, let window = view?.window, window.isKeyWindow, event.window === window,
            window.attachedSheet == nil,
            let key = RenameDialogKeyboardBridge.key(for: event,
              markedText: (window.firstResponder as? NSTextView)?.hasMarkedText() == true) else { return event }
          self.action(key)
          return nil
        }
      }
    }
    private func removeKeyObserver() {
      if let keyObserver { NotificationCenter.default.removeObserver(keyObserver) }
      keyObserver = nil
    }
    func stop() {
      removeKeyObserver()
      needsInitialFocus = false
      pendingWindow = nil
      anchor = nil
      if let monitor { NSEvent.removeMonitor(monitor) }
      monitor = nil
    }
    deinit { stop() }
  }
}
