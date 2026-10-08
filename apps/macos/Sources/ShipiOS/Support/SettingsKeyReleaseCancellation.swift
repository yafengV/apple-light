import AppKit
import SwiftUI

/// A retained SwiftUI focus target can survive window deactivation. Cancel a
/// pending release action at that boundary without moving or replacing focus.
struct SettingsKeyReleaseCancellation: NSViewRepresentable {
  let cancel: () -> Void
  func makeNSView(context: Context) -> Anchor {
    let view = Anchor(); view.cancel = cancel
    view.setAccessibilityElement(false)
    return view
  }
  func updateNSView(_ view: Anchor, context: Context) { view.cancel = cancel }
  static func dismantleNSView(_ view: Anchor, coordinator: ()) { view.stopObserving(); view.cancel = nil }

  final class Anchor: NSView {
    var cancel: (() -> Void)?
    private var observers: [NSObjectProtocol] = []
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow(); stopObserving()
      guard let window else { return }
      for name in [NSWindow.didResignKeyNotification, NSWindow.willCloseNotification] {
        observe(name, object: window)
      }
      observe(NSApplication.didResignActiveNotification, object: NSApp)
    }
    private func observe(_ name: Notification.Name, object: AnyObject?) {
      observers.append(NotificationCenter.default.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
        MainActor.assumeIsolated { guard let self, self.window != nil else { return }; self.cancel?() }
      })
    }
    func stopObserving() {
      observers.forEach(NotificationCenter.default.removeObserver); observers.removeAll()
    }
    deinit { observers.forEach(NotificationCenter.default.removeObserver) }
  }
}
