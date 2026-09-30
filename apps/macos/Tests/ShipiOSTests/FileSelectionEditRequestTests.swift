import Foundation
import XCTest
@testable import ShipiOS

final class FileSelectionEditRequestTests: XCTestCase {
  func testProposalReplacesOnlyUTF16SelectionAndAcceptsFencedJSON() throws {
    let source = "🐱 alpha beta"
    let request = FileSelectionEditRequest(path: "File.swift", source: source,
      range: NSRange(location: 3, length: 5), instruction: "uppercase")
    XCTAssertEqual(request.selectedText, "alpha")
    XCTAssertTrue(try request.prompt().contains("Selected text:\nalpha"))
    let proposal = try request.proposal(from: "```json\n{\"replacement\":\"ALPHA\"}\n```")
    XCTAssertEqual(proposal.content, "🐱 ALPHA beta")
    XCTAssertEqual(source, "🐱 alpha beta")
  }

  func testMalformedOrOversizedProposalIsRejected() throws {
    let request = FileSelectionEditRequest(path: "a", source: "hello",
      range: NSRange(location: 0, length: 5), instruction: "change")
    XCTAssertThrowsError(try request.proposal(from: "hello"))
    XCTAssertThrowsError(try request.proposal(from: "{\"replacement\":\"\\u0000\"}"))
    XCTAssertThrowsError(try request.proposal(from: "{\"replacement\":\"\(String(repeating: "x", count: 1_100_000))\"}"))
  }
}
