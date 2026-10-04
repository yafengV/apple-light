import AppKit
import SwiftUI

struct PRCommentTableCopyToolbar: NSViewRepresentable {
  let block: MessageBlock
  let hovered: Bool
  let scroll: (CGFloat, Bool) -> Bool
  var write: (PRCommentTableClipboard) -> Bool = { $0.write(to: .general) }
  @Environment(\.appAppearance) private var appearance
  @Environment(\.isEnabled) private var enabled
  func makeNSView(context: Context) -> Surface { Surface() }
  func updateNSView(_ view: Surface, context: Context) {
    view.preferences = appearance; view.tableHovered = hovered
    view.button.preferences = appearance; view.button.isEnabled = enabled; view.button.active = true
    view.button.scroll = scroll; view.button.write = write
    view.button.configure(PRCommentTableClipboard(block: block)); view.refresh()
  }
  func sizeThatFits(_ proposal: ProposedViewSize, nsView: Surface, context: Context) -> CGSize? { .init(width: 40, height: 40) }
  static func dismantleNSView(_ view: Surface, coordinator: ()) { view.button.retire() }

  final class Surface: NSView {
    let button = CopyButton()
    var preferences = AppearancePreferences()
    var tableHovered = false
    override var isFlipped: Bool { true }
    var visible: Bool { tableHovered || window?.firstResponder === button }
    override init(frame: NSRect) { super.init(frame: frame); addSubview(button); button.surface = self }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layout() { super.layout(); button.frame = .init(x: 2, y: 2, width: 36, height: 36) }
    override func hitTest(_ point: NSPoint) -> NSView? { visible && button.active ? super.hitTest(point) : nil }
    func refresh() { needsDisplay = true; button.needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
      guard visible else { return }
      preferences.resolvedColors["surface"].nativeColor.setFill()
      NSBezierPath(roundedRect: bounds, xRadius: 20, yRadius: 20).fill()
    }
  }

