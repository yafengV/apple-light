import AppKit
import SwiftUI

/// SwiftUI owns the selection; AppKit makes the popover's slider a real key responder.
struct ModelPowerSlider: NSViewRepresentable {
  @Binding var value: Double
  let count: Int
  let valueDescription: String
  let available: () -> Bool
  let onStep: (Bool) -> Void
  let onComplete: () -> Void
  let navigation: ModelPickerMenuFocus
  @Environment(\.isEnabled) private var enabled

  func makeCoordinator() -> Coordinator { Coordinator(self) }
  func makeNSView(context: Context) -> KeyboardControl {
    let container = KeyboardControl()
    let view = container.slider
    view.owner = context.coordinator; view.target = context.coordinator
    view.action = #selector(Coordinator.changed(_:)); view.isContinuous = true
    view.setAccessibilityLabel("推理强度")
    return container
  }
  func updateNSView(_ container: KeyboardControl, context: Context) {
    context.coordinator.parent = self
    if container.navigation !== navigation { container.navigation?.unregister(container, id: "power") }
    container.navigation = navigation
    let view = container.slider
    view.isEnabled = enabled && count >= 2 && available()
    view.minValue = 0; view.maxValue = Double(max(1, count - 1))
    view.numberOfTickMarks = count; view.allowsTickMarkValuesOnly = true
    context.coordinator.refresh(view)
    container.setAccessibilityValue(valueDescription)
    navigation.register(container, id: "power")
  }
  static func dismantleNSView(_ view: KeyboardControl, coordinator: Coordinator) {
    view.navigation?.unregister(view, id: "power"); view.navigation = nil
    coordinator.active = false; view.slider.owner = nil; view.slider.target = nil
  }

  /// The reference's keyboard menu item is distinct from its pointer/AX slider.
  final class KeyboardControl: NSView {
    let slider = Control()
    weak var navigation: ModelPickerMenuFocus?
    override init(frame: NSRect) {
      super.init(frame: frame)
      addSubview(slider)
      setAccessibilityElement(true); setAccessibilityRole(.menuItem)
      setAccessibilityLabel("推理强度")
      setAccessibilityHelp("使用左右方向键调整档位；使用上下方向键或 Tab 移动菜单焦点")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layout() { super.layout(); slider.frame = bounds }
    override var intrinsicContentSize: NSSize { .init(width: 200, height: 28) }
    override var acceptsFirstResponder: Bool { navigation?.active == true && slider.owner?.canAct(slider) == true }
    override var canBecomeKeyView: Bool { acceptsFirstResponder }
    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      if window != nil { navigation?.register(self, id: "power") }
    }
    override func becomeFirstResponder() -> Bool {
      let result = super.becomeFirstResponder()
      if result { navigation?.didFocus(self, id: "power"); needsDisplay = true; slider.needsDisplay = true }
      return result
    }
    override func resignFirstResponder() -> Bool { needsDisplay = true; slider.needsDisplay = true; return super.resignFirstResponder() }
    override func keyDown(with event: NSEvent) {
      guard acceptsFirstResponder else { return }
      let key: String?
      switch event.keyCode { case 48: key = "Tab"; case 125: key = "ArrowDown"; case 126: key = "ArrowUp"; default: key = nil }
      if let key, navigation?.move(from: self, id: "power", key: key, shift: event.modifierFlags.contains(.shift)) == true { return }
      if [123, 124, 36, 76].contains(event.keyCode) { slider.keyDown(with: event) }
      else { nextResponder?.keyDown(with: event) }
    }
    override func draw(_ dirtyRect: NSRect) {
      guard window?.firstResponder === self else { return }
      NSColor.keyboardFocusIndicatorColor.setStroke()
      let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 5, yRadius: 5)
      path.lineWidth = 2; path.stroke()
    }
  }

  final class Control: NSSlider {
    weak var owner: Coordinator?
    override var acceptsFirstResponder: Bool { owner?.canAct(self) == true }
    override var canBecomeKeyView: Bool { acceptsFirstResponder }
    override func keyDown(with event: NSEvent) {
      guard owner?.canAct(self) == true else { return }
      guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty else {
        superview?.nextResponder?.keyDown(with: event); return
      }
      switch event.keyCode {
      case 123: _ = owner?.step(increasing: false, in: self)
      case 124: _ = owner?.step(increasing: true, in: self)
      case 36, 76: owner?.parent.onComplete()
      case 125, 126: break // Actual slider descendants do not run the menu's focus capture.
      case 48:
        if event.modifierFlags.contains(.shift) { window?.selectPreviousKeyView(self) }
        else { window?.selectNextKeyView(self) }
      default: superview?.nextResponder?.keyDown(with: event)
      }
    }
    override func mouseDown(with event: NSEvent) {
      guard owner?.canAct(self) == true else { return }
      window?.makeFirstResponder(self); super.mouseDown(with: event)
    }
    override func accessibilityPerformIncrement() -> Bool { owner?.step(increasing: true, in: self) ?? false }
    override func accessibilityPerformDecrement() -> Bool { owner?.step(increasing: false, in: self) ?? false }
  }

  @MainActor final class Coordinator: NSObject {
    var parent: ModelPowerSlider
    var active = true
    init(_ parent: ModelPowerSlider) { self.parent = parent }
    func canAct(_ view: Control) -> Bool {
      active && parent.navigation.active && parent.enabled && parent.count >= 2 && parent.available() && view.isEnabled
        && !view.isHiddenOrHasHiddenAncestor && view.window != nil
        && view.window?.attachedSheet == nil && WindowModalInteraction.allows(view)
    }
    func refresh(_ view: Control) {
      view.doubleValue = parent.value
      view.setAccessibilityValueDescription(parent.valueDescription)
    }
    @objc func changed(_ view: Control) {
      guard canAct(view) else { refresh(view); return }
      parent.value = view.doubleValue; refresh(view)
    }
    @discardableResult func step(increasing: Bool, in view: Control) -> Bool {
      guard canAct(view) else { return false }
      parent.onStep(increasing); refresh(view); return true
    }
  }
}
