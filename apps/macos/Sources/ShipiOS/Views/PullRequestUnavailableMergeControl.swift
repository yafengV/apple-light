import AppKit
import SwiftUI

/// A disabled merge remains keyboard discoverable for its reason, without an activation route.
struct PullRequestUnavailableMergeControl: NSViewRepresentable {
  let reason: String
  func makeNSView(context: Context) -> PullRequestUnavailableMergeButton { .init(frame: .zero) }
  func updateNSView(_ button: PullRequestUnavailableMergeButton, context: Context) {
    button.toolTip = reason
    button.setAccessibilityLabel("合并不可用：" + reason)
    button.setAccessibilityIdentifier("pull-request-merge-unavailable")
  }
  static func dismantleNSView(_ button: PullRequestUnavailableMergeButton, coordinator: ()) {
    button.active = false
    weak var previousWindow = button.window
    DispatchQueue.main.async { [weak button] in
      guard let button, previousWindow?.firstResponder === button else { return }
      previousWindow?.makeFirstResponder(nil)
    }
  }
}

@MainActor final class PullRequestUnavailableMergeButton: NSButton {
  var active = true
  override var isEnabled: Bool {
    get { false }
    set { if super.isEnabled { super.isEnabled = false } }
  }
  override var acceptsFirstResponder: Bool { active && !isHiddenOrHasHiddenAncestor }
  override var canBecomeKeyView: Bool { acceptsFirstResponder && window != nil }
  override var intrinsicContentSize: NSSize { .init(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric) }
  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    title = ""; isBordered = false; isTransparent = true; isEnabled = false
    focusRingType = .exterior; setAccessibilityRole(.button)
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
  override func becomeFirstResponder() -> Bool { acceptsFirstResponder }
  override func accessibilityPerformPress() -> Bool { false }
  override func keyDown(with event: NSEvent) {
    guard acceptsFirstResponder else { return }
    if event.keyCode == 48 {
      if event.modifierFlags.contains(.shift) { window?.selectPreviousKeyView(self) }
      else { window?.selectNextKeyView(self) }
    }
  }
  override func drawFocusRingMask() { NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill() }
  override var focusRingMaskBounds: NSRect { bounds }
}
