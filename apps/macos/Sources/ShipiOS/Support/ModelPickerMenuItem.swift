import AppKit
import SwiftUI

/// A picker owns its responders. No window-wide monitor or shared focus state.
@MainActor final class ModelPickerMenuFocus {
  struct Item {
    let id: String
    var disabled = false
    var interactive = true
    var hidden = false
  }
  static func destination(items: [Item], currentID: String?, key: String, shift: Bool = false,
    slider: Bool = false, composerReasoningNavigation: Bool = false) -> String? {
    guard ["Tab", "ArrowDown", "ArrowUp"].contains(key), !slider, !composerReasoningNavigation else { return nil }
    let eligible = items.filter { !$0.disabled && $0.interactive && !$0.hidden }
    guard let currentID, let index = eligible.firstIndex(where: { $0.id == currentID }) else { return nil }
    let step = key == "ArrowUp" || (key == "Tab" && shift) ? -1 : 1
    return eligible[(index + step + eligible.count) % eligible.count].id
  }

  private final class Reference {
    weak var button: ModelPickerMenuItem.Control?
    init(_ button: ModelPickerMenuItem.Control) { self.button = button }
  }
  private var buttons: [String: Reference] = [:]
  private var ids: [String] = []
  private var pendingID: String?
  private var generation = UUID()
  private var initiallyFocused = false
  private(set) var active = false

  func configure(ids: [String], preferredID: String?, active: Bool) {
    let entering = active && !self.active
    self.active = active; self.ids = ids
    guard active else { deactivate(); return }
    if entering { initiallyFocused = false }
    if !initiallyFocused {
      pendingID = preferredID.flatMap { ids.contains($0) ? $0 : nil } ?? ids.first
      scheduleInitialFocus()
    }
  }
  func deactivate() {
    active = false; pendingID = nil; initiallyFocused = false; generation = UUID()
  }
  func register(_ button: ModelPickerMenuItem.Control) {
    buttons[button.itemID] = Reference(button)
    scheduleInitialFocus()
  }
  func unregister(_ button: ModelPickerMenuItem.Control) {
    if buttons[button.itemID]?.button === button { buttons[button.itemID] = nil }
  }
  func didFocus(_ button: ModelPickerMenuItem.Control) {
    guard active, ids.contains(button.itemID) else { return }
    initiallyFocused = true; pendingID = nil; generation = UUID()
  }
  private func scheduleInitialFocus() {
    guard active, !initiallyFocused, let pendingID, let button = buttons[pendingID]?.button else { return }
    let token = generation
    DispatchQueue.main.async { [weak self, weak button] in
      guard let self, let button, self.generation == token, self.active,
        self.pendingID == button.itemID, self.buttons[button.itemID]?.button === button,
        button.acceptsFirstResponder, let window = button.window else { return }
      if window.makeFirstResponder(button) { button.scrollToVisible(button.bounds) }
    }
  }
  func move(from button: ModelPickerMenuItem.Control, key: String, shift: Bool) -> Bool {
    guard active, button.acceptsFirstResponder else { return false }
    let items = ids.map { id in
      Item(id: id, disabled: buttons[id]?.button?.acceptsFirstResponder != true)
    }
    guard let id = Self.destination(items: items, currentID: button.itemID, key: key, shift: shift),
      let target = buttons[id]?.button, target.window === button.window,
      target.acceptsFirstResponder, target.window?.makeFirstResponder(target) == true else { return false }
    target.scrollToVisible(target.bounds)
    return true
  }
}

