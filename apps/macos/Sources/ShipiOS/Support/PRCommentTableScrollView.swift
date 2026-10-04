import AppKit
import SwiftUI

/// Only the overflow viewport is a keyboard stop; the toolbar owns its separate shortcuts.
struct PRCommentTableScrollView: NSViewRepresentable {
  let block: MessageBlock
  let source: String
  let metrics: PRCommentTableMetrics
  let width: CGFloat
  let target: PRCommentTableScrollTarget
  let measured: (CGSize, CGFloat) -> Void
  @Environment(\.appAppearance) private var appearance
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.openURL) private var openURL
  @Environment(\.prMarkdownImageLoader) private var imageLoader
  @Environment(\.prMarkdownRevision) private var revision
  @Environment(\.isEnabled) private var enabled

  func makeNSView(context: Context) -> Surface { Surface() }
  func updateNSView(_ view: Surface, context: Context) {
    view.enabled = enabled
    view.receive = measured
    view.configure(block: block, source: source, metrics: metrics, width: width, appearance: appearance,
      colorScheme: colorScheme, openURL: openURL, imageLoader: imageLoader, revision: revision)
    target.anchor = view.anchor
  }
  static func dismantleNSView(_ view: Surface, coordinator: ()) { view.retire() }

  final class Surface: NSScrollView {
    let document = NSHostingView<AnyView>(rootView: AnyView(EmptyView()))
    let anchor = NSView()
    var receive: ((CGSize, CGFloat) -> Void)?
    var enabled = true
    private(set) var active = true
    private(set) var overflowing = false
    private var renderedKey = ""
    private var renderedAppearance: AppearancePreferences?
    private var renderedScheme: ColorScheme?
    private var renderedEnabled: Bool?
    private var generation = UUID()
    private var tableSize = CGSize.zero
    private var viewportWidth: CGFloat = 0
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool {
      active && enabled && overflowing && window != nil && !isHiddenOrHasHiddenAncestor
        && window?.attachedSheet == nil && WindowModalInteraction.allows(self)
    }
    override var canBecomeKeyView: Bool { acceptsFirstResponder }
    override func becomeFirstResponder() -> Bool { acceptsFirstResponder }
    override init(frame: NSRect) {
      super.init(frame: frame)
      drawsBackground = false; borderType = .noBorder
      hasHorizontalScroller = true; hasVerticalScroller = false
      autohidesScrollers = true; scrollerStyle = .overlay; horizontalScroller?.controlSize = .small
      document.sizingOptions = []; documentView = document; document.addSubview(anchor)
      setAccessibilityIdentifier("pr-comment-table-scroll")
      setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func configure(block: MessageBlock, source: String, metrics: PRCommentTableMetrics, width: CGFloat,
      appearance: AppearancePreferences, colorScheme: ColorScheme, openURL: OpenURLAction,
      imageLoader: ((String) async throws -> Data)?, revision: String) {
      let width = width.isFinite ? max(0, width) : 0
      let key = block.id + "\n" + block.source + "\n" + source + "\n" + revision + "\n" + String(describing: width)
      guard key != renderedKey || appearance != renderedAppearance || colorScheme != renderedScheme || enabled != renderedEnabled else { return }
      renderedKey = key; renderedAppearance = appearance; renderedScheme = colorScheme; renderedEnabled = enabled
      generation = UUID(); let id = generation; viewportWidth = width
      let plan = metrics.plan(block, width: width)
      tableSize = .init(width: plan.width, height: plan.height)
      document.rootView = AnyView(Content(block: block, source: source, metrics: metrics, width: width) { [weak self] size in
        guard let self, self.active, self.generation == id, size.width.isFinite, size.height.isFinite, size.height > 0 else { return }
        // Geometry preferences run during SwiftUI layout; neither focus nor parent state may mutate there.
        DispatchQueue.main.async { [weak self] in
          guard let self, self.active, self.generation == id else { return }
          self.tableSize = size; self.needsLayout = true
          self.refreshOverflow(); self.receive?(size, width)
        }
      }.environment(\.appAppearance, appearance).environment(\.colorScheme, colorScheme)
        .environment(\.openURL, openURL).environment(\.prMarkdownImageLoader, imageLoader)
        .environment(\.prMarkdownRevision, revision).environment(\.isEnabled, enabled))
      needsLayout = true
      DispatchQueue.main.async { [weak self] in
        guard let self, self.active, self.generation == id else { return }
        self.refreshOverflow()
      }
    }
    override func layout() {
      super.layout()
      document.frame = .init(origin: .zero, size: tableSize)
      anchor.frame = .zero
    }
    private func refreshOverflow() {
      let value = viewportWidth > 0 && tableSize.width > viewportWidth + 0.5
      guard value != overflowing else { return }
      overflowing = value
      setAccessibilityElement(value)
      setAccessibilityRole(value ? .group : nil)
      setAccessibilityLabel(value ? "可滚动表格" : nil)
      if !value {
        // When the region disappears, preserve the page focus without leaving a dead Tab stop.
        if window?.firstResponder === self { window?.selectNextKeyView(self) }
        contentView.scroll(to: .init(x: 0, y: contentView.bounds.minY)); reflectScrolledClipView(contentView)
      }
    }
    @discardableResult func handle(_ event: NSEvent) -> Bool {
      guard acceptsFirstResponder, event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
        [123, 124].contains(event.keyCode) else { return false }
      let clip = contentView, visible = clip.bounds
      clip.scroll(to: .init(x: min(max(0, visible.minX + (event.keyCode == 123 ? -40 : 40)),
        max(0, document.bounds.width - visible.width)), y: visible.minY))
      reflectScrolledClipView(clip); return true
    }
    override func keyDown(with event: NSEvent) {
      if !handle(event) { super.keyDown(with: event) }
    }
    func retire() {
      active = false; generation = UUID(); receive = nil; anchor.removeFromSuperview()
      if window?.firstResponder === self { window?.makeFirstResponder(nil) }
    }
  }
  private struct Content: View {
    let block: MessageBlock
    let source: String
    let metrics: PRCommentTableMetrics
    let width: CGFloat
    let measured: (CGSize) -> Void
    var body: some View {
      PRCommentTableContent(block: block, source: source, metrics: metrics, availableWidth: width)
        .fixedSize(horizontal: false, vertical: true)
        .background { GeometryReader { geometry in Color.clear.preference(key: SizeKey.self, value: geometry.size) } }
        .onPreferenceChange(SizeKey.self, perform: measured)
    }
  }
  private struct SizeKey: PreferenceKey {
    static var defaultValue = CGSize.zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
      let next = nextValue(); if next.height > value.height { value = next }
    }
  }
}
