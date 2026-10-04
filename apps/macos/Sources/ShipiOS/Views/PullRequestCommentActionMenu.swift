import AppKit
import SwiftUI

struct PullRequestCommentActionMenu: View {
  let options: [PullRequestCommentMenuAction]
  let enabled: Bool
  let select: (PullRequestCommentMenuAction) -> Bool
  @State private var menu: PullRequestCommentMenuState
  @Environment(\.appAppearance) private var appearance
  init(options: [PullRequestCommentMenuAction], enabled: Bool, select: @escaping (PullRequestCommentMenuAction) -> Bool) {
    self.options = options; self.enabled = enabled; self.select = select
    _menu = State(initialValue: .init(options: options))
  }
  var body: some View {
    SettingsPopupMenuButton(title: "", label: "评论操作", menu: menu, buttonWidth: 24, menuWidth: 160,
      icon: { PullRequestCommentMenuArtwork.draw("ellipsis", in: $0, color: $1, flipped: $2) },
      dismissOnWindowBlur: false, focusTriggerBeforeSelection: true, restoreFocusAfterSelection: false,
      commentMenuShadow: true,
      menuHeight: { 8 + CGFloat(menu.options.count) * PullRequestCommentMenuSurface.rowHeight(appearance.nativeFont(size: 13)) },
      available: enabled && !options.isEmpty, open: { menu.open(keyboard: $0) }, choose: { id in
        guard enabled, let action = PullRequestCommentMenuAction(rawValue: id), options.contains(action) else { return false }
        return select(action)
      }, content: { choose in AnyView(PullRequestCommentMenuContent(menu: menu, enabled: enabled, choose: choose)) })
      .frame(width: 24, height: 24).disabled(!enabled)
      .onChange(of: options) { _, value in menu.configure(value) }
      .onDisappear { menu.dismiss() }
  }
}

private struct PullRequestCommentMenuContent: View {
  let menu: PullRequestCommentMenuState
  let enabled: Bool
  let choose: (String) -> Void
  @Environment(\.appAppearance) private var appearance
  var body: some View {
    GeometryReader { geometry in
      PullRequestCommentMenuSurface(options: menu.options, highlighted: menu.highlightedID,
        enabled: enabled && menu.presented, appearance: appearance, hover: menu.hover, choose: choose)
        .frame(width: geometry.size.width, height: geometry.size.height)
    }
  }
}

struct PullRequestCommentMenuSurface: NSViewRepresentable {
  let options: [PullRequestCommentMenuAction]
  let highlighted: String?
  let enabled: Bool
  let appearance: AppearancePreferences
  let hover: (String?) -> Void
  let choose: (String) -> Void
  static func rowHeight(_ font: NSFont) -> CGFloat { max(16, font.pointSize * 10 / 7) + 10 }
  func sizeThatFits(_ proposal: ProposedViewSize, nsView: Surface, context: Context) -> CGSize? {
    // Keep the native scroll viewport finite for unspecified or unbounded proposals.
    let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? 160
    let height = proposal.height.flatMap { $0.isFinite ? $0 : nil }
      ?? 8 + CGFloat(options.count) * Self.rowHeight(appearance.nativeFont(size: 13))
    return .init(width: max(0, width), height: max(0, height))
  }
  func makeNSView(context: Context) -> Surface { Surface() }
  func updateNSView(_ view: Surface, context: Context) {
    view.configure(options, highlighted: highlighted, enabled: enabled, appearance: appearance, hover: hover, choose: choose)
  }
  static func dismantleNSView(_ view: Surface, coordinator: ()) { view.deactivate() }

