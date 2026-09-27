import AppKit
import SwiftUI

/// A browser-local key equivalent takes priority over the chat's Stop command.
struct BrowserCommentModeKeyboardBridge: NSViewRepresentable {
  let tab: BrowserTab?
  let session: BrowserSession
  let canFocus: () -> Bool

  func makeCoordinator() -> Coordinator { Coordinator() }
  func makeNSView(context: Context) -> NSView {
    let view = NSView()
    context.coordinator.install(view)
    return view
  }
  func updateNSView(_ view: NSView, context: Context) {
    context.coordinator.handle = { [weak tab, weak session] in
      guard canFocus(), let tab, let session, tab.canToggleCommentMode,
        session.hasNativeFocus(tabID: tab.id) else { return false }
      tab.toggleCommentMode()
      return true
    }
  }
  static func dismantleNSView(_ view: NSView, coordinator: Coordinator) { coordinator.stop() }

  final class Coordinator {
    var handle: (() -> Bool)?
    private var monitor: Any?
    func install(_ view: NSView) {
      monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self, weak view] event in
        MainActor.assumeIsolated {
          guard let window = view?.window, window.isKeyWindow, event.window === window,
            window.attachedSheet == nil, NSApp.modalWindow == nil,
            ShortcutBinding(event: event) == ShortcutBinding("⌘.") else { return event }
          return self?.handle?() == true ? nil : event
        }
      }
    }
    func stop() {
      if let monitor { NSEvent.removeMonitor(monitor) }
      monitor = nil
      handle = nil
    }
    deinit { stop() }
  }
}
