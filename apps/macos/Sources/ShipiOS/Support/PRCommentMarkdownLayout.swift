import AppKit
import Observation
import SwiftUI

@MainActor @Observable final class PRCommentMarkdownLayout {
  private struct Entry { weak var view: NSView?; var lines: [CGRect]; var trailing: CGFloat }
  @ObservationIgnored private var entries: [ObjectIdentifier: Entry] = [:]
  @ObservationIgnored private weak var anchor: NSView?
  @ObservationIgnored private var pending: Task<Void, Never>?
  @ObservationIgnored private var source = ""
  private(set) var previewHeight: CGFloat?
  private(set) var lineCount = 0
  func prepare(_ source: String) {
    guard self.source != source else { return }
    self.source = source; entries.removeAll(); previewHeight = nil; lineCount = 0
  }
  func bind(_ view: NSView) { anchor = view; schedule() }
  func unbind(_ view: NSView) { if anchor === view { anchor = nil; pending?.cancel(); pending = nil } }
  func record(_ view: NSView, lines: [CGRect], trailing: CGFloat, source: String) {
    guard self.source == source else { return }
    entries[ObjectIdentifier(view)] = .init(view: view, lines: lines, trailing: trailing); schedule()
  }
  func remove(_ view: NSView) { entries.removeValue(forKey: ObjectIdentifier(view)); schedule() }
  func schedule() {
    guard pending == nil else { return }
    pending = Task { [weak self] in
      await Task.yield()
      guard !Task.isCancelled, let self else { return }
      self.pending = nil; self.measure()
    }
  }
  private func measure() {
    guard let anchor, anchor.window != nil, anchor.bounds.width > 0 else { return }
    entries = entries.filter { $0.value.view?.window === anchor.window }
    var lines: [(rect: CGRect, trailing: CGFloat)] = []
    for entry in entries.values {
      guard let view = entry.view, view.bounds.width > 0 else { continue }
      for line in entry.lines {
        let native = anchor.convert(line, from: view)
        let top = anchor.isFlipped ? native.minY - anchor.bounds.minY : anchor.bounds.maxY - native.maxY
        guard top.isFinite else { continue }
        lines.append((.init(x: native.minX, y: top, width: native.width, height: native.height), entry.trailing))
      }
    }
    lines.sort { $0.rect.minY == $1.rect.minY ? $0.rect.minX < $1.rect.minX : $0.rect.minY < $1.rect.minY }
    let height = lines.count > 6 ? lines[5].rect.maxY + lines[5].trailing : nil
    if lineCount != lines.count { lineCount = lines.count }
    if let height, let previous = previewHeight, abs(previous - height) < 0.01 { return }
    if previewHeight != height { previewHeight = height }
  }
}

struct PRCommentMarkdownLayoutAnchor: NSViewRepresentable {
  let layout: PRCommentMarkdownLayout
  func makeNSView(context: Context) -> Anchor {
    let view = Anchor(); view.owner = layout; layout.bind(view); return view
  }
  func updateNSView(_ view: Anchor, context: Context) { view.owner = layout; layout.bind(view) }
  static func dismantleNSView(_ view: Anchor, coordinator: ()) { view.owner?.unbind(view); view.owner = nil }
  final class Anchor: NSView {
    weak var owner: PRCommentMarkdownLayout?
    override func layout() { super.layout(); owner?.schedule() }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); owner?.schedule() }
  }
}

struct PRCommentMarkdownText: NSViewRepresentable {
  let text: AttributedString
  let font: NSFont
  let lineHeight: CGFloat
  var weight: NSFont.Weight = .regular
  let source: String
  let layout: PRCommentMarkdownLayout?
  var trailing: CGFloat = 0
  var alignment: NSTextAlignment = .left
  var tabFocus = true
  @Environment(\.appAppearance) private var appearance
  @Environment(\.openURL) private var openURL
  func makeNSView(context: Context) -> TextView {
    let view = TextView(); view.isEditable = false; view.isSelectable = true; view.drawsBackground = false
    view.isRichText = true; view.textContainerInset = .zero; view.textContainer?.lineFragmentPadding = 0
    view.textContainer?.widthTracksTextView = true; view.isVerticallyResizable = true; view.minSize = .zero
    view.maxSize = .init(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
    view.linkTextAttributes = [:]; view.delegate = view; return view
  }
  func updateNSView(_ view: TextView, context: Context) {
    view.useFontSmoothing = appearance.useFontSmoothing
    let content = NSMutableAttributedString(attributedString: LegacyMessageLinkText.attributedText(text, appearance: appearance, size: font.pointSize,
      weight: weight, lineSpacing: 0, fontOverride: font, lineHeight: lineHeight, inlineCodeScale: 0.92)
    )
    content.enumerateAttribute(.paragraphStyle, in: .init(location: 0, length: content.length)) { value, range, _ in
      let paragraph = (value as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
      paragraph.alignment = alignment; content.addAttribute(.paragraphStyle, value: paragraph, range: range)
    }
    let selected = view.selectedRange()
    if view.textStorage?.isEqual(to: content) != true {
      view.textStorage?.setAttributedString(content)
      let start = min(selected.location, content.length)
      view.setSelectedRange(.init(location: start, length: min(selected.length, content.length - start)))
      view.invalidateIntrinsicContentSize()
    }
    view.owner = layout; view.source = source; view.trailing = trailing; view.open = { openURL($0) }; view.tabFocus = tabFocus
    view.needsLayout = true
  }
  func sizeThatFits(_ proposal: ProposedViewSize, nsView: TextView, context: Context) -> CGSize? {
    if proposal.width == 0 { return .zero }
    guard let content = nsView.textStorage else { return nil }
    let width = proposal.width.flatMap { $0.isFinite ? max(1, $0) : nil } ?? 10_000
    let storage = NSTextStorage(attributedString: content), manager = NSLayoutManager()
    let container = NSTextContainer(containerSize: .init(width: width, height: CGFloat.greatestFiniteMagnitude))
    container.lineFragmentPadding = 0; storage.addLayoutManager(manager); manager.addTextContainer(container)
    manager.ensureLayout(for: container)
    let used = manager.usedRect(for: container)
    return .init(width: proposal.width == nil ? used.width : width, height: used.height)
  }
  static func dismantleNSView(_ view: TextView, coordinator: ()) { view.owner?.remove(view); view.owner = nil; view.open = nil }
  final class TextView: AppearanceTextView, NSTextViewDelegate {
    weak var owner: PRCommentMarkdownLayout?
    var source = "", trailing: CGFloat = 0
    var open: ((URL) -> Void)?
    var tabFocus = true
    override var canBecomeKeyView: Bool { tabFocus && super.canBecomeKeyView }
    override func layout() {
      super.layout()
      guard bounds.width > 0, let manager = layoutManager, let container = textContainer else { return }
      manager.ensureLayout(for: container)
      var lines: [CGRect] = []
      manager.enumerateLineFragments(forGlyphRange: .init(location: 0, length: manager.numberOfGlyphs)) { rect, _, _, _, _ in
        lines.append(rect.offsetBy(dx: self.textContainerOrigin.x, dy: self.textContainerOrigin.y))
      }
      owner?.record(self, lines: lines, trailing: trailing, source: source)
    }
    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
      guard let url = link as? URL else { return false }; open?(url); return true
    }
  }
}
