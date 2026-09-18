import SwiftUI

private struct ImagePreviewActiveKey: FocusedValueKey { typealias Value = Bool }
extension FocusedValues {
  var imagePreviewActive: Bool? {
    get { self[ImagePreviewActiveKey.self] }
    set { self[ImagePreviewActiveKey.self] = newValue }
  }
}

struct ImagePreviewKeyboardBridge: NSViewRepresentable {
  enum Key: Equatable { case close, previous, next, zoomIn, zoomOut, fit, tab(Bool), activate }
  let onReady: () -> Void
  let action: (Key) -> Bool
  static func key(for event: NSEvent) -> Key? {
    let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
    if modifiers == .command || modifiers == [.command, .shift] {
      switch event.charactersIgnoringModifiers?.lowercased() {
      case "w" where modifiers == .command: return .close
      case "+", "=": return .zoomIn
      case "-" where modifiers == .command: return .zoomOut
      case "0" where modifiers == .command: return .fit
      default: return nil
      }
    }
    if event.keyCode == 48, modifiers.isEmpty || modifiers == .shift { return .tab(modifiers == .shift) }
    guard modifiers.isEmpty else { return nil }
    switch event.keyCode {
    case 53: return .close
    case 123: return .previous
    case 124: return .next
    case 36, 49, 76: return .activate
    default: return nil
    }
  }
  func makeCoordinator() -> Coordinator { Coordinator() }
  func makeNSView(context: Context) -> NSView {
    let view = NSView()
    context.coordinator.install(view)
    return view
  }
  func updateNSView(_ view: NSView, context: Context) {
    context.coordinator.action = action
    if !context.coordinator.ready {
      context.coordinator.ready = true
      DispatchQueue.main.async { [weak view, weak coordinator = context.coordinator] in
        guard let view, let window = view.window, coordinator?.active == true else { return }
        window.makeFirstResponder(nil)
        onReady()
      }
    }
  }
  static func dismantleNSView(_ view: NSView, coordinator: Coordinator) { coordinator.stop() }
  final class Coordinator {
    var action: ((Key) -> Bool)?
    var active = true
    var ready = false
    private var monitor: Any?
    func install(_ view: NSView) {
      monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self, weak view] event in
        MainActor.assumeIsolated {
          guard let self, self.active, let window = view?.window, window.isKeyWindow,
            event.window === window, window.attachedSheet == nil,
            let key = ImagePreviewKeyboardBridge.key(for: event), self.action?(key) == true else { return event }
          return nil
        }
      }
    }
    func stop() {
      active = false
      action = nil
      if let monitor { NSEvent.removeMonitor(monitor) }
      monitor = nil
    }
    deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
  }
}
