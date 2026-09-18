import AppKit
import SwiftUI

/// Observe Escape without consuming it; AppKit still cancels the system drag.
struct TabDragEscapeObserver: NSViewRepresentable {
  let cancel: () -> Void
  func makeCoordinator() -> Coordinator { Coordinator() }
  func makeNSView(context: Context) -> NSView {
    let view = NSView()
    context.coordinator.install(view: view, cancel: cancel)
    return view
  }
  func updateNSView(_ view: NSView, context: Context) { context.coordinator.cancel = cancel }
  static func dismantleNSView(_ view: NSView, coordinator: Coordinator) { coordinator.stop() }

  final class Coordinator {
    var cancel: (() -> Void)?
    private var monitor: Any?
    func install(view: NSView, cancel: @escaping () -> Void) {
      self.cancel = cancel
      monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self, weak view] event in
        MainActor.assumeIsolated {
          if event.keyCode == 53, let window = view?.window, window.isKeyWindow,
            event.window == nil || event.window === window {
            self?.cancel?()
          }
          return event
        }
      }
    }
    func stop() {
      if let monitor { NSEvent.removeMonitor(monitor) }
      monitor = nil
      cancel = nil
    }
    deinit { stop() }
  }
}

/// Runs only while a system mouse drag is active; long drags have no time limit.
private struct TabDragLifecycle: ViewModifier {
  let session: UUID?
  let end: (UUID) -> Void

  func body(content: Content) -> some View {
    content
      .background(TabDragEscapeObserver(cancel: { if let session { end(session) } }).frame(width: 0, height: 0))
      .task(id: session) {
        guard let session else { return }
        while !Task.isCancelled, NSEvent.pressedMouseButtons & 1 != 0 {
          try? await Task.sleep(for: .milliseconds(50))
        }
        if !Task.isCancelled { end(session) }
      }
      .onDisappear { if let session { end(session) } }
  }
}

extension View {
  func tabDragLifecycle(session: UUID?, end: @escaping (UUID) -> Void) -> some View {
    modifier(TabDragLifecycle(session: session, end: end))
  }
}
