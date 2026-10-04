import AppKit
import SwiftUI
import XCTest
@testable import ShipiOS

@MainActor final class PRCommentTableCopyTests: XCTestCase {
  private let markdown = "| Name | Value |\n| :--- | ---: |\n| Alpha | **12** |\n| Beta | `345` |"
  private func table(_ source: String) throws -> MessageBlock {
    func find(_ blocks: [MessageBlock]) -> MessageBlock? {
      for block in blocks { if block.kind == .table { return block }; if let found = find(block.children) { return found } }
      return nil
    }
    return try XCTUnwrap(find(MessageDocument.parse(source)))
  }
  private func event(_ code: UInt16, flags: NSEvent.ModifierFlags = [], repeatKey: Bool = false, type: NSEvent.EventType = .keyDown) throws -> NSEvent {
    try XCTUnwrap(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: 0,
      windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: repeatKey, keyCode: code))
  }
  private func host() -> (NSWindow, PRCommentTableCopyToolbar.Surface) {
    _ = NSApplication.shared
    let surface = PRCommentTableCopyToolbar.Surface(frame: .init(x: 0, y: 0, width: 40, height: 40))
    let root = NSView(frame: .init(x: 0, y: 0, width: 500, height: 400)); root.addSubview(surface)
    let window = NSWindow(contentRect: root.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.contentView = root; root.layoutSubtreeIfNeeded()
    addTeardownBlock { @MainActor in surface.button.retire(); window.contentView = nil; window.close() }
    return (window, surface)
  }
  func testOriginalTableSourcePreservesSpacingSyntaxUnicodeAndCRLF() throws {
    let raw = "| 名称 🧪 | 值 |\n|:---|---:|\n| **甲** | a\\|b |"
    XCTAssertEqual(try table("Before\n\n" + raw + "\n\nAfter").source, raw)
    XCTAssertEqual(try table(raw.replacingOccurrences(of: "\n", with: "\r\n")).source, raw)
    XCTAssertEqual(try table(raw + "  \n").source, raw)
  }
  func testNestedQuoteAndListSourcesExcludeOnlyContainerPrefixes() throws {
    XCTAssertEqual(try table(markdown.split(separator: "\n").map { "> " + $0 }.joined(separator: "\n")).source, markdown)
    XCTAssertEqual(try table("- " + markdown.split(separator: "\n").joined(separator: "\n  ")).source, markdown)
    let lazy = "> | a | b |\n> |---|---|\n| c | d |"
    XCTAssertEqual(try table(lazy).source, "| a | b |\n|---|---|", "The unquoted body line is outside this rendered table")
  }
  func testClipboardContainsMarkdownAndSemanticHTMLWithoutRendererDecorations() throws {
    let block = try table(markdown), value = try XCTUnwrap(PRCommentTableClipboard(block: block))
    XCTAssertEqual(value.markdown, markdown)
    let fixtureURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/pr_comment_table_copy_reference.json")
    let facts = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: fixtureURL)) as? [String: Any])
    let clipboard = try XCTUnwrap(facts["clipboard"] as? [String: Any])
    XCTAssertEqual(value.html, try XCTUnwrap(clipboard["html"] as? String))
    let pasteboard = NSPasteboard.withUniqueName(); defer { pasteboard.releaseGlobally() }
    XCTAssertTrue(value.write(to: pasteboard))
    XCTAssertEqual(pasteboard.string(forType: .string), markdown); XCTAssertEqual(pasteboard.string(forType: .html), value.html)
    XCTAssertEqual(pasteboard.pasteboardItems?.count, 1)
    XCTAssertNil(PRCommentTableClipboard(block: .init(id: "empty", kind: .table)))
    XCTAssertNil(PRCommentTableClipboard(block: try table("| | |\n|---|---|\n| | |")))
  }
  func testHTMLPreservesSafeInlineLinksAndEscapesTextInsteadOfExecutingIt() {
    var value = AttributedString("<script>&\"")
    value.inlinePresentationIntent = [.stronglyEmphasized, .emphasized, .strikethrough]
    value.link = URL(string: "https://example.com/?a=1&b=2")
    let html = PRCommentTableClipboard.inlineHTML(value)
    XCTAssertEqual(html, "<a href=\"https://example.com/?a=1&amp;b=2\"><strong><em><del>&lt;script&gt;&amp;&quot;</del></em></strong></a>")
    value.link = URL(string: "javascript:alert(1)")
    XCTAssertFalse(PRCommentTableClipboard.inlineHTML(value).contains("href="))
  }
  func testHiddenToolbarParticipatesInKeyboardFocusAndHoverUsesFortyPointSurface() {
    let (window, surface) = host(), button = surface.button
    XCTAssertEqual(button.frame, .init(x: 2, y: 2, width: 36, height: 36))
    XCTAssertFalse(surface.visible); XCTAssertNil(surface.hitTest(.init(x: 10, y: 10)))
    XCTAssertTrue(button.canBecomeKeyView); XCTAssertTrue(window.makeFirstResponder(button))
    XCTAssertTrue(surface.visible)
    window.makeFirstResponder(nil); surface.tableHovered = true; XCTAssertTrue(surface.visible)
    XCTAssertNotNil(surface.hitTest(.init(x: 10, y: 10)))
  }
  func testReturnSpaceSuccessSuppressesRepeatedCopiesAndResetsAfterTwoSeconds() async throws {
    let (window, surface) = host(), button = surface.button
    button.configure(try XCTUnwrap(PRCommentTableClipboard(block: table(markdown))))
    var copies = 0; button.write = { _ in copies += 1; return true }
    XCTAssertTrue(window.makeFirstResponder(button))
    button.keyDown(with: try event(36)); XCTAssertEqual(copies, 1); XCTAssertTrue(button.copied)
    XCTAssertEqual(button.accessibilityLabel(), "已复制")
    button.keyDown(with: try event(49)); button.keyUp(with: try event(49, type: .keyUp))
    XCTAssertTrue(button.accessibilityPerformPress()); XCTAssertEqual(copies, 1)
    try await Task.sleep(for: .milliseconds(1100)); XCTAssertTrue(button.copied)
    try await Task.sleep(for: .milliseconds(1050)); XCTAssertFalse(button.copied)
    XCTAssertEqual(button.accessibilityLabel(), "复制表格")
    button.keyDown(with: try event(49, repeatKey: true)); XCTAssertEqual(copies, 1)
    button.keyDown(with: try event(49)); XCTAssertEqual(copies, 1)
    button.keyUp(with: try event(49, type: .keyUp)); XCTAssertEqual(copies, 2)
  }
  func testSpaceReleaseRechecksFocusModalAndCurrentSourceBeforeCopy() throws {
    final class Scope: WindowModalScope { let modalRoot = NSView(); var modalScopeActive = true }
    let (window, surface) = host(), button = surface.button
    let payload = try XCTUnwrap(PRCommentTableClipboard(block: table(markdown)))
    button.configure(payload); var count = 0; button.write = { _ in count += 1; return true }
    XCTAssertTrue(window.makeFirstResponder(button))
    button.keyDown(with: try event(49)); window.makeFirstResponder(nil)
    button.keyUp(with: try event(49, type: .keyUp)); XCTAssertEqual(count, 0)
    XCTAssertTrue(window.makeFirstResponder(button)); button.keyDown(with: try event(49))
    let scope = Scope(); window.contentView?.addSubview(scope.modalRoot); WindowModalInteraction.install(scope, in: window)
    button.keyUp(with: try event(49, type: .keyUp)); XCTAssertEqual(count, 0)
    WindowModalInteraction.remove(scope, from: window)
    button.keyDown(with: try event(49)); button.configure(nil)
    button.keyUp(with: try event(49, type: .keyUp)); XCTAssertEqual(count, 0)
    button.configure(payload); button.keyUp(with: try event(49, type: .keyUp)); XCTAssertEqual(count, 0)
  }
  func testFailedCopyAndReplacementRetirementCannotReportStaleSuccess() throws {
    let (_, surface) = host(), button = surface.button
    button.configure(try XCTUnwrap(PRCommentTableClipboard(block: table(markdown))))
    button.write = { _ in false }; XCTAssertTrue(button.accessibilityPerformPress()); XCTAssertFalse(button.copied)
    button.write = { _ in true }; XCTAssertTrue(button.accessibilityPerformPress()); XCTAssertTrue(button.copied)
    button.configure(try XCTUnwrap(PRCommentTableClipboard(block: table(markdown.replacingOccurrences(of: "Alpha", with: "New")))))
    XCTAssertFalse(button.copied); XCTAssertTrue(button.payload?.markdown.contains("New") == true)
    button.retire(); XCTAssertFalse(button.accessibilityPerformPress()); XCTAssertFalse(button.canBecomeKeyView)
  }
  func testOwningWindowModalAndLatestDisableProtectClipboard() throws {
    final class Scope: WindowModalScope { let modalRoot = NSView(); var modalScopeActive = true }
    let (window, surface) = host(), button = surface.button, scope = Scope()
    button.configure(try XCTUnwrap(PRCommentTableClipboard(block: table(markdown))))
    var count = 0; button.write = { _ in count += 1; return true }
    window.contentView?.addSubview(scope.modalRoot); WindowModalInteraction.install(scope, in: window)
    defer { WindowModalInteraction.remove(scope, from: window) }
    XCTAssertFalse(button.accessibilityPerformPress()); XCTAssertEqual(count, 0)
    scope.modalScopeActive = false; button.isEnabled = false
    XCTAssertFalse(button.accessibilityPerformPress()); XCTAssertEqual(count, 0)
    button.isEnabled = true; XCTAssertTrue(button.accessibilityPerformPress()); XCTAssertEqual(count, 1)
  }
  func testNativeScrollerArrowAndOptionPagePreserveVerticalPosition() throws {
    let (window, surface) = host(), button = surface.button
    let scroll = NSScrollView(frame: .init(x: 0, y: 50, width: 200, height: 100))
    let document = NSView(frame: .init(x: 0, y: 0, width: 800, height: 400)), anchor = NSView()
    document.addSubview(anchor); scroll.documentView = document; window.contentView?.addSubview(scroll)
    scroll.contentView.scroll(to: .init(x: 0, y: 60))
    let target = PRCommentTableScrollTarget(); target.anchor = anchor
    button.scroll = { target.scroll($0, page: $1) }
    button.keyDown(with: try event(124)); XCTAssertEqual(scroll.contentView.bounds.minX, 40)
    XCTAssertEqual(scroll.contentView.bounds.minY, 60)
    button.keyDown(with: try event(124, flags: .option)); XCTAssertEqual(scroll.contentView.bounds.minX, 240)
    button.keyDown(with: try event(123)); XCTAssertEqual(scroll.contentView.bounds.minX, 200)
    button.keyDown(with: try event(124, flags: .shift)); XCTAssertEqual(scroll.contentView.bounds.minX, 200)
    anchor.removeFromSuperview(); XCTAssertFalse(target.scroll(40, page: false))
  }
  func testLateAnchorTeardownKeepsReplacementAndCurrentTeardownRetiresIt() {
    let target = PRCommentTableScrollTarget(), old = NSView(), next = NSView()
    let oldOwner = PRCommentTableScrollAnchor.Coordinator(target), nextOwner = PRCommentTableScrollAnchor.Coordinator(target)
    target.anchor = next
    PRCommentTableScrollAnchor.dismantleNSView(old, coordinator: oldOwner)
    XCTAssertTrue(target.anchor === next)
    PRCommentTableScrollAnchor.dismantleNSView(next, coordinator: nextOwner)
    XCTAssertNil(target.anchor)
  }
}
