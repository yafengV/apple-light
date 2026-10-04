import AppKit
import SwiftUI

/// Present on the entire owning window, including independent task windows.
/// This must not create a sheet, panel, or cover only the message row.
struct HookStatsDialogPresenter: NSViewRepresentable {
  @Binding var showing: Bool
  let run: AgentRun
  @Environment(\.appAppearance) private var appearance
  @Environment(\.colorScheme) private var colorScheme

  func makeCoordinator() -> Coordinator { Coordinator(self) }
  func makeNSView(context: Context) -> WindowDialogHost.Anchor {
    let view = WindowDialogHost.Anchor(); view.host = context.coordinator.host; return view
  }
  func updateNSView(_ view: WindowDialogHost.Anchor, context: Context) {
    let owner = context.coordinator; owner.parent = self
    owner.preferences = appearance
    if appearance.theme == "system" { owner.preferences.theme = colorScheme == .dark ? "dark" : "light" }
    owner.host.update(view)
    if let surface = owner.host.surface as? Surface, let stats = run.codexHookStats {
      surface.update(stats: stats, preferences: owner.preferences)
    }
  }
  static func dismantleNSView(_ view: WindowDialogHost.Anchor, coordinator: Coordinator) {
    view.host = nil; coordinator.host.stop()
  }

  @MainActor final class Coordinator {
    var parent: HookStatsDialogPresenter
    var preferences = AppearancePreferences()
    let host = WindowDialogHost()
    init(_ parent: HookStatsDialogPresenter) {
      self.parent = parent
      host.identity = { [weak self] in self?.parent.showing == true ? self?.parent.run.id : nil }
      host.valid = { [weak self] in self?.parent.run.codexHookStats != nil }
      host.canDismiss = { true }
      host.onDismiss = { [weak self] in self?.parent.showing = false }
      host.make = { [weak self] frame in
        guard let self, let stats = self.parent.run.codexHookStats else { return WindowDialogSurface(frame: frame) }
        return Surface(frame: frame, stats: stats, preferences: self.preferences)
      }
      host.key = { [weak self] event in
        guard let surface = self?.host.surface as? Surface else { return false }
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if flags.isEmpty, [36, 49, 76].contains(event.keyCode),
          let button = surface.window?.firstResponder as? NSButton {
          button.performClick(nil); return true
        }
        return false
      }
    }
  }

  final class HistoryScroll: NSScrollView {
    // NSScrollView normally forwards focus to its clip/document view. Keep
    // this explicit tab stop stable for the owning modal focus cycle.
    override func becomeFirstResponder() -> Bool { needsDisplay = true; return true }
    override func resignFirstResponder() -> Bool { needsDisplay = true; return true }
    override var acceptsFirstResponder: Bool { WindowModalInteraction.allows(self) }
    override var canBecomeKeyView: Bool { window != nil && acceptsFirstResponder }
  }
  final class Document: NSView { override var isFlipped: Bool { true } }

  final class RunButton: NSButton {
    var run: CodexHookRun
    var expanded = false
    var preferences = AppearancePreferences()
    var available: () -> Bool = { false }
    var activate: () -> Void = {}
    init(run: CodexHookRun) {
      self.run = run; super.init(frame: .zero)
      isBordered = false; focusRingType = .none; target = self; action = #selector(pressed)
      setAccessibilityIdentifier("hook-history-run-" + run.id)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { available() && WindowModalInteraction.allows(self) }
    override var canBecomeKeyView: Bool { window != nil && acceptsFirstResponder }
    @objc private func pressed() { guard acceptsFirstResponder else { return }; activate() }
    override func accessibilityPerformPress() -> Bool { guard acceptsFirstResponder else { return false }; activate(); return true }
    override func mouseDown(with event: NSEvent) {
      guard acceptsFirstResponder else { return }; window?.makeFirstResponder(self); super.mouseDown(with: event)
    }
    override func becomeFirstResponder() -> Bool { needsDisplay = true; return super.becomeFirstResponder() }
    override func resignFirstResponder() -> Bool { needsDisplay = true; return super.resignFirstResponder() }
    override func draw(_ dirtyRect: NSRect) {
      let roles = preferences.resolvedColors
      if window?.firstResponder === self {
        roles["borderFocus"].nativeColor.setStroke()
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 4, yRadius: 4)
        path.lineWidth = 1.5; path.stroke()
      }
      let secondary = roles["textForegroundSecondary"].nativeColor
      let warning = NSColor.systemOrange
      let font = preferences.nativeFont(size: 13)
      func text(_ text: String, x: CGFloat, width: CGFloat, color: NSColor, size: CGFloat = 13) {
        let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byTruncatingTail
        (text as NSString).draw(in: .init(x: x, y: 9, width: max(0, width), height: 20),
          withAttributes: [.font: size == 13 ? font : preferences.nativeFont(size: size), .foregroundColor: color, .paragraphStyle: paragraph])
      }
      let chevron = NSBezierPath()
      if expanded {
        chevron.move(to: .init(x: 5, y: 16)); chevron.line(to: .init(x: 9, y: 20)); chevron.line(to: .init(x: 13, y: 16))
      } else {
        chevron.move(to: .init(x: 7, y: 13)); chevron.line(to: .init(x: 11, y: 17)); chevron.line(to: .init(x: 7, y: 21))
      }
      chevron.lineWidth = 1.5; chevron.lineCapStyle = .round; chevron.lineJoinStyle = .round
      secondary.setStroke(); chevron.stroke()
      text(run.statusLabel, x: 24, width: 82, color: run.hasWarningStatus ? warning : secondary)
      let badgeWidth = ceil((run.sourceLabel as NSString).size(withAttributes: [.font: preferences.nativeFont(size: 11)]).width) + 12
      let eventWidth = ceil((run.eventTitle as NSString).size(withAttributes: [.font: font]).width)
      let badgeX = min(max(118, bounds.width - badgeWidth - 4), 118 + eventWidth + 8)
      roles["panelBackground"].nativeColor.setFill()
      NSBezierPath(roundedRect: .init(x: badgeX, y: 8, width: badgeWidth, height: 22), xRadius: 4, yRadius: 4).fill()
      text(run.sourceLabel, x: badgeX + 6, width: badgeWidth - 12, color: secondary, size: 11)
      text(run.eventTitle, x: 118, width: badgeX - 126, color: roles["textForeground"].nativeColor)
    }
  }

