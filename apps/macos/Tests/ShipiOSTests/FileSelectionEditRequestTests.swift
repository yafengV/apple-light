import Foundation
import XCTest
@testable import ShipiOS

final class FileSelectionEditRequestTests: XCTestCase {
  func testProposalReplacesOnlyUTF16SelectionAndPreservesWhitespace() throws {
    let source = "🐱 alpha beta"
    let request = FileSelectionEditRequest(path: "File.swift", source: source,
      range: NSRange(location: 3, length: 5), instruction: "uppercase")
    XCTAssertEqual(request.selectedText, "alpha")
    let prompt = try request.promptParts()
    XCTAssertTrue(prompt.appendix.contains("<selected_text>\nalpha\n</selected_text>"))
    let proposal = try request.proposal(from: "\n  ALPHA\n")
    XCTAssertEqual(proposal.content, "🐱 \n  ALPHA\n beta")
    XCTAssertEqual(source, "🐱 alpha beta")
  }

  func testUnchangedNulOrOversizedProposalIsRejected() throws {
    let request = FileSelectionEditRequest(path: "a", source: "hello",
      range: NSRange(location: 0, length: 5), instruction: "change")
    XCTAssertThrowsError(try request.proposal(from: "hello"))
    XCTAssertThrowsError(try request.proposal(from: "a\0b"))
    XCTAssertThrowsError(try request.proposal(from: String(repeating: "x", count: 32_769)))
  }

  func testRequestAllowsCodexSizedSelectionAndContext() throws {
    let source = String(repeating: "a", count: 45_000) + "SELECTED" + String(repeating: "b", count: 45_000)
    let request = FileSelectionEditRequest(path: "File.swift", source: source,
      range: NSRange(location: 45_000, length: 8), instruction: "change")
    let prompt = try request.promptParts()
    XCTAssertEqual(prompt.header.utf8.count < 48_000, true)
    XCTAssertTrue(prompt.appendix.contains("<document_context>\n\(source)\n</document_context>"))
    let tooLarge = FileSelectionEditRequest(path: "File.swift", source: String(repeating: "a", count: 32_769),
      range: NSRange(location: 0, length: 32_769), instruction: "change")
    XCTAssertThrowsError(try tooLarge.prompt())
  }

  func testReviewPlacementUsesCodexCharacterAndLineLimits() {
    let inline = FileSelectionEditProposal(replacement: "b", content: "b")
    XCTAssertTrue(inline.prefersInlineReview(selectedText: String(repeating: "a", count: 3_999)))
    XCTAssertFalse(inline.prefersInlineReview(selectedText: String(repeating: "a", count: 4_000)))
    XCTAssertFalse(inline.prefersInlineReview(selectedText: String(repeating: "🐱", count: 2_000)),
      "JavaScript's length limit counts UTF-16 code units")
    XCTAssertFalse(FileSelectionEditProposal(replacement: (0..<41).map(String.init).joined(separator: "\n"),
      content: "").prefersInlineReview(selectedText: "a"))
    XCTAssertFalse(inline.prefersInlineReview(selectedText: (0..<41).map(String.init).joined(separator: "\n")))
  }

  func testFullReviewDiffShowsChangedLinesWithSourceNumbers() {
    let diff = FileSelectionReviewDiff.make(old: "alpha\nbeta\ngamma", new: "alpha\nBETA\ngamma")
    XCTAssertEqual(diff.lines.map(\.text), [
      "@@ -1,3 +1,3 @@", " alpha", "-beta", "+BETA", " gamma"
    ])
    XCTAssertEqual(diff.lines[2].oldLine, 2)
    XCTAssertEqual(diff.lines[3].newLine, 2)
    XCTAssertEqual(diff.additions, 1)
    XCTAssertEqual(diff.deletions, 1)
  }

  func testFullReviewDiffHandlesInsertionAtStartAndRepeatedLines() {
    let inserted = FileSelectionReviewDiff.make(old: "b", new: "a\nb")
    XCTAssertEqual(inserted.lines.map(\.text), ["@@ -1,1 +1,2 @@", "+a", " b"])
    let repeated = FileSelectionReviewDiff.make(old: "a\nb\na", new: "a\nc\na")
    XCTAssertEqual(repeated.lines.filter { $0.kind == .deletion }.map(\.text), ["-b"])
    XCTAssertEqual(repeated.lines.filter { $0.kind == .addition }.map(\.text), ["+c"])
  }

  func testFullReviewDiffKeepsOriginalLineNumbersInLongFiles() {
    let lines = (1...25).map { "line \($0)" }
    var updated = lines
    updated[14] = "updated line 15"
    let diff = FileSelectionReviewDiff.make(old: lines.joined(separator: "\n"),
      new: updated.joined(separator: "\n"))
    XCTAssertEqual(diff.lines.first?.text, "@@ -12,7 +12,7 @@")
    XCTAssertEqual(diff.lines.first(where: { $0.kind == .deletion })?.oldLine, 15)
    XCTAssertEqual(diff.lines.first(where: { $0.kind == .addition })?.newLine, 15)
    XCTAssertEqual(diff.lines.count, 9, "Only three context lines on each side should be expanded")
  }

  func testFullReviewDiffHandlesManyRewrittenLinesWithoutLosingEdges() {
    let old = (["prefix"] + (0..<500).map { "old \($0)" } + ["suffix"]).joined(separator: "\n")
    let new = (["prefix"] + (0..<500).map { "new \($0)" } + ["suffix"]).joined(separator: "\n")
    let diff = FileSelectionReviewDiff.make(old: old, new: new)
    XCTAssertEqual(diff.deletions, 500)
    XCTAssertEqual(diff.additions, 500)
    XCTAssertEqual(diff.lines.first?.text, "@@ -1,502 +1,502 @@")
    XCTAssertEqual(diff.lines.dropFirst().first?.text, " prefix")
    XCTAssertEqual(diff.lines.last?.text, " suffix")
  }
}
