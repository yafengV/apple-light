import AppKit
import SwiftUI

/// A temporary surface above embedded WebKit/terminal views while a tab is
/// being dragged. Only validated internal tokens can claim the drop.
struct ContentTabDropSurface: NSViewRepresentable {
  let accepts: (String) -> Bool
  let drop: (String) -> Bool
  let targeted: (Bool) -> Void
  func makeNSView(context: Context) -> DropView {
    let view = DropView()
    view.registerForDraggedTypes([.string])
    view.setAccessibilityElement(false)
    return view
  }
  func updateNSView(_ view: DropView, context: Context) {
    view.accepts = accepts
    view.drop = drop
    view.targeted = targeted
  }
  static func dismantleNSView(_ view: DropView, coordinator: ()) {
    view.unregisterDraggedTypes()
    view.accepts = nil
    view.drop = nil
    view.targeted = nil
  }
  final class DropView: NSView {
    var accepts: ((String) -> Bool)?
    var drop: ((String) -> Bool)?
    var targeted: ((Bool) -> Void)?
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { update(sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { update(sender) }
    override func draggingExited(_ sender: NSDraggingInfo?) { targeted?(false) }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { token(sender) != nil }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
      performDrop(from: sender.draggingPasteboard, sourceOperations: sender.draggingSourceOperationMask)
    }
    func performDrop(from pasteboard: NSPasteboard, sourceOperations: NSDragOperation) -> Bool {
      guard let token = acceptedToken(from: pasteboard, sourceOperations: sourceOperations) else {
        targeted?(false)
        return false
      }
      let perform = drop
      targeted?(false)
      return perform?(token) ?? false
    }
    private func update(_ sender: NSDraggingInfo) -> NSDragOperation {
      let valid = token(sender) != nil
      targeted?(valid)
      return valid ? .move : []
    }
    private func token(_ sender: NSDraggingInfo) -> String? {
      acceptedToken(from: sender.draggingPasteboard, sourceOperations: sender.draggingSourceOperationMask)
    }
    func acceptedToken(from pasteboard: NSPasteboard, sourceOperations: NSDragOperation) -> String? {
      guard sourceOperations.contains(.move),
        let value = pasteboard.string(forType: .string), accepts?(value) == true else { return nil }
      return value
    }
  }
}
