import AppKit
import SwiftUI
import XCTest

@testable import ShipiOS

final class ComposerTextEditorTests: XCTestCase {
  @MainActor func testClickFocusWithoutTypingSurvivesUnrelatedViewUpdate() async throws {
    _ = NSApplication.shared
    var text = "Keep this draft", focused = false
    let request = UUID()
    func root(_ placeholder: String) -> some View {
      ComposerTextEditor(text: Binding(get: { text }, set: { text = $0 }),
        focused: Binding(get: { focused }, set: { focused = $0 }), plainTextMode: false,
        placeholder: placeholder, accessibilityLabel: "Composer", focusRequest: request,
        onKey: { _, _, _ in false }, onPasteAttachments: { _ in })
        .frame(width: 400, height: 100)
    }
    let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 400, height: 100),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    let host = NSHostingView(rootView: root("Message"))
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    let editor = try XCTUnwrap(descendants(host).compactMap { $0 as? ComposerNativeTextView }.first)
    XCTAssertTrue(window.makeFirstResponder(editor))
    editor.setSelectedRange(.init(location: 5, length: 4))
    host.rootView = root("Update during focus handoff")
    host.layoutSubtreeIfNeeded()
    try await Task.sleep(for: .milliseconds(30))
    XCTAssertTrue(focused, "Focus must be published before the user types the first character")
    host.rootView = root("Changed surrounding UI")
    host.layoutSubtreeIfNeeded()
    try await Task.sleep(for: .milliseconds(30))
    XCTAssertTrue(window.firstResponder === editor)
    XCTAssertEqual(editor.selectedRange(), .init(location: 5, length: 4))
    XCTAssertEqual(text, "Keep this draft")
    window.makeFirstResponder(nil)
    try await Task.sleep(for: .milliseconds(30))
    XCTAssertFalse(focused, "Leaving the editor must clear its focus binding")
    window.makeFirstResponder(editor)
    window.makeFirstResponder(nil)
    window.makeFirstResponder(editor)
    try await Task.sleep(for: .milliseconds(30))
    XCTAssertTrue(focused, "Queued transitions must publish the latest responder")
    focused = false
    host.rootView = root("Explicit blur")
    host.layoutSubtreeIfNeeded()
    try await Task.sleep(for: .milliseconds(30))
    XCTAssertFalse(window.firstResponder === editor, "Explicit model blur must still work")
  }

  @MainActor func testDisabledRetainedEditorCannotReclaimFocusOrAcceptInput() async throws {
    _ = NSApplication.shared
    var text = "Retained draft"
    func root(enabled: Bool, request: UUID) -> some View {
      ComposerTextEditor(text: Binding(get: { text }, set: { text = $0 }),
        focused: .constant(true), plainTextMode: false, placeholder: "Message",
        accessibilityLabel: "Composer", focusRequest: request,
        onKey: { _, _, _ in XCTFail("Disabled editor must not dispatch keys"); return false },
        onPasteAttachments: { _ in XCTFail("Disabled editor must not paste attachments") })
        .disabled(!enabled).frame(width: 400, height: 100)
    }
    let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 400, height: 100),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    let host = NSHostingView(rootView: root(enabled: true, request: UUID()))
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    try await Task.sleep(for: .milliseconds(50))
    func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    let editor = try XCTUnwrap(descendants(host).compactMap { $0 as? ComposerNativeTextView }.first)
    XCTAssertTrue(editor.acceptsFirstResponder)
    window.makeFirstResponder(editor)
    editor.coordinator?.requestFocus(in: editor)
    host.rootView = root(enabled: false, request: UUID())
    host.layoutSubtreeIfNeeded()
    try await Task.sleep(for: .milliseconds(80))
    let retained = try XCTUnwrap(descendants(host).compactMap { $0 as? ComposerNativeTextView }.first)
    XCTAssertTrue(retained === editor, "Hiding settings must not discard the native editor")
    XCTAssertFalse(editor.isEditable)
    XCTAssertFalse(editor.isSelectable)
    XCTAssertFalse(editor.acceptsFirstResponder)
    XCTAssertFalse(window.firstResponder === editor)
    let key = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
      timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "x",
      charactersIgnoringModifiers: "x", isARepeat: false, keyCode: 7))
    editor.keyDown(with: key)
    editor.paste(nil)
    XCTAssertEqual(editor.string, "Retained draft")
    XCTAssertEqual(text, "Retained draft")
    host.rootView = root(enabled: true, request: UUID())
    host.layoutSubtreeIfNeeded()
    try await Task.sleep(for: .milliseconds(50))
    XCTAssertTrue(editor.isEditable)
    XCTAssertTrue(editor.acceptsFirstResponder)
    XCTAssertEqual(editor.string, "Retained draft")
  }

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
