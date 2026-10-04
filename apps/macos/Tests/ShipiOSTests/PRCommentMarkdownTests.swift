import AppKit
import SwiftUI
import Observation
import XCTest
@testable import ShipiOS

@MainActor final class PRCommentMarkdownTests: XCTestCase {
  private struct Anchor: NSViewRepresentable {
    let capture: (NSView) -> Void
    func makeNSView(context: Context) -> NSView { let v = NSView(); capture(v); return v }
    func updateNSView(_ view: NSView, context: Context) {}
  }
  @Observable final class Input {
    var width: CGFloat = 500
    var source = Array(repeating: "A line containing words that will wrap in a narrow window.", count: 10).joined(separator: "  \n")
  }
  private struct DynamicBody: View {
    let input: Input
    let layout: PRCommentMarkdownLayout
    let capture: (NSView) -> Void
    var body: some View {
      VStack(spacing: 0) {
        MessageMarkdownView(source: input.source, compactPRComment: true, prCommentLayout: layout, openLink: { _ in })
          .fixedSize(horizontal: false, vertical: true).frame(width: input.width).background { Anchor(capture: capture) }
        Spacer(minLength: 0)
      }.frame(width: input.width, height: 1200, alignment: .top)
    }
  }
  private func settle(_ view: NSView) async throws {
    for _ in 0..<8 { view.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(30)) }
  }
  private func host(_ source: String, width: CGFloat = 500, uiSize: Double = 14) async throws -> (NSWindow, NSHostingView<AnyView>, NSView, PRCommentMarkdownLayout) {
    _ = NSApplication.shared
    let window = NSWindow(contentRect: .init(x: 0, y: 0, width: width, height: 1200), styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.appearance = NSAppearance(named: .aqua)
    let layout = PRCommentMarkdownLayout(); var captured: NSView?
    var appearance = AppearancePreferences(); appearance.theme = "light"; appearance.uiSize = uiSize
    let root = NSHostingView(rootView: AnyView(VStack(spacing: 0) {
      MessageMarkdownView(source: source, compactPRComment: true, prCommentLayout: layout, openLink: { _ in })
        .fixedSize(horizontal: false, vertical: true).frame(width: width).background { Anchor { captured = $0 } }
      Spacer(minLength: 0)
    }.frame(width: width, height: 1200, alignment: .top).environment(\.appAppearance, appearance)))
    window.contentView = root; try await settle(root)
    addTeardownBlock { @MainActor in window.contentView = nil; window.close() }
    return (window, root, try XCTUnwrap(captured), layout)
  }
  private func textViews(_ view: NSView) -> [PRCommentMarkdownText.TextView] {
    (view as? PRCommentMarkdownText.TextView).map { [$0] } ?? view.subviews.flatMap { textViews($0) }
  }
  private func facts() throws -> [String: Any] {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/pr_comment_markdown_reference.json")
    return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
  }
  func testNativeParagraphListQuoteAndHeadingGeometryMatchesPublicCSSBrowserFixture() async throws {
    let cases = try XCTUnwrap(try facts()["browserFixture"] as? [String: Any])["cases"] as? [[String: Any]]
    let samples: [String: String] = [
      "lines": Array(repeating: "A plain text line", count: 10).joined(separator: "  \n"),
      "paragraphs": Array(repeating: "A paragraph that is long enough to be visible.", count: 10).joined(separator: "\n\n"),
      "list": Array(repeating: "- A list item", count: 10).joined(separator: "\n"),
      "quote": Array(repeating: "> A quote line  ", count: 10).joined(separator: "\n"),
      "loose-list": "- First paragraph\n\n  Second paragraph\n\n" + Array(repeating: "- Other item", count: 8).joined(separator: "\n"),
      "nested-list": "- Level one\n  - Level two\n    - Level three\n" + Array(repeating: "- Other item", count: 7).joined(separator: "\n"),
      "headings": (1...6).map { String(repeating: "#", count: $0) + " Heading \($0)" }.joined(separator: "\n\n")
    ]
    for sample in try XCTUnwrap(cases) {
      let name = try XCTUnwrap(sample["name"] as? String), source = try XCTUnwrap(samples[name])
      let (_, root, body, layout) = try await host(source)
      XCTAssertEqual(body.bounds.height, try XCTUnwrap(sample["full"] as? Double), accuracy: 1, name)
      XCTAssertEqual(layout.lineCount, name == "headings" ? 6 : 10, name)
      if name == "nested-list" {
        for (level, expected) in [("Level one", 26.0), ("Level two", 52.0), ("Level three", 78.0)] {
          let leaf = try XCTUnwrap(textViews(root).first { $0.string == level })
          XCTAssertEqual(body.convert(leaf.bounds, from: leaf).minX, expected, accuracy: 1)
        }
        XCTAssertEqual((1...4).map { PRCommentMarkdownTypography.listMarker("•", depth: $0) }, ["•", "◦", "■", "■"])
        XCTAssertEqual(PRCommentMarkdownTypography.listMarker("123.", depth: 3), "123.")
      }
      if let directory = ProcessInfo.processInfo.environment["SHIPIOS_PR_MARKDOWN_RENDER_DIR"] {
        let rect = root.convert(body.bounds, from: body)
        let bitmap = try XCTUnwrap(root.bitmapImageRepForCachingDisplay(in: rect))
        root.cacheDisplay(in: rect, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: directory).appendingPathComponent(name + ".png"))
      }
      if name == "headings" { XCTAssertNil(layout.previewHeight) }
      else { XCTAssertEqual(try XCTUnwrap(layout.previewHeight), try XCTUnwrap(sample["preview"] as? Double), accuracy: 1, name) }
    }
  }
  func testFractionalHeadingFontsAndLineHeightsKeepSmallTextStyle() async throws {
    let source = (1...6).map { String(repeating: "#", count: $0) + " Heading \($0)" }.joined(separator: "\n\n")
    let (_, root, _, _) = try await host(source)
    let views = textViews(root).sorted { $0.string < $1.string }
    XCTAssertEqual(views.count, 6)
    for (index, view) in views.enumerated() {
      let font = try XCTUnwrap(view.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
      let paragraph = try XCTUnwrap(view.textStorage?.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
      XCTAssertEqual(font.pointSize, [19.5, 16.25, 14.625, 13, 13, 13][index], accuracy: 0.001)
      XCTAssertEqual(paragraph.minimumLineHeight, [26, 22.75, 22.75, 19.5, 21.125, 21.125][index], accuracy: 0.001)
      XCTAssertEqual(paragraph.maximumLineHeight, paragraph.minimumLineHeight)
    }
  }
  func testSmallCommentFontRemainsThirteenAtCustomChatFontSize() async throws {
    let (_, root, body, layout) = try await host(Array(repeating: "Small body line", count: 10).joined(separator: "  \n"), uiSize: 18.5)
    let text = try XCTUnwrap(textViews(root).first)
    XCTAssertEqual(try XCTUnwrap(text.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont).pointSize, 13)
    XCTAssertEqual(body.bounds.height, 211.25, accuracy: 1)
    XCTAssertEqual(try XCTUnwrap(layout.previewHeight), 126.75, accuracy: 1)
  }

  func testSourceChangeRejectsOldLineReportsAndClearsCollapsedPreview() async throws {
    let layout = PRCommentMarkdownLayout(); layout.prepare("old")
    let anchor = NSView(frame: .init(x: 0, y: 0, width: 500, height: 500)), leaf = NSView(frame: .init(x: 0, y: 0, width: 500, height: 500))
    let window = NSWindow(contentRect: anchor.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.contentView = anchor; anchor.addSubview(leaf); layout.bind(anchor)
    defer { layout.unbind(anchor); window.contentView = nil; window.close() }
    let lines = (0..<10).map { CGRect(x: 0, y: CGFloat($0) * 21.125, width: 100, height: 21.125) }
    layout.record(leaf, lines: lines, trailing: 0, source: "old"); try await settle(anchor)
    XCTAssertEqual(layout.lineCount, 10); XCTAssertNotNil(layout.previewHeight)
    layout.prepare("new"); layout.record(leaf, lines: lines, trailing: 0, source: "old"); try await settle(anchor)
    XCTAssertEqual(layout.lineCount, 0); XCTAssertNil(layout.previewHeight)
    layout.record(leaf, lines: [lines[0]], trailing: 0, source: "new"); try await settle(anchor)
    XCTAssertEqual(layout.lineCount, 1); XCTAssertNil(layout.previewHeight)
    layout.remove(leaf); try await settle(anchor); XCTAssertEqual(layout.lineCount, 0)
  }
  func testActualTextReflowsOnWindowResizeAndSourceReplacementClearsOldPreview() async throws {
    let input = Input(), layout = PRCommentMarkdownLayout()
    _ = NSApplication.shared
    let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 500, height: 1200), styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    var body: NSView?
    let root = NSHostingView(rootView: AnyView(DynamicBody(input: input, layout: layout, capture: { body = $0 })))
    window.contentView = root
    defer { window.contentView = nil; window.close() }
    try await settle(root); let initialLines = layout.lineCount
    XCTAssertEqual(initialLines, 10)
    XCTAssertEqual(try XCTUnwrap(layout.previewHeight), 126.75, accuracy: 1)
    input.width = 170; window.setContentSize(.init(width: 170, height: 1200)); try await settle(root)
    XCTAssertGreaterThan(layout.lineCount, initialLines)
    XCTAssertEqual(try XCTUnwrap(layout.previewHeight), 126.75, accuracy: 1)
    input.source = "Short replacement"; try await settle(root)
    XCTAssertEqual(layout.lineCount, 1); XCTAssertNil(layout.previewHeight)
    XCTAssertEqual(try XCTUnwrap(body).bounds.height, 21.125, accuracy: 1)
    XCTAssertEqual(textViews(root).map(\.string), ["Short replacement"])
  }

  func testNativeBodyRemainsSelectableAndPreservesInlineLinksAndCodeSize() async throws {
    let (_, root, _, _) = try await host("Plain **bold** and `code` with [a link](https://example.com).")
    let view = try XCTUnwrap(textViews(root).first), storage = try XCTUnwrap(view.textStorage)
    XCTAssertTrue(view.isSelectable); XCTAssertFalse(view.isEditable); XCTAssertFalse(view.drawsBackground)
    let code = (view.string as NSString).range(of: "code"), link = (view.string as NSString).range(of: "a link")
    XCTAssertEqual(try XCTUnwrap(storage.attribute(.font, at: code.location, effectiveRange: nil) as? NSFont).pointSize, 11.96, accuracy: 0.001)
    XCTAssertEqual(storage.attribute(.link, at: link.location, effectiveRange: nil) as? URL, URL(string: "https://example.com"))
    view.setSelectedRange(link); root.layoutSubtreeIfNeeded(); XCTAssertEqual(view.selectedRange(), link)
    var opened: URL?; view.open = { opened = $0 }
    XCTAssertTrue(view.textView(view, clickedOnLink: URL(string: "https://example.com")!, at: link.location))
    XCTAssertEqual(opened, URL(string: "https://example.com"))
  }
}