  final class Row: NSView {
    let button: RunButton
    var fields: [NSTextField] = []
    var run: CodexHookRun { button.run }
    override var isFlipped: Bool { true }
    init(run: CodexHookRun) { button = RunButton(run: run); super.init(frame: .zero); addSubview(button) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func update(run: CodexHookRun, expanded: Bool, preferences: AppearancePreferences) {
      button.run = run; button.expanded = expanded; button.preferences = preferences
      button.setAccessibilityLabel("\(run.statusLabel) · \(run.eventTitle) · \(run.sourceLabel)")
      button.setAccessibilityValue(expanded ? "已展开" : "已折叠")
      fields.forEach { $0.removeFromSuperview() }; fields = []
      guard expanded else { button.needsDisplay = true; return }
      func add(_ text: String, warning: Bool = false, label: Bool = false) {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = preferences.nativeFont(size: label ? 12 : 13)
        field.textColor = warning ? .systemOrange : preferences.resolvedColors[label ? "textForegroundSecondary" : "textForeground"].nativeColor
        field.isSelectable = !label; field.setAccessibilityRole(.staticText)
        field.setAccessibilityLabel(text); addSubview(field); fields.append(field)
      }
      if let message = run.visibleStatusMessage { add(message) }
      for entry in run.visibleEntries {
        add(entry.label, warning: entry.kind == "error", label: true)
        add(entry.text, warning: entry.kind == "error")
      }
      if let fallback = run.fallbackMessage { add(fallback) }
      button.needsDisplay = true
    }
    func measure(width: CGFloat) -> CGFloat {
      button.frame = .init(x: 0, y: 0, width: width, height: 38)
      var y: CGFloat = 38
      for field in fields {
        let height = max(18, ceil(field.cell?.cellSize(forBounds: .init(x: 0, y: 0, width: max(0, width - 24), height: 1_000_000)).height ?? 18))
        field.frame = .init(x: 24, y: y + 4, width: max(0, width - 24), height: height)
        y += height + 8
      }
      return y
    }
  }

