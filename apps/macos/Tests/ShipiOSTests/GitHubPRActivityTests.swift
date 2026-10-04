import XCTest
@testable import ShipiOS

final class GitHubPRActivityTests: XCTestCase {
  private let day = "2026-09-29T10:00:00Z"
  private func snapshot() -> GitHubPRDiscussionSnapshot {
    .init(requestURL: "https://github.com/sample/project/pull/42", nodeID: "pr", viewer: "viewer", author: "author",
      state: "OPEN", head: String(repeating: "a", count: 40), comments: [], threads: [], events: [], omittedTypes: [])
  }
  private func comment(_ id: String, date: String? = nil, body: String = "Body", state: String? = nil) -> GitHubPRComment {
    .init(id: id, kind: state == nil ? .issue : .review, body: body, author: "reviewer", authorType: "User",
      createdAt: date ?? day, url: nil, canUpdate: true, canDelete: false, reviewState: state)
  }
  private func commit(_ id: String, date: String? = nil) -> GitHubPRActivityEvent {
    .init(id: id, kind: "PullRequestCommit", author: "author", createdAt: date ?? day, text: id, url: nil)
  }
  private func thread(_ root: GitHubPRComment) -> GitHubPRReviewThread {
    .init(id: "thread", path: "Main.swift", line: 1, originalLine: nil, diffHunk: "", isResolved: false,
      isOutdated: false, canReply: true, canResolve: true, canUnresolve: false, comments: [root])
  }

  func testFourEventsAndBlankReviewPreserveEditableRawDataWithoutEmptyCards() {
    var value = snapshot(); value.createdAt = day; value.mergedAt = day
    value.comments = [comment("approve", body: " \n", state: "APPROVED"),
      comment("changes", body: "\t", state: "CHANGES_REQUESTED"),
      comment("dismissed", body: "", state: "DISMISSED"), comment("pending", body: "", state: "PENDING")]
    XCTAssertEqual(value.activity.compactMap { if case .event(let x) = $0 { return x.kind }; return nil },
      ["opened", "approved", "changes_requested", "merged"])
    XCTAssertEqual(value.allComments.count, 4)
    XCTAssertEqual(value.comment("approve")?.body, " \n")
  }

  func testReviewSubmissionDatePlacesDecisionBeforeItsBody() {
    var value = snapshot(), review = comment("review", date: "2026-09-29T08:00:00Z", state: "APPROVED")
    review.submittedAt = "2026-09-29T12:00:00Z"
    value.comments = [review, comment("issue")]
    XCTAssertEqual(value.activity.map(\.id), ["comment:issue", "event:review:review:approved", "comment:review"])
    XCTAssertEqual(value.activity.last?.createdAt, review.submittedAt)
  }

  func testNonDecisionReviewsOnlyRenderNonblankBodies() {
    var value = snapshot()
    value.comments = [comment("commented", state: "COMMENTED"), comment("dismissed", state: "DISMISSED"),
      comment("pending", state: "PENDING"), comment("blank", body: "\n", state: "COMMENTED")]
    XCTAssertEqual(value.activity.map(\.id), ["comment:commented", "comment:dismissed", "comment:pending"])
  }

  func testConsecutiveCommitsGroupAtLatestDateAndSplitAtComments() throws {
    var value = snapshot()
    value.events = [commit("a", date: "2026-09-29T08:00:00Z"), commit("b", date: "2026-09-29T09:00:00Z"),
      commit("c", date: "2026-09-29T11:00:00Z")]
    value.comments = [comment("issue")]
    XCTAssertEqual(value.activity.map(\.id), ["commits:a", "comment:issue", "commits:c"])
    guard case .commitGroup(let group) = try XCTUnwrap(value.activity.first) else { return XCTFail("Expected commit group") }
    XCTAssertEqual(group.commits.map(\.id), ["a", "b"])
    XCTAssertEqual(group.createdAt, "2026-09-29T09:00:00Z")
    value.events.insert(commit("between", date: "2026-09-29T08:30:00Z"), at: 1)
    XCTAssertEqual(value.activity.first?.id, group.id, "Appending inside a group retains disclosure identity")
  }

  func testEqualInstantsKeepReferenceSeedOrderAcrossTimezonesAndFractions() {
    var value = snapshot(); value.createdAt = day; value.mergedAt = day
    value.events = [commit("first", date: "2026-09-29T18:00:00+08:00"), commit("second", date: "2026-09-29T10:00:00.000Z")]
    value.comments = [comment("review", state: "APPROVED"), comment("issue")]
    value.threads = [thread(comment("code"))]
    XCTAssertEqual(value.activity.map(\.id), ["event:opened:" + value.requestURL, "commits:first", "comment:issue",
      "event:review:review:approved", "comment:review", "thread:thread", "event:merged:" + value.requestURL])
  }

  func testNumericDatesOrderCorrectlyWhereLexicalOrderWouldFail() throws {
    var value = snapshot()
    value.comments = [comment("late", date: "2026-09-29T03:00:00-08:00"),
      comment("early", date: "2026-09-29T18:00:00.125+08:00")]
    XCTAssertEqual(value.activity.map(\.id), ["comment:early", "comment:late"])
    XCTAssertEqual(try XCTUnwrap(GitHubPRActivityDate.parse("2026-09-29T18:00:00.125+08:00")),
      try XCTUnwrap(GitHubPRActivityDate.parse("2026-09-29T10:00:00.125Z")))
  }

  func testInvalidDatesSortLastStablyAndBlankBodiesNeverSplitGroups() {
    var value = snapshot()
    value.comments = [comment("invalid1", date: "invalid"), comment("valid"),
      comment("invalid2", date: "also invalid"), comment("blank", body: " \n\t")]
    value.events = [commit("a"), commit("b")]
    XCTAssertEqual(value.activity.map(\.id), ["commits:a", "comment:valid", "comment:invalid1", "comment:invalid2"])
  }

  func testMissingMetadataDoesNotInventEventsAndBlankThreadsDoNotRender() {
    var value = snapshot(); value.threads = [thread(comment("blank", body: " \n"))]
    XCTAssertTrue(value.activity.isEmpty)
    value.mergedAt = day
    guard case .event(let event) = value.activity.first else { return XCTFail("Missing merged event") }
    XCTAssertEqual(event.author, "")
  }

  func testOlderCommentRecordsDecodeWithoutSubmittedAt() throws {
    let data = try JSONEncoder().encode(comment("old", state: "APPROVED"))
    var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any]); object.removeValue(forKey: "submittedAt")
    let decoded = try JSONDecoder().decode(GitHubPRComment.self, from: JSONSerialization.data(withJSONObject: object))
    XCTAssertNil(decoded.submittedAt); XCTAssertEqual(decoded.activityDate, day)
  }

  func testOverviewCountsCardsRatherThanRepliesDecisionsOrCommitEvents() {
    var value = snapshot(); value.createdAt = day; value.mergedAt = day
    value.events = [commit("a"), commit("b")]
    value.comments = [comment("issue"), comment("blank", body: "\n"),
      comment("review", state: "APPROVED"), comment("decision", body: "", state: "CHANGES_REQUESTED")]
    var discussion = thread(comment("root"))
    discussion.comments += [comment("reply-1"), comment("reply-2")]
    value.threads = [discussion]
    XCTAssertEqual(value.overviewCommentCount, 3)
    value.comments = []; value.threads = []
    XCTAssertEqual(value.overviewCommentCount, 0)
  }
}
