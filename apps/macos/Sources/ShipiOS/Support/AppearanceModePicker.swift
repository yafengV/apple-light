import AppKit
import SwiftUI

struct AppearanceModePicker: NSViewRepresentable {
  @Bindable var store: WorkspaceStore
  @Environment(\.isEnabled) private var enabled
  @Environment(\.appAppearance) private var appearance
  @Environment(\.colorScheme) private var scheme
  private var displayAppearance: AppearancePreferences {
    var value = appearance; if value.theme == "system" { value.theme = scheme == .dark ? "dark" : "light" }; return value
  }
  func makeCoordinator() -> Coordinator { Coordinator(self) }
  func makeNSView(context: Context) -> Group {
    let group = Group(); group.owner = context.coordinator
    group.setAccessibilityRole(.radioGroup); group.setAccessibilityLabel("主题")
    return group
  }
  func updateNSView(_ group: Group, context: Context) {
    context.coordinator.parent = self
    group.selected = AppearanceMode(preference: store.appearance.theme)
    group.available = enabled && store.libraryLoaded && !store.restoringLibrary
    group.colors = displayAppearance.resolvedColors
    group.refresh()
  }
  func sizeThatFits(_ proposal: ProposedViewSize, nsView: Group, context: Context) -> CGSize? {
    let width = min(272, max(0, proposal.width ?? 272))
    return .init(width: width, height: max(0, width - 32) / 3 * 3 / 4)
  }
  static func dismantleNSView(_ group: Group, coordinator: Coordinator) { coordinator.active = false; group.owner = nil }

  final class Group: NSView {
    weak var owner: Coordinator?
    var selected = AppearanceMode.system
    var available = false
    var colors = AppearancePreferences().resolvedColors
    let radios = AppearanceMode.allCases.map { Radio(mode: $0) }
    override var isFlipped: Bool { true }
    override var wantsDefaultClipping: Bool { false }
    override init(frame: NSRect) { super.init(frame: frame); radios.forEach { addSubview($0) }; setAccessibilityElement(true) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layout() {
      super.layout(); let width = max(0, min(272, bounds.width) - 32) / 3
      for (index, radio) in radios.enumerated() { radio.frame = .init(x: CGFloat(index) * (width + 16), y: 0, width: width, height: bounds.height) }
    }
    func refresh() {
      for radio in radios {
        radio.isEnabled = available
        let value = NSNumber(value: radio.mode == selected ? 1 : 0)
        let previous = radio.accessibilityValue() as? NSNumber
        radio.setAccessibilityValue(value); radio.needsDisplay = true
        if let previous, previous != value { NSAccessibility.post(element: radio, notification: .valueChanged) }
      }
      if !available, let focused = window?.firstResponder as? Radio, focused.superview === self {
        DispatchQueue.main.async { [weak self, weak focused] in
          guard let self, let focused, !self.available, self.window?.firstResponder === focused else { return }
          self.window?.makeFirstResponder(nil)
        }
      }
    }
  }
  final class Radio: NSControl {
    let mode: AppearanceMode
    private var hovered = false
    private var tracking: NSTrackingArea?
    var group: Group? { superview as? Group }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { guard let group else { return false }; return isEnabled && group.owner?.canAct(group) == true }
    // A native radio group is a single Tab stop. Arrow keys visit its other radios.
    override var canBecomeKeyView: Bool { acceptsFirstResponder && group?.selected == mode }
    init(mode: AppearanceMode) {
      self.mode = mode; super.init(frame: .zero)
      // A custom NSControl is ignored by AppKit until explicitly exposed.
      setAccessibilityElement(true)
      setAccessibilityRole(.radioButton); setAccessibilityLabel(mode.title)
      toolTip = mode.title
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func updateTrackingAreas() {
      super.updateTrackingAreas(); if let tracking { removeTrackingArea(tracking) }
      let next = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self)
      addTrackingArea(next); tracking = next
    }
    override func mouseEntered(with event: NSEvent) { hovered = isEnabled; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
    override func resetCursorRects() {
      if isEnabled && group?.owner?.parent.store.appearance.usePointerCursors == true { addCursorRect(bounds, cursor: .pointingHand) }
    }
    override func becomeFirstResponder() -> Bool { let ok = super.becomeFirstResponder(); invalidateFocusOutline(); return ok }
    override func resignFirstResponder() -> Bool { let ok = super.resignFirstResponder(); invalidateFocusOutline(); return ok }
    private func invalidateFocusOutline() {
      needsDisplay = true
      superview?.setNeedsDisplay(convert(bounds.insetBy(dx: -4, dy: -4), to: superview))
    }
    override var wantsDefaultClipping: Bool { false }
    var cardRect: NSRect { .init(x: 0, y: 0, width: bounds.width, height: bounds.width * 3 / 4) }
    override func draw(_ dirtyRect: NSRect) {
      guard let group else { return }
      NSGraphicsContext.saveGraphicsState()
      if !isEnabled { NSGraphicsContext.current?.cgContext.setAlpha(0.5) }
      let rect = cardRect, clip = NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8)
      clip.addClip(); AppearanceModeArtwork.draw(mode, in: rect, accent: group.colors["textAccent"])
      let selected = group.selected == mode
      (selected ? group.colors["borderFocus"] : group.colors[hovered ? "borderHeavy" : "border"]).nativeColor.setStroke()
      let border = NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: 8, yRadius: 8)
      border.lineWidth = 2; border.stroke()
      NSGraphicsContext.restoreGraphicsState()
      if window?.firstResponder === self {
        group.colors["borderFocus"].nativeColor.setStroke(); let focus = NSBezierPath(roundedRect: rect.insetBy(dx: -3, dy: -3), xRadius: 10, yRadius: 10)
        focus.lineWidth = 2; focus.stroke()
      }
    }
    override func mouseDown(with event: NSEvent) { choose(mode) }
    override func keyDown(with event: NSEvent) {
      guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { super.keyDown(with: event); return }
      switch event.keyCode {
      case 123, 126: choose(mode.moved(by: -1))
      case 124, 125: choose(mode.moved(by: 1))
      case 49: choose(mode)
      default: super.keyDown(with: event)
      }
    }
    @discardableResult private func choose(_ mode: AppearanceMode) -> Bool {
      guard let group else { return false }; return group.owner?.choose(mode, in: group) ?? false
    }
    override func accessibilityPerformPress() -> Bool { choose(mode) }
  }
  @MainActor final class Coordinator {
    var parent: AppearanceModePicker; var active = true
    init(_ parent: AppearanceModePicker) { self.parent = parent }
    func canAct(_ group: Group) -> Bool {
      active && parent.enabled && parent.store.libraryLoaded && !parent.store.restoringLibrary && group.available
        && group.window != nil && !group.isHiddenOrHasHiddenAncestor && group.window?.attachedSheet == nil
        && WindowModalInteraction.allows(group)
    }
    @discardableResult func choose(_ mode: AppearanceMode, in group: Group) -> Bool {
      guard canAct(group) else { return false }
      group.window?.makeFirstResponder(group.radios.first { $0.mode == mode })
      if parent.store.appearance.theme != mode.rawValue {
        var next = parent.store.appearance; next.theme = mode.rawValue; _ = parent.store.commitAppearance(next)
      }
      group.selected = AppearanceMode(preference: parent.store.appearance.theme); group.refresh(); return true
    }
  }
}
