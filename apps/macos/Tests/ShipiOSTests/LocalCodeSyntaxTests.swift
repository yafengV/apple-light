import AppKit
import SwiftUI
import WebKit
import XCTest
@testable import ShipiOS

@MainActor final class LocalCodeSyntaxTests: XCTestCase {
  private final class Pending: CodeSyntaxHighlighting {
    var inputs: [CodeSyntaxInput] = []
    var continuations: [CheckedContinuation<CodeSyntaxResult, Error>] = []
    func highlight(_ input: CodeSyntaxInput) async throws -> CodeSyntaxResult {
      inputs.append(input)
      return try await withCheckedThrowingContinuation { continuations.append($0) }
    }
  }
  private func plain(_ input: CodeSyntaxInput, light: String = "#D53538", dark: String = "#F67576", fontStyle: Int = 0) -> CodeSyntaxResult {
    func rows(_ left: Bool) -> [CodeSyntaxResult.Row] {
      input.lines.filter { left ? $0.left : $0.right }.map {
        .init(id: $0.id, tokens: [.init(content: $0.text,
          light: .init(color: light, fontStyle: fontStyle), dark: .init(color: dark, fontStyle: fontStyle))])
      }
    }
    return .init(language: "swift", left: rows(true), right: rows(false))
  }
  private func appearance(_ dark: Bool = false) -> AppearancePreferences {
    var value = AppearancePreferences(); value.theme = dark ? "dark" : "light"; return value
  }
  private func native(_ source: String) -> (NSScrollView, NSTextView) {
    _ = NSApplication.shared
    let scroll = NSScrollView(frame: .init(x: 0, y: 0, width: 420, height: 160))
    let text = NSTextView(frame: .init(x: 0, y: 0, width: 420, height: 2500))
    text.isEditable = false; text.isRichText = false; text.string = source
    text.isVerticallyResizable = true
    scroll.documentView = text
    return (scroll, text)
  }
  private func hex(_ text: NSTextView, at index: Int) -> String? {
    guard let color = text.textStorage?.attribute(.foregroundColor, at: index, effectiveRange: nil) as? NSColor,
      let rgb = color.usingColorSpace(.sRGB) else { return nil }
    return String(format: "#%02X%02X%02X", Int((rgb.redComponent * 255).rounded()),
      Int((rgb.greenComponent * 255).rounded()), Int((rgb.blueComponent * 255).rounded()))
  }

