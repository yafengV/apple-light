import AppKit
import SwiftUI

/// Toolbar actions participate in Tab navigation without a window-wide default.
struct AppearanceActionButton: NSViewRepresentable {
  let title: String
  let label: String
  var symbolName: String?
  var accessibilityValue: String?
  let available: () -> Bool
  var interactionAvailable: () -> Bool = { true }
  let action: (Control) -> Void
  @Environment(\.isEnabled) private var enabled
  @Environment(\.appAppearance) private var appearance
  func makeNSView(context: Context) -> Control { Control() }
  func updateNSView(_ view: Control, context: Context) {
    view.title = title; view.setAccessibilityLabel(label)
    view.symbolName = symbolName; view.setAccessibilityValue(accessibilityValue)
    view.font = appearance.nativeFont(size: 13); view.preferences = appearance
    view.canAct = { enabled && available() && interactionAvailable() }; view.activate = { [weak view] in if let view { action(view) } }
    view.isEnabled = enabled && available(); view.invalidateIntrinsicContentSize(); view.needsDisplay = true
  }
  static func dismantleNSView(_ view: Control, coordinator: ()) {
    view.active = false; view.activate = nil; view.canAct = { false }
  }
  final class Control: NSButton {
    var active = true
    var preferences = AppearancePreferences()
    var primary = false
    var outlinedPill = false
    var closeIcon = false
    var symbolName: String?
    var hovered = false { didSet { needsDisplay = true } }
    var canAct: () -> Bool = { true }
    var activate: (() -> Void)?
    private var tracking: NSTrackingArea?
    override init(frame: NSRect) {
      super.init(frame: frame); isBordered = false; setButtonType(.momentaryPushIn)
      target = self; action = #selector(pressed)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var acceptsFirstResponder: Bool { active && isEnabled && canAct() && !isHiddenOrHasHiddenAncestor && WindowModalInteraction.allows(self) }
    override var canBecomeKeyView: Bool { acceptsFirstResponder && window != nil }
    override var intrinsicContentSize: NSSize {
      if closeIcon { return .init(width: 22, height: 22) }
      return .init(width: ceil((title as NSString).size(withAttributes: [.font: font ?? .systemFont(ofSize: 13)]).width) + 18 + (symbolName == nil ? 0 : 18), height: outlinedPill ? 24 : 28)
    }
    @objc private func pressed() { guard acceptsFirstResponder, window != nil, canAct() else { return }; activate?() }
    override func accessibilityPerformPress() -> Bool {
      guard acceptsFirstResponder, window != nil, canAct() else { return false }; activate?(); return true
    }
    override func keyDown(with event: NSEvent) {
      let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
      if flags.isEmpty, [36, 49, 76].contains(event.keyCode) {
        if !event.isARepeat { pressed() }; return
      }
      super.keyDown(with: event)
    }
    override func mouseDown(with event: NSEvent) {
      guard acceptsFirstResponder, canAct() else { return }; window?.makeFirstResponder(self); super.mouseDown(with: event)
    }
    override func becomeFirstResponder() -> Bool { needsDisplay = true; return super.becomeFirstResponder() }
    override func resignFirstResponder() -> Bool { needsDisplay = true; return super.resignFirstResponder() }
    override func resetCursorRects() {
      super.resetCursorRects()
      if preferences.usePointerCursors && isEnabled { addCursorRect(bounds, cursor: .pointingHand) }
    }
    override func updateTrackingAreas() {
      super.updateTrackingAreas(); if let tracking { removeTrackingArea(tracking) }
      let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
      addTrackingArea(area); tracking = area
    }
    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
    override func draw(_ dirtyRect: NSRect) {
      let roles = preferences.resolvedColors
      let alpha: Double = isEnabled ? 1 : 0.4
      let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: closeIcon ? 4 : outlinedPill ? bounds.height / 2 : 10, yRadius: closeIcon ? 4 : outlinedPill ? bounds.height / 2 : 10)
      if primary {
        roles["textForeground"].opacity(alpha * (hovered ? 0.8 : 1)).nativeColor.setFill(); path.fill()
        roles["border"].opacity(alpha).nativeColor.setStroke(); path.lineWidth = 1; path.stroke()
      } else if outlinedPill {
        roles[hovered && isEnabled ? "buttonSecondaryBackgroundHover" : "elevatedSecondary"].opacity(alpha).nativeColor.setFill(); path.fill()
        roles["border"].opacity(alpha).nativeColor.setStroke(); path.lineWidth = 1; path.stroke()
      } else if hovered && isEnabled { roles["buttonSecondaryBackgroundHover"].nativeColor.setFill(); path.fill() }
      let foreground = roles[primary ? "controlBackgroundOpaque" : closeIcon ? "textForeground" : "textForegroundTertiary"].opacity(alpha * (closeIcon ? 0.8 : 1)).nativeColor
      if closeIcon {
        let x = NSBezierPath(); x.move(to: .init(x: bounds.midX - 4, y: bounds.midY - 4)); x.line(to: .init(x: bounds.midX + 4, y: bounds.midY + 4))
        x.move(to: .init(x: bounds.midX - 4, y: bounds.midY + 4)); x.line(to: .init(x: bounds.midX + 4, y: bounds.midY - 4)); foreground.setStroke(); x.lineWidth = 1.2; x.stroke()
      } else {
        let text = NSAttributedString(string: title, attributes: [.font: font ?? .systemFont(ofSize: 13), .foregroundColor: foreground])
        let iconWidth: CGFloat = symbolName == nil ? 0 : 18
        let textX = (bounds.width - text.size().width - iconWidth) / 2
        text.draw(at: .init(x: textX, y: (bounds.height - text.size().height) / 2))
        if let symbolName, let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) {
          let rect = NSRect(x: textX + text.size().width + (title.isEmpty ? 0 : 6), y: bounds.midY - 6, width: 12, height: 12)
          let tinted = NSImage(size: rect.size, flipped: false) { bounds in
            image.draw(in: bounds); foreground.setFill(); bounds.fill(using: .sourceAtop); return true
          }
          tinted.draw(in: rect)
        }
      }
      if window?.firstResponder === self && isEnabled {
        roles["borderFocus"].nativeColor.setStroke(); path.lineWidth = 2; path.stroke()
      }
    }
  }
}
