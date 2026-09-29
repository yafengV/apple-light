import XCTest
@testable import ShipiOS

final class GitHubPRCommentPositionTests: XCTestCase {
  private func thread(line: Int? = 20, original: Int? = 10, start: Int? = 18, originalStart: Int? = 8,
    side: String? = "RIGHT", startSide: String? = "RIGHT", path: String = "Sources/Main.swift") -> GitHubPRReviewThread {
    .init(id: "thread", path: path, line: line, originalLine: original, diffHunk: "@@ -8,3 +18,3 @@\n a\n b\n c",
      isResolved: false, isOutdated: false, canReply: true, canResolve: true, canUnresolve: false,
      comments: [.init(id: "root", kind: .code, body: " Feedback \n", author: "author", authorType: "User",
        createdAt: "2026-09-29T10:00:00Z", url: nil, canUpdate: true, canDelete: true)],
      diffSide: side, startLine: start, startDiffSide: startSide, originalStartLine: originalStart)
  }
  func testCurrentRangeAndOriginalHunkRemainDistinct() throws {
    let value = thread()
    let position = try XCTUnwrap(value.position), hunk = try XCTUnwrap(value.hunkPosition)
    XCTAssertEqual(position.line, 20); XCTAssertEqual(position.startLine, 18)
    XCTAssertEqual(position.label, "R18–R20")
    XCTAssertEqual(hunk.line, 10); XCTAssertEqual(hunk.startLine, 8)
    XCTAssertEqual(value.line, 20); XCTAssertEqual(value.originalLine, 10)
  }
  func testOutdatedRangeUsesOriginalStartBeforeCurrentStart() throws {
    let value = thread(line: nil)
    let position = try XCTUnwrap(value.position)
    XCTAssertEqual(position.line, 10); XCTAssertEqual(position.startLine, 8)
    XCTAssertEqual(position.label, "R8–R10")
    XCTAssertTrue(PullRequestCommentAttachment(thread: value).isValid)
  }
  func testFallbackOrderAndSingleLineDoNotInventRanges() throws {
    let single = try XCTUnwrap(thread(line: nil, original: nil, start: 7, originalStart: 6).position)
    XCTAssertEqual(single.line, 7); XCTAssertNil(single.startLine); XCTAssertEqual(single.label, "Line R7")
    let originalStart = try XCTUnwrap(thread(line: nil, original: nil, start: nil, originalStart: 6).position)
    XCTAssertEqual(originalStart.line, 6); XCTAssertNil(originalStart.startLine)
    let original = try XCTUnwrap(thread(line: nil, original: 10, start: 8, originalStart: nil).position)
    XCTAssertEqual(original.startLine, 8)
    XCTAssertNil(thread(line: nil, original: nil, start: nil, originalStart: nil).position)
  }
  func testLeftAndCrossSideRangesRetainSideIdentity() throws {
    let single = try XCTUnwrap(thread(line: 5, original: nil, start: nil, originalStart: nil, side: "LEFT", startSide: nil).position)
    XCTAssertEqual(single.side, .left); XCTAssertEqual(single.label, "Line L5")
    let cross = try XCTUnwrap(thread(line: 12, start: 9, startSide: "LEFT").position)
    XCTAssertEqual(cross.label, "L9–R12"); XCTAssertEqual(cross.startSide, .left)
    let sameNumber = try XCTUnwrap(thread(line: 12, start: 12, startSide: "LEFT").position)
    XCTAssertNil(sameNumber.startLine); XCTAssertEqual(sameNumber.label, "L12–R12")
  }
  func testMissingSideAndUnsafeOrInvalidPositionNeverBecomeFixAttachments() {
    for value in [thread(side: nil), thread(side: "UNKNOWN"), thread(line: 0), thread(start: -1),
      thread(path: "../Main.swift"), thread(path: "/Main.swift"), thread(path: " \n")] {
      XCTAssertFalse(PullRequestCommentAttachment(thread: value).isValid)
    }
  }
  func testNormalizedPositionIsEncodedWhileOriginalThreadAndLegacyDecodeArePreserved() throws {
    let attachment = PullRequestCommentAttachment(thread: thread(line: nil), guidance: "Keep scope")
    var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(attachment)) as? [String: Any])
    let position = try XCTUnwrap(object["position"] as? [String: Any])
    XCTAssertEqual(position["line"] as? Int, 10); XCTAssertEqual(position["start_line"] as? Int, 8)
    XCTAssertEqual(position["side"] as? String, "right"); XCTAssertNil(position["start_side"])
    object.removeValue(forKey: "position")
    let decoded = try JSONDecoder().decode(PullRequestCommentAttachment.self, from: JSONSerialization.data(withJSONObject: object))
    XCTAssertEqual(decoded, attachment); XCTAssertNil(decoded.thread.line); XCTAssertEqual(decoded.thread.originalLine, 10)
    object["position"] = ["line": 999, "path": "fake"]
    let tampered = try JSONDecoder().decode(PullRequestCommentAttachment.self, from: JSONSerialization.data(withJSONObject: object))
    XCTAssertEqual(tampered.position, attachment.position, "Persisted display fields cannot override the actual thread snapshot")
  }
  func testThreadBodyUsesTrimmedNonblankCommentsWithoutInventedUnknownMentions() throws {
    var value = thread()
    value.comments.append(.init(id: "blank", kind: .code, body: " \n", author: "reviewer", authorType: "User",
      createdAt: "date", url: nil, canUpdate: false, canDelete: false))
    value.comments.append(.init(id: "unknown", kind: .code, body: " Reply \n", author: "未知作者", authorType: "User",
      createdAt: "date", url: nil, canUpdate: false, canDelete: false))
    let attachment = PullRequestCommentAttachment(thread: value)
    XCTAssertEqual(attachment.body, "@author:\nFeedback\n\nReply")
    XCTAssertEqual(attachment.thread.comments.count, 3)
    value.comments = [value.comments[1]]
    XCTAssertFalse(PullRequestCommentAttachment(thread: value).isValid)
  }
  func testQuoteTrimsDisplayBodyButEditingKeepsRawBody() {
    let comment = thread().comments[0]
    XCTAssertEqual(comment.quotedBody, "> Feedback\n\n")
    XCTAssertEqual(comment.body, " Feedback \n")
  }
}
