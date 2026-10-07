import AppKit
import SwiftUI

struct AppearanceDockIconPicker: NSViewRepresentable {
  @Bindable var store: WorkspaceStore
  @Environment(\.isEnabled) private var enabled
  @Environment(\.appAppearance) private var appearance
  func makeCoordinator() -> Coordinator { Coordinator(self) }
  func makeNSView(context: Context) -> Group {
    let group = Group(); group.owner = context.coordinator
    return group
  }
  func updateNSView(_ group: Group, context: Context) {
    context.coordinator.parent = self
    group.selected = store.appearance.dockIcon
    group.available = enabled && store.libraryLoaded && !store.restoringLibrary
    group.colors = appearance.resolvedColors
    group.refresh()
  }
  func sizeThatFits(_ proposal: ProposedViewSize, nsView: Group, context: Context) -> CGSize? { .init(width: 104, height: 48) }
  static func dismantleNSView(_ group: Group, coordinator: Coordinator) { coordinator.active = false; group.owner = nil }

  final class Group: NSView {
    weak var owner: Coordinator?
    var selected = DockIconPreference.appDefault
    var available = false
    var colors = AppearancePreferences().resolvedColors
    let radios = DockIconPreference.allCases.map { Radio(preference: $0) }
    override var wantsDefaultClipping: Bool { false }
    override init(frame: NSRect) {
      super.init(frame: frame)
      setAccessibilityElement(true); setAccessibilityRole(.radioGroup); setAccessibilityLabel("Dock 图标")
      radios.forEach { addSubview($0) }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layout() {
      super.layout()
      for (index, radio) in radios.enumerated() { radio.frame = .init(x: CGFloat(index) * 56, y: 0, width: 48, height: 48) }
    }
    func refresh() {
      for radio in radios {
        radio.isEnabled = available
        let next = NSNumber(value: radio.preference == selected ? 1 : 0)
        let old = radio.accessibilityValue() as? NSNumber
        radio.setAccessibilityValue(next); radio.needsDisplay = true
        if let old, old != next { NSAccessibility.post(element: radio, notification: .valueChanged) }
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
    let preference: DockIconPreference
    private var hovered = false
    private var tracking: NSTrackingArea?
    var group: Group? { superview as? Group }
    override var acceptsFirstResponder: Bool { guard let group else { return false }; return isEnabled && group.owner?.canAct(group) == true }
    override var canBecomeKeyView: Bool { acceptsFirstResponder && group?.selected == preference }
    override var wantsDefaultClipping: Bool { false }
    init(preference: DockIconPreference) {
      self.preference = preference; super.init(frame: .zero)
      setAccessibilityElement(true); setAccessibilityRole(.radioButton); setAccessibilityLabel(preference.title)
      toolTip = preference.title
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func updateTrackingAreas() {
      super.updateTrackingAreas(); if let tracking { removeTrackingArea(tracking) }
      let next = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self)
      addTrackingArea(next); tracking = next
    }
    override func mouseEntered(with event: NSEvent) { hovered = isEnabled; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
    override func becomeFirstResponder() -> Bool { let result = super.becomeFirstResponder(); needsDisplay = true; return result }
    override func resignFirstResponder() -> Bool { let result = super.resignFirstResponder(); needsDisplay = true; return result }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
      guard let group else { return }
      NSGraphicsContext.saveGraphicsState()
      if !isEnabled { NSGraphicsContext.current?.cgContext.setAlpha(0.5) }
      let selected = preference == group.selected
      let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 12, yRadius: 12)
      group.colors["surface"].nativeColor.setFill(); shape.fill()
      if selected { group.colors["buttonSecondaryBackgroundHover"].nativeColor.setFill(); shape.fill() }
      group.colors[selected ? "textForeground" : hovered ? "borderHeavy" : "border"].nativeColor.setStroke(); shape.lineWidth = 1; shape.stroke()
      let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
      DockIconArtwork.image(preference, dark: dark).draw(in: bounds.insetBy(dx: 4, dy: 4))
      NSGraphicsContext.restoreGraphicsState()
      if window?.firstResponder === self {
        group.colors["borderFocus"].nativeColor.setStroke()
        let focus = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 12, yRadius: 12)
        focus.lineWidth = 2; focus.stroke()
      }
    }
    override func resetCursorRects() {
      if isEnabled && group?.owner?.parent.store.appearance.usePointerCursors == true { addCursorRect(bounds, cursor: .pointingHand) }
    }
    override func mouseDown(with event: NSEvent) { _ = choose(preference) }
    override func keyDown(with event: NSEvent) {
      guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { super.keyDown(with: event); return }
      switch event.keyCode {
      case 123, 126: _ = choose(preference.moved(by: -1))
      case 124, 125: _ = choose(preference.moved(by: 1))
      case 49: _ = choose(preference)
      default: super.keyDown(with: event)
      }
    }
    private func choose(_ preference: DockIconPreference) -> Bool { guard let group else { return false }; return group.owner?.choose(preference, in: group) ?? false }
    override func accessibilityPerformPress() -> Bool { choose(preference) }
  }
  @MainActor final class Coordinator {
    var parent: AppearanceDockIconPicker; var active = true
    init(_ parent: AppearanceDockIconPicker) { self.parent = parent }
    func canAct(_ group: Group) -> Bool {
      active && parent.enabled && parent.store.libraryLoaded && !parent.store.restoringLibrary && group.available
        && !parent.store.hasSettingsConfirmation && group.window != nil && !group.isHiddenOrHasHiddenAncestor
        && group.window?.attachedSheet == nil && WindowModalInteraction.allows(group)
    }
    func choose(_ preference: DockIconPreference, in group: Group) -> Bool {
      guard canAct(group) else { return false }
      group.window?.makeFirstResponder(group.radios.first { $0.preference == preference })
      var next = parent.store.appearance; next.dockIcon = preference
      let saved = parent.store.commitAppearance(next)
      group.selected = parent.store.appearance.dockIcon; group.refresh()
      return saved
    }
  }
}
