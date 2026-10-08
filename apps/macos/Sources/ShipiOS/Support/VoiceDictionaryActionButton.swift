import AppKit
import SwiftUI

/// Dictionary buttons prevent pointer-down from blurring the input. Keyboard
/// focus remains available, with native responder routing and release activation.
struct VoiceDictionaryActionButton: NSViewRepresentable {
  var title = ""
  let label: String
  let identifier: String
  var enabled = true
  let action: () -> Void
  @Environment(\.appAppearance) private var appearance
  @Environment(\.isEnabled) private var isEnabled
  @Environment(\.layoutDirection) private var direction
  @Environment(\.settingsNativeControlDidFocus) private var didFocus

  func makeNSView(context: Context) -> Control { Control() }
  func updateNSView(_ view: Control, context: Context) {
    view.title = title; view.isEnabled = enabled && isEnabled; view.preferences = appearance
    view.userInterfaceLayoutDirection = direction == .rightToLeft ? .rightToLeft : .leftToRight
    view.didFocus = didFocus
    view.setAccessibilityLabel(label); view.setAccessibilityIdentifier(identifier)
    view.activate = action; view.invalidateIntrinsicContentSize(); view.needsDisplay = true
    if !view.isEnabled { view.cancelPending() }
  }
  static func dismantleNSView(_ view: Control, coordinator: ()) {
    view.active = false; view.activate = nil; view.didFocus = nil; view.stopObserving(); view.cancelPending()
  }

  final class Control: NSButton {
    var active = true
    var preferences = AppearancePreferences()
    var activate: (() -> Void)?
    var didFocus: (() -> Void)?
    private var spacePressed = false
    private var pointerPressed = false
    private var hovered = false
    private var tracking: NSTrackingArea?
    private var observers: [NSObjectProtocol] = []
    override init(frame: NSRect) {
      super.init(frame: frame); isBordered = false; setButtonType(.momentaryPushIn)
      setAccessibilityElement(true); setAccessibilityRole(.button)
      target = self; action = #selector(pressed)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var acceptsFirstResponder: Bool {
      active && isEnabled && !isHiddenOrHasHiddenAncestor && WindowModalInteraction.allows(self)
    }
    override var canBecomeKeyView: Bool { acceptsFirstResponder && window != nil }
    override var mouseDownCanMoveWindow: Bool { false }
    override var intrinsicContentSize: NSSize {
      let width = title.isEmpty ? 28 : ceil((title as NSString).size(withAttributes: [.font: preferences.nativeFont(size: 13)]).width) + 38
      return .init(width: width, height: 28)
    }
    override func isAccessibilityEnabled() -> Bool { active && isEnabled }
    override func accessibilityPerformPress() -> Bool {
      guard acceptsFirstResponder, window != nil else { return false }
      activate?(); return true
    }
    @objc private func pressed() { guard acceptsFirstResponder, window != nil else { return }; activate?() }
    override func becomeFirstResponder() -> Bool {
      let result = super.becomeFirstResponder(); needsDisplay = true
      if result {
        DispatchQueue.main.async { [weak self] in
          guard let self, self.acceptsFirstResponder, self.window?.firstResponder === self else { return }
          self.didFocus?()
        }
      }
      return result
    }
    override func resignFirstResponder() -> Bool { cancelPending(); needsDisplay = true; return super.resignFirstResponder() }
    override func keyDown(with event: NSEvent) {
      guard acceptsFirstResponder, event.modifierFlags.intersection([.command, .control, .option]).isEmpty else {
        cancelPending(); super.keyDown(with: event); return
      }
      if event.keyCode == 49 { spacePressed = true; needsDisplay = true; return }
      if [36, 76].contains(event.keyCode) { activate?(); return }
      super.keyDown(with: event)
    }
    override func keyUp(with event: NSEvent) {
      guard event.keyCode == 49 else { super.keyUp(with: event); return }
      let invoke = spacePressed && acceptsFirstResponder && window?.firstResponder === self
        && event.modifierFlags.intersection([.command, .control, .option]).isEmpty
      spacePressed = false; needsDisplay = true
      if invoke { activate?() }
    }
    override func mouseDown(with event: NSEvent) {
      guard acceptsFirstResponder else { return }
      pointerPressed = true; needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
      let invoke = pointerPressed && acceptsFirstResponder && bounds.contains(convert(event.locationInWindow, from: nil))
      pointerPressed = false; needsDisplay = true
      if invoke { activate?() }
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
    override func updateTrackingAreas() {
      super.updateTrackingAreas(); if let tracking { removeTrackingArea(tracking) }
      let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
      addTrackingArea(area); tracking = area
    }
    override func resetCursorRects() {
      super.resetCursorRects()
      if isEnabled && preferences.usePointerCursors { addCursorRect(bounds, cursor: .pointingHand) }
    }
    func cancelPending() { spacePressed = false; pointerPressed = false; needsDisplay = true }
    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow(); stopObserving(); cancelPending()
      guard let window else { return }
      for (name, object) in [(NSWindow.didResignKeyNotification, window as AnyObject),
        (NSWindow.willCloseNotification, window as AnyObject),
        (NSApplication.didResignActiveNotification, NSApp as AnyObject)] {
        observers.append(NotificationCenter.default.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
          MainActor.assumeIsolated { self?.cancelPending() }
        })
      }
    }
    func stopObserving() { observers.forEach(NotificationCenter.default.removeObserver); observers.removeAll() }
    deinit { observers.forEach(NotificationCenter.default.removeObserver) }
    override func draw(_ dirtyRect: NSRect) {
      let roles = preferences.resolvedColors
      let path = NSBezierPath(roundedRect: bounds, xRadius: 10, yRadius: 10)
      let alpha: Double = isEnabled ? 1 : 0.4
      if !title.isEmpty {
        roles["textForeground"].opacity(alpha * (hovered ? 0.1 : 0.05)).nativeColor.setFill(); path.fill()
      } else if hovered && isEnabled { roles["buttonSecondaryBackgroundHover"].nativeColor.setFill(); path.fill() }
      let foreground = roles[title.isEmpty ? "textForegroundTertiary" : "textForeground"].opacity(alpha).nativeColor
      foreground.setStroke()
      let rtl = userInterfaceLayoutDirection == .rightToLeft
      let iconX: CGFloat = title.isEmpty ? bounds.midX : rtl ? bounds.maxX - 16 : 16
      let icon = NSBezierPath(); icon.move(to: .init(x: iconX - 4, y: bounds.midY)); icon.line(to: .init(x: iconX + 4, y: bounds.midY))
      if !title.isEmpty { icon.move(to: .init(x: iconX, y: bounds.midY - 4)); icon.line(to: .init(x: iconX, y: bounds.midY + 4)) }
      icon.lineWidth = 1.2; icon.stroke()
      if !title.isEmpty {
        let text = NSAttributedString(string: title, attributes: [.font: preferences.nativeFont(size: 13), .foregroundColor: foreground])
        text.draw(at: .init(x: rtl ? bounds.maxX - 27 - text.size().width : 27, y: bounds.midY - text.size().height / 2))
      }
      if window?.firstResponder === self && isEnabled {
        roles["borderFocus"].nativeColor.setStroke(); path.lineWidth = 2; path.stroke()
      }
    }
  }
}
