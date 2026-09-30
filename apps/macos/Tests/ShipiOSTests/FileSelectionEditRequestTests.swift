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
}
