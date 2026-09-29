import AppKit
import SwiftUI
import XCTest
@testable import ShipiOS

@MainActor final class CodeWordDiffTests: XCTestCase {
  private struct Fixture: Decodable {
    struct Item: Decodable { let old: String; let new: String; let left: [CodeWordRange]; let right: [CodeWordRange] }
    let referenceVersion: String
    let cases: [Item]
  }
  private func token(_ text: String, color: String = "#0071EA", fontStyle: Int = 0) -> CodeSyntaxToken {
    .init(content: text, light: .init(color: color, fontStyle: fontStyle), dark: .init(color: color, fontStyle: fontStyle))
  }
  private func source(_ patch: String, wordDiffs: Bool = true) -> CodeSyntaxInput {
    .init(path: "unknown.extension", diff: .init(patch), wordDiffs: wordDiffs)
  }
  private final class Pending: CodeSyntaxHighlighting {
    var continuations: [CheckedContinuation<CodeSyntaxResult, Error>] = []
    func highlight(_ input: CodeSyntaxInput) async throws -> CodeSyntaxResult {
      try await withCheckedThrowingContinuation { continuations.append($0) }
    }
  }
  func testToggleKeepsSyntaxAndDiscardsLateWordResultAfterDisable() async throws {
    let patch = "@@ -1,1 +1,1 @@\n-old\n+new\n"
    let off = source(patch, wordDiffs: false), on = source(patch), service = Pending()
    let state = CodeSyntaxState(service: service)
    func result(_ input: CodeSyntaxInput) -> CodeSyntaxResult {
      func rows(_ left: Bool) -> [CodeSyntaxResult.Row] {
        input.lines.filter { left ? $0.left : $0.right }.map {
          .init(id: $0.id, tokens: [token($0.text)], changes: input.wordDiffs ? [.init(location: 0, length: 3)] : [])
        }
      }
      return .init(language: "text", left: rows(true), right: rows(false))
    }
    let first = Task { await state.load(off) }; await Task.yield()
    service.continuations[0].resume(returning: result(off)); await first.value
    let added = try XCTUnwrap(ReviewDiff(patch).lines.first { $0.kind == .addition })
    let tokens = state.tokens(added, identity: off.identity)
    let enabled = Task { await state.load(on) }; await Task.yield()
    XCTAssertEqual(state.tokens(added, identity: off.identity), tokens)
    let disabled = Task { await state.load(off) }; await Task.yield()
    service.continuations[2].resume(returning: result(off)); await disabled.value
    service.continuations[1].resume(returning: result(on)); await enabled.value
    XCTAssertEqual(state.identity, off.identity); XCTAssertTrue(state.changes(added, identity: off.identity).isEmpty)
    XCTAssertEqual(state.tokens(added, identity: off.identity), tokens)
  }
  func testActualEngineSeparatesWordPreferenceCacheWithoutChangingSyntax() async throws {
    let patch = "@@ -1,1 +1,1 @@\n-old\n+new\n", service = CodeSyntaxService()
    let off = source(patch, wordDiffs: false), on = source(patch)
    XCTAssertNotEqual(off.identity, on.identity)
    let plain = try await service.highlight(off), marked = try await service.highlight(on)
    XCTAssertTrue(plain.right[0].changes.isEmpty); XCTAssertFalse(marked.right[0].changes.isEmpty)
    XCTAssertEqual(plain.right[0].tokens, marked.right[0].tokens)
    let again = try await service.highlight(off); XCTAssertEqual(again, plain)
  }
  func testActualIsolatedWebKitMatchesAllReferenceWordRangesAndPreservesSources() async throws {
    let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf:
      try XCTUnwrap(Bundle.module.url(forResource: "word_diff_reference", withExtension: "json", subdirectory: "Fixtures"))))
    XCTAssertEqual(fixture.referenceVersion, "26.911.61220"); XCTAssertEqual(fixture.cases.count, 2062)
    let service = CodeSyntaxService()
    for start in stride(from: 0, to: fixture.cases.count, by: 400) {
      let items = Array(fixture.cases[start..<min(start + 400, fixture.cases.count)])
      var lines: [[String: Any]] = []
      for (index, item) in items.enumerated() {
        for (side, raw) in [item.old, item.new].enumerated() {
          let newline = raw.hasSuffix("\n")
          let text = newline ? String(String.UnicodeScalarView(raw.unicodeScalars.dropLast())) : raw
          lines.append(["id": index * 2 + side, "text": text, "left": side == 0, "right": side == 1,
            "hunk": index, "hasNewline": newline])
        }
      }
      let data = try JSONSerialization.data(withJSONObject: ["path": "unknown.extension", "fingerprint": "word-reference-\(start)", "lines": lines, "wordDiffs": true])
      let input = try JSONDecoder().decode(CodeSyntaxInput.self, from: data)
      let result = try await service.highlight(input); try result.validate(input)
      XCTAssertEqual(result.left.map(\.changes), items.map(\.left), "left batch \(start)")
      XCTAssertEqual(result.right.map(\.changes), items.map(\.right), "right batch \(start)")
    }
    XCTAssertTrue(service.usesIsolatedDocument); XCTAssertNil(service.view?.window)
  }
  func testMissingFinalNewlineAndCRLFHaveDistinctOffsetsWithoutChangingTokens() async throws {
    let input = source("@@ -1,1 +1,1 @@\n-old\r\n+new\r\n\\ No newline at end of file\n")
    XCTAssertEqual(input.lines.map(\.hasNewline), [true, false])
    let result = try await CodeSyntaxService().highlight(input)
    XCTAssertEqual(result.left[0].changes, [.init(location: 0, length: 3)])
    XCTAssertEqual(result.right[0].changes, [.init(location: 0, length: 4)])
    XCTAssertEqual(result.right[0].tokens.map(\.content).joined(), "new\r")
  }
  func testRangesAreScopedToContextHunksSidesAndCurrentVersion() async throws {
    let diff = ReviewDiff("@@ -1,3 +1,2 @@\n-old\n-left alone\n+new\n context\n@@ -20,1 +20,0 @@\n-previous hunk\n@@ -30,0 +30,1 @@\n+next hunk\n")
    let input = CodeSyntaxInput(path: "Main.swift", diff: diff, wordDiffs: true), state = CodeSyntaxState(service: CodeSyntaxService())
    await state.load(input); XCTAssertNil(state.error)
    let removed = try XCTUnwrap(diff.lines.first { $0.text == "-old" })
    let added = try XCTUnwrap(diff.lines.first { $0.text == "+new" })
    XCTAssertEqual(state.changes(removed, identity: input.identity), [.init(location: 0, length: 3)])
    XCTAssertEqual(state.changes(added, identity: input.identity), [.init(location: 0, length: 3)])
    XCTAssertTrue(state.changes(removed, identity: input.identity, side: .right).isEmpty)
    for line in diff.lines where line.id != removed.id && line.id != added.id {
      XCTAssertTrue(state.changes(line, identity: input.identity).isEmpty)
    }
    XCTAssertTrue(state.changes(added, identity: .init(path: "Other.swift", fingerprint: input.fingerprint)).isEmpty)
    await state.load(.init(path: "Main.swift", diff: .init("@@ -1,1 +1,1 @@\n-same\n+same\n")))
    XCTAssertTrue(state.changes(added, identity: input.identity).isEmpty)
    let full = try await CodeSyntaxService().highlight(.init(path: "Main.swift", source: "let a = 1\n"))
    XCTAssertTrue(full.right.allSatisfy { $0.changes.isEmpty })
  }
  func testValidationRejectsInvalidOverlappingSurrogateAndContextRanges() throws {
    let input = source("@@ -0,0 +1,1 @@\n+🚀abc\n"), row = input.lines[0]
    for ranges in [[CodeWordRange(location: -1, length: 1)], [.init(location: 0, length: Int.max)],
      [.init(location: 0, length: 0)], [.init(location: 1, length: 1)],
      [.init(location: 0, length: 3), .init(location: 2, length: 2)], [.init(location: 5, length: 1)]] {
      XCTAssertThrowsError(try CodeSyntaxResult(language: "text", left: [], right: [.init(id: row.id,
        tokens: [token(row.text)], changes: ranges)]).validate(input))
    }
    let context = source("@@ -1,1 +1,1 @@\n context\n")
    let changed = CodeSyntaxResult.Row(id: context.lines[0].id, tokens: [token("context")], changes: [.init(location: 0, length: 1)])
    XCTAssertThrowsError(try CodeSyntaxResult(language: "text", left: [changed], right: [changed]).validate(context))
  }
  func testWordAndGrammarBoundariesPreserveExactBytesAndStyles() {
    let tokens = [token("let "), token("a", color: "#D53538", fontStyle: 2), token(" = ", fontStyle: 1), token("42", fontStyle: 4)]
    let pieces = CodeSyntaxText.segments(tokens, changes: [.init(location: 3, length: 5)], dark: false)
    XCTAssertTrue(pieces.map(\.content).joined().utf8.elementsEqual(tokens.map(\.content).joined().utf8))
    XCTAssertEqual(pieces.filter { $0.group == 0 }.map(\.content).joined(), " a = ")
    XCTAssertEqual(pieces.first { $0.content == "a" }?.style.fontStyle, 2)
    XCTAssertEqual(pieces.first { $0.content == "a" }?.style.color, "#D53538"); XCTAssertEqual(pieces.last?.style.fontStyle, 4)
    let emoji = "👩🏽‍💻 e\u{301}"
    let parts = CodeSyntaxText.segments([token(emoji)], changes: [.init(location: 2, length: 2)], dark: true)
    XCTAssertTrue(parts.map(\.content).joined().utf8.elementsEqual(emoji.utf8))
    XCTAssertEqual(parts.filter { $0.group == 0 }.map(\.content).joined(), "🏽")
  }
  func testSharedPreferenceDefaultsOffPersistsAndPreservesDraftAndTabs() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("words-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root)
    XCTAssertFalse(store.reviewWordDiffs)
    XCTAssertFalse(try JSONDecoder().decode(WorkspaceLibrary.self, from: Data("{}".utf8)).reviewWordDiffs)
    store.reviewWordDiffs = true; XCTAssertFalse(store.reviewWordDiffs); XCTAssertNotNil(store.generalSettingsError)
    store.libraryLoaded = true; store.library.drafts["fixture"] = "keep this draft"
    let before = store.library.workspaceTabLayouts
    store.reviewWordDiffs = true; XCTAssertTrue(store.reviewWordDiffs); XCTAssertNil(store.generalSettingsError)
    XCTAssertEqual(store.library.drafts["fixture"], "keep this draft"); XCTAssertEqual(store.library.workspaceTabLayouts, before)
    let restored = WorkspaceStore(dataRoot: root)
    restored.library = try WorkspaceLibrary.load(from: root.appendingPathComponent("workspace.json")); restored.libraryLoaded = true
    XCTAssertTrue(restored.reviewWordDiffs); restored.reviewWordDiffs = false
    XCTAssertFalse(try WorkspaceLibrary.load(from: root.appendingPathComponent("workspace.json")).reviewWordDiffs)
  }
  func testFailedSaveDoesNotPublishNewValueOrLoseDraft() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("words-failed-" + UUID().uuidString)
    try Data("not a directory".utf8).write(to: root)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root); store.libraryLoaded = true
    store.library.drafts["fixture"] = "keep this draft"; store.reviewWordDiffs = true
    XCTAssertFalse(store.reviewWordDiffs); XCTAssertNotNil(store.generalSettingsError)
    XCTAssertEqual(store.library.drafts["fixture"], "keep this draft")
  }
  func testActualNativeRendererPaintsWrappedBackgroundsAndRetainsGrammarColors() throws {
    guard #available(macOS 15, *) else { throw XCTSkip("Public native TextRenderer requires macOS 15") }
    _ = NSApplication.shared
    let content = "let count = 42; let name = 99; let next = 12;"
    let tokens = [token("let ", color: "#D53538"), token(String(content.dropFirst(4)))]
    let ranges = [CodeWordRange(location: 0, length: content.utf16.count)]
    func bitmap(_ changes: [CodeWordRange], _ kind: ReviewDiffLine.Kind, _ dark: Bool) throws -> NSBitmapImageRep {
      let line = ReviewDiffLine(id: 1, text: (kind == .addition ? "+" : "-") + content, kind: kind, oldLine: 1, newLine: 1)
      let renderer = ImageRenderer(content: CodeWordDiffText(line: line, tokens: tokens, changes: changes, marker: .color, dark: dark)
        .font(.system(size: 20, design: .monospaced)).textSelection(.enabled).frame(width: 160, alignment: .leading)
        .padding(8).background(Color.white).environment(\.colorScheme, .light))
      return NSBitmapImageRep(cgImage: try XCTUnwrap(renderer.cgImage))
    }
    let off = try bitmap([], .addition, false), on = try bitmap(ranges, .addition, false)
    XCTAssertEqual(on.pixelsHigh, off.pixelsHigh); XCTAssertGreaterThan(on.pixelsHigh, 60)
    var greenRows: Set<Int> = [], blues = 0, reds = 0
    for y in 0..<on.pixelsHigh { for x in 0..<on.pixelsWide {
      guard let a = on.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), let b = off.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
      if a.greenComponent - a.redComponent > 0.04 && a.greenComponent - a.blueComponent > 0.035,
        b.redComponent > 0.95, b.greenComponent > 0.95, b.blueComponent > 0.95 { greenRows.insert(y) }
      if a.blueComponent > a.redComponent + 0.2 { blues += 1 }
      if a.redComponent > a.blueComponent + 0.2 { reds += 1 }
    } }
    XCTAssertGreaterThan(greenRows.count, 40); XCTAssertGreaterThan(blues, 20); XCTAssertGreaterThan(reds, 10)
    for dark in [false, true] {
      let removed = try bitmap(ranges, .deletion, dark)
      var redBackground = 0
      for y in 0..<removed.pixelsHigh { for x in 0..<removed.pixelsWide {
        guard let a = removed.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
        if a.redComponent - a.greenComponent > 0.03 && a.redComponent - a.blueComponent > 0.03 { redBackground += 1 }
      } }
      XCTAssertGreaterThan(redBackground, 100)
    }
  }
}
