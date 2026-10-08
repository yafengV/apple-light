import AppKit
import SwiftUI

/// The inline disclosure belongs to the hold shortcut's description. It has
/// native keyboard focus and exposes its expanded state to accessibility.
struct VoiceDictationAdvancedButton: NSViewRepresentable {
  let expanded: Bool
  let action: (Control) -> Void
  @Environment(\.appAppearance) private var appearance
  @Environment(\.isEnabled) private var enabled
  @Environment(\.layoutDirection) private var direction
  @Environment(\.settingsNativeControlDidFocus) private var didFocus

  func makeNSView(context: Context) -> Control { Control() }
  func updateNSView(_ view: Control, context: Context) {
    view.expanded = expanded; view.preferences = appearance; view.isEnabled = enabled
    view.userInterfaceLayoutDirection = direction == .rightToLeft ? .rightToLeft : .leftToRight
    view.didFocus = didFocus; view.activate = { [weak view] in if let view { action(view) } }
    view.setAccessibilityExpanded(expanded)
    view.setAccessibilityValue(expanded ? "已展开" : "已折叠")
    view.invalidateIntrinsicContentSize(); view.needsDisplay = true
    if !enabled { view.cancelPending() }
  }
  static func dismantleNSView(_ view: Control, coordinator: ()) {
    view.active = false; view.activate = nil; view.didFocus = nil; view.stopObserving(); view.cancelPending()
  }
  final class Control: NSButton {
    var expanded = false
    var active = true
    var preferences = AppearancePreferences()
    var activate: (() -> Void)?
    var didFocus: (() -> Void)?
    private var spacePressed = false
    private var pointerPressed = false
    private var hovered = false
    private var observers: [NSObjectProtocol] = []
    private var tracking: NSTrackingArea?
    override init(frame: NSRect) {
      super.init(frame: frame); title = "高级"; isBordered = false; focusRingType = .none
      setButtonType(.momentaryPushIn); target = self; action = #selector(pressed)
      setAccessibilityElement(true); setAccessibilityRole(.button)
      setAccessibilityLabel("高级听写快捷键"); setAccessibilityIdentifier("voice-dictation-advanced")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var acceptsFirstResponder: Bool {
      active && isEnabled && !isHiddenOrHasHiddenAncestor && WindowModalInteraction.allows(self)
    }
    override var canBecomeKeyView: Bool { acceptsFirstResponder && window != nil }
    override var mouseDownCanMoveWindow: Bool { false }
    override var intrinsicContentSize: NSSize {
      .init(width: ceil((title as NSString).size(withAttributes: [.font: preferences.nativeFont(size: 12)]).width) + 16,
        height: 16 * CGFloat(preferences.uiSize) / 14)
    }
    @objc private func pressed() { guard acceptsFirstResponder, window != nil else { return }; activate?() }
    override func accessibilityPerformPress() -> Bool {
      guard acceptsFirstResponder, window != nil else { return false }; activate?(); return true
    }
    override func becomeFirstResponder() -> Bool {
      let result = super.becomeFirstResponder(); needsDisplay = true
      if result { DispatchQueue.main.async { [weak self] in
        guard let self, self.acceptsFirstResponder, self.window?.firstResponder === self else { return }
        self.didFocus?()
      } }
      return result
    }
    override func resignFirstResponder() -> Bool { cancelPending(); return super.resignFirstResponder() }
    override func keyDown(with event: NSEvent) {
      guard acceptsFirstResponder, event.modifierFlags.intersection([.command, .control, .option]).isEmpty else {
        super.keyDown(with: event); return
      }
      if event.keyCode == 49 { if !event.isARepeat { spacePressed = true }; return }
      if [36, 76].contains(event.keyCode) { pressed(); return }
      super.keyDown(with: event)
    }
    override func keyUp(with event: NSEvent) {
      guard event.keyCode == 49 else { super.keyUp(with: event); return }
      let invoke = spacePressed && acceptsFirstResponder && window?.firstResponder === self
        && event.modifierFlags.intersection([.command, .control, .option]).isEmpty
      spacePressed = false
      if invoke { pressed() }
    }
    override func mouseDown(with event: NSEvent) {
      guard acceptsFirstResponder else { return }
      window?.makeFirstResponder(self); pointerPressed = true
    }
    override func mouseUp(with event: NSEvent) {
      let invoke = pointerPressed && acceptsFirstResponder && bounds.contains(convert(event.locationInWindow, from: nil))
      pointerPressed = false
      if invoke { pressed() }
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
    override func updateTrackingAreas() {
      super.updateTrackingAreas(); if let tracking { removeTrackingArea(tracking) }
      let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
      addTrackingArea(area); tracking = area
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
    override func resetCursorRects() {
      super.resetCursorRects()
      if isEnabled && preferences.usePointerCursors { addCursorRect(bounds, cursor: .pointingHand) }
    }
    override func draw(_ dirtyRect: NSRect) {
      let roles = preferences.resolvedColors
      let foreground = roles[hovered && isEnabled ? "textForeground" : "textForegroundTertiary"].opacity(isEnabled ? 1 : 0.4).nativeColor
      let text = NSAttributedString(string: title, attributes: [.font: preferences.nativeFont(size: 12), .foregroundColor: foreground])
      let rtl = userInterfaceLayoutDirection == .rightToLeft
      text.draw(at: .init(x: rtl ? bounds.maxX - text.size().width : 0, y: bounds.midY - text.size().height / 2))
      let x = rtl ? bounds.minX + 5 : bounds.maxX - 5
      let y = bounds.midY
      let sign: CGFloat = (expanded ? -1 : 1) * (isFlipped ? -1 : 1)
      let chevron = NSBezierPath(); chevron.move(to: .init(x: x - 3, y: y + sign * 1.5))
      chevron.line(to: .init(x: x, y: y - sign * 1.5)); chevron.line(to: .init(x: x + 3, y: y + sign * 1.5))
      foreground.setStroke(); chevron.lineWidth = 1.2; chevron.stroke()
      if window?.firstResponder === self && isEnabled {
        let ring = NSBezierPath(roundedRect: bounds.insetBy(dx: -1, dy: -1), xRadius: 6, yRadius: 6)
        roles["borderFocus"].nativeColor.setStroke(); ring.lineWidth = 2; ring.stroke()
      }
    }
  }
}
