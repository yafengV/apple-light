import SwiftUI

/// Track real pointer movement, not SwiftUI hover notifications emitted while rows mount.
struct SearchResultPointerBridge: NSViewRepresentable {
  let enabled: Bool
  let select: () -> Void

  func makeNSView(context: Context) -> PointerView { PointerView() }
  func updateNSView(_ view: PointerView, context: Context) {
    view.enabled = enabled
    view.select = select
  }
  static func dismantleNSView(_ view: PointerView, coordinator: ()) { view.select = nil }

  final class PointerView: NSView {
    var enabled = false
    var select: (() -> Void)?
    private var tracking: NSTrackingArea?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func updateTrackingAreas() {
      super.updateTrackingAreas()
      if let tracking { removeTrackingArea(tracking) }
      let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect],
        owner: self, userInfo: nil)
      addTrackingArea(area)
      tracking = area
    }
    override func mouseMoved(with event: NSEvent) {
      guard event.type == .mouseMoved else { return }
      receiveMovement(in: event.window, locationInWindow: event.locationInWindow)
    }
    func receiveMovement(in eventWindow: NSWindow?, locationInWindow: NSPoint) {
      // On newer macOS, non-clipping views may report a visibleRect larger than bounds.
      let hitRegion = bounds.intersection(visibleRect)
      guard enabled, let window, window.isKeyWindow,
        eventWindow === window, window.attachedSheet == nil, !isHiddenOrHasHiddenAncestor,
        !hitRegion.isEmpty, hitRegion.contains(convert(locationInWindow, from: nil)) else { return }
      select?()
    }
  }
}

extension View {
  func searchResultPointer(enabled: Bool = true, select: @escaping () -> Void) -> some View {
    background(SearchResultPointerBridge(enabled: enabled, select: select).accessibilityHidden(true))
  }
}
