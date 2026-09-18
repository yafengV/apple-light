import AppKit
import SwiftUI

/// AppKit owns cursor rectangles and responder input; SwiftUI owns panel sizes.
struct PanelResizeHandle: NSViewRepresentable {
  enum Axis { case vertical, horizontal }
  let axis: Axis
  let value: Double
  let bounds: ClosedRange<Double>
  let label: String
  let onResize: (Double) -> Void
  let onEnd: () -> Void
  let onReset: () -> Void

  func makeNSView(context: Context) -> ResizeView { ResizeView() }
  func updateNSView(_ view: ResizeView, context: Context) {
    view.axis = axis
    view.position = value
    view.limits = bounds
    view.onResize = onResize
    view.onEnd = onEnd
    view.onReset = onReset
    view.toolTip = label + "；拖动调整，双击恢复默认，也可使用方向键。"
    view.setAccessibilityElement(true)
    view.setAccessibilityRole(.splitter)
    view.setAccessibilityLabel(label)
    view.setAccessibilityMinValue(bounds.lowerBound)
    view.setAccessibilityMaxValue(bounds.upperBound)
    view.setAccessibilityOrientation(axis == .vertical ? .vertical : .horizontal)
    view.window?.invalidateCursorRects(for: view)
    view.needsDisplay = true
  }

  final class ResizeView: NSView {
    var axis: Axis = .vertical
    var position = 0.0
    var limits = 0.0...0.0
    var onResize: ((Double) -> Void)?
    var onEnd: (() -> Void)?
    var onReset: (() -> Void)?
    private var origin: NSPoint?
    private var initial = 0.0
    override var acceptsFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool {
      needsDisplay = true
      return true
    }
    override func resignFirstResponder() -> Bool {
      needsDisplay = true
      return true
    }
    override func resetCursorRects() {
      addCursorRect(bounds, cursor: axis == .vertical ? .resizeLeftRight : .resizeUpDown)
    }
    override func draw(_ dirtyRect: NSRect) {
      if window?.firstResponder === self {
        NSColor.controlAccentColor.withAlphaComponent(0.15).setFill()
        bounds.fill()
      }
      NSColor.separatorColor.setFill()
      if axis == .vertical {
        NSRect(x: bounds.midX - 0.5, y: 0, width: 1, height: bounds.height).fill()
      } else {
        NSRect(x: 0, y: bounds.midY - 0.5, width: bounds.width, height: 1).fill()
      }
    }
    override func mouseDown(with event: NSEvent) {
      window?.makeFirstResponder(self)
      if event.clickCount == 2 {
        origin = nil
        onReset?()
        return
      }
      initial = position
      origin = event.locationInWindow
    }
    override func mouseDragged(with event: NSEvent) {
      guard let origin else { return }
      let delta =
        axis == .vertical
        ? origin.x - event.locationInWindow.x : event.locationInWindow.y - origin.y
      resize(initial + delta, finish: false)
    }
    override func mouseUp(with event: NSEvent) {
      guard origin != nil else { return }
      origin = nil
      onEnd?()
    }
    override func keyDown(with event: NSEvent) {
      if event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
        if (axis == .vertical && event.keyCode == 123)
          || (axis == .horizontal && event.keyCode == 126)
        {
          resize(position + 20, finish: true)
          return
        }
        if (axis == .vertical && event.keyCode == 124)
          || (axis == .horizontal && event.keyCode == 125)
        {
          resize(position - 20, finish: true)
          return
        }
      }
      super.keyDown(with: event)
    }
    override func accessibilityPerformIncrement() -> Bool {
      resize(position + 20, finish: true)
      return true
    }
    override func accessibilityPerformDecrement() -> Bool {
      resize(position - 20, finish: true)
      return true
    }
    override func accessibilityValue() -> Any? { NSNumber(value: position) }
    override func setAccessibilityValue(_ accessibilityValue: Any?) {
      guard let number = accessibilityValue as? NSNumber, number.doubleValue.isFinite else {
        return
      }
      resize(number.doubleValue, finish: true)
    }
    private func resize(_ newValue: Double, finish: Bool) {
      position = WorkspacePanelSizes.clamp(newValue, to: limits)
      onResize?(position)
      if finish { onEnd?() }
      NSAccessibility.post(element: self, notification: .valueChanged)
    }
  }
}
