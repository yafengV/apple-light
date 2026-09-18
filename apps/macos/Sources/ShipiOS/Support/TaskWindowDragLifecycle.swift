import AppKit
import SwiftUI

/// Observe Escape without consuming it; AppKit still cancels the system drag.
struct TaskWindowDragLifecycle: NSViewRepresentable {
  let tabs: TaskWindowTabs
  func makeCoordinator() -> Coordinator { Coordinator() }
  func makeNSView(context: Context) -> NSView {
    let view = NSView()
    context.coordinator.install(view: view, tabs: tabs)
    return view
  }
  func updateNSView(_ view: NSView, context: Context) { context.coordinator.tabs = tabs }
  static func dismantleNSView(_ view: NSView, coordinator: Coordinator) { coordinator.stop() }

  final class Coordinator {
    weak var tabs: TaskWindowTabs?
    private var monitor: Any?
    func install(view: NSView, tabs: TaskWindowTabs) {
      self.tabs = tabs
      monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self, weak view] event in
        MainActor.assumeIsolated {
          if event.keyCode == 53, let window = view?.window, window.isKeyWindow,
            event.window == nil || event.window === window {
            self?.tabs?.endDrag()
          }
          return event
        }
      }
    }
    func stop() {
      if let monitor { NSEvent.removeMonitor(monitor) }
      monitor = nil
      tabs = nil
    }
    deinit { stop() }
  }
}
