import AppKit
import SwiftUI
import WebKit
import XCTest
@testable import ShipiOS

@MainActor final class CodeSyntaxTests: XCTestCase {
  private func file(_ path: String = "Main.swift", _ text: String = "let value = \"你好 👩🏽‍💻\"") -> GitHubPRCodeFile {
    .init(path: path, oldPath: nil, patch: "@@ -0,0 +1,1 @@\n+" + text + "\n", kind: .added, binary: false)
  }
  private func plain(_ input: CodeSyntaxInput) -> CodeSyntaxResult {
    let style = CodeSyntaxToken.Style(color: nil, fontStyle: 0)
    func rows(_ left: Bool) -> [CodeSyntaxResult.Row] {
      input.lines.filter { left ? $0.left : $0.right }.map {
        .init(id: $0.id, tokens: $0.text.isEmpty ? [] : [.init(content: $0.text, light: style, dark: style)])
      }
    }
    return .init(language: "text", left: rows(true), right: rows(false))
  }
  private final class Pending: CodeSyntaxHighlighting {
    var inputs: [CodeSyntaxInput] = []
    var continuations: [CheckedContinuation<CodeSyntaxResult, Error>] = []
    func highlight(_ input: CodeSyntaxInput) async throws -> CodeSyntaxResult {
      inputs.append(input)
      return try await withCheckedThrowingContinuation { continuations.append($0) }
    }
  }
  func testInputSeparatesSidesAndExcludesMetadataWithoutChangingRowIDs() {
    let value = GitHubPRCodeFile(path: "Main.swift", oldPath: nil,
      patch: "diff --git a/Main.swift b/Main.swift\n--- a/Main.swift\n+++ b/Main.swift\n@@ -1,2 +1,2 @@\n-old\n+new\n context\n\\ No newline at end of file\n", kind: .modified, binary: false)
    let input = CodeSyntaxInput(value)
    XCTAssertEqual(input.lines.map(\.text), ["old", "new", "context"])
    XCTAssertEqual(input.lines.filter(\.left).map(\.text), ["old", "context"])
    XCTAssertEqual(input.lines.filter(\.right).map(\.text), ["new", "context"])
    XCTAssertEqual(input.lines.map(\.id), value.diff.lines.filter(\.canComment).map(\.id))
    XCTAssertNoThrow(try plain(input).validate(input))
  }
  func testValidationRejectsChangedSourceMissingOrWrongRowsAndInvalidStyles() throws {
    let input = CodeSyntaxInput(file()), expected = plain(input)
    let original = try XCTUnwrap(expected.right.first)
    let bad = CodeSyntaxToken.Style(color: "red); script()", fontStyle: 0)
    for (id, content, style) in [(original.id, "changed", CodeSyntaxToken.Style(color: nil, fontStyle: 0)),
      (999, input.lines[0].text, CodeSyntaxToken.Style(color: nil, fontStyle: 0)),
      (original.id, input.lines[0].text, bad),
      (original.id, input.lines[0].text, CodeSyntaxToken.Style(color: "#008809", fontStyle: 8))] {
      let result = CodeSyntaxResult(language: "swift", left: [], right: [.init(id: id,
        tokens: [.init(content: content, light: style, dark: style)])])
      XCTAssertThrowsError(try result.validate(input))
    }
    XCTAssertThrowsError(try CodeSyntaxResult(language: "swift", left: [], right: []).validate(input))
  }
  func testLateCompletionCannotRecolorNewVersionOrDifferentFile() async throws {
    let service = Pending(), state = CodeSyntaxState(service: service)
    let old = file("Old.swift", "old"), new = file("New.swift", "new")
    let first = Task { await state.load(old) }; await Task.yield()
    let second = Task { await state.load(new) }; await Task.yield()
    XCTAssertEqual(service.inputs.count, 2)
    service.continuations[1].resume(returning: plain(service.inputs[1])); await second.value
    service.continuations[0].resume(returning: plain(service.inputs[0])); await first.value
    XCTAssertEqual(state.identity, CodeSyntaxInput(new).identity)
    XCTAssertEqual(state.right.values.flatMap { $0 }.map(\.content).joined(), "new")
    XCTAssertNil(state.tokens(old.diff.lines.last!, in: old, side: .right))
  }
  func testCancellationAndWindowStateDoNotInstallAnotherPendingResult() async {
    let service = Pending(), state = CodeSyntaxState(service: service), other = CodeSyntaxState(service: service)
    let value = file()
    let first = Task { await state.load(value) }; await Task.yield()
    let second = Task { await other.load(value) }; await Task.yield()
    first.cancel(); state.cancel()
    service.continuations[0].resume(returning: plain(service.inputs[0])); await first.value
    service.continuations[1].resume(returning: plain(service.inputs[1])); await second.value
    XCTAssertNil(state.language); XCTAssertTrue(state.right.isEmpty)
    XCTAssertEqual(other.language, "text"); XCTAssertFalse(other.right.isEmpty)
  }
  func testFailureRemainsReadableAndRetryCanInstallTheSameIdentity() async {
    let service = Pending(), state = CodeSyntaxState(service: service), value = file()
    let first = Task { await state.load(value) }; await Task.yield()
    service.continuations[0].resume(throwing: AgentFailure(message: "failed")); await first.value
    XCTAssertNotNil(state.error); XCTAssertTrue(state.right.isEmpty)
    let retry = Task { await state.load(value) }; await Task.yield()
    service.continuations[1].resume(returning: plain(service.inputs[1])); await retry.value
    XCTAssertNil(state.error); XCTAssertEqual(state.language, "text")
  }
  func testTokenForegroundSurvivesNativeTextRenderingAndOverallForegroundStyle() throws {
    _ = NSApplication.shared
    let value = file(), line = try XCTUnwrap(value.diff.lines.first(where: \.canComment))
    let red = CodeSyntaxToken.Style(color: "#D53538", fontStyle: 0), green = CodeSyntaxToken.Style(color: "#008809", fontStyle: 0)
    let tokens = [CodeSyntaxToken(content: "let", light: red, dark: red), .init(content: " value", light: green, dark: green)]
    let renderer = ImageRenderer(content: CodeSyntaxText.text(line, tokens: tokens, marker: .color, dark: false)
      .font(.system(size: 24, design: .monospaced)).foregroundStyle(.primary).environment(\.colorScheme, .light))
    let image = NSBitmapImageRep(cgImage: try XCTUnwrap(renderer.cgImage))
    var reds = 0, greens = 0
    for y in 0..<image.pixelsHigh { for x in 0..<image.pixelsWide {
      guard let color = image.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), color.alphaComponent > 0.5 else { continue }
      if color.redComponent > color.greenComponent * 1.5 { reds += 1 }
      if color.greenComponent > color.redComponent * 1.5 { greens += 1 }
    } }
    XCTAssertGreaterThan(reds, 10); XCTAssertGreaterThan(greens, 10)
  }
  func testActualOfflineWebKitEngineHighlightsBothThemesAndNeverInterpretsCodeAsHTML() async throws {
    let service = CodeSyntaxService(), input = CodeSyntaxInput(file())
    let result = try await service.highlight(input); try result.validate(input)
    XCTAssertEqual(result.language, "swift"); XCTAssertTrue(service.usesIsolatedDocument)
    let tokens = try XCTUnwrap(result.right.first?.tokens)
    let keyword = try XCTUnwrap(tokens.first { $0.content == "let" })
    XCTAssertEqual(keyword.light.color, "#D53538"); XCTAssertEqual(keyword.dark.color, "#F67576")
    let html = CodeSyntaxInput(file("snippet.html", "<script>globalThis.payloadExecuted=true</script>"))
    try (await service.highlight(html)).validate(html)
    let view = try XCTUnwrap(service.view); XCTAssertNil(view.window)
    for world in [WKContentWorld.page, .defaultClient] {
      let executed = try await view.callAsyncJavaScript("return globalThis.payloadExecuted === true", in: nil, contentWorld: world)
      XCTAssertEqual(executed as? Bool, false)
    }
    let body = try await view.callAsyncJavaScript("return document.body.textContent", in: nil, contentWorld: .page)
    XCTAssertEqual(body as? String, "")
  }
  func testActualEngineKeepsMultilineSideStateUnknownLanguageAndCRSource() async throws {
    let service = CodeSyntaxService()
    let value = GitHubPRCodeFile(path: "Example.swift", oldPath: nil,
      patch: "@@ -1,3 +1,3 @@\n-/* old open\n+let newCode = 42\n still old comment\r\n */\n", kind: .modified, binary: false)
    let input = CodeSyntaxInput(value), result = try await service.highlight(input)
    try result.validate(input)
    let context = try XCTUnwrap(input.lines.first { $0.left && $0.right })
    XCTAssertTrue(try XCTUnwrap(result.left.first { $0.id == context.id }).tokens.filter { $0.content != "\r" }.allSatisfy { $0.light.color == "#666666" })
    let unknown = CodeSyntaxInput(file("unknown.extension", "literal \t🚀"))
    let fallback = try await service.highlight(unknown); try fallback.validate(unknown)
    XCTAssertEqual(fallback.language, "text"); XCTAssertTrue(fallback.right[0].tokens.allSatisfy { $0.light.color == nil })
  }
  func testActualWebKitMatchesCurrentCodexWorkerReferenceFixture() async throws {
    struct Fixture: Decodable {
      struct Item: Decodable { let path: String; let language: String; let lines: [String]; let expected: [[CodeSyntaxToken]] }
      let cases: [Item]
    }
    let url = try XCTUnwrap(Bundle.module.url(forResource: "code_syntax_reference", withExtension: "json", subdirectory: "Fixtures"))
    let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    let service = CodeSyntaxService()
    for item in fixture.cases {
      let count = item.lines.count
      let value = GitHubPRCodeFile(path: item.path, oldPath: nil,
        patch: "@@ -0,0 +1,\(count) @@\n" + item.lines.map { "+" + $0 }.joined(separator: "\n") + "\n", kind: .added, binary: false)
      let result = try await service.highlight(CodeSyntaxInput(value))
      XCTAssertEqual(result.language, item.language, item.path)
      XCTAssertEqual(result.right.map(\.tokens), item.expected, item.path)
    }
    XCTAssertEqual(fixture.cases.count, 19); XCTAssertTrue(service.usesIsolatedDocument)
  }
  func testMissingOrCorruptResourceFailsWithoutOpeningAWindowOrWebsite() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("syntax-invalid-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    let service = CodeSyntaxService(resources: directory)
    do { _ = try await service.highlight(CodeSyntaxInput(file())); XCTFail("Missing resource must fail") } catch {}
    XCTAssertNil(service.view)
    try Data("invalid".utf8).write(to: directory.appendingPathComponent("engine.js"))
    try Data("{\"format\":1,\"sha256\":\"wrong\",\"bytes\":7}".utf8).write(to: directory.appendingPathComponent("manifest.json"))
    do { _ = try await service.highlight(CodeSyntaxInput(file())); XCTFail("Corrupt resource must fail") } catch {}
    XCTAssertNil(service.view)
  }
}
