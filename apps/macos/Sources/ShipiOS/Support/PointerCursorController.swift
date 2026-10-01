import AppKit
import SwiftTerm
import WebKit

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
    monitor = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { event in
      guard let window = event.window else { return event }
      let location = window.contentView?.convert(event.locationInWindow, from: nil) ?? event.locationInWindow
      if let cursor = Self.cursorOverride(for: window.contentView?.hitTest(location)) {
        cursor.set()
      }
      return event
    }
  }

  deinit {
    if let monitor { NSEvent.removeMonitor(monitor) }
  }

  /// `nil` leaves AppKit's cursor rectangles in charge of text, resizing, and panning.
  static func cursorOverride(for view: NSView?) -> NSCursor? {
    var ancestor = view
    while let current = ancestor {
      if current is NSTextView || current is NSTextField
        || current is PanelResizeHandle.ResizeView || current is ImagePreviewCanvas.Picture
        || current is WKWebView || current is TerminalView {
        return nil
      }
      ancestor = current.superview
    }
    ancestor = view
    var interactive = false
    while let current = ancestor {
      if let control = current as? NSControl, !control.isEnabled { return .arrow }
      if current is NSButton { interactive = true }
      if let role = current.accessibilityRole(), role == .button || role == .link { interactive = true }
      ancestor = current.superview
    }
    return interactive ? .pointingHand : .arrow
  }
}