  final class CopyButton: NSButton {
    weak var surface: Surface?
    var active = true
    var preferences = AppearancePreferences()
    var scroll: ((CGFloat, Bool) -> Bool)?
    var write: ((PRCommentTableClipboard) -> Bool)?
    private(set) var payload: PRCommentTableClipboard?
    private(set) var copied = false
    private var reset: Task<Void, Never>?
    private var generation = UUID()
    private var tracking: NSTrackingArea?
    private var hovered = false
    private var spaceArmed = false
    override var isFlipped: Bool { true }
    override init(frame: NSRect) {
      super.init(frame: frame); isBordered = false; setButtonType(.momentaryPushIn)
      target = self; action = #selector(pressed); updateLabel()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var acceptsFirstResponder: Bool { active && isEnabled && !isHiddenOrHasHiddenAncestor && WindowModalInteraction.allows(self) }
    override var canBecomeKeyView: Bool { acceptsFirstResponder && window != nil }
    func configure(_ value: PRCommentTableClipboard?) {
      guard payload != value else { return }
      payload = value; reset?.cancel(); reset = nil; generation = UUID(); copied = false; spaceArmed = false; updateLabel()
    }
    @objc private func pressed() {
      guard acceptsFirstResponder, window != nil, !copied, let payload, write?(payload) == true else { return }
      copied = true; updateLabel(); let id = UUID(); generation = id
      reset?.cancel()
      reset = Task { [weak self] in
        try? await Task.sleep(for: .seconds(2))
        guard !Task.isCancelled, let self, self.active, self.generation == id else { return }
        self.copied = false; self.reset = nil; self.updateLabel()
      }
    }
    func retire() { active = false; spaceArmed = false; reset?.cancel(); reset = nil; generation = UUID(); write = nil; scroll = nil; surface?.refresh() }
    private func updateLabel() {
      let label = copied ? "已复制" : "复制表格"
      setAccessibilityLabel(label); toolTip = label; surface?.refresh(); needsDisplay = true
    }
    override func accessibilityPerformPress() -> Bool {
      guard acceptsFirstResponder, window != nil else { return false }; pressed(); return true
    }
    override func becomeFirstResponder() -> Bool { let result = super.becomeFirstResponder(); surface?.refresh(); return result }
    override func resignFirstResponder() -> Bool {
      spaceArmed = false
      let result = super.resignFirstResponder()
      DispatchQueue.main.async { [weak self] in guard let self, self.active else { return }; self.surface?.refresh() }
      return result
    }
    override func keyDown(with event: NSEvent) {
      guard acceptsFirstResponder else { return }
      let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
      if flags.isEmpty, event.keyCode == 49 { if !event.isARepeat { spaceArmed = true }; return }
      if flags.isEmpty, [36, 76].contains(event.keyCode) { if !event.isARepeat { pressed() }; return }
      if [123, 124].contains(event.keyCode), flags.subtracting(.option).isEmpty,
        scroll?(event.keyCode == 123 ? -40 : 40, flags.contains(.option)) == true { return }
      super.keyDown(with: event)
    }
    override func keyUp(with event: NSEvent) {
      if event.keyCode == 49 {
        let armed = spaceArmed; spaceArmed = false
        if armed, event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty { pressed() }
        return
      }
      super.keyUp(with: event)
    }
    override func mouseDown(with event: NSEvent) {
      guard acceptsFirstResponder, surface?.visible == true else { return }
      window?.makeFirstResponder(self); super.mouseDown(with: event)
    }
    override func resetCursorRects() {
      super.resetCursorRects()
      if preferences.usePointerCursors && isEnabled { addCursorRect(bounds, cursor: .pointingHand) }
    }
    override func updateTrackingAreas() {
      super.updateTrackingAreas(); if let tracking { removeTrackingArea(tracking) }
      let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
      addTrackingArea(area); tracking = area
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
      guard surface?.visible == true else { return }
      let roles = preferences.resolvedColors, alpha = isEnabled ? 1.0 : 0.4
      let circle = NSBezierPath(ovalIn: bounds)
      if hovered { roles["buttonSecondaryBackgroundHover"].opacity(alpha).nativeColor.setFill(); circle.fill() }
      roles[copied || hovered ? "textForeground" : "textForegroundTertiary"].opacity(alpha).nativeColor.setStroke()
      let glyph = NSBezierPath(); glyph.lineWidth = 1.5; glyph.lineCapStyle = .round; glyph.lineJoinStyle = .round
      if copied {
        glyph.move(to: .init(x: 11, y: 18)); glyph.line(to: .init(x: 16, y: 23)); glyph.line(to: .init(x: 25, y: 13))
      } else {
        glyph.appendRoundedRect(.init(x: 14, y: 12, width: 12, height: 15), xRadius: 2, yRadius: 2)
        glyph.move(to: .init(x: 11, y: 23)); glyph.line(to: .init(x: 10, y: 23))
        glyph.curve(to: .init(x: 8, y: 21), controlPoint1: .init(x: 8.8, y: 23), controlPoint2: .init(x: 8, y: 22.2))
        glyph.line(to: .init(x: 8, y: 10)); glyph.curve(to: .init(x: 10, y: 8), controlPoint1: .init(x: 8, y: 8.8), controlPoint2: .init(x: 8.8, y: 8))
        glyph.line(to: .init(x: 19, y: 8)); glyph.curve(to: .init(x: 21, y: 10), controlPoint1: .init(x: 20.2, y: 8), controlPoint2: .init(x: 21, y: 8.8))
      }
      glyph.stroke()
      if window?.firstResponder === self { roles["borderFocus"].nativeColor.setStroke(); circle.lineWidth = 2; circle.stroke() }
    }
  }
}

@MainActor final class PRCommentTableScrollTarget {
  weak var anchor: NSView?
  func scroll(_ amount: CGFloat, page: Bool) -> Bool {
    guard let anchor, let scroll = anchor.enclosingScrollView, let document = scroll.documentView else { return false }
    let clip = scroll.contentView, visible = clip.bounds
    guard document.bounds.width > visible.width else { return false }
    let step = page ? (amount < 0 ? -1.0 : 1.0) * visible.width : amount
    clip.scroll(to: .init(x: min(max(0, visible.minX + step), document.bounds.width - visible.width), y: visible.minY))
    scroll.reflectScrolledClipView(clip); return true
  }
}

struct PRCommentTableScrollAnchor: NSViewRepresentable {
  let target: PRCommentTableScrollTarget
  final class Coordinator {
    weak var target: PRCommentTableScrollTarget?
    init(_ target: PRCommentTableScrollTarget) { self.target = target }
  }
  func makeCoordinator() -> Coordinator { .init(target) }
  func makeNSView(context: Context) -> NSView { let v = NSView(); target.anchor = v; return v }
  func updateNSView(_ view: NSView, context: Context) { context.coordinator.target = target; target.anchor = view }
  static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
    if coordinator.target?.anchor === view { coordinator.target?.anchor = nil }
    coordinator.target = nil
  }
}
