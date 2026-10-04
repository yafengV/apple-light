import AppKit
import SwiftUI

/// Table previews share the image dialog's full-window backdrop and close
/// control, without its image, download, zoom or gallery actions.
struct PRCommentTablePreviewPresenter: NSViewRepresentable {
  let block: MessageBlock
  let source: String
  @Binding var open: Bool
  @Environment(\.appAppearance) private var appearance
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.openURL) private var openURL
  @Environment(\.prMarkdownImageLoader) private var imageLoader
  @Environment(\.prMarkdownRevision) private var revision

  func makeCoordinator() -> Coordinator { Coordinator(self) }
  func makeNSView(context: Context) -> WindowDialogHost.Anchor {
    let anchor = WindowDialogHost.Anchor(); anchor.host = context.coordinator.host; return anchor
  }
  func updateNSView(_ anchor: WindowDialogHost.Anchor, context: Context) {
    let owner = context.coordinator; owner.parent = self
    var resolved = appearance
    if resolved.theme == "system" { resolved.theme = colorScheme == .dark ? "dark" : "light" }
    owner.preferences = resolved
    owner.update(anchor)
  }
  static func dismantleNSView(_ anchor: WindowDialogHost.Anchor, coordinator: Coordinator) {
    anchor.host = nil; coordinator.host.stop()
  }
  @MainActor final class Coordinator {
    var parent: PRCommentTablePreviewPresenter
    var preferences = AppearancePreferences()
    let host = WindowDialogHost()
    private var showing: Bool
    private var blockID: String
    init(_ parent: PRCommentTablePreviewPresenter) {
      self.parent = parent; showing = parent.open; blockID = parent.block.id
      host.identity = { [weak self] in guard let self, self.showing else { return nil }; return "table:" + self.blockID }
      host.valid = { [weak self] in self?.showing == true }
      host.canDismiss = { true }
      host.onDismiss = { [weak self] in self?.showing = false; self?.parent.open = false }
      host.make = { [weak self] frame in
        let surface = Surface(frame: frame)
        surface.close.available = { [weak self, weak surface] in self?.host.canAct() == true && self?.host.surface === surface }
        surface.close.activate = { [weak self] in self?.host.dismiss() }
        self?.configure(surface); return surface
      }
    }
    func update(_ anchor: WindowDialogHost.Anchor) {
      showing = parent.open && parent.block.kind == .table; blockID = parent.block.id
      host.update(anchor)
      if let surface = host.surface as? Surface { configure(surface) }
    }
    func configure(_ surface: Surface) {
      surface.configure(block: parent.block, source: parent.source, appearance: preferences,
        openURL: parent.openURL, imageLoader: parent.imageLoader, revision: parent.revision)
    }
  }

  final class ScrollView: NSScrollView {
    override var acceptsFirstResponder: Bool { window != nil && WindowModalInteraction.allows(self) }
    override var canBecomeKeyView: Bool { acceptsFirstResponder }
    override func becomeFirstResponder() -> Bool { acceptsFirstResponder }
    override func resignFirstResponder() -> Bool { true }
    override func keyDown(with event: NSEvent) {
      guard acceptsFirstResponder else { return }
      let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
      guard flags.isEmpty || flags == .shift && event.keyCode == 49, let document = documentView else { super.keyDown(with: event); return }
      let clip = contentView, visible = clip.bounds
      var point = visible.origin
      switch event.keyCode {
      case 123: point.x -= 40
      case 124: point.x += 40
      case 125: point.y += 40
      case 126: point.y -= 40
      case 116: point.y -= visible.height
      case 121: point.y += visible.height
      case 115: point.y = 0
      case 119: point.y = document.bounds.height
      case 49: point.y += flags == .shift ? -visible.height : visible.height
      default: super.keyDown(with: event); return
      }
      point.x = min(max(0, point.x), max(0, document.bounds.width - visible.width))
      point.y = min(max(0, point.y), max(0, document.bounds.height - visible.height))
      clip.scroll(to: point); reflectScrolledClipView(clip)
    }
  }
  final class Surface: WindowDialogSurface {
    let close = PRCommentTableCopyToolbar.CopyButton()
    let scroll = ScrollView()
    let edges = EdgeCover()
    let document = NSHostingView<AnyView>(rootView: AnyView(EmptyView()))
    private(set) var cardFrame: NSRect = .zero
    private(set) var tableSize = CGSize.zero
    private var preferences = AppearancePreferences()
    private var renderedKey = ""
    private var renderedAppearance: AppearancePreferences?
    private var generation = UUID()
    override var dialogFrame: NSRect { cardFrame }
    override var focusTargets: [NSView] { [close, scroll].filter { $0.acceptsFirstResponder } }
    override var initialFocus: NSView? { close }
    override func retainsContentFocus(_ view: NSView) -> Bool {
      guard view.isDescendant(of: self), !view.isHiddenOrHasHiddenAncestor else { return false }
      return (view as? NSTextView).map { $0.isSelectable && !$0.isEditable } == true
    }
    override init(frame: NSRect) {
      super.init(frame: frame)
      setAccessibilityRole(.group); setAccessibilitySubrole(.dialog); setAccessibilityModal(true)
      setAccessibilityLabel("表格预览"); setAccessibilityIdentifier("pr-comment-table-preview")
      close.mode = .close; close.alwaysVisible = true; close.focusRingType = .none
      scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true
      scroll.autohidesScrollers = true; scroll.scrollerStyle = .overlay; scroll.horizontalScroller?.controlSize = .small
      scroll.verticalScroller?.controlSize = .small
      scroll.setAccessibilityRole(.group); scroll.setAccessibilityLabel("可滚动表格")
      document.sizingOptions = []; scroll.documentView = document
      addSubview(scroll); addSubview(edges); addSubview(close)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func configure(block: MessageBlock, source: String, appearance: AppearancePreferences, openURL: OpenURLAction, imageLoader: ((String) async throws -> Data)?, revision: String) {
      self.preferences = appearance; close.preferences = appearance; edges.color = appearance.resolvedColors["elevatedSecondaryOpaque"].nativeColor
      let key = block.id + "\n" + block.source + "\n" + source + "\n" + revision
      guard key != renderedKey || renderedAppearance != appearance else { needsDisplay = true; return }
      renderedKey = key; renderedAppearance = appearance; generation = UUID(); let id = generation
      let metrics = PRCommentTableMetrics(appearance: appearance, baseSize: CGFloat(appearance.uiSize),
        tabularDigits: false, preferredLimit: .greatestFiniteMagnitude)
      let plan = metrics.plan(block, width: nil); tableSize = .init(width: plan.width, height: plan.height)
      document.rootView = AnyView(PreviewContent(block: block, source: source, metrics: metrics, width: plan.width) { [weak self] height in
        guard let self, self.active, self.generation == id, height.isFinite, height > 0, abs(self.tableSize.height - height) > 0.1 else { return }
        DispatchQueue.main.async { [weak self] in
          guard let self, self.active, self.generation == id else { return }
          self.tableSize.height = height; self.needsLayout = true
        }
      }.environment(\.appAppearance, appearance).environment(\.openURL, openURL).environment(\.prMarkdownImageLoader, imageLoader).environment(\.prMarkdownRevision, revision))
      needsLayout = true; needsDisplay = true
    }
    override func layout() {
      super.layout()
      let side: CGFloat = bounds.width >= 640 ? 32 : 16
      let area = NSRect(x: side, y: 48, width: max(0, bounds.width - side * 2), height: max(0, bounds.height - 100))
      // 32 padding + 1 border on each side; 8-pixel sticky edge surfaces
      // cover content touching the viewport's bottom and trailing edge.
      let width = min(area.width * 0.8, tableSize.width + 74), height = min(area.height, tableSize.height + 74)
      cardFrame = .init(x: area.midX - width / 2, y: area.midY - height / 2, width: width, height: height)
      scroll.frame = .init(x: cardFrame.minX + 33, y: cardFrame.minY + 33, width: max(0, width - 66), height: max(0, height - 66))
      document.frame = .init(origin: .zero, size: .init(width: tableSize.width + 8, height: tableSize.height + 8))
      edges.frame = scroll.frame; edges.isHidden = scroll.isHidden
      close.frame = .init(x: max(0, bounds.width - 52), y: 12, width: 40, height: 40)
      scroll.isHidden = width <= 66 || height <= 66; edges.isHidden = scroll.isHidden; needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) {
      NSColor.black.withAlphaComponent(0.9).setFill(); bounds.fill()
      guard cardFrame.width > 0, cardFrame.height > 0 else { return }
      let path = NSBezierPath(cgPath: PRCommentMediaCornerShape(radius: 20).cgPath(in: cardFrame))
      NSGraphicsContext.saveGraphicsState()
      let shadow = NSShadow(); shadow.shadowColor = NSColor.black.withAlphaComponent(48.0 / 255)
      shadow.shadowBlurRadius = 32; shadow.shadowOffset = .init(width: 0, height: -16); shadow.set()
      preferences.resolvedColors["elevatedSecondaryOpaque"].nativeColor.setFill()
      NSBezierPath(cgPath: PRCommentMediaCornerShape(radius: 12).cgPath(in: cardFrame.insetBy(dx: 8, dy: 8))).fill()
      NSGraphicsContext.restoreGraphicsState()
      preferences.resolvedColors["elevatedSecondaryOpaque"].nativeColor.setFill(); path.fill()
      preferences.resolvedColors["border"].nativeColor.setStroke(); path.lineWidth = 1; path.stroke()
      let button = NSBezierPath(ovalIn: close.frame)
      preferences.resolvedColors["controlBackgroundOpaque"].nativeColor.setFill(); button.fill()
    }

  }
  final class EdgeCover: NSView {
    var color = NSColor.clear { didSet { needsDisplay = true } }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
      color.setFill()
      NSRect(x: 0, y: max(0, bounds.height - 8), width: bounds.width, height: min(8, bounds.height)).fill()
      NSRect(x: max(0, bounds.width - 8), y: 0, width: min(8, bounds.width), height: bounds.height).fill()
    }
  }
  private struct PreviewContent: View {
    let block: MessageBlock
    let source: String
    let metrics: PRCommentTableMetrics
    let width: CGFloat
    let height: (CGFloat) -> Void
    @Environment(\.appAppearance) private var appearance
    var body: some View {
      PRCommentTableContent(block: block, source: source, metrics: metrics, availableWidth: width)
        .fixedSize(horizontal: false, vertical: true).frame(width: width, alignment: .topLeading)
        .background { GeometryReader { proxy in Color.clear.preference(key: Height.self, value: proxy.size.height) } }
        .padding(.trailing, 8).padding(.bottom, 8)
        .onPreferenceChange(Height.self, perform: height)
    }
    private struct Height: PreferenceKey {
      static var defaultValue: CGFloat = 0
      static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
    }
  }
}
