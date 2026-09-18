import AppKit

@MainActor
final class PointerCursorController {
  private var monitor: Any?

  func apply(_ enabled: Bool) {
    if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
    guard enabled else {
      NSCursor.arrow.set()
      return
    }
    for window in NSApp.windows { window.acceptsMouseMovedEvents = true }
    monitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .cursorUpdate]) {
      event in
      if Self.isInteractive(event.window?.contentView?.hitTest(event.locationInWindow)) {
        NSCursor.pointingHand.set()
      } else {
        NSCursor.arrow.set()
      }
      return event
    }
  }

  deinit {
    if let monitor { NSEvent.removeMonitor(monitor) }
  }

  private static func isInteractive(_ view: NSView?) -> Bool {
    var view = view
    while let current = view {
      if current is NSButton { return true }
      if let role = current.accessibilityRole(), role == .button || role == .link { return true }
      view = current.superview
    }
    return false
  }
}
