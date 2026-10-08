import AppKit
import SwiftUI

/// Only the capture cancel button preserves pointer-down focus on the recorder.
/// Edit and clear remain ordinary, independently named keyboard/AX controls.
struct VoiceShortcutActionButton: NSViewRepresentable {
  enum Kind { case edit, clear, cancel }
  let kind: Kind
  let label: String
  let identifier: String
  let action: () -> Void
  @Environment(\.appAppearance) private var appearance
  @Environment(\.isEnabled) private var enabled
  @Environment(\.layoutDirection) private var direction
  @Environment(\.settingsNativeControlDidFocus) private var didFocus

  func makeNSView(context: Context) -> Control { Control() }
  func updateNSView(_ view: Control, context: Context) {
    view.kind = kind; view.title = kind == .cancel ? "取消" : ""
    view.preferences = appearance; view.isEnabled = enabled
    view.userInterfaceLayoutDirection = direction == .rightToLeft ? .rightToLeft : .leftToRight
    view.didFocus = didFocus; view.activate = action; view.toolTip = label
    view.setAccessibilityLabel(label); view.setAccessibilityIdentifier(identifier)
    view.invalidateIntrinsicContentSize(); view.needsDisplay = true
    if !enabled { view.cancelPending() }
  }
  static func dismantleNSView(_ view: Control, coordinator: ()) {
    view.active = false; view.activate = nil; view.didFocus = nil
    view.stopObserving(); view.cancelPending()
  }

  final class Control: NSButton {
    var kind: Kind = .edit
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
      super.init(frame: frame); isBordered = false; focusRingType = .none
      setButtonType(.momentaryPushIn); target = self; action = #selector(pressed)
      setAccessibilityElement(true); setAccessibilityRole(.button)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var acceptsFirstResponder: Bool {
      active && isEnabled && !isHiddenOrHasHiddenAncestor && WindowModalInteraction.allows(self)
    }
    override var canBecomeKeyView: Bool { acceptsFirstResponder && window != nil }
    override var mouseDownCanMoveWindow: Bool { false }
    override var intrinsicContentSize: NSSize {
      .init(width: kind == .cancel
        ? ceil((title as NSString).size(withAttributes: [.font: preferences.nativeFont(size: 13)]).width) + 18
        : 28, height: 28)
    }
    @objc private func pressed() { guard acceptsFirstResponder, window != nil else { return }; activate?() }
    override func isAccessibilityEnabled() -> Bool { active && isEnabled }
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
        cancelPending(); super.keyDown(with: event); return
      }
      if event.keyCode == 49 { if !event.isARepeat { spacePressed = true }; needsDisplay = true; return }
      if [36, 76].contains(event.keyCode) { pressed(); return }
      super.keyDown(with: event)
    }
    override func keyUp(with event: NSEvent) {
      guard event.keyCode == 49 else { super.keyUp(with: event); return }
      let invoke = spacePressed && acceptsFirstResponder && window?.firstResponder === self
        && event.modifierFlags.intersection([.command, .control, .option]).isEmpty
      spacePressed = false; needsDisplay = true
      if invoke { pressed() }
    }
    override func mouseDown(with event: NSEvent) {
      guard acceptsFirstResponder else { return }
      if kind != .cancel { window?.makeFirstResponder(self) }
      pointerPressed = true; needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
      let invoke = pointerPressed && acceptsFirstResponder && bounds.contains(convert(event.locationInWindow, from: nil))
      pointerPressed = false; needsDisplay = true
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
      let path = NSBezierPath(roundedRect: bounds, xRadius: 10, yRadius: 10)
      if hovered && isEnabled { roles["buttonSecondaryBackgroundHover"].nativeColor.setFill(); path.fill() }
      let role = roles["textForegroundTertiary"]
      let foreground = role.nativeColor.withAlphaComponent(role.alpha * (isEnabled ? 1 : 0.4))
      if kind == .cancel {
        let text = NSAttributedString(string: title, attributes: [.font: preferences.nativeFont(size: 13), .foregroundColor: foreground])
        text.draw(at: .init(x: bounds.midX - text.size().width / 2, y: bounds.midY - text.size().height / 2))
      } else {
        let name = kind == .edit ? "pencil" : "xmark"
        let configuration = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
          .applying(NSImage.SymbolConfiguration(paletteColors: [foreground.withAlphaComponent(1)]))
        // SF Symbol palette alpha is applied to multiple drawing layers. Apply
        // the theme's opacity once when compositing the opaque symbol instead.
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(configuration)?
          .draw(in: .init(x: bounds.midX - 8, y: bounds.midY - 8, width: 16, height: 16),
            from: .zero, operation: .sourceOver, fraction: foreground.alphaComponent,
            respectFlipped: true, hints: nil)
      }
      if window?.firstResponder === self && isEnabled {
        let ring = NSBezierPath(roundedRect: bounds.insetBy(dx: -1, dy: -1), xRadius: 11, yRadius: 11)
        roles["borderFocus"].nativeColor.setStroke(); ring.lineWidth = 2; ring.stroke()
      }
    }
  }
}
