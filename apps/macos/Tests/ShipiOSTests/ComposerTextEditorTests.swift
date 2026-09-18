import AppKit
import SwiftUI
import XCTest

@testable import ShipiOS

final class ComposerTextEditorTests: XCTestCase {
  func testRichStylePlanRecognizesMarkdownWithoutChangingSourceRanges() throws {
    let source = "# Title\n- item\n**bold** and `code` [site](https://example.com)\n```swift\nlet n = 1\n```"
    let spans = ComposerTextStylePlan.spans(in: source)

    XCTAssertTrue(spans.contains { $0.style == .heading(1) })
    XCTAssertTrue(spans.contains { $0.style == .listMarker })
    XCTAssertTrue(spans.contains { $0.style == .strong })
    XCTAssertTrue(spans.contains { $0.style == .inlineCode })
    XCTAssertTrue(spans.contains { $0.style == .codeBlock })
    XCTAssertTrue(spans.contains { span in
      if case .link(let url) = span.style { return url.absoluteString == "https://example.com" }
      return false
    })
    for span in spans {
      XCTAssertLessThanOrEqual(NSMaxRange(span.range), source.utf16.count)
    }
  }

  @MainActor func testNativeEditorHidesRichMarkersAndPlainModeRestoresLiteralText() throws {
    var value = "**bold** and [site](https://example.com)"
    var focused = false
    func configured(plain: Bool) -> ComposerTextEditor {
      ComposerTextEditor(
        text: Binding(get: { value }, set: { value = $0 }),
        focused: Binding(get: { focused }, set: { focused = $0 }),
        plainTextMode: plain,
        placeholder: "Message",
        accessibilityLabel: "Composer",
        focusRequest: UUID(),
        onKey: { _, _, _ in false },
        onPasteAttachments: { _ in })
    }
    let native = ComposerNativeTextView()
    let coordinator = ComposerTextEditor.Coordinator(configured(plain: false))
    native.delegate = coordinator
    native.coordinator = coordinator
    coordinator.install(value, in: native)

    XCTAssertEqual(native.string, value)
    XCTAssertEqual((native.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize, 0.1)
    let label = (value as NSString).range(of: "site")
    XCTAssertEqual(native.textStorage?.attribute(.link, at: label.location, effectiveRange: nil) as? URL,
      URL(string: "https://example.com"))

    coordinator.parent = configured(plain: true)
    coordinator.sync(value, plainTextMode: true, in: native)
    XCTAssertEqual(native.string, value)
    XCTAssertNil(native.textStorage?.attribute(.link, at: label.location, effectiveRange: nil))
    XCTAssertEqual((native.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize, 14)
  }

  func testRichListContinuationAdvancesOrderedListsAndPreservesIndent() {
    XCTAssertEqual(ComposerTextStylePlan.continuation(after: "- first"), "- ")
    XCTAssertEqual(ComposerTextStylePlan.continuation(after: "  9. ninth"), "  10. ")
    XCTAssertEqual(ComposerTextStylePlan.continuation(after: "3) third"), "4) ")
    XCTAssertNil(ComposerTextStylePlan.continuation(after: "ordinary text"))
    XCTAssertNil(ComposerTextStylePlan.continuation(after: "- "))
    XCTAssertTrue(ComposerTextStylePlan.isEmptyListItem("- "))
    XCTAssertTrue(ComposerTextStylePlan.isEmptyListItem("  3.  "))
    XCTAssertFalse(ComposerTextStylePlan.isEmptyListItem("- content"))
  }
}