  final class Surface: NSVisualEffectView {
    let scroll = NSScrollView()
    let document = Document()
    private(set) var rows: [Row] = []
    var rowHeight: CGFloat = 28.5714285714
    var surface = NSColor.windowBackgroundColor, border = NSColor.separatorColor
    override var isFlipped: Bool { true }
    override var allowsVibrancy: Bool { false }
    override init(frame frameRect: NSRect) {
      super.init(frame: frameRect)
      material = .popover; blendingMode = .withinWindow; state = .active
      wantsLayer = true; layer?.cornerRadius = 16; layer?.masksToBounds = true
      scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
      scroll.documentView = document; addSubview(scroll)
      setAccessibilityRole(.menu); setAccessibilityLabel("评论操作")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func configure(_ options: [PullRequestCommentMenuAction], highlighted: String?, enabled: Bool,
      appearance: AppearancePreferences, hover: @escaping (String?) -> Void, choose: @escaping (String) -> Void) {
      let font = appearance.nativeFont(size: 13); rowHeight = PullRequestCommentMenuSurface.rowHeight(font)
      surface = appearance.resolvedColors["controlBackgroundOpaque"].opacity(0.9).nativeColor
      border = appearance.resolvedColors["border"].nativeColor
      if rows.map(\.item) != options {
        deactivate(); rows = options.map { Row($0) }; rows.forEach { document.addSubview($0) }
      }
      for row in rows {
        row.active = true; row.isEnabled = enabled; row.font = font
        row.foreground = row.item == .delete ? .systemRed : appearance.resolvedColors["textForeground"].nativeColor
        row.hoverSurface = appearance.resolvedColors["buttonSecondaryBackgroundHover"].nativeColor
        row.menuHighlighted = row.item.id == highlighted
        let id = row.item.id
        row.hover = { hover($0 ? id : nil) }
        row.activate = { choose(id) }; row.needsDisplay = true
      }
      needsLayout = true; layoutSubtreeIfNeeded(); needsDisplay = true
      if let row = rows.first(where: \.menuHighlighted), enabled, WindowModalInteraction.allows(row) {
        row.scrollToVisible(row.bounds)
        if window?.firstResponder !== row { window?.makeFirstResponder(row) }
      }
    }
    func deactivate() {
      rows.forEach { $0.active = false; $0.activate = nil; $0.hover = nil; $0.removeFromSuperview() }; rows = []
    }
    override func layout() {
      super.layout()
      // SwiftUI first configures the representable at zero size. CGRect.insetBy
      // produces .null below eight points, which would become huge origin
      // constants when AppKit converts the scroll view's autoresizing mask.
      let insetX = min(4, max(0, bounds.width) / 2)
      let insetY = min(4, max(0, bounds.height) / 2)
      scroll.frame = .init(x: bounds.minX + insetX, y: bounds.minY + insetY,
        width: max(0, bounds.width - 8), height: max(0, bounds.height - 8))
      document.frame = .init(x: 0, y: 0, width: scroll.contentSize.width, height: CGFloat(rows.count) * rowHeight)
      for (index, row) in rows.enumerated() { row.frame = .init(x: 0, y: CGFloat(index) * rowHeight, width: document.bounds.width, height: rowHeight) }
    }
    override func draw(_ dirtyRect: NSRect) {
      super.draw(dirtyRect)
      let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 16, yRadius: 16)
      surface.setFill(); path.fill(); border.setStroke(); path.lineWidth = 0.5; path.stroke()
    }
  }
  final class Document: NSView { override var isFlipped: Bool { true } }
  final class Row: NSButton {
    let item: PullRequestCommentMenuAction
    var active = true, menuHighlighted = false
    var foreground = NSColor.labelColor, hoverSurface = NSColor.controlBackgroundColor
    var activate: (() -> Void)?, hover: ((Bool) -> Void)?
    private var hoverArea: NSTrackingArea?
    override var isFlipped: Bool { true }
    override var allowsVibrancy: Bool { false }
    init(_ item: PullRequestCommentMenuAction) {
      self.item = item; super.init(frame: .zero)
      title = item.title; isBordered = false; focusRingType = .none; target = self; action = #selector(selectItem)
      setAccessibilityRole(.menuItem); setAccessibilityLabel(item.title)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var acceptsFirstResponder: Bool { active && isEnabled && !isHiddenOrHasHiddenAncestor && WindowModalInteraction.allows(self) }
    override var canBecomeKeyView: Bool { acceptsFirstResponder && window != nil }
    @objc private func selectItem() { guard acceptsFirstResponder, window != nil else { return }; activate?() }
    override func accessibilityPerformPress() -> Bool {
      guard acceptsFirstResponder, window != nil else { return false }; selectItem(); return true
    }
    override func mouseDown(with event: NSEvent) {
      guard acceptsFirstResponder else { return }; window?.makeFirstResponder(self); super.mouseDown(with: event)
    }
    override func mouseEntered(with event: NSEvent) { guard acceptsFirstResponder else { return }; hover?(true) }
    override func mouseExited(with event: NSEvent) { if active { hover?(false) } }
    override func updateTrackingAreas() {
      super.updateTrackingAreas(); if let hoverArea { removeTrackingArea(hoverArea) }
      let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
      addTrackingArea(area); hoverArea = area
    }
    override func draw(_ dirtyRect: NSRect) {
      if menuHighlighted { hoverSurface.setFill(); NSBezierPath(roundedRect: bounds, xRadius: 12, yRadius: 12).fill() }
      let color = foreground.withAlphaComponent(isEnabled ? 1 : 0.5)
      PullRequestCommentMenuArtwork.draw(item.id, in: .init(x: 8, y: bounds.midY - 8, width: 16, height: 16),
        color: color.withAlphaComponent((menuHighlighted ? 1 : 0.75) * color.alphaComponent), flipped: true)
      let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byTruncatingTail
      let text = NSAttributedString(string: title, attributes: [.font: font ?? .systemFont(ofSize: 13),
        .foregroundColor: color, .paragraphStyle: paragraph])
      text.draw(in: .init(x: 30, y: (bounds.height - text.size().height) / 2, width: max(0, bounds.width - 38), height: text.size().height))
    }
  }
}
