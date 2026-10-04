import AppKit
import SwiftUI
import Observation
import XCTest
@testable import ShipiOS

@MainActor final class PRCommentTableScrollTests: XCTestCase {
  private let short = "| Name | Value |\n|---|---|\n| Alpha | 12 |\n| Beta | 345 |"
  private let overflow = "| " + String(repeating: "W", count: 100) + " | Value |\n|---|---|\n| Cell | 123 |"
  private final class TestWindow: NSWindow { override var isKeyWindow: Bool { true } }
  private final class Stop: NSButton { override var canBecomeKeyView: Bool { true } }
  private struct StopView: NSViewRepresentable {
    let name: String
    func makeNSView(context: Context) -> Stop { let view = Stop(); view.title = name; return view }
    func updateNSView(_ view: Stop, context: Context) {}
  }
  @MainActor @Observable final class Input {
    var source = ""; var width: CGFloat = 220; var enabled = true
    var block: MessageBlock?
    var opened: [URL] = []
    var imageLoader: ((String) async throws -> Data)?
    var revision = "one"
  }
  private struct Body: View {
    let input: Input
    var body: some View {
      VStack(spacing: 12) {
        StopView(name: "Before").frame(width: 80, height: 30)
        PRCommentMarkdownTableView(block: input.block ?? MessageDocument.parse(input.source).first!, source: input.source)
          .frame(width: input.width).disabled(!input.enabled)
        StopView(name: "After").frame(width: 80, height: 30)
        Spacer()
      }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .environment(\.openURL, OpenURLAction { input.opened.append($0); return .handled })
        .environment(\.prMarkdownImageLoader, input.imageLoader)
        .environment(\.prMarkdownRevision, input.revision)
    }
  }
  private func descendants<T: NSView>(_ root: NSView, _ type: T.Type) -> [T] {
    (root as? T).map { [$0] } ?? root.subviews.flatMap { descendants($0, type) }
  }
  private func settle(_ root: NSView) async throws {
    for _ in 0..<10 { root.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(30)) }
  }
  private func host(_ source: String) async throws -> (TestWindow, NSHostingView<Body>, Input, PRCommentTableScrollView.Surface) {
    _ = NSApplication.shared
    let input = Input(); input.source = source
    let window = TestWindow(contentRect: .init(x: 0, y: 0, width: 700, height: 700), styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let root = NSHostingView(rootView: Body(input: input)); root.sizingOptions = []; window.contentView = root
    try await settle(root)
    let region = try XCTUnwrap(descendants(root, PRCommentTableScrollView.Surface.self).first)
    addTeardownBlock { @MainActor in window.contentView = nil; window.close() }
    return (window, root, input, region)
  }
  private func key(_ code: UInt16, flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
    try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
      windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code))
  }
  func testOnlyOverflowRegionIsLabeledAndTabFocusableWhileCellsRemainSelectable() async throws {
    let (window, root, input, region) = try await host(short)
    XCTAssertFalse(region.overflowing); XCTAssertFalse(region.canBecomeKeyView)
    XCTAssertFalse(region.isAccessibilityElement()); XCTAssertNil(region.accessibilityLabel())
    let cells = descendants(root, PRCommentMarkdownText.TextView.self)
    XCTAssertEqual(cells.count, 6)
    for cell in cells { XCTAssertFalse(cell.canBecomeKeyView); XCTAssertTrue(cell.isSelectable); XCTAssertFalse(cell.isEditable) }
    let cell = try XCTUnwrap(cells.first)
    XCTAssertTrue(window.makeFirstResponder(cell)); cell.setSelectedRange(.init(location: 0, length: 2))
    XCTAssertEqual(cell.selectedRange().length, 2)
    input.source = overflow; try await settle(root)
    XCTAssertTrue(region.overflowing); XCTAssertTrue(region.canBecomeKeyView)
    XCTAssertTrue(region.isAccessibilityElement()); XCTAssertEqual(region.accessibilityRole(), .group)
    XCTAssertEqual(region.accessibilityLabel(), "可滚动表格"); XCTAssertEqual(region.accessibilityIdentifier(), "pr-comment-table-scroll")
    XCTAssertTrue(window.makeFirstResponder(region)); XCTAssertTrue(window.firstResponder === region)
    let toolbar = try XCTUnwrap(descendants(root, PRCommentTableCopyToolbar.Surface.self).first)
    XCTAssertFalse(toolbar.visible, "Region focus is outside toolbar focus-within")
    XCTAssertNotNil(region.layer?.mask); XCTAssertFalse(toolbar.isDescendant(of: region))
    XCTAssertNil(toolbar.layer?.mask, "The table fade does not fade its copy/expand actions")
  }
  func testRealKeyViewLoopEntersRegionBeforeCopyAndExpandAndSkipsPlainCells() async throws {
    let (window, root, _, region) = try await host(overflow)
    let before = try XCTUnwrap(descendants(root, Stop.self).first { $0.title == "Before" })
    let after = try XCTUnwrap(descendants(root, Stop.self).first { $0.title == "After" })
    let toolbar = try XCTUnwrap(descendants(root, PRCommentTableCopyToolbar.Surface.self).first)
    window.recalculateKeyViewLoop(); XCTAssertTrue(window.makeFirstResponder(before))
    window.selectNextKeyView(nil); XCTAssertTrue(window.firstResponder === region)
    window.selectNextKeyView(nil); XCTAssertTrue(window.firstResponder === toolbar.button)
    window.selectNextKeyView(nil); XCTAssertTrue(window.firstResponder === toolbar.expand)
    window.selectNextKeyView(nil); XCTAssertTrue(window.firstResponder === after)
    window.selectPreviousKeyView(nil); XCTAssertTrue(window.firstResponder === toolbar.expand)
    window.selectPreviousKeyView(nil); XCTAssertTrue(window.firstResponder === toolbar.button)
    window.selectPreviousKeyView(nil); XCTAssertTrue(window.firstResponder === region)
    window.selectPreviousKeyView(nil); XCTAssertTrue(window.firstResponder === before)
  }
  func testRegionArrowsClampAndModifiersDoNotBecomeToolbarPageShortcuts() async throws {
    let (window, root, _, region) = try await host(overflow)
    XCTAssertTrue(window.makeFirstResponder(region))
    XCTAssertTrue(region.handle(try key(124))); XCTAssertEqual(region.contentView.bounds.minX, 40, accuracy: 0.1)
    XCTAssertEqual(region.contentView.bounds.minY, 0)
    for flags: NSEvent.ModifierFlags in [.option, .shift, .control, .command] {
      XCTAssertFalse(region.handle(try key(124, flags: flags)))
      region.keyDown(with: try key(124, flags: flags))
      XCTAssertEqual(region.contentView.bounds.minX, 40, accuracy: 0.1)
    }
    let copy = try XCTUnwrap(descendants(root, PRCommentTableCopyToolbar.Surface.self).first).button
    XCTAssertTrue(window.makeFirstResponder(copy))
    copy.keyDown(with: try key(124, flags: .option)); XCTAssertEqual(region.contentView.bounds.minX, 260, accuracy: 0.1)
    for _ in 0..<30 { XCTAssertTrue(region.handle(try key(124))) }
    XCTAssertEqual(region.contentView.bounds.maxX, region.document.bounds.width, accuracy: 0.1)
    for _ in 0..<30 { XCTAssertTrue(region.handle(try key(123))) }
    XCTAssertEqual(region.contentView.bounds.minX, 0)
  }
  func testSourceAndWidthChangesRemoveRegionSemanticsResetScrollAndMoveFocus() async throws {
    let (window, root, input, region) = try await host(overflow)
    window.recalculateKeyViewLoop(); XCTAssertTrue(window.makeFirstResponder(region))
    XCTAssertTrue(region.handle(try key(124))); XCTAssertEqual(region.contentView.bounds.minX, 40)
    input.source = short; input.width = 500; try await settle(root)
    XCTAssertFalse(region.overflowing); XCTAssertFalse(region.canBecomeKeyView); XCTAssertFalse(region.isAccessibilityElement())
    XCTAssertNil(region.accessibilityLabel()); XCTAssertEqual(region.contentView.bounds.minX, 0)
    XCTAssertFalse(window.firstResponder === region)
    let toolbar = try XCTUnwrap(descendants(root, PRCommentTableCopyToolbar.Surface.self).first)
    XCTAssertTrue(window.firstResponder === toolbar.button); XCTAssertTrue(toolbar.expand.isHidden)
    XCTAssertFalse(region.handle(try key(124)))
    let before = try XCTUnwrap(descendants(root, Stop.self).first { $0.title == "Before" })
    window.recalculateKeyViewLoop(); window.makeFirstResponder(before); window.selectNextKeyView(nil)
    XCTAssertTrue(window.firstResponder === toolbar.button)
  }
  func testModalDisableWindowRemovalAndRetirementCannotScrollOldContent() async throws {
    final class Scope: WindowModalScope { let modalRoot = NSView(); var modalScopeActive = true }
    let (window, root, input, region) = try await host(overflow)
    let scope = Scope(); root.addSubview(scope.modalRoot); WindowModalInteraction.install(scope, in: window)
    XCTAssertFalse(region.canBecomeKeyView); XCTAssertFalse(region.handle(try key(124)))
    WindowModalInteraction.remove(scope, from: window); scope.modalRoot.removeFromSuperview()
    XCTAssertTrue(region.canBecomeKeyView)
    input.enabled = false; try await settle(root); XCTAssertFalse(region.handle(try key(124)))
    input.enabled = true; try await settle(root); XCTAssertTrue(region.handle(try key(124)))
    let target = PRCommentTableScrollTarget(); target.anchor = region.anchor
    region.retire(); XCTAssertFalse(region.handle(try key(124))); XCTAssertFalse(target.scroll(40, page: false))
    window.contentView = nil; XCTAssertFalse(region.canBecomeKeyView)
  }
  func testResizeWithoutSourceChangeAddsAndRemovesOverflowAndPreservesSelection() async throws {
    let (window, root, input, region) = try await host(overflow)
    let text = try XCTUnwrap(descendants(root, PRCommentMarkdownText.TextView.self).first)
    window.makeFirstResponder(text); text.setSelectedRange(.init(location: 1, length: 4))
    input.width = 650; try await settle(root)
    XCTAssertFalse(region.overflowing); XCTAssertFalse(region.canBecomeKeyView)
    XCTAssertEqual(text.selectedRange(), .init(location: 1, length: 4))
    input.width = 220; try await settle(root)
    XCTAssertTrue(region.overflowing); XCTAssertTrue(region.canBecomeKeyView)
    XCTAssertEqual(text.selectedRange(), .init(location: 1, length: 4))
    XCTAssertEqual(region.contentView.bounds.minX, 0)
  }
  func testLinkCellKeepsNativeKeyboardSelectionAndUsesInheritedOpenURL() async throws {
    let (_, root, input, region) = try await host(short)
    input.source = "| Link | Value |\n|---|---|\n| [Read](https://example.com/help) | 12 |"
    try await settle(root)
    let text = try XCTUnwrap(descendants(region.document, PRCommentMarkdownText.TextView.self).first { $0.string == "Read" })
    XCTAssertTrue(text.canBecomeKeyView); XCTAssertTrue(text.isSelectable)
    let url = try XCTUnwrap(URL(string: "https://example.com/help"))
    XCTAssertTrue(text.textView(text, clickedOnLink: url, at: 0)); XCTAssertEqual(input.opened, [url])
  }
  func testNativeDocumentPreservesPRImageLoaderRevisionAndMeasuredMediaHeight() async throws {
    let (_, root, input, region) = try await host(short)
    let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 20, pixelsHigh: 60, bitsPerSample: 8,
      samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
    let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    let block = MessageBlock(id: "image-table", kind: .table, source: "| Picture |\n|---|\n| ![Preview](image.png) |",
      rows: [[AttributedString("Picture")], [AttributedString("Preview")]],
      mediaRows: [[[]], [[MessageBlock(id: "image", kind: .prImage(path: "image.png", alt: "Preview"))]]])
    var paths: [String] = []
    input.imageLoader = { paths.append($0); return data }
    input.source = block.source; input.block = block
    try await settle(root); XCTAssertEqual(paths, ["image.png"])
    XCTAssertGreaterThan(region.document.bounds.height, PRCommentTableMetrics(appearance: .init()).plan(block, width: 220).height)
    input.revision = "two"; try await settle(root); XCTAssertEqual(paths, ["image.png", "image.png"])
  }
}
