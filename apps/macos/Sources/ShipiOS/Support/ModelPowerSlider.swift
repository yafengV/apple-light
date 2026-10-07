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
  @Environment(\.isEnabled) private var enabled

  func makeCoordinator() -> Coordinator { Coordinator(self) }
  func makeNSView(context: Context) -> Control {
    let view = Control()
    view.owner = context.coordinator; view.target = context.coordinator
    view.action = #selector(Coordinator.changed(_:)); view.isContinuous = true
    view.setAccessibilityLabel("推理强度")
    return view
  }
  func updateNSView(_ view: Control, context: Context) {
    context.coordinator.parent = self
    view.isEnabled = enabled && count >= 2 && available()
    view.minValue = 0; view.maxValue = Double(max(1, count - 1))
    view.numberOfTickMarks = count; view.allowsTickMarkValuesOnly = true
    context.coordinator.refresh(view)
    view.requestInitialFocus()
  }
  static func dismantleNSView(_ view: Control, coordinator: Coordinator) {
    coordinator.active = false; view.owner = nil; view.target = nil
  }

  final class Control: NSSlider {
    weak var owner: Coordinator?
    private var focusedWindowID: ObjectIdentifier?
    private var focusPending = false
    override var acceptsFirstResponder: Bool { owner?.canAct(self) == true }
    override var canBecomeKeyView: Bool { acceptsFirstResponder }
    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      if window == nil { focusedWindowID = nil }
      else { requestInitialFocus() }
    }
    func requestInitialFocus() {
      guard let window, focusedWindowID != ObjectIdentifier(window), !focusPending else { return }
      let expectedWindowID = ObjectIdentifier(window)
      focusPending = true
      DispatchQueue.main.async { [weak self] in
        guard let self else { return }; self.focusPending = false
        guard let window = self.window, ObjectIdentifier(window) == expectedWindowID,
          self.owner?.canAct(self) == true else { return }
        if window.makeFirstResponder(self) { self.focusedWindowID = expectedWindowID }
      }
    }
    override func keyDown(with event: NSEvent) {
      guard owner?.canAct(self) == true else { return }
      guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty else {
        nextResponder?.keyDown(with: event); return
      }
      switch event.keyCode {
      case 123: _ = owner?.step(increasing: false, in: self)
      case 124: _ = owner?.step(increasing: true, in: self)
      case 36, 76: owner?.parent.onComplete()
      default: nextResponder?.keyDown(with: event)
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
      active && parent.enabled && parent.count >= 2 && parent.available() && view.isEnabled
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