  func testFullSourcePreservesEveryLineEndingAndHasSeparateIdentityFromDiffs() {
    let source = "let emoji = \"👩🏽‍💻\"\r\n\r\n\tend\r\n"
    let input = CodeSyntaxInput(path: "Main.swift", source: source)
    XCTAssertEqual(input.lines.map(\.text).joined(separator: "\n"), source)
    XCTAssertEqual(input.lines.map(\.id), [0, 1, 2, 3])
    XCTAssertTrue(input.lines.allSatisfy { $0.hunk == 0 && !$0.left && $0.right })
    XCTAssertNotEqual(input.identity, CodeSyntaxInput(path: "Main.swift", diff: .untracked(source)).identity)
    XCTAssertNotEqual(input.identity, CodeSyntaxInput(path: "Other.swift", source: source).identity)
    XCTAssertNotEqual(input.identity, CodeSyntaxInput(path: "Main.swift", source: source + " ").identity)
    XCTAssertNotEqual(CodeSyntaxInput(path: "x", source: "é").identity,
      CodeSyntaxInput(path: "x", source: "e\u{301}").identity)
    XCTAssertNoThrow(try plain(input).validate(input))
    XCTAssertEqual(CodeSyntaxInput(path: "empty", source: "").lines.map(\.text), [""])
  }
  func testValidationRejectsCanonicallyEqualTokensWithDifferentSourceBytes() throws {
    let input = CodeSyntaxInput(path: "Main.swift", source: "e\u{301}")
    let style = CodeSyntaxToken.Style(color: "#D53538", fontStyle: 0)
    let result = CodeSyntaxResult(language: "swift", left: [], right: [.init(id: 0,
      tokens: [.init(content: "é", light: style, dark: style)])])
    XCTAssertEqual(result.right[0].tokens[0].content, input.lines[0].text)
    XCTAssertThrowsError(try result.validate(input))
    XCTAssertNoThrow(try plain(input).validate(input))
  }
  func testLocalDiffUsesOriginalRowsAndResetsEachPartialHunk() async throws {
    let diff = ReviewDiff("@@ -1,1 +1,1 @@\n-/* old\n+/* new\n@@ -10,1 +10,1 @@\n-let before = 1\n+let after = 2\n")
    let input = CodeSyntaxInput(path: "Main.swift", diff: diff), state = CodeSyntaxState(service: CodeSyntaxService())
    XCTAssertEqual(input.lines.map(\.hunk), [1, 1, 2, 2])
    await state.load(input)
    XCTAssertEqual(state.language, "swift")
    let line = try XCTUnwrap(diff.lines.first { $0.newLine == 10 })
    XCTAssertEqual(state.tokens(line, identity: input.identity)?.first?.light.color, "#D53538")
    let other = CodeSyntaxInput(path: "Other.swift", diff: diff)
    XCTAssertNil(state.tokens(line, identity: other.identity))
    XCTAssertEqual(line.newLine, 10)
  }
  func testActualFullSourceCarriesMultilineGrammarAndMatchesReferenceExamples() async throws {
    let service = CodeSyntaxService()
    let input = CodeSyntaxInput(path: "Main.swift", source: "/* start\nlet inside = 1\n*/\nlet outside = 2\n")
    let value = try await service.highlight(input); try value.validate(input)
    XCTAssertTrue(value.right[1].tokens.allSatisfy { $0.light.color == "#666666" })
    XCTAssertEqual(value.right[3].tokens.first?.light.color, "#D53538")
    let view = try XCTUnwrap(service.view)
    _ = try await view.callAsyncJavaScript("""
      const original = globalThis.shipiosSyntax.highlight;
      globalThis.syntaxRecoveries = 0;
      globalThis.shipiosSyntax.highlight = async input => {
        const result = await original(input);
        globalThis.syntaxRecoveries += result.recoveredTokenizations;
        return result;
      };
      """, in: nil, contentWorld: .defaultClient)
    struct Fixture: Decodable {
      struct Item: Decodable { let path: String; let expected: [[CodeSyntaxToken]]; let lines: [String] }
      let cases: [Item]
    }
    let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: XCTUnwrap(
      Bundle.module.url(forResource: "code_syntax_reference", withExtension: "json", subdirectory: "Fixtures"))))
    for item in fixture.cases {
      let source = CodeSyntaxInput(path: item.path, source: item.lines.joined(separator: "\n"))
      let result = try await service.highlight(source)
      XCTAssertEqual(result.right.map(\.tokens), item.expected, item.path)
    }
    let recoveries = try await view.callAsyncJavaScript("return globalThis.syntaxRecoveries", in: nil, contentWorld: .defaultClient)
    print("Offline syntax cold-start recoveries:", recoveries ?? "none")
    XCTAssertTrue(service.usesIsolatedDocument)
  }
  func testActualWebKitRecoversOneControlledTokenizationDeadlineWithoutKeepingPartialColors() async throws {
    let service = CodeSyntaxService(), input = CodeSyntaxInput(path: "Main.swift", source: "let value = 42")
    _ = try await service.highlight(input)
    let arguments = try JSONSerialization.jsonObject(with: JSONEncoder().encode(input))
    let object = try await XCTUnwrap(service.view).callAsyncJavaScript("""
      const now = Date.now;
      let calls = 0;
      Date.now = () => now() + (++calls === 2 ? 1000 : 0);
      try { return await globalThis.shipiosSyntax.highlight(input); }
      finally { Date.now = now; }
      """, arguments: ["input": arguments], in: nil, contentWorld: .defaultClient)
    let result = try XCTUnwrap(object as? [String: Any])
    XCTAssertEqual(result["recoveredTokenizations"] as? Int, 1)
    let value = try JSONDecoder().decode(CodeSyntaxResult.self, from: JSONSerialization.data(withJSONObject: result))
    try value.validate(input)
    XCTAssertEqual(value.right[0].tokens.first?.light.color, "#D53538")
    XCTAssertEqual(value.right[0].tokens.first?.dark.color, "#F67576")
    XCTAssertTrue(service.usesIsolatedDocument)
  }
  func testLateNativeHighlightAndThemeSwitchPreserveSelectionScrollAndSource() async throws {
    let source = "let emoji = \"👩🏽‍💻\"\r\n" + (1...100).map { "let row\($0) = \($0)" }.joined(separator: "\n")
    let (scroll, text) = native(source), service = Pending(), controller = FilePreviewSyntaxController(service: service)
    defer { controller.stop() }
    controller.update(text, path: "/tmp/Main.swift", source: source, ready: true, appearance: appearance())
    await Task.yield()
    text.setSelectedRange(.init(location: 4, length: 12))
    text.layoutManager?.ensureLayout(for: text.textContainer!)
    scroll.contentView.scroll(to: .init(x: 0, y: 180)); scroll.reflectScrolledClipView(scroll.contentView)
    let selection = text.selectedRanges, origin = scroll.contentView.bounds.origin
    service.continuations[0].resume(returning: plain(service.inputs[0], fontStyle: 6))
    try await Task.sleep(for: .milliseconds(25))
    XCTAssertEqual(text.string, source); XCTAssertEqual(text.selectedRanges, selection)
    XCTAssertEqual(scroll.contentView.bounds.origin, origin); XCTAssertNil(text.window)
    XCTAssertEqual(hex(text, at: 0), "#D53538")
    let font = try XCTUnwrap(text.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
    XCTAssertTrue(NSFontManager.shared.traits(of: font).contains(.boldFontMask))
    XCTAssertEqual(text.textStorage?.attribute(.underlineStyle, at: 0, effectiveRange: nil) as? Int, NSUnderlineStyle.single.rawValue)
    let row = (source as NSString).range(of: "let row1")
    XCTAssertEqual(hex(text, at: row.location), "#D53538", "UTF-16 offsets must account for emoji and CRLF")
    controller.update(text, path: "/tmp/Main.swift", source: source, ready: true, appearance: appearance(true))
    XCTAssertEqual(hex(text, at: 0), "#F67576"); XCTAssertEqual(service.inputs.count, 1)
    XCTAssertEqual(text.selectedRanges, selection); XCTAssertEqual(scroll.contentView.bounds.origin, origin)
  }
  func testNativeStaleFileVersionAndUnmountCannotInstallOldColors() async throws {
    let (_, text) = native("old"), service = Pending(), controller = FilePreviewSyntaxController(service: service)
    defer { controller.stop() }
    controller.update(text, path: "Main.swift", source: "old", ready: true, appearance: appearance()); await Task.yield()
    text.string = "new"
    controller.update(text, path: "Main.swift", source: "new", ready: true, appearance: appearance()); await Task.yield()
    service.continuations[1].resume(returning: plain(service.inputs[1], light: "#008809"))
    try await Task.sleep(for: .milliseconds(25))
    service.continuations[0].resume(returning: plain(service.inputs[0]))
    try await Task.sleep(for: .milliseconds(25))
    XCTAssertEqual(text.string, "new"); XCTAssertEqual(hex(text, at: 0), "#008809")
    text.string = "other"
    controller.update(text, path: "Other.swift", source: "other", ready: true, appearance: appearance()); await Task.yield()
    controller.stop()
    service.continuations[2].resume(returning: plain(service.inputs[2], light: "#0000FF"))
    try await Task.sleep(for: .milliseconds(25))
    XCTAssertNotEqual(hex(text, at: 0), "#0000FF"); XCTAssertNil(text.window)
  }
  func testFailureReloadAndSeparateNativePreviewsRemainIndependent() async throws {
    let (_, text) = native("let a = 1"), (_, other) = native("let a = 1"), service = Pending()
    let first = FilePreviewSyntaxController(service: service), second = FilePreviewSyntaxController(service: service)
    defer { first.stop(); second.stop() }
    first.update(text, path: "a.swift", source: text.string, ready: true, appearance: appearance()); await Task.yield()
    second.update(other, path: "a.swift", source: other.string, ready: true, appearance: appearance(true)); await Task.yield()
    service.continuations[0].resume(throwing: AgentFailure(message: "failed"))
    service.continuations[1].resume(returning: plain(service.inputs[1])); try await Task.sleep(for: .milliseconds(25))
    XCTAssertNotNil(first.error); XCTAssertEqual(hex(other, at: 0), "#F67576")
    XCTAssertEqual(text.string, "let a = 1")
    first.update(text, path: "a.swift", source: text.string, ready: false, appearance: appearance())
    first.update(text, path: "a.swift", source: text.string, ready: true, appearance: appearance()); await Task.yield()
    service.continuations[2].resume(returning: plain(service.inputs[2])); try await Task.sleep(for: .milliseconds(25))
    XCTAssertNil(first.error); XCTAssertEqual(hex(text, at: 0), "#D53538"); XCTAssertEqual(hex(other, at: 0), "#F67576")
  }
  func testHiddenNativePreviewKeepsFocusSelectionAndScrollWhenRecoloredAndUpdatesExactUnicodeBytes() async throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("syntax-preview-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root), workspace = DeveloperWorkspace()
    workspace.root = root; workspace.selectedFile = "Main.swift"; workspace.openFiles = ["Main.swift"]
    workspace.fileText = (1...150).map { "let row\($0) = \($0)" }.joined(separator: "\n")
    let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 500, height: 350),
      styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    let host = NSHostingView(rootView: FileSourcePreview(store: store, workspace: workspace)
      .environment(\.appAppearance, appearance()))
    window.contentView = host; host.frame.size = .init(width: 500, height: 350)
    func preview(_ view: NSView) -> FilePreviewTextView? {
      if let text = view as? FilePreviewTextView { return text }
      return view.subviews.compactMap(preview).first
    }
    for _ in 0..<30 {
      try await Task.sleep(for: .milliseconds(50)); host.layoutSubtreeIfNeeded()
      if let text = preview(host), hex(text, at: 0) == "#D53538" { break }
    }
    let text = try XCTUnwrap(preview(host)), scroll = try XCTUnwrap(text.enclosingScrollView)
    XCTAssertEqual(hex(text, at: 0), "#D53538")
    XCTAssertFalse(window.isVisible); window.makeFirstResponder(nil)
    let responder = window.firstResponder
    text.setSelectedRange(.init(location: 200, length: 12))
    text.layoutManager?.ensureLayout(for: text.textContainer!)
    scroll.contentView.scroll(to: .init(x: 0, y: 220)); scroll.reflectScrolledClipView(scroll.contentView)
    let selected = text.selectedRange(), origin = scroll.contentView.bounds.origin
    host.rootView = FileSourcePreview(store: store, workspace: workspace).environment(\.appAppearance, appearance(true))
    try await Task.sleep(for: .milliseconds(100)); host.layoutSubtreeIfNeeded()
    XCTAssertTrue(preview(host) === text); XCTAssertEqual(hex(text, at: 0), "#F67576")
    XCTAssertEqual(text.selectedRange(), selected); XCTAssertEqual(scroll.contentView.bounds.origin, origin)
    XCTAssertTrue(window.firstResponder === responder)
    workspace.fileText = "let value = \"é\""
    try await Task.sleep(for: .milliseconds(100)); host.layoutSubtreeIfNeeded()
    workspace.fileText = "let value = \"e\u{301}\""
    try await Task.sleep(for: .milliseconds(100)); host.layoutSubtreeIfNeeded()
    XCTAssertEqual(Array(text.string.utf8), Array(workspace.fileText.utf8))
    XCTAssertNil(store.workspace.selectedFile)
  }
}
