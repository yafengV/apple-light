import AppKit
import CoreText
import SwiftUI

/// AppKit owns the draft editor; only blur or Enter writes the SwiftUI binding.
struct AppearanceFontSizeInput: NSViewRepresentable {
  let kind: AppearanceFontSize
  @Binding var value: Double
  @Environment(\.isEnabled) private var enabled
  @Environment(\.appAppearance) private var appearance
  func makeCoordinator() -> Coordinator { Coordinator(self) }
  func makeNSView(context: Context) -> Control {
    let field = Control(); field.owner = context.coordinator; field.delegate = context.coordinator
    field.cell = Cell(textCell: ""); field.isBordered = false; field.drawsBackground = false
    field.cell?.usesSingleLineMode = true; field.cell?.isScrollable = true
    field.focusRingType = .none; field.alignment = .left
    field.setAccessibilityLabel(kind.title); field.setAccessibilityRole(.incrementor)
    return field
  }
  func updateNSView(_ field: Control, context: Context) {
    let owner = context.coordinator; owner.parent = self
    field.isEnabled = enabled; field.isEditable = enabled; field.isSelectable = enabled
    let font = appearance.nativeFont(size: 13)
    field.font = NSFont(descriptor: font.fontDescriptor.addingAttributes([.featureSettings: [[
      NSFontDescriptor.FeatureKey.typeIdentifier: kNumberSpacingType,
      NSFontDescriptor.FeatureKey.selectorIdentifier: kMonospacedNumbersSelector
    ]]]), size: font.pointSize) ?? font
    field.textColor = NSColor(appearance.foregroundColor)
    field.surface = appearance.resolvedColors["controlBackground"].nativeColor
    field.border = appearance.resolvedColors["borderHeavy"].nativeColor
    field.focusBorder = appearance.resolvedColors["borderFocus"].nativeColor; field.needsDisplay = true
    field.setAccessibilityHelp("px；" + AppearanceFontSize.text(kind.range.lowerBound) + "–" + AppearanceFontSize.text(kind.range.upperBound))
    field.setAccessibilityMinValue(NSNumber(value: kind.range.lowerBound))
    field.setAccessibilityMaxValue(NSNumber(value: kind.range.upperBound))
    if owner.lastValue != value {
      owner.lastValue = value; owner.editing = false
      field.stringValue = AppearanceFontSize.text(value)
    }
  }
  static func dismantleNSView(_ field: Control, coordinator: Coordinator) {
    coordinator.active = false; field.active = false; field.cancelArrowHold(); field.owner = nil; field.delegate = nil
  }
  final class Cell: NSTextFieldCell {
    override func drawingRect(forBounds rect: NSRect) -> NSRect {
      let height = ceil(font.map { NSLayoutManager().defaultLineHeight(for: $0) } ?? 16)
      return .init(x: rect.minX + 8, y: rect.midY - height / 2, width: max(0, rect.width - 22), height: height)
    }
    override func edit(withFrame rect: NSRect, in view: NSView, editor: NSText, delegate: Any?, event: NSEvent?) {
      super.edit(withFrame: drawingRect(forBounds: rect), in: view, editor: editor, delegate: delegate, event: event)
    }
    override func select(withFrame rect: NSRect, in view: NSView, editor: NSText, delegate: Any?, start: Int, length: Int) {
      super.select(withFrame: drawingRect(forBounds: rect), in: view, editor: editor, delegate: delegate, start: start, length: length)
    }
  }
  final class Control: NSTextField {
    weak var owner: Coordinator?
    var active = true
    var surface = NSColor.controlBackgroundColor
    var border = NSColor.separatorColor
    var focusBorder = NSColor.keyboardFocusIndicatorColor
    var hovered = false { didSet { needsDisplay = true } }
    var showsArrows: Bool { acceptsFirstResponder && (hovered || currentEditor() != nil) }
    private var hoverArea: NSTrackingArea?
    private var arrowTimer: Timer?
    private(set) var arrowDirection: Int?
    private var requestedEnabled = true
    private var generation = UUID()
    override var isEnabled: Bool {
      get { requestedEnabled }
      set {
        guard requestedEnabled != newValue else { return }; requestedEnabled = newValue
        if !newValue { cancelArrowHold() }
        generation = UUID(); let token = generation
        DispatchQueue.main.async { [weak self] in
          guard let self, self.generation == token else { return }
          if !newValue, self.currentEditor() != nil { self.window?.makeFirstResponder(nil) }
          self.applyEnabled(newValue)
        }
      }
    }
    private func applyEnabled(_ value: Bool) { super.isEnabled = value; needsDisplay = true }
    override var acceptsFirstResponder: Bool { active && isEnabled && !isHiddenOrHasHiddenAncestor && WindowModalInteraction.allows(self) }
    override var canBecomeKeyView: Bool { acceptsFirstResponder && window != nil }
    override var intrinsicContentSize: NSSize { .init(width: 64, height: 28) }
    override var alignmentRectInsets: NSEdgeInsets { .init(top: 0, left: 0, bottom: 0, right: 0) }
    override func draw(_ dirtyRect: NSRect) {
      let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
      surface.withAlphaComponent(surface.alphaComponent * (isEnabled ? 1 : 0.5)).setFill(); path.fill()
      let ink = textColor ?? .labelColor
      (currentEditor() == nil ? border : focusBorder).setStroke(); path.lineWidth = 1; path.stroke()
      super.draw(dirtyRect)
      guard showsArrows else { return }
      for (y, up) in [(bounds.midY + 4, true), (bounds.midY - 4, false)] {
        let chevron = NSBezierPath(); let x = bounds.maxX - 8
        chevron.move(to: .init(x: x - 2, y: y + (up ? -1 : 1)))
        chevron.line(to: .init(x: x, y: y + (up ? 1 : -1)))
        chevron.line(to: .init(x: x + 2, y: y + (up ? -1 : 1)))
        ink.withAlphaComponent(isEnabled ? 0.6 : 0.25).setStroke(); chevron.lineWidth = 1; chevron.stroke()
      }
    }
    override func mouseDown(with event: NSEvent) {
      guard acceptsFirstResponder else { return }
      let point = convert(event.locationInWindow, from: nil)
      if showsArrows, point.x >= bounds.maxX - 14 {
        window?.makeFirstResponder(self)
        beginArrowHold(direction: point.y >= bounds.midY ? 1 : -1)
      } else { super.mouseDown(with: event) }
    }
    override func mouseDragged(with event: NSEvent) {
      guard arrowDirection != nil else { super.mouseDragged(with: event); return }
      arrowDirection = convert(event.locationInWindow, from: nil).y >= bounds.midY ? 1 : -1
    }
    override func mouseUp(with event: NSEvent) {
      guard arrowDirection != nil else { super.mouseUp(with: event); return }
      cancelArrowHold()
    }
    override func scrollWheel(with event: NSEvent) {
      if !handleWheel(deltaY: event.scrollingDeltaY) { super.scrollWheel(with: event) }
    }
    @discardableResult func handleWheel(deltaY: CGFloat) -> Bool {
      guard acceptsFirstResponder, let window,
        window.firstResponder === self || window.firstResponder === currentEditor() else { return false }
      if deltaY != 0 { owner?.step(self, direction: deltaY > 0 ? 1 : -1) }
      return true
    }
    override func viewWillMove(toWindow newWindow: NSWindow?) {
      if newWindow == nil { cancelArrowHold() }
      super.viewWillMove(toWindow: newWindow)
    }
    func beginArrowHold(direction: Int) {
      cancelArrowHold()
      arrowDirection = direction
      owner?.step(self, direction: direction)
      scheduleArrowTimer(after: 0.5, repeats: false) { [weak self] in
        guard let self else { return }
        self.repeatArrowStep()
        self.scheduleArrowTimer(after: 0.05, repeats: true) { [weak self] in self?.repeatArrowStep() }
      }
    }
    func cancelArrowHold() {
      arrowTimer?.invalidate(); arrowTimer = nil; arrowDirection = nil
    }
    private func repeatArrowStep() {
      guard let direction = arrowDirection, acceptsFirstResponder, window != nil else {
        cancelArrowHold(); return
      }
      owner?.step(self, direction: direction)
    }
    private func scheduleArrowTimer(after delay: TimeInterval, repeats: Bool, action: @escaping () -> Void) {
      arrowTimer?.invalidate()
      let timer = Timer(timeInterval: delay, repeats: repeats) { [weak self] timer in
        guard self != nil else { timer.invalidate(); return }
        action()
      }
      arrowTimer = timer
      RunLoop.main.add(timer, forMode: .common)
    }
    override func updateTrackingAreas() {
      super.updateTrackingAreas()
      if let hoverArea { removeTrackingArea(hoverArea) }
      let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
      addTrackingArea(area); hoverArea = area
    }
    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
    override func accessibilityPerformIncrement() -> Bool {
      guard acceptsFirstResponder else { return false }; owner?.step(self, direction: 1); return true
    }
    override func accessibilityPerformDecrement() -> Bool {
      guard acceptsFirstResponder else { return false }; owner?.step(self, direction: -1); return true
    }
  }
  @MainActor final class Coordinator: NSObject, NSTextFieldDelegate {
    var parent: AppearanceFontSizeInput
    var active = true
    var editing = false
    var lastValue: Double?
    init(_ parent: AppearanceFontSizeInput) { self.parent = parent }
    private func canAct(_ field: Control) -> Bool { active && parent.enabled && field.acceptsFirstResponder && field.window != nil }
    func controlTextDidBeginEditing(_ notification: Notification) {
      guard let field = notification.object as? Control, canAct(field) else { return }; editing = true; field.needsDisplay = true
    }
    func controlTextDidChange(_ notification: Notification) {
      guard let field = notification.object as? Control, canAct(field) else { return }; editing = true
    }
    func controlTextDidEndEditing(_ notification: Notification) {
      guard let field = notification.object as? Control else { return }
      field.cancelArrowHold()
      guard editing else { return }
      commit(field); editing = false; field.needsDisplay = true
    }
    func commit(_ field: Control) {
      guard canAct(field), (field.currentEditor() as? NSTextView)?.hasMarkedText() != true else { return }
      let current = parent.value
      let requested = parent.kind.committed(field.currentEditor()?.string ?? field.stringValue, current: current)
      if requested != current { parent.value = requested }
      // Read back the actual value when persistence rejects a binding write.
      lastValue = parent.value; replace(field, text: AppearanceFontSize.text(parent.value))
    }
    func step(_ field: Control, direction: Int) {
      guard canAct(field), (field.currentEditor() as? NSTextView)?.hasMarkedText() != true else { return }
      if field.currentEditor() == nil { field.window?.makeFirstResponder(field) }
      let text = parent.kind.stepped(field.currentEditor()?.string ?? field.stringValue, direction: direction)
      replace(field, text: text); editing = true
    }
    private func replace(_ field: Control, text: String) {
      field.stringValue = text
      if let editor = field.currentEditor() as? NSTextView {
        editor.string = text; editor.setSelectedRange(.init(location: text.utf16.count, length: 0))
      }
    }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
      guard let field = control as? Control, canAct(field), !textView.hasMarkedText() else { return false }
      switch selector {
      case #selector(NSResponder.insertNewline(_:)): commit(field)
      case #selector(NSResponder.moveUp(_:)): step(field, direction: 1)
      case #selector(NSResponder.moveDown(_:)): step(field, direction: -1)
      case #selector(NSResponder.cancelOperation(_:)): break // Editing Esc must not close settings.
      default: return false
      }
      return true
    }
  }
}