/// SwiftUI owns values and actions; AppKit supplies concrete menu row responders.
struct ModelPickerMenuItem: NSViewRepresentable {
  let id: String
  let title: String
  var subtitle: String? = nil
  let label: String
  let selected: Bool
  let navigation: ModelPickerMenuFocus
  let available: () -> Bool
  let action: () -> Void
  @Environment(\.isEnabled) private var enabled
  @Environment(\.appAppearance) private var appearance
  func makeNSView(context: Context) -> Control { Control() }
  func updateNSView(_ button: Control, context: Context) {
    if button.itemID != id || button.navigation !== navigation { button.navigation?.unregister(button) }
    button.itemID = id; button.navigation = navigation
    button.title = title; button.subtitle = subtitle; button.selected = selected
    button.preferences = appearance; button.font = appearance.nativeFont(size: 13)
    button.setAccessibilityLabel(label); button.setAccessibilityHelp(subtitle)
    button.setAccessibilityValue(selected ? 1 : 0)
    button.canAct = { enabled && available() }; button.activate = action
    button.isEnabled = enabled && available()
    button.invalidateIntrinsicContentSize(); button.needsDisplay = true
    navigation.register(button)
  }
  static func dismantleNSView(_ button: Control, coordinator: ()) {
    button.navigation?.unregister(button); button.active = false
    button.navigation = nil; button.activate = nil; button.canAct = { false }
  }
  final class Control: NSButton {
    var itemID = ""
    weak var navigation: ModelPickerMenuFocus?
    var active = true
    var subtitle: String?
    var selected = false
    var preferences = AppearancePreferences()
    var canAct: () -> Bool = { false }
    var activate: (() -> Void)?
    private var hovered = false
    private var tracking: NSTrackingArea?
    private var requestedEnabled = true
    private var enabledGeneration = UUID()
    override var isEnabled: Bool {
      get { requestedEnabled }
      set {
        guard requestedEnabled != newValue else { return }
        requestedEnabled = newValue; enabledGeneration = UUID()
        let token = enabledGeneration
        DispatchQueue.main.async { [weak self] in
          guard let self, self.enabledGeneration == token else { return }
          self.applyEnabled(newValue)
        }
      }
    }
    private func applyEnabled(_ enabled: Bool) {
      if !enabled, window?.firstResponder === self { window?.makeFirstResponder(nil) }
      super.isEnabled = enabled; needsDisplay = true
    }
    override init(frame: NSRect) {
      super.init(frame: frame)
      isBordered = false; setButtonType(.momentaryPushIn)
      focusRingType = .none
      setAccessibilityElement(true); setAccessibilityRole(.radioButton)
      target = self; action = #selector(pressed)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var acceptsFirstResponder: Bool {
      active && navigation?.active == true && isEnabled && canAct() && window != nil
        && !isHiddenOrHasHiddenAncestor && window?.attachedSheet == nil && WindowModalInteraction.allows(self)
    }
    override var canBecomeKeyView: Bool { acceptsFirstResponder }
    override var intrinsicContentSize: NSSize { .init(width: 280, height: subtitle == nil ? 34 : 52) }
    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      if window != nil { navigation?.register(self) }
    }
    override func becomeFirstResponder() -> Bool {
      let result = super.becomeFirstResponder()
      if result { navigation?.didFocus(self); needsDisplay = true }
      return result
    }
    override func resignFirstResponder() -> Bool { needsDisplay = true; return super.resignFirstResponder() }
    @objc private func pressed() { guard acceptsFirstResponder else { return }; activate?() }
    override func accessibilityPerformPress() -> Bool {
      guard acceptsFirstResponder else { return false }
      window?.makeFirstResponder(self); activate?(); return true
    }
    override func keyDown(with event: NSEvent) {
      guard acceptsFirstResponder else { return }
      let key: String?
      switch event.keyCode { case 48: key = "Tab"; case 125: key = "ArrowDown"; case 126: key = "ArrowUp"; default: key = nil }
      if let key, navigation?.move(from: self, key: key, shift: event.modifierFlags.contains(.shift)) == true { return }
      if event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
        [36, 49, 76].contains(event.keyCode) {
        if !event.isARepeat { pressed() }; return
      }
      super.keyDown(with: event)
    }
    override func mouseDown(with event: NSEvent) {
      guard acceptsFirstResponder else { return }
      window?.makeFirstResponder(self); super.mouseDown(with: event)
    }
    override func updateTrackingAreas() {
      super.updateTrackingAreas(); if let tracking { removeTrackingArea(tracking) }
      let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
      addTrackingArea(area); tracking = area
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
    override func resetCursorRects() {
      super.resetCursorRects()
      if preferences.usePointerCursors && isEnabled { addCursorRect(bounds, cursor: .pointingHand) }
    }
    override func draw(_ dirtyRect: NSRect) {
      let roles = preferences.resolvedColors, focused = window?.firstResponder === self
      let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 6, yRadius: 6)
      if hovered || focused { roles["buttonSecondaryBackgroundHover"].nativeColor.setFill(); path.fill() }
      let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byTruncatingTail
      let font = font ?? .systemFont(ofSize: 13)
      let alpha = isEnabled ? 1.0 : 0.4
      let text = NSAttributedString(string: title, attributes: [.font: font,
        .foregroundColor: roles["textForeground"].opacity(alpha).nativeColor, .paragraphStyle: paragraph])
      let top = subtitle == nil ? bounds.midY - text.size().height / 2
        : isFlipped ? 8 : bounds.maxY - 8 - text.size().height
      text.draw(in: .init(x: 8, y: top, width: max(0, bounds.width - 34), height: text.size().height))
      if let subtitle {
        let sub = NSAttributedString(string: subtitle, attributes: [.font: preferences.nativeFont(size: 11),
          .foregroundColor: roles["textForegroundTertiary"].opacity(alpha).nativeColor, .paragraphStyle: paragraph])
        let subY = isFlipped ? top + text.size().height + 2 : max(3, top - sub.size().height - 2)
        sub.draw(in: .init(x: 8, y: subY, width: max(0, bounds.width - 34), height: sub.size().height))
      }
      if selected {
        let check = NSBezierPath(), x = bounds.maxX - 17, y = bounds.midY
        check.move(to: .init(x: x - 4, y: y))
        check.line(to: .init(x: x - 1, y: y + (isFlipped ? 3 : -3)))
        check.line(to: .init(x: x + 4, y: y + (isFlipped ? -4 : 4)))
        roles["textForeground"].opacity(alpha).nativeColor.setStroke()
        check.lineWidth = 1.6; check.lineCapStyle = .round; check.lineJoinStyle = .round; check.stroke()
      }
      if focused { roles["borderFocus"].nativeColor.setStroke(); path.lineWidth = 2; path.stroke() }
    }
  }
}
