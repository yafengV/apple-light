import AppKit
import SwiftUI
import Observation
import XCTest
@testable import ShipiOS

@MainActor final class PRCommentTablePreviewTests: XCTestCase {
  private let short = "| Name | Value |\n|---|---|\n| Alpha | 12 |\n| Beta | 345 |"
  private let long = "| Name | Value |\n|---|---|\n" + (1...20).map {
    "| " + ($0 == 1 ? "Words that wrap into multiple lines when the window narrows to a smaller width." : "Row \($0)") + " | \($0) |"
  }.joined(separator: "\n")
  private final class Swatch: NSView {
    let color: NSColor
    init(_ color: NSColor, frame: NSRect) { self.color = color; super.init(frame: frame) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func draw(_ dirtyRect: NSRect) { color.setFill(); bounds.fill() }
  }
  private final class TestWindow: NSWindow { override var isKeyWindow: Bool { true } }
  @MainActor @Observable final class Input { var source = ""; var width: CGFloat = 220 }
  private struct Body: View {
    let input: Input
    var body: some View {
      VStack { PRCommentMarkdownTableView(block: MessageDocument.parse(input.source).first!, source: input.source).frame(width: input.width); Spacer() }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
  }
  private func table(_ text: String) throws -> MessageBlock { try XCTUnwrap(MessageDocument.parse(text).first { $0.kind == .table }) }
  private func settle(_ view: NSView) async throws {
    for _ in 0..<12 { view.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(30)) }
  }
  private func descendants<T: NSView>(_ root: NSView, _ type: T.Type) -> [T] {
    (root as? T).map { [$0] } ?? root.subviews.flatMap { descendants($0, type) }
  }
  private func host(_ source: String, size: CGSize = .init(width: 1280, height: 720),
    previous: NSView? = nil) throws -> (TestWindow, NSView, WindowDialogHost.Anchor, PRCommentTablePreviewPresenter.Coordinator, () -> Bool) {
    _ = NSApplication.shared
    let window = TestWindow(contentRect: .init(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.appearance = NSAppearance(named: .aqua)
    let root = NSView(frame: .init(origin: .zero, size: size)); window.contentView = root
    if let previous { root.addSubview(previous); window.makeFirstResponder(previous) }
    var open = true
    let presenter = PRCommentTablePreviewPresenter(block: try table(source), source: source, open: Binding(get: { open }, set: { open = $0 }))
    let owner = presenter.makeCoordinator(), anchor = WindowDialogHost.Anchor(frame: .init(x: 1, y: 1, width: 1, height: 1))
    anchor.host = owner.host; root.addSubview(anchor); owner.host.present(anchor)
    root.layoutSubtreeIfNeeded()
    addTeardownBlock { @MainActor in owner.host.stop(); window.contentView = nil; window.close() }
    return (window, root, anchor, owner, { open })
  }
  private func key(_ code: UInt16, _ window: NSWindow, shift: Bool = false, command: Bool = false, type: NSEvent.EventType = .keyDown) throws -> NSEvent {
    try XCTUnwrap(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: shift ? .shift : command ? .command : [],
      timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: command ? "w" : "",
      charactersIgnoringModifiers: command ? "w" : "", isARepeat: false, keyCode: code))
  }
  func testOverflowShowsExpandAndMountedActionOpensOnlyOwningWindow() async throws {
    _ = NSApplication.shared
    let input = Input(); input.source = "| " + String(repeating: "W", count: 100) + " | Value |\n|---|---|\n| Cell | 123 |"
    let window = TestWindow(contentRect: .init(x: 0, y: 0, width: 1000, height: 720), styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let root = NSHostingView(rootView: Body(input: input)); root.sizingOptions = []; window.contentView = root
    defer { window.contentView = nil; window.close() }
    try await settle(root)
    let expand = try XCTUnwrap(descendants(root, PRCommentTableCopyToolbar.CopyButton.self).first { $0.mode == .expand })
    XCTAssertEqual(expand.accessibilityRole(), .popUpButton)
    XCTAssertFalse(expand.isHidden); XCTAssertEqual(try XCTUnwrap(expand.surface).bounds.width, 80, accuracy: 0.1)
    XCTAssertTrue(window.makeFirstResponder(expand)); XCTAssertTrue(expand.accessibilityPerformShowMenu())
    try await settle(root)
    let preview = try XCTUnwrap(descendants(root, PRCommentTablePreviewPresenter.Surface.self).first)
    XCTAssertTrue(preview.superview === root); XCTAssertEqual(preview.bounds.size, root.bounds.size)
    XCTAssertNil(window.attachedSheet); XCTAssertTrue(window.firstResponder === preview.close)
    XCTAssertTrue(WindowModalInteraction.blocksCommands(in: window)); XCTAssertFalse(WindowModalInteraction.allows(expand))
    XCTAssertTrue(expand.isAccessibilityExpanded())
    XCTAssertTrue(preview.close.accessibilityPerformPress()); try await settle(root)
    XCTAssertTrue(descendants(root, PRCommentTablePreviewPresenter.Surface.self).isEmpty)
    XCTAssertTrue(window.firstResponder === expand); XCTAssertFalse(expand.isAccessibilityExpanded())
    input.source = short; input.width = 500; try await settle(root)
    XCTAssertTrue(expand.isHidden); XCTAssertFalse(expand.canBecomeKeyView)
  }
  func testPreviewGeometryAndTypographyMatchActualPublicCSSFixture() async throws {
    let (_, root, _, owner, _) = try host(long)
    try await settle(root)
    let surface = try XCTUnwrap(owner.host.surface as? PRCommentTablePreviewPresenter.Surface)
    let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/pr_comment_table_preview_reference.json")
    let facts = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
    let geometry = try XCTUnwrap(facts["longGeometry"] as? [String: Double])
    // CoreText and the browser have a recorded 1.08-point shaping difference.
    // Check the panel rules without treating that discrepancy as pixel parity.
    XCTAssertEqual(surface.tableSize.height, try XCTUnwrap(geometry["tableHeight"]), accuracy: 1)
    XCTAssertEqual(surface.cardFrame.width, surface.tableSize.width + 74, accuracy: 0.1)
    XCTAssertEqual(surface.cardFrame.height, 620, accuracy: 1); XCTAssertEqual(surface.cardFrame.minY, 48, accuracy: 1)
    XCTAssertEqual(surface.scroll.frame.height, 554, accuracy: 1)
    XCTAssertNil(surface.scroll.layer?.mask, "Public table previews do not enable the ordinary table edge fade")
    XCTAssertEqual(surface.close.frame, .init(x: 1228, y: 12, width: 40, height: 40))
    XCTAssertEqual(surface.close.accessibilityLabel(), "关闭表格预览")
    let texts = descendants(surface.document, PRCommentMarkdownText.TextView.self)
    XCTAssertEqual(texts.count, 42)
    for text in texts {
      XCTAssertEqual((text.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize, 12.25)
      XCTAssertTrue(text.isSelectable); XCTAssertFalse(text.isEditable)
    }
    let top = surface.document.convert(try XCTUnwrap(texts.first).bounds, from: try XCTUnwrap(texts.first))
    surface.scroll.contentView.scroll(to: .init(x: 0, y: 200))
    surface.scroll.reflectScrolledClipView(surface.scroll.contentView)
    XCTAssertEqual(surface.scroll.contentView.bounds.minY, 200, accuracy: 1)
    XCTAssertEqual(surface.document.convert(try XCTUnwrap(texts.first).bounds, from: try XCTUnwrap(texts.first)), top, "The preview path does not enable sticky headers")
    XCTAssertNil(surface.edges.hitTest(.zero))
    if let directory = ProcessInfo.processInfo.environment["SHIPIOS_PR_TABLE_PREVIEW_RENDER_DIR"] {
      let bitmap = try XCTUnwrap(root.bitmapImageRepForCachingDisplay(in: root.bounds)); root.cacheDisplay(in: root.bounds, to: bitmap)
      try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: directory).appendingPathComponent("long.png"))
    }
  }
  func testTabLoopSelectionRetentionEscapeAndFocusReturn() async throws {
    let previous = NSTextView(); previous.string = "Source"
    let (window, root, _, owner, showing) = try host(long, previous: previous); try await settle(root)
    let surface = try XCTUnwrap(owner.host.surface as? PRCommentTablePreviewPresenter.Surface)
    XCTAssertTrue(owner.host.handle(try key(48, window))); XCTAssertTrue(window.firstResponder === surface.scroll)
    XCTAssertTrue(owner.host.handle(try key(48, window))); XCTAssertTrue(window.firstResponder === surface.close)
    XCTAssertTrue(owner.host.handle(try key(48, window, shift: true))); XCTAssertTrue(window.firstResponder === surface.scroll)
    let text = try XCTUnwrap(descendants(surface.document, PRCommentMarkdownText.TextView.self).first)
    window.makeFirstResponder(text); text.setSelectedRange(.init(location: 0, length: 2)); owner.host.containFocus()
    XCTAssertTrue(window.firstResponder === text); XCTAssertEqual(text.selectedRange().length, 2)
    XCTAssertTrue(owner.host.handle(try key(53, window))); try await settle(root)
    XCTAssertFalse(showing()); XCTAssertNil(owner.host.surface); XCTAssertTrue(window.firstResponder === previous)
    XCTAssertFalse(WindowModalInteraction.blocksCommands(in: window))
    XCTAssertFalse(surface.close.accessibilityPerformPress(), "Detached callbacks must not close a new dialog")
  }
  func testNarrowWindowAndSourceUpdateKeepScrollViewportFiniteAndUseLatestTable() async throws {
    let (window, root, _, owner, _) = try host(long, size: .init(width: 500, height: 300)); try await settle(root)
    let surface = try XCTUnwrap(owner.host.surface as? PRCommentTablePreviewPresenter.Surface)
    XCTAssertEqual(surface.cardFrame.width, (500 - 32) * 0.8, accuracy: 1)
    XCTAssertEqual(surface.cardFrame.height, 200, accuracy: 1)
    XCTAssertTrue(surface.tableSize.width > surface.scroll.bounds.width)
    owner.parent = .init(block: try table(short), source: short, open: owner.parent.$open); owner.configure(surface)
    try await settle(root)
    XCTAssertEqual(descendants(surface.document, PRCommentMarkdownText.TextView.self).count, 6)
    XCTAssertFalse(descendants(surface.document, PRCommentMarkdownText.TextView.self).contains { $0.string.hasPrefix("Words") })
    window.setContentSize(.init(width: 40, height: 40)); try await settle(root)
    XCTAssertTrue(surface.scroll.isHidden); XCTAssertTrue(surface.scroll.frame.width.isFinite); XCTAssertTrue(surface.scroll.frame.height.isFinite)
  }
  func testBackdropAndCommandCloseAndRemovalDoNotLeakToOtherWindows() async throws {
    let (window, root, anchor, owner, showing) = try host(short)
    try await settle(root)
    let second = TestWindow(contentRect: root.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    second.isReleasedWhenClosed = false; defer { second.close() }
    XCTAssertFalse(WindowModalInteraction.blocksCommands(in: second))
    XCTAssertFalse(owner.host.handle(try key(53, second)))
    XCTAssertTrue(owner.host.handle(try key(13, window, command: true))); XCTAssertFalse(showing())
    XCTAssertNil(owner.host.surface)
    var reopened = true
    owner.parent = .init(block: try table(short), source: short, open: Binding(get: { reopened }, set: { reopened = $0 }))
    owner.update(anchor); owner.host.present(anchor); XCTAssertNotNil(owner.host.surface)
    anchor.removeFromSuperview(); XCTAssertNil(owner.host.surface); XCTAssertFalse(WindowModalInteraction.blocksCommands(in: window))
  }
  func testBackdropPressAndSpaceReleaseCloseWithoutCopiedFeedback() async throws {
    let (window, root, _, owner, showing) = try host(short); try await settle(root)
    let surface = try XCTUnwrap(owner.host.surface as? PRCommentTablePreviewPresenter.Surface)
    func mouse(_ point: NSPoint) throws -> NSEvent {
      try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: surface.convert(point, to: nil), modifierFlags: [],
        timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    }
    surface.mouseDown(with: try mouse(.init(x: surface.cardFrame.minX + 4, y: surface.cardFrame.minY + 4)))
    XCTAssertTrue(showing(), "Padding belongs to the table card, not the backdrop")
    surface.close.keyDown(with: try key(49, window)); XCTAssertTrue(showing()); XCTAssertFalse(surface.close.copied)
    surface.close.keyUp(with: try key(49, window, type: .keyUp)); XCTAssertFalse(showing()); XCTAssertNil(owner.host.surface)
    let (_, secondRoot, _, secondOwner, secondShowing) = try host(short); try await settle(secondRoot)
    let second = try XCTUnwrap(secondOwner.host.surface as? PRCommentTablePreviewPresenter.Surface)
    let outside = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: second.convert(.init(x: 2, y: 2), to: nil),
      modifierFlags: [], timestamp: 0, windowNumber: second.window!.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    second.mouseDown(with: outside); XCTAssertFalse(secondShowing()); XCTAssertNil(secondOwner.host.surface)
  }
  func testKeyboardScrollingUsesCurrentRegionAndPreservesOtherAxis() async throws {
    let text = "| " + String(repeating: "W", count: 200) + " | Value |\n|---|---|\n" + (1...20).map { "| Row \($0) | \($0) |" }.joined(separator: "\n")
    let (window, root, _, owner, _) = try host(text); try await settle(root)
    let surface = try XCTUnwrap(owner.host.surface as? PRCommentTablePreviewPresenter.Surface), scroll = surface.scroll
    XCTAssertTrue(window.makeFirstResponder(scroll))
    scroll.keyDown(with: try key(124, window)); XCTAssertEqual(scroll.contentView.bounds.minX, 40, accuracy: 1)
    scroll.keyDown(with: try key(125, window)); XCTAssertEqual(scroll.contentView.bounds.minY, 40, accuracy: 1)
    XCTAssertEqual(scroll.contentView.bounds.minX, 40, accuracy: 1)
    scroll.keyDown(with: try key(119, window))
    XCTAssertEqual(scroll.contentView.bounds.minY, surface.document.bounds.height - scroll.contentView.bounds.height, accuracy: 1)
    scroll.keyDown(with: try key(49, window, shift: true)); XCTAssertEqual(scroll.contentView.bounds.minY, 0, accuracy: 1)
    XCTAssertEqual(scroll.contentView.bounds.minX, 40, accuracy: 1)
    owner.host.dismiss(); XCTAssertFalse(scroll.acceptsFirstResponder)
  }
  func testPreviewRetainsPRImageLoaderAndRevisionContext() async throws {
    let (_, root, _, owner, _) = try host(short); try await settle(root)
    let surface = try XCTUnwrap(owner.host.surface as? PRCommentTablePreviewPresenter.Surface)
    let png = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8,
      samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
    let data = try XCTUnwrap(png.representation(using: .png, properties: [:]))
    var paths: [String] = []
    let block = MessageBlock(id: "image-table", kind: .table, source: "| Picture |\n|---|\n| ![Preview](image.png) |",
      rows: [[AttributedString("Picture")], [AttributedString("Preview")]],
      mediaRows: [[[]], [[MessageBlock(id: "image", kind: .prImage(path: "image.png", alt: "Preview"))]]])
    let loader: (String) async throws -> Data = { paths.append($0); return data }
    surface.configure(block: block, source: block.source, appearance: .init(), openURL: OpenURLAction { _ in .handled }, imageLoader: loader, revision: "one")
    try await settle(root); XCTAssertEqual(paths, ["image.png"])
    surface.configure(block: block, source: block.source, appearance: .init(), openURL: OpenURLAction { _ in .handled }, imageLoader: loader, revision: "two")
    try await settle(root); XCTAssertEqual(paths, ["image.png", "image.png"])
  }

  func testPreviewPanelFillUsesOpaqueThemeSurfaceRatherThanBackdrop() async throws {
    let (_, root, _, owner, _) = try host(long); try await settle(root)
    let surface = try XCTUnwrap(owner.host.surface as? PRCommentTablePreviewPresenter.Surface)
    var preferences = AppearancePreferences(); preferences.theme = "dark"
    owner.preferences = preferences; owner.configure(surface); try await settle(root)
    // Draw the reference chip through the same offscreen color profile;
    // cacheDisplay's calibrated bitmap differs from a raw sRGB NSColor.
    let chip = Swatch(preferences.resolvedColors["elevatedSecondaryOpaque"].nativeColor,
      frame: .init(x: 10, y: root.bounds.midY - 10, width: 20, height: 20))
    root.addSubview(chip); defer { chip.removeFromSuperview() }
    let bitmap = try XCTUnwrap(root.bitmapImageRepForCachingDisplay(in: root.bounds)); root.cacheDisplay(in: root.bounds, to: bitmap)
    let scale = CGFloat(bitmap.pixelsWide) / root.bounds.width
    let color = try XCTUnwrap(bitmap.colorAt(x: Int((surface.cardFrame.minX + 16) * scale), y: bitmap.pixelsHigh / 2)?.usingColorSpace(.deviceRGB))
    let expected = try XCTUnwrap(bitmap.colorAt(x: Int(20 * scale), y: bitmap.pixelsHigh / 2)?.usingColorSpace(.deviceRGB))
    XCTAssertEqual(color.redComponent, expected.redComponent, accuracy: 0.03)
    XCTAssertEqual(color.greenComponent, expected.greenComponent, accuracy: 0.03)
    XCTAssertEqual(color.blueComponent, expected.blueComponent, accuracy: 0.03)
    XCTAssertEqual(color.alphaComponent, 1, accuracy: 0.01)
  }

}
