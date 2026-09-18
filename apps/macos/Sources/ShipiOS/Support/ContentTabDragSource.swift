import AppKit
import SwiftUI

/// SwiftUI owns the tab and its drop destinations. AppKit owns the pointer drag
/// so cleanup happens after the system session, not before an asynchronous drop.
struct ContentTabDragSource: NSViewRepresentable {
  let title: String
  let token: String
  let select: () -> Void
  let begin: () -> UUID?
  let end: (UUID) -> Void

  func makeNSView(context: Context) -> SourceView { SourceView() }
  func updateNSView(_ view: SourceView, context: Context) {
    view.title = title
    view.token = token
    view.select = select
    view.begin = begin
    view.end = end
    view.setAccessibilityElement(false)
  }
  static func dismantleNSView(_ view: SourceView, coordinator: ()) {
    view.pointerDown = nil
    // AppKit may still be completing a drop after SwiftUI has moved the tab.
    // The in-flight session retains its own completion until endedAt arrives.
    view.select = nil
    view.begin = nil
    view.end = nil
  }

  final class SourceView: NSView, NSDraggingSource {
    var title = ""
    var token = ""
    var select: (() -> Void)?
    var begin: (() -> UUID?)?
    var end: ((UUID) -> Void)?
    var pointerDown: NSPoint?
    private(set) var completion: TabDragCompletion?

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? {
      // Leave secondary clicks, scrolling and accessibility on the SwiftUI
      // button/context menu. Only the title's left-pointer gesture is bridged.
      guard let event = NSApp.currentEvent,
        [.leftMouseDown, .leftMouseDragged, .leftMouseUp].contains(event.type)
      else { return nil }
      return super.hitTest(point)
    }
    override func mouseDown(with event: NSEvent) {
      guard completion == nil else { return }
      pointerDown = event.locationInWindow
    }
    override func mouseUp(with event: NSEvent) {
      defer { pointerDown = nil }
      guard completion == nil, pointerDown != nil,
        bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
      select?()
    }
    override func mouseDragged(with event: NSEvent) {
      guard completion == nil, let origin = pointerDown,
        Self.crossedDragThreshold(from: origin, to: event.locationInWindow),
        !token.isEmpty, let sessionID = begin?(), let end else { return }
      pointerDown = nil
      completion = TabDragCompletion(id: sessionID, end: end)
      let item = NSDraggingItem(pasteboardWriter: token as NSString)
      item.setDraggingFrame(bounds, contents: preview())
      let session = beginDraggingSession(with: [item], event: event, source: self)
      session.animatesToStartingPositionsOnCancelOrFail = true
    }
    static func crossedDragThreshold(from origin: NSPoint, to point: NSPoint) -> Bool {
      hypot(point.x - origin.x, point.y - origin.y) >= 4
    }
    func draggingSession(_ session: NSDraggingSession,
      sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
      context == .withinApplication ? [.copy, .move] : []
    }
    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint,
      operation: NSDragOperation) {
      let finished = completion
      completion = nil
      pointerDown = nil
      finished?.finish()
    }
    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }

    private func preview() -> NSImage {
      let size = NSSize(width: max(24, bounds.width), height: max(24, bounds.height))
      return NSImage(size: size, flipped: false) { [title] rect in
        NSColor.windowBackgroundColor.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        (title as NSString).draw(in: rect.insetBy(dx: 5, dy: 4), withAttributes: [
          .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
          .foregroundColor: NSColor.labelColor, .paragraphStyle: style,
        ])
        return true
      }
    }
  }
}

/// Snapshot the source callback: moving/remounting a tab must not retarget an
/// already-running session's completion to a newer source or model.
@MainActor final class TabDragCompletion {
  let id: UUID
  private var end: ((UUID) -> Void)?
  init(id: UUID, end: @escaping (UUID) -> Void) { self.id = id; self.end = end }
  func finish() {
    let action = end
    end = nil
    action?(id)
  }
}
