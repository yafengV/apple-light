import AppKit
import SwiftUI
import XCTest
@testable import ShipiOS

@MainActor final class LegacyMessageLinkTests: XCTestCase {
  private let first = URL(string: "https://example.invalid/first")!
  private let second = URL(string: "https://example.invalid/second")!

  func testNativeConversionRetainsMarkdownFontsAndSearchColors() throws {
    let markdown = try AttributedString(markdown: "Plain **bold** *italic* `code` ~~strike~~ [First](https://example.invalid/first)")
    let text = ConversationHighlight.apply(markdown, query: "First", activeRange: NSRange(location: 30, length: 5))
    let native = LegacyMessageLinkText.attributedText(text, appearance: .init(), size: 19,
      weight: .semibold, lineSpacing: 7, alignment: .trailing, secondary: true)
    func attrs(_ word: String) -> [NSAttributedString.Key: Any] {
      native.attributes(at: (native.string as NSString).range(of: word).location, effectiveRange: nil)
    }
    let bold = try XCTUnwrap(attrs("bold")[.font] as? NSFont)
    XCTAssertTrue(NSFontManager.shared.traits(of: bold).contains(.boldFontMask))
    let italic = try XCTUnwrap(attrs("italic")[.font] as? NSFont)
    XCTAssertTrue(NSFontManager.shared.traits(of: italic).contains(.italicFontMask))
    XCTAssertTrue(try XCTUnwrap(attrs("code")[.font] as? NSFont).isFixedPitch)
    XCTAssertEqual(attrs("strike")[.strikethroughStyle] as? Int, NSUnderlineStyle.single.rawValue)
    XCTAssertEqual(attrs("Plain")[.foregroundColor] as? NSColor, .secondaryLabelColor)
    XCTAssertEqual(attrs("First")[.link] as? URL, first)
    XCTAssertNotNil(attrs("First")[.backgroundColor])
    XCTAssertEqual(attrs("First")[.foregroundColor] as? NSColor, NSColor(Color.black))
    let paragraph = try XCTUnwrap(attrs("Plain")[.paragraphStyle] as? NSParagraphStyle)
    XCTAssertEqual(paragraph.lineSpacing, 7)
    XCTAssertEqual(paragraph.alignment, .right)
    XCTAssertEqual(bold.pointSize, AppearancePreferences().nativeFont(size: 19).pointSize)
  }

  func testAccessibleLinksCoalesceStyleRunsButKeepRepeatedLinksSeparate() throws {
    let text = try AttributedString(markdown: "[First **bold**](https://example.invalid/first) plain [First](https://example.invalid/second) [Again](https://example.invalid/first) [file](file:///tmp/file.txt)")
    let links = MessageAccessibleLink.links(in: text)
    XCTAssertEqual(links.map(\.label), ["First bold", "First", "Again"])
    XCTAssertEqual(links.map(\.url), [first, second, first])
    XCTAssertEqual(Set(links.map(\.id)).count, 3)
    XCTAssertNotEqual(links[0].title(for: .copy), links[1].title(for: .copy))
    XCTAssertTrue(links[0].title(for: .copy).contains(first.absoluteString))
  }

  func testSelectionSurvivesHighlightUpdatesAndClampsWhenTextShrinks() {
    let view = LegacyMessageLinkText.TextView()
    view.update(NSAttributedString(string: "first second"))
    view.setSelectedRange(.init(location: 6, length: 6))
    view.update(NSAttributedString(string: "first second", attributes: [.backgroundColor: NSColor.yellow]))
    XCTAssertEqual(view.selectedRange(), .init(location: 6, length: 6))
    view.update(NSAttributedString(string: "first"))
    XCTAssertEqual(view.selectedRange(), .init(location: 5, length: 0))
  }

  func testForcedLegacyRenderingWrapsAndRoutesMenusAndModifiedClicks() async throws {
    _ = NSApplication.shared
    let text = try AttributedString(markdown: "Plain [First](https://example.invalid/first) and [second long link that wraps onto several lines and keeps the entire destination available when the window becomes narrower](https://example.invalid/second) tail")
    let highlighted = ConversationHighlight.apply(text, query: "First", activeRange: .init(location: 6, length: 5))
    var clicks: [(URL, WebLinkClick)] = []
    var performed: [(URL, MessageLinkAction)] = []
    let root = LegacyMessageLinkText(text: highlighted, fontSize: 16, weight: .regular,
      actions: .init(activate: { clicks.append(($0, $1)) }, perform: { performed.append(($0, $1)) }))
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 240, height: 180),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    let host = NSHostingView(rootView: root)
    window.contentView = host
    func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    var heights: [CGFloat] = []
    for width in [240.0, 420.0] {
      window.setContentSize(.init(width: width, height: 180))
      host.layoutSubtreeIfNeeded()
      try await Task.sleep(for: .milliseconds(40))
      host.layoutSubtreeIfNeeded()
      let view = try XCTUnwrap(descendants(host).compactMap { $0 as? LegacyMessageLinkText.TextView }.first)
      XCTAssertEqual(host.bounds.width, width, accuracy: 1)
      XCTAssertEqual(host.bounds.height, 180, accuracy: 1)
      XCTAssertTrue(view.isSelectable)
      XCTAssertFalse(view.isEditable)
      let manager = try XCTUnwrap(view.layoutManager), container = try XCTUnwrap(view.textContainer)
      manager.ensureLayout(for: container)
      heights.append(manager.usedRect(for: container).height)
      XCTAssertLessThanOrEqual(manager.usedRect(for: container).width, width + 1)
      let glyph = manager.glyphIndexForCharacter(at: 7)
      let rect = manager.boundingRect(forGlyphRange: .init(location: glyph, length: 1), in: container)
      let point = NSPoint(x: rect.midX + view.textContainerOrigin.x, y: rect.midY + view.textContainerOrigin.y)
      XCTAssertEqual(view.link(at: point), first)
      XCTAssertNil(view.link(at: .init(x: width - 1, y: 170)))
      let menu = try XCTUnwrap(view.linkMenu(second))
      let copy = menu.items[3]
      _ = try XCTUnwrap(copy.target as? NSObject).perform(try XCTUnwrap(copy.action))
      XCTAssertEqual(performed.last?.0, second)
      XCTAssertEqual(performed.last?.1, .copy)
      XCTAssertNil(view.linkMenu(URL(fileURLWithPath: "/tmp/file")))
      XCTAssertEqual(view.accessibilityCustomActions()?.count, 8)
      let location = view.convert(point, to: nil)
      func event(_ type: NSEvent.EventType, delta: CGFloat = 0) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(with: type,
          location: .init(x: location.x + delta, y: location.y), modifierFlags: .option,
          timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 0))
      }
      let count = clicks.count
      view.mouseDown(with: try event(.leftMouseDown))
      view.mouseUp(with: try event(.leftMouseUp))
      XCTAssertEqual(clicks.count, count + 1)
      XCTAssertEqual(clicks.last?.0, first)
      XCTAssertEqual(clicks.last?.1.modifiers, .option)
      view.mouseDown(with: try event(.leftMouseDown))
      view.mouseDragged(with: try event(.leftMouseDragged, delta: 10))
      view.mouseUp(with: try event(.leftMouseUp))
      XCTAssertEqual(clicks.count, count + 1)
      if let directory = ProcessInfo.processInfo.environment["SHIPIOS_SETTINGS_SNAPSHOTS"] {
        let url = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
          .write(to: url.appendingPathComponent("message-links-legacy-\(Int(width)).png"))
      }
    }
    XCTAssertGreaterThan(heights[0], heights[1])
  }
}