  final class Surface: WindowDialogSurface {
    var preferences: AppearancePreferences
    private(set) var stats: CodexHookStats
    let close = PullRequestMergeDialogPresenter.Button(frame: .zero)
    let title = NSTextField(labelWithString: "Hook 统计")
    let countLabels = ["运行次数", "已阻止", "失败"].map { NSTextField(labelWithString: $0) }
    let countValues = (0..<3).map { _ in NSTextField(labelWithString: "0") }
    let heading = NSTextField(labelWithString: "运行历史")
    let scroll = HistoryScroll()
    let document = Document()
    private(set) var rows: [Row] = []
    private(set) var expanded: Set<String> = []
    override var dialogFrame: NSRect {
      let width = min(680, max(0, bounds.width - 32)), height = min(800, bounds.height * 0.92)
      return .init(x: (bounds.width - width) / 2, y: (bounds.height - height) / 2, width: width, height: height)
    }
    override var focusTargets: [NSView] { [close, scroll] + rows.map(\.button) }
    override func retainsContentFocus(_ view: NSView) -> Bool {
      if view.isDescendant(of: document) { return true }
      if let text = view as? NSTextView, text.isFieldEditor, let field = text.delegate as? NSView {
        return field.isDescendant(of: document)
      }
      return false
    }
    init(frame: NSRect, stats: CodexHookStats, preferences: AppearancePreferences) {
      self.stats = stats; self.preferences = preferences; super.init(frame: frame)
      setAccessibilityRole(.group); setAccessibilitySubrole(.dialog); setAccessibilityModal(true)
      setAccessibilityLabel("Hook 统计"); setAccessibilityIdentifier("hook-stats-dialog")
      close.title = "×"; close.setAccessibilityLabel("关闭 Hook 统计")
      close.available = { [weak self] in self?.host?.canAct() == true }
      close.activate = { [weak self] in self?.host?.dismiss() }
      scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
      scroll.documentView = document; scroll.setAccessibilityLabel("运行历史")
      scroll.setAccessibilityIdentifier("hook-run-history")
      ([title, heading, close, scroll] + countLabels + countValues).forEach(addSubview)
      rebuild()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func update(stats: CodexHookStats, preferences: AppearancePreferences) {
      guard self.stats != stats || self.preferences != preferences else { return }
      self.stats = stats; self.preferences = preferences; rebuild()
    }
    func toggle(_ id: String) {
      guard host?.canAct() == true, rows.contains(where: { $0.run.id == id }) else { return }
      if !expanded.insert(id).inserted { expanded.remove(id) }
      rebuild()
    }
    private func rebuild() {
      expanded.formIntersection(Set(stats.runs.map(\.id)))
      let old = Dictionary(rows.map { ($0.run.id, $0) }, uniquingKeysWith: { a, _ in a })
      let ids = Set(stats.runs.map(\.id))
      rows.filter { !ids.contains($0.run.id) }.forEach { $0.removeFromSuperview() }
      rows = stats.runs.map { run in
        let row = old[run.id] ?? Row(run: run)
        if row.superview == nil { document.addSubview(row) }
        row.update(run: run, expanded: expanded.contains(run.id), preferences: preferences)
        row.button.available = { [weak self] in self?.host?.canAct() == true }
        row.button.activate = { [weak self] in self?.toggle(run.id) }
        return row
      }
      for (index, value) in [stats.count, stats.blockedCount, stats.errorCount].enumerated() {
        countValues[index].stringValue = String(value)
        countValues[index].setAccessibilityLabel(countLabels[index].stringValue + " " + String(value))
      }
      title.font = preferences.nativeFont(size: 20)
      for field in countLabels + countValues { field.font = preferences.nativeFont(size: 13) }
      heading.font = preferences.nativeFont(size: 14)
      for field in [title, heading] + countLabels + countValues { field.textColor = preferences.resolvedColors["textForeground"].nativeColor }
      close.preferences = preferences; needsLayout = true; needsDisplay = true
    }
    override func layout() {
      super.layout(); let panel = dialogFrame, inner = max(0, panel.width - 48)
      title.frame = .init(x: panel.minX + 24, y: panel.minY + 24, width: max(0, inner - 32), height: 28)
      close.frame = .init(x: panel.maxX - 48, y: panel.minY + 24, width: 24, height: 24)
      for index in 0..<3 {
        let y = title.frame.maxY + 20 + CGFloat(index * 24)
        countLabels[index].frame = .init(x: panel.minX + 24, y: y, width: max(0, inner - 60), height: 20)
        countValues[index].frame = .init(x: panel.maxX - 72, y: y, width: 48, height: 20)
        countValues[index].alignment = .right
      }
      heading.frame = .init(x: panel.minX + 24, y: title.frame.maxY + 112, width: inner, height: 22)
      scroll.frame = .init(x: panel.minX + 24, y: heading.frame.maxY + 12, width: inner,
        height: max(0, panel.maxY - heading.frame.maxY - 36))
      let width = max(0, scroll.contentSize.width); var y: CGFloat = 0
      for row in rows {
        let height = row.measure(width: width)
        row.frame = .init(x: 0, y: y, width: width, height: height); y += height + 12
      }
      document.frame.size = .init(width: width, height: max(scroll.contentSize.height, y))
    }
    override func draw(_ dirtyRect: NSRect) {
      NSColor.black.withAlphaComponent(0.3).setFill(); bounds.fill()
      let path = NSBezierPath(roundedRect: dialogFrame, xRadius: 20, yRadius: 20)
      preferences.resolvedColors["elevatedSecondary"].nativeColor.setFill(); path.fill()
      preferences.resolvedColors["border"].nativeColor.setStroke(); path.lineWidth = 0.5; path.stroke()
    }
  }
}
