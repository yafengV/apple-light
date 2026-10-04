import AppKit
import SwiftUI
import Observation
import XCTest
@testable import ShipiOS

@MainActor final class PRCommentMarkdownTableTests: XCTestCase {
  private let short = "| Name | Value |\n| :--- | ---: |\n| Alpha | 12 |\n| Beta | 345 |"
  private let long = "| Description | Value |\n| :--- | ---: |\n| Words that wrap into multiple lines when the window narrows to a smaller width. | 17 |\n| End | 123456 |"
  private struct Anchor: NSViewRepresentable {
    let capture: (NSView) -> Void
    func makeNSView(context: Context) -> NSView { let v = NSView(); capture(v); return v }
    func updateNSView(_ view: NSView, context: Context) { capture(view) }
  }
  @MainActor @Observable final class Input { var width: CGFloat = 500; var source = ""; let layout = PRCommentMarkdownLayout() }
  private struct DynamicBody: View {
    let input: Input
    let capture: (NSView) -> Void
    var body: some View {
      VStack(spacing: 0) {
        MessageMarkdownView(source: input.source, compactPRComment: true, prCommentLayout: input.layout, openLink: { _ in })
          .fixedSize(horizontal: false, vertical: true).frame(width: input.width)
          .background { Anchor(capture: capture) }
        Spacer(minLength: 0)
      }.frame(width: input.width, height: 1200, alignment: .top)
    }
  }
  private func settle(_ root: NSView) async throws {
    for _ in 0..<10 { root.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(30)) }
  }
  private func host(_ input: Input, appearance: AppearancePreferences = .init()) async throws -> (NSWindow, NSHostingView<AnyView>, () -> NSView?) {
    _ = NSApplication.shared
    let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 500, height: 1200), styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    var anchor: NSView?
    let root = NSHostingView(rootView: AnyView(DynamicBody(input: input, capture: { anchor = $0 }).environment(\.appAppearance, appearance)))
    window.contentView = root; root.sizingOptions = []; try await settle(root)
    addTeardownBlock { @MainActor in window.contentView = nil; window.close() }
    return (window, root, { anchor })
  }
  private func texts(_ view: NSView) -> [PRCommentMarkdownText.TextView] {
    (view as? PRCommentMarkdownText.TextView).map { [$0] } ?? view.subviews.flatMap { texts($0) }
  }
  private func table(_ source: String) throws -> MessageBlock {
    try XCTUnwrap(MessageDocument.parse(source).first { $0.kind == .table })
  }
  func testTableGeometryAndFontsAgainstBrowserFixture() async throws {
    let input = Input(); input.source = short
    let (_, root, capture) = try await host(input)
    let body = try XCTUnwrap(capture())
    XCTAssertEqual(body.bounds.width, 500, accuracy: 0.1)
    XCTAssertEqual(body.bounds.height, 114.125, accuracy: 1)
    let views = texts(root); XCTAssertEqual(views.count, 6)
    for view in views {
      let attributes = try XCTUnwrap(view.textStorage)
      let font = try XCTUnwrap(attributes.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
      let paragraph = try XCTUnwrap(attributes.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
      XCTAssertEqual(font.pointSize, 12)
      XCTAssertEqual(paragraph.maximumLineHeight, ["Name", "Value"].contains(view.string) ? 13 : 21.125)
      XCTAssertEqual(paragraph.alignment, ["Value", "12", "345"].contains(view.string) ? .right : .left)
      XCTAssertTrue(view.isSelectable); XCTAssertFalse(view.isEditable)
    }
    let header = try XCTUnwrap(views.first { $0.string == "Name" })
    let alpha = try XCTUnwrap(views.first { $0.string == "Alpha" })
    let first = body.convert(header.bounds, from: header), next = body.convert(alpha.bounds, from: alpha)
    XCTAssertEqual(abs((body.isFlipped ? next.minY : next.maxY) - (body.isFlipped ? first.minY : first.maxY)), 28.625, accuracy: 1)
    let value = try XCTUnwrap(views.first { $0.string == "Value" })
    XCTAssertEqual(body.convert(value.bounds, from: value).minX, 225.8515625, accuracy: 1)
    if let directory = ProcessInfo.processInfo.environment["SHIPIOS_PR_TABLE_RENDER_DIR"] {
      let rect = root.convert(body.bounds, from: body)
      let bitmap = try XCTUnwrap(root.bitmapImageRepForCachingDisplay(in: rect))
      root.cacheDisplay(in: rect, to: bitmap)
      try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: directory).appendingPathComponent("short.png"))
    }
  }
  func testLongCellWrapsAndResizingUpdatesHeightWithoutFixedColumnWidth() async throws {
    let input = Input(); input.source = long
    let (window, root, capture) = try await host(input)
    XCTAssertEqual(try XCTUnwrap(capture()).bounds.height, 135.25, accuracy: 1)
    let initial = try XCTUnwrap(capture()).bounds.height
    input.width = 220; window.setContentSize(.init(width: 220, height: 1200)); try await settle(root)
    XCTAssertGreaterThan(try XCTUnwrap(capture()).bounds.height, initial)
    XCTAssertEqual(try XCTUnwrap(capture()).bounds.height, 177.5, accuracy: 1)
    XCTAssertEqual(try XCTUnwrap(capture()).bounds.width, 220, accuracy: 1)
    let text = try XCTUnwrap(texts(root).first { $0.string.hasPrefix("Words that wrap") })
    XCTAssertGreaterThan(text.bounds.height, 42.25)
    input.source = short; try await settle(root)
    XCTAssertEqual(try XCTUnwrap(capture()).bounds.height, 114.125, accuracy: 1)
    XCTAssertFalse(texts(root).contains { $0.string.hasPrefix("Words that wrap") })
  }
  func testTableSmallFontUsesCodeSizeFloorAndRetainsContentFamily() async throws {
    let input = Input(); input.source = short
    var appearance = AppearancePreferences(); appearance.uiSize = 18.5; appearance.codeSize = 16.25
    let (_, root, _) = try await host(input, appearance: appearance)
    for view in texts(root) {
      XCTAssertEqual(try XCTUnwrap(view.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont).pointSize, 16.25)
    }
    appearance.codeSize = 8
    XCTAssertEqual(PRCommentTableMetrics(appearance: appearance).font.pointSize, 11.375)
    let font = PRCommentTableMetrics(appearance: appearance).font
    let features = font.fontDescriptor.object(forKey: .featureSettings) as? [[NSFontDescriptor.FeatureKey: Int]]
    XCTAssertTrue(features?.contains { $0[.typeIdentifier] == kNumberSpacingType && $0[.selectorIdentifier] == kMonospacedNumbersSelector } == true)
  }
  func testLongTableKeepsEveryRowAndUsesFinalRowBottomPadding() async throws {
    let input = Input()
    input.source = "| Name | Value |\n| :--- | ---: |\n" + (1...10).map { "| Row \($0) | \($0) |" }.joined(separator: "\n")
    let (_, root, capture) = try await host(input)
    XCTAssertEqual(texts(root).count, 22)
    XCTAssertEqual(try XCTUnwrap(capture()).bounds.height, 421.125, accuracy: 1)
    XCTAssertEqual(input.layout.lineCount, 0)
    XCTAssertNil(input.layout.previewHeight, "The browser fixture keeps all table rows under line-clamp-6")
  }
  func testColumnMetricsPreserveNarrowMinimumNumericContentAndFiniteProposals() throws {
    let block = try table(long), metrics = PRCommentTableMetrics(appearance: .init())
    let wide = metrics.plan(block, width: 500), narrow = metrics.plan(block, width: 1)
    XCTAssertEqual(wide.width, 500, accuracy: 0.001)
    XCTAssertGreaterThan(wide.columns[0], wide.columns[1])
    XCTAssertGreaterThan(narrow.width, 1)
    XCTAssertTrue(metrics.plan(block, width: .nan).height.isFinite)
    XCTAssertTrue(metrics.plan(block, width: .infinity).width.isFinite)
    XCTAssertEqual(metrics.plan(.init(id: "empty", kind: .table), width: 500).height, 0)
    let native = metrics.plan(try table(short), width: 500)
    XCTAssertEqual(native.rows[0], 27, accuracy: 1)
    XCTAssertEqual(native.rows[1], 38.375, accuracy: 1)
    XCTAssertEqual(native.rows[2], 48.75, accuracy: 1)
  }
  func testTableTopMarginCollapsesWithAdjacentParagraphAndListItem() throws {
    let table = try table(short), typography = PRCommentMarkdownTypography(font: .systemFont(ofSize: 13))
    let paragraph = MessageBlock(id: "p", kind: .paragraph, text: AttributedString("Before"))
    XCTAssertEqual(typography.gap([table], before: 0, in: .root), 0)
    XCTAssertEqual(typography.gap([paragraph, table], before: 1, in: .root), 13)
    XCTAssertEqual(typography.gap([table], before: 0, in: .item), 0)
  }
  func testMountedToolbarUsesCurrentTableAndActualSwiftUIScrollContainer() async throws {
    let input = Input(); input.width = 220
    input.source = "| " + String(repeating: "W", count: 100) + " | Value |\n|---|---|\n| Cell | 123 |"
    let (window, root, _) = try await host(input)
    func find(_ view: NSView) -> PRCommentTableCopyToolbar.CopyButton? {
      if let button = view as? PRCommentTableCopyToolbar.CopyButton { return button }
      return view.subviews.lazy.compactMap { find($0) }.first
    }
    let button = try XCTUnwrap(find(root))
    XCTAssertEqual(button.frame.size, .init(width: 36, height: 36))
    XCTAssertEqual(button.payload?.markdown, input.source)
    XCTAssertTrue(window.makeFirstResponder(button))
    XCTAssertTrue(button.surface?.visible == true)
    XCTAssertTrue(button.scroll?(40, false) == true, "The real mounted horizontal scroller must be reachable")
    input.source = short; try await settle(root)
    let replacement = try XCTUnwrap(find(root))
    XCTAssertEqual(replacement.payload?.markdown, short)
    XCTAssertFalse(replacement.scroll?(40, false) == true)
  }
}
