import XCTest
@testable import ShipiOS

final class GitHubPRDiscussionTests: XCTestCase {
  private let request = GitHubPullRequest(number: 42, url: "https://github.com/sample/project/pull/42",
    title: "Feature", isDraft: false, headRefName: "feature/topic", baseRefName: "main", isCrossRepository: false)
  private let head = String(repeating: "a", count: 40)
  private func comment(_ id: String, type: String = "IssueComment", body: String = "Original") -> [String: Any] {
    ["id": id, "__typename": type, "body": body, "createdAt": "2026-09-29T10:00:00Z",
      "url": "https://github.com/sample/project/pull/42#" + id,
      "author": ["login": "reviewer", "__typename": "User"], "viewerCanUpdate": true, "viewerCanDelete": true]
  }
  private func thread(_ id: String, comments: [[String: Any]]) -> [String: Any] {
    ["id": id, "path": "Sources/Main.swift", "line": 12, "originalLine": 10,
      "diffSide": "RIGHT", "startLine": 8, "startDiffSide": "RIGHT", "originalStartLine": 6,
      "isResolved": false, "isOutdated": false, "viewerCanReply": true,
      "viewerCanResolve": true, "viewerCanUnresolve": true, "comments": comments]
  }
  private func fixture(_ extra: [String: Any] = [:]) async throws -> (URL, GitHubPRService) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("pr-discussion-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    _ = try await GitReviewService.checked(["init", "-q", "-b", "feature/topic"], at: root)
    let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Fixtures/github_cli.py")
    let executable = root.appendingPathComponent(".git/gh-fixture")
    try FileManager.default.copyItem(at: source, to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    let item = try JSONSerialization.jsonObject(with: JSONEncoder().encode(request))
    var state: [String: Any] = ["head": head, "pullRequests": [item], "viewer": "reviewer",
      "discussionTimeline": [comment("issue-1")],
      "discussionThreads": [thread("thread-1", comments: [comment("code-1", type: "PullRequestReviewComment")])]]
    extra.forEach { state[$0.key] = $0.value }; try write(state, root)
    return (root, .init(executable: executable))
  }
  private func read(_ root: URL) throws -> [String: Any] {
    try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent(".git/github-fixture.json"))) as? [String: Any])
  }
  private func write(_ state: [String: Any], _ root: URL) throws {
    try JSONSerialization.data(withJSONObject: state).write(to: root.appendingPathComponent(".git/github-fixture.json"))
  }
  private func change(_ fields: [String: Any], _ root: URL) throws {
    var state = try read(root); fields.forEach { state[$0.key] = $0.value }; try write(state, root)
  }
  private func logs(_ root: URL, mutationsOnly: Bool = false) throws -> [[String: Any]] {
    let path = root.appendingPathComponent(".git/github-requests.jsonl")
    guard FileManager.default.fileExists(atPath: path.path) else { return [] }
    return try String(contentsOf: path, encoding: .utf8).split(separator: "\n").compactMap {
      let value = try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
      guard let input = value?["input"] as? [String: Any], let query = input["query"] as? String else { return nil }
      return !mutationsOnly || query.contains("mutation ShipiOSPRDiscussionMutation") ? value : nil
    }
  }
  private func failure(_ work: () async throws -> Void) async -> Error? {
    do { try await work(); XCTFail("Expected failure"); return nil } catch { return error }
  }

  func testIndependentPaginationIncludesEveryThreadReplyAndTimelineEntry() async throws {
    var review = comment("review-1", type: "PullRequestReview", body: "")
    review["state"] = "APPROVED"; review["commit"] = ["oid": head]
    let timeline = [comment("issue-1"), comment("issue-2"), review,
      ["id": "closed", "__typename": "ClosedEvent", "createdAt": "2026-09-29T11:00:00Z", "actor": ["login": "author"]],
      ["__typename": "PullRequestCommit", "commit": ["oid": "commit-id", "messageHeadline": "Change", "committedDate": "2026-09-29T09:00:00Z", "author": ["name": "Author"]]],
      ["__typename": "LabeledEvent"]]
    let replies = (1...5).map { comment("code-\($0)", type: "PullRequestReviewComment") }
    let threads = [thread("thread-1", comments: replies), thread("thread-2", comments: [comment("code-6", type: "PullRequestReviewComment")])]
    let (root, service) = try await fixture(["discussionPageSize": 2, "discussionTimeline": timeline, "discussionThreads": threads])
    let result = try await service.discussion(for: request, at: root)
    XCTAssertEqual(result.comments.count, 3); XCTAssertEqual(result.threads.count, 2)
    XCTAssertEqual(result.threads.first?.comments.count, 5); XCTAssertEqual(result.events.count, 1)
    XCTAssertEqual(result.activity.first?.id, "commits:commit-id")
    XCTAssertTrue(result.omittedTypes.isEmpty); XCTAssertTrue(result.canReview)
    XCTAssertFalse(try XCTUnwrap(result.comment("review-1")).canDelete)
    XCTAssertTrue(try logs(root).contains { (($0["input"] as? [String: Any])?["query"] as? String)?.contains("ShipiOSPRDiscussionReplies") == true })
  }

  func testCurrentPRCommitListExcludesOldTimelineCommitsAndRetainsAuthorsAndLinks() async throws {
    let commits: [[String: Any]] = [
      ["oid": "current-a", "committedDate": "2026-09-29T08:00:00Z", "messageHeadline": "Current A",
       "authors": ["nodes": [["name": "Name", "user": ["login": "login", "avatarUrl": "https://github.com/avatar"]]]]],
      ["oid": "current-b", "committedDate": "2026-09-29T09:00:00Z", "authors": ["nodes": [["name": "Local Author"]]]]]
    let (root, service) = try await fixture(["discussionCommits": commits, "discussionThreads": [],
      "discussionTimeline": [["__typename": "PullRequestCommit", "commit": ["oid": "old", "committedDate": "2026-09-29T07:00:00Z"]]],
      "discussionCreatedAt": "2026-09-29T06:00:00Z", "discussionMergedAt": "2026-09-29T12:00:00Z", "discussionMergedBy": "merger"])
    let value = try await service.discussion(for: request, at: root)
    XCTAssertEqual(value.events.map(\.id), ["current-a", "current-b"])
    XCTAssertEqual(value.events.map(\.author), ["login", "Local Author"])
    XCTAssertEqual(value.events[0].avatarURL, "https://github.com/avatar")
    XCTAssertEqual(value.events[1].text, "current-b")
    XCTAssertEqual(value.events[1].url, "https://github.com/sample/project/commit/current-b")
    XCTAssertEqual(value.activity.map(\.id), ["event:opened:" + request.url, "commits:current-a", "event:merged:" + request.url])
    XCTAssertEqual(value.mergedBy, "merger")
    let queries = try logs(root).compactMap { ($0["input"] as? [String: Any])?["query"] as? String }
    XCTAssertEqual(queries.filter { $0.contains("commits(last:100)") }.count, 1)
    XCTAssertFalse(queries.contains { $0.contains("timelineItems") })
    XCTAssertTrue(queries.contains { $0.contains("comments(first:100,after:") })
    XCTAssertTrue(queries.contains { $0.contains("reviews(first:100,after:") })
  }

  func testCommitLimitUsesMostRecentHundredAndMarksPartialActivity() async throws {
    let commits = (1...105).map { ["oid": "commit-\($0)", "committedDate": "2026-09-29T09:00:00Z"] }
    let (root, service) = try await fixture(["discussionCommits": commits, "discussionTimeline": [], "discussionThreads": []])
    let value = try await service.discussion(for: request, at: root)
    XCTAssertEqual(value.events.count, 100); XCTAssertTrue(value.isActivityPartial)
    XCTAssertEqual(value.events.first?.id, "commit-6"); XCTAssertEqual(value.events.last?.id, "commit-105")
    XCTAssertEqual(value.activity.count, 1)
    guard case .commitGroup(let group) = value.activity.first else { return XCTFail("Missing group") }
    XCTAssertEqual(group.commits.count, 100)
    try change(["discussionCommits": Array(commits.prefix(100))], root)
    let complete = try await service.discussion(for: request, at: root)
    XCTAssertFalse(complete.isActivityPartial)
  }

  func testReviewDatesAreSubmittedTimesAndBlankApprovalProducesOnlyEvent() async throws {
    var review = comment("review-1", type: "PullRequestReview", body: " \n")
    review["state"] = "APPROVED"; review["submittedAt"] = "2026-09-29T12:00:00Z"; review["commit"] = ["oid": head]
    let (root, service) = try await fixture(["discussionTimeline": [review, comment("issue-1")], "discussionThreads": []])
    let value = try await service.discussion(for: request, at: root)
    XCTAssertEqual(value.activity.map(\.id), ["comment:issue-1", "event:review:review-1:approved"])
    XCTAssertEqual(value.activity.last?.createdAt, "2026-09-29T12:00:00Z")
    XCTAssertEqual(value.comment("review-1")?.body, " \n")
  }

  func testInvalidCommitSummaryCannotInstallAnIncompleteSnapshot() async throws {
    let duplicate = ["oid": "duplicate", "committedDate": "2026-09-29T09:00:00Z"]
    for fields: [String: Any] in [["discussionMalformedCommits": true], ["discussionCommits": [duplicate, duplicate]]] {
      let (root, service) = try await fixture(fields)
      _ = await failure { _ = try await service.discussion(for: self.request, at: root) }
      XCTAssertTrue(try logs(root, mutationsOnly: true).isEmpty)
    }
  }

  func testBlankReviewReceiptDuringReadOutageRetainsSubmissionTimeAndMetadata() async throws {
    let (root, service) = try await fixture(["discussionFailureAfterAction": true, "discussionCreatedAt": "2026-09-29T08:00:00Z"])
    let baseline = try await service.discussion(for: request, at: root)
    let result = try await service.applyDiscussion(.review(body: "", decision: .approve, head: head), expected: baseline, request: request, at: root)
    let review = try XCTUnwrap(result.snapshot.comments.last)
    XCTAssertEqual(review.submittedAt, "2026-09-29T12:00:00Z")
    XCTAssertEqual(result.snapshot.createdAt, baseline.createdAt)
    XCTAssertTrue(result.notice?.contains("已接受") == true)
    XCTAssertFalse(result.snapshot.activity.contains { $0.id == "comment:" + review.id })
    XCTAssertTrue(result.snapshot.activity.contains { $0.id == "event:review:" + review.id + ":approved" })
  }

  func testOrdinaryCommentsReviewsThreadsAndRepliesAllPaginateIndependently() async throws {
    let issues = (1...5).map { comment("issue-\($0)") }
    let reviews = (1...5).map { index -> [String: Any] in
      var value = comment("review-\(index)", type: "PullRequestReview")
      value["state"] = "COMMENTED"; value["commit"] = ["oid": head]; return value
    }
    let threads = (1...3).map { index in thread("thread-\(index)", comments:
      (1...5).map { comment("code-\(index)-\($0)", type: "PullRequestReviewComment") }) }
    let (root, service) = try await fixture(["discussionPageSize": 2, "discussionTimeline": issues + reviews, "discussionThreads": threads])
    let value = try await service.discussion(for: request, at: root)
    XCTAssertEqual(value.comments.filter { $0.kind == .issue }.map(\.id), issues.compactMap { $0["id"] as? String })
    XCTAssertEqual(value.comments.filter { $0.kind == .review }.map(\.id), reviews.compactMap { $0["id"] as? String })
    XCTAssertEqual(value.threads.map { $0.comments.count }, [5, 5, 5])
    XCTAssertEqual(value.activity.count, 13)
    let queries = try logs(root).compactMap { ($0["input"] as? [String: Any])?["query"] as? String }
    for (connection, pages) in [("comments", 3), ("reviews", 3), ("reviewThreads", 2)] {
      XCTAssertEqual(queries.filter { $0.contains("query ShipiOSPRDiscussion(") && $0.contains(connection + "(first:100,after:") }.count, pages)
    }
    XCTAssertEqual(queries.filter { $0.contains("ShipiOSPRDiscussionReplies") }.count, 6)
  }

  func testPrivateJSONRequestsPreserveRawEditAndCleanUpAllTemporaryFiles() async throws {
    let (root, service) = try await fixture(), expected = try await service.discussion(for: request, at: root)
    let text = "\n## 评论\r\n`$(never-execute)` \"literal\"\n\n"
    let result = try await service.applyDiscussion(.edit(id: "issue-1", kind: .issue, body: text), expected: expected, request: request, at: root)
    XCTAssertEqual(result.snapshot.comment("issue-1")?.body, text)
    for entry in try logs(root) {
      XCTAssertEqual(entry["inputMode"] as? String, "0o600"); XCTAssertEqual(entry["folderMode"] as? String, "0o700")
      let args = try XCTUnwrap(entry["args"] as? [String]); XCTAssertFalse(args.contains(text))
      let file = args[try XCTUnwrap(args.firstIndex(of: "--input")) + 1]
      XCTAssertFalse(FileManager.default.fileExists(atPath: file))
      XCTAssertFalse(FileManager.default.fileExists(atPath: URL(fileURLWithPath: file).deletingLastPathComponent().path))
    }
  }

  func testPostAndThreadReplyTrimInputAndStayInTheirTargets() async throws {
    let (root, service) = try await fixture()
    var expected = try await service.discussion(for: request, at: root)
    var result = try await service.applyDiscussion(.post(body: "  Normal\r\n\n", thread: nil), expected: expected, request: request, at: root)
    XCTAssertEqual(result.snapshot.comments.last?.body, "Normal")
    XCTAssertEqual(result.snapshot.threads[0].comments.count, 1)
    expected = result.snapshot
    result = try await service.applyDiscussion(.post(body: "  Reply\n", thread: "thread-1"), expected: expected, request: request, at: root)
    XCTAssertEqual(result.snapshot.threads[0].comments.last?.body, "Reply")
    XCTAssertEqual(result.snapshot.comments.count, 2)
  }

  func testEditsDispatchAllThreeCommentKindsAndReviewDeleteIsRejected() async throws {
    var review = comment("review-1", type: "PullRequestReview"); review["state"] = "COMMENTED"; review["commit"] = ["oid": head]
    let (root, service) = try await fixture(["discussionTimeline": [comment("issue-1"), review]])
    for (id, kind): (String, GitHubPRCommentKind) in [("issue-1", .issue), ("review-1", .review), ("code-1", .code)] {
      let expected = try await service.discussion(for: request, at: root)
      let result = try await service.applyDiscussion(.edit(id: id, kind: kind, body: "New " + id), expected: expected, request: request, at: root)
      XCTAssertEqual(result.snapshot.comment(id)?.body, "New " + id)
    }
    let expected = try await service.discussion(for: request, at: root)
    _ = await failure { _ = try await service.applyDiscussion(.delete(id: "review-1", kind: .review), expected: expected, request: self.request, at: root) }
    XCTAssertEqual(try logs(root, mutationsOnly: true).count, 3)
  }

  func testDeleteResolveUnresolveAndExplicitRetryAreIdempotent() async throws {
    let (root, service) = try await fixture()
    let first = try await service.discussion(for: request, at: root)
    _ = try await service.applyDiscussion(.delete(id: "issue-1", kind: .issue), expected: first, request: request, at: root)
    _ = try await service.applyDiscussion(.delete(id: "issue-1", kind: .issue), expected: first, request: request, at: root)
    var current = try await service.discussion(for: request, at: root)
    let resolved = try await service.applyDiscussion(.resolve(thread: "thread-1", resolved: true), expected: current, request: request, at: root)
    XCTAssertTrue(resolved.snapshot.threads[0].isResolved)
    _ = try await service.applyDiscussion(.resolve(thread: "thread-1", resolved: true), expected: current, request: request, at: root)
    current = resolved.snapshot
    let open = try await service.applyDiscussion(.resolve(thread: "thread-1", resolved: false), expected: current, request: request, at: root)
    XCTAssertFalse(open.snapshot.threads[0].isResolved)
    XCTAssertEqual(try logs(root, mutationsOnly: true).count, 3)
  }

  func testForeignIDsAndFreshPermissionLossNeverMutate() async throws {
    let (root, service) = try await fixture(), expected = try await service.discussion(for: request, at: root)
    for action: GitHubPRDiscussionAction in [.edit(id: "foreign", kind: .issue, body: "Changed"), .delete(id: "foreign", kind: .issue),
      .post(body: "Reply", thread: "foreign"), .resolve(thread: "foreign", resolved: true)] {
      _ = await failure { _ = try await service.applyDiscussion(action, expected: expected, request: self.request, at: root) }
    }
    var item = comment("issue-1"); item["viewerCanUpdate"] = false; item["viewerCanDelete"] = false
    var restricted = thread("thread-1", comments: [comment("code-1", type: "PullRequestReviewComment")])
    restricted["viewerCanReply"] = false; restricted["viewerCanResolve"] = false
    try change(["discussionTimeline": [item], "discussionThreads": [restricted]], root)
    for action: GitHubPRDiscussionAction in [.edit(id: "issue-1", kind: .issue, body: "Changed"), .delete(id: "issue-1", kind: .issue),
      .post(body: "Reply", thread: "thread-1"), .resolve(thread: "thread-1", resolved: true)] {
      _ = await failure { _ = try await service.applyDiscussion(action, expected: expected, request: self.request, at: root) }
    }
    XCTAssertTrue(try logs(root, mutationsOnly: true).isEmpty)
  }

  func testPaginationDriftDuplicatesAndCursorLoopsAreErrors() async throws {
    for option in ["discussionDuplicate", "discussionCountDrift", "discussionRepeatCursor"] {
      let timeline = (1...5).map { comment("issue-\($0)") }
      let (root, service) = try await fixture(["discussionPageSize": 1, "discussionTimeline": timeline, option: true])
      _ = await failure { _ = try await service.discussion(for: self.request, at: root) }
    }
  }

  func testHeadAndAccountChangesDuringReadAreRejected() async throws {
    for fields: [String: Any] in [["discussionHeadAfterPage": String(repeating: "b", count: 40)],
      ["discussionViewerAfterPage": "different-account"], ["metadataRepository": "foreign/project"], ["discussionGraphQLError": true]] {
      let (root, service) = try await fixture(fields)
      _ = await failure { _ = try await service.discussion(for: self.request, at: root) }
    }
  }

  func testAccountChangeBeforeWriteRequiresRefresh() async throws {
    let (root, service) = try await fixture(), expected = try await service.discussion(for: request, at: root)
    try change(["viewer": "different-account"], root)
    _ = await failure { _ = try await service.applyDiscussion(.post(body: "Comment", thread: nil), expected: expected, request: self.request, at: root) }
    XCTAssertTrue(try logs(root, mutationsOnly: true).isEmpty)
  }

  func testReviewOnlyOpenNonAuthorAndDisplayedHeadIsBound() async throws {
    let (root, service) = try await fixture(), expected = try await service.discussion(for: request, at: root)
    let result = try await service.applyDiscussion(.review(body: "  Looks good \n", decision: .approve, head: head), expected: expected, request: request, at: root)
    XCTAssertEqual(result.snapshot.comments.last?.reviewState, "APPROVED")
    XCTAssertEqual(result.snapshot.comments.last?.commit, head)
    XCTAssertEqual(result.snapshot.comments.last?.body, "Looks good")
    let entry = try XCTUnwrap(logs(root, mutationsOnly: true).last)
    let input = try XCTUnwrap(entry["input"] as? [String: Any]); let variables = try XCTUnwrap(input["variables"] as? [String: Any])
    let fields = try XCTUnwrap(variables["input"] as? [String: Any]); XCTAssertEqual(fields["commitOID"] as? String, head)
    for changeFields: [String: Any] in [["detailState": "CLOSED"], ["detailState": "OPEN", "author": "reviewer"],
      ["author": "fixture-author", "detailHead": String(repeating: "b", count: 40)]] {
      try change(changeFields, root)
      _ = await failure { _ = try await service.applyDiscussion(.review(body: "Review", decision: .comment, head: self.head), expected: expected, request: self.request, at: root) }
    }
    XCTAssertEqual(try logs(root, mutationsOnly: true).count, 1)
  }

  func testBlankApproveAllowedOtherDecisionsAndOversizeRejectedWithoutRequest() async throws {
    let (root, service) = try await fixture(), expected = try await service.discussion(for: request, at: root)
    for action: GitHubPRDiscussionAction in [.post(body: " \n", thread: nil), .edit(id: "issue-1", kind: .issue, body: ""),
      .review(body: "", decision: .comment, head: head), .review(body: " ", decision: .requestChanges, head: head),
      .post(body: String(repeating: "界", count: 22_000), thread: nil)] {
      _ = await failure { _ = try await service.applyDiscussion(action, expected: expected, request: self.request, at: root) }
    }
    XCTAssertTrue(try logs(root, mutationsOnly: true).isEmpty)
    let result = try await service.applyDiscussion(.review(body: "  \n", decision: .approve, head: head), expected: expected, request: request, at: root)
    XCTAssertEqual(result.snapshot.comments.last?.body, "")
  }

  func testAcceptedLostResponseIsReconciledForPostReplyAndReview() async throws {
    for action: GitHubPRDiscussionAction in [.post(body: "Accepted", thread: nil), .post(body: "Reply", thread: "thread-1"),
      .review(body: "Review", decision: .requestChanges, head: head)] {
      let (root, service) = try await fixture(["discussionFailAfterAction": true])
      let expected = try await service.discussion(for: request, at: root)
      let result = try await service.applyDiscussion(action, expected: expected, request: request, at: root)
      XCTAssertTrue(GitHubPRService.discussionConfirmed(action, baseline: expected, current: result.snapshot))
      XCTAssertEqual(try logs(root, mutationsOnly: true).count, 1)
    }
  }

  @MainActor func testUncertainPostRetainsInputAndConfirmationNeverWritesAgain() async throws {
    let (root, service) = try await fixture(["discussionFailAfterAction": true, "discussionFailureAfterAction": true])
    let state = GitHubPRDiscussionState(service: service)
    await state.load(request, at: root, valid: { true }); state.commentBody = "Pending comment"
    XCTAssertTrue(state.start(.post(body: state.commentBody, thread: nil), request: request, at: root, valid: { true }, writable: { true }))
    await state.operation?.value
    XCTAssertNotNil(state.uncertain); XCTAssertEqual(state.commentBody, "Pending comment")
    XCTAssertFalse(state.start(.post(body: "Duplicate", thread: nil), request: request, at: root, valid: { true }, writable: { true }))
    try change(["discussionFailureAfterAction": false], root)
    XCTAssertTrue(state.confirm(request: request, at: root, valid: { true })); await state.operation?.value
    XCTAssertNil(state.uncertain); XCTAssertEqual(state.commentBody, "")
    XCTAssertEqual(try logs(root, mutationsOnly: true).count, 1)
  }

  func testValidReceiptAcknowledgesWriteWhenRefreshFails() async throws {
    let (root, service) = try await fixture(["discussionFailureAfterAction": true])
    let expected = try await service.discussion(for: request, at: root)
    let result = try await service.applyDiscussion(.post(body: "Accepted", thread: nil), expected: expected, request: request, at: root)
    XCTAssertTrue(result.notice?.contains("已接受") == true)
    XCTAssertEqual(result.snapshot.comments.last?.body, "Accepted", "The accepted receipt appears even while the reread is unavailable")
    XCTAssertEqual(try logs(root, mutationsOnly: true).count, 1)
  }

  func testResolveAndUnresolveReceiptsRetainThreadPositionsWhenRefreshFails() async throws {
    for resolved in [true, false] {
      var item = thread("thread-1", comments: [comment("code-1", type: "PullRequestReviewComment")])
      item["isResolved"] = !resolved
      let (root, service) = try await fixture(["discussionThreads": [item], "discussionFailureAfterAction": true])
      let expected = try await service.discussion(for: request, at: root)
      XCTAssertEqual(expected.threads[0].diffSide, "RIGHT")
      XCTAssertEqual(expected.threads[0].startLine, 8)
      XCTAssertEqual(expected.threads[0].startDiffSide, "RIGHT")
      XCTAssertEqual(expected.threads[0].originalStartLine, 6)
      let result = try await service.applyDiscussion(.resolve(thread: "thread-1", resolved: resolved),
        expected: expected, request: request, at: root)
      var encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(expected.threads[0])) as? [String: Any])
      encoded["isResolved"] = resolved
      let preserved = try JSONDecoder().decode(GitHubPRReviewThread.self, from: JSONSerialization.data(withJSONObject: encoded))
      XCTAssertEqual(result.snapshot.threads, [preserved])
      XCTAssertTrue(result.notice?.contains("已接受") == true)
      XCTAssertEqual(try logs(root, mutationsOnly: true).count, 1)
    }
  }

  @MainActor func testMultipleDraftsQuotesAndSuccessfulPostOnlyClearTheirOwnInput() async throws {
    let (root, service) = try await fixture(), state = GitHubPRDiscussionState(service: service)
    await state.load(request, at: root, valid: { true })
    let issue = try XCTUnwrap(state.snapshot?.comment("issue-1")), code = try XCTUnwrap(state.snapshot?.comment("code-1"))
    state.beginEdit(code); state.beginReply(issue, thread: nil, quote: true)
    XCTAssertEqual(state.drafts[issue.id]?.text, "> Original\n\n"); XCTAssertEqual(state.drafts.count, 2)
    state.commentBody = "General post"
    XCTAssertTrue(state.start(.post(body: state.commentBody, thread: nil), request: request, at: root, valid: { true }, writable: { true }))
    await state.operation?.value; XCTAssertEqual(state.commentBody, ""); XCTAssertEqual(state.drafts.count, 2)
    let action = try XCTUnwrap(state.draftAction(issue.id))
    XCTAssertTrue(state.start(action, request: request, at: root, valid: { true }, writable: { true }, draftID: issue.id))
    await state.operation?.value; XCTAssertNil(state.drafts[issue.id]); XCTAssertNotNil(state.drafts[code.id])
  }

  @MainActor func testReviewCancelPreservesDraftAndSuccessResetsDecision() async throws {
    let (root, service) = try await fixture(), state = GitHubPRDiscussionState(service: service)
    await state.load(request, at: root, valid: { true }); state.openReview()
    state.reviewBody = "Review text"; state.reviewDecision = .requestChanges
    state.closeReview(); state.openReview(); XCTAssertEqual(state.reviewBody, "Review text")
    XCTAssertEqual(state.reviewDecision, .requestChanges); XCTAssertEqual(state.reviewHead, head)
    XCTAssertTrue(state.start(try XCTUnwrap(state.reviewAction), request: request, at: root, valid: { true }, writable: { true }))
    await state.operation?.value
    XCTAssertFalse(state.showingReview); XCTAssertEqual(state.reviewBody, ""); XCTAssertEqual(state.reviewDecision, .comment)
  }

  @MainActor func testDeleteFailureKeepsFixedTargetAndEditFailureKeepsDraft() async throws {
    let (root, service) = try await fixture(["discussionMutationFailure": true]), state = GitHubPRDiscussionState(service: service)
    await state.load(request, at: root, valid: { true }); let comment = try XCTUnwrap(state.snapshot?.comment("issue-1"))
    state.deleteTarget = comment
    state.start(.delete(id: comment.id, kind: .issue), request: request, at: root, valid: { true }, writable: { true })
    await state.operation?.value; XCTAssertEqual(state.deleteTarget?.id, comment.id); XCTAssertNotNil(state.error)
    state.deleteTarget = nil; state.beginEdit(comment); state.drafts[comment.id]?.text = "Edited"
    state.start(try XCTUnwrap(state.draftAction(comment.id)), request: request, at: root, valid: { true }, writable: { true })
    await state.operation?.value; XCTAssertEqual(state.drafts[comment.id]?.text, "Edited"); XCTAssertNotNil(state.error)
    try change(["discussionMutationFailure": false], root)
    state.start(try XCTUnwrap(state.draftAction(comment.id)), request: request, at: root, valid: { true }, writable: { true })
    await state.operation?.value; XCTAssertNil(state.drafts[comment.id])
  }

  @MainActor func testSharedCoordinatorBlocksOtherWindowAndEditMergeOperations() async throws {
    let (root, service) = try await fixture(), coordinator = GitHubPRActionCoordinator()
    let state = GitHubPRDiscussionState(service: service, coordinator: coordinator)
    await state.load(request, at: root, valid: { true })
    let token = UUID(); XCTAssertTrue(coordinator.begin(request.url, token: token))
    XCTAssertFalse(state.start(.post(body: "Blocked", thread: nil), request: request, at: root, valid: { true }, writable: { true }))
    coordinator.end(request.url, token: token)
    XCTAssertTrue(state.start(.post(body: "Allowed", thread: nil), request: request, at: root, valid: { true }, writable: { true }))
    XCTAssertTrue(coordinator.isBusy(request.url)); await state.operation?.value
    XCTAssertFalse(coordinator.isBusy(request.url))
  }

  @MainActor func testCancelLateReadAndReadOnlyChangePreventWrites() async throws {
    let (root, service) = try await fixture(), state = GitHubPRDiscussionState(service: service)
    await state.load(request, at: root, valid: { true }); state.commentBody = "Keep draft"
    try change(["discussionDelay": 0.15], root)
    var writable = true
    state.start(.post(body: state.commentBody, thread: nil), request: request, at: root, valid: { true }, writable: { writable })
    let operation = state.operation; writable = false
    await operation?.value; XCTAssertEqual(state.commentBody, "Keep draft")
    XCTAssertTrue(try logs(root, mutationsOnly: true).isEmpty)
    let loading = Task { await state.load(self.request, at: root, valid: { true }) }
    await Task.yield(); state.cancel(); await loading.value
    XCTAssertFalse(state.loading)
    XCTAssertTrue(try logs(root, mutationsOnly: true).isEmpty)
  }

  @MainActor func testCrossWindowUpdateBusIsPRAndDataDirectoryScoped() {
    let bus = GitHubPRDiscussionUpdates(), root = URL(fileURLWithPath: "/tmp/application-one")
    bus.publish(dataRoot: root, request: request)
    XCTAssertNotNil(bus.revision(dataRoot: root, request: request))
    XCTAssertNil(bus.revision(dataRoot: URL(fileURLWithPath: "/tmp/application-two"), request: request))
    let other = GitHubPullRequest(number: 43, url: "https://github.com/sample/project/pull/43", title: "Other",
      isDraft: false, headRefName: "other", baseRefName: "main", isCrossRepository: false)
    XCTAssertNil(bus.revision(dataRoot: root, request: other))
  }

  @MainActor func testDefiniteServerRejectionRetainsPostAndAllowsExplicitRetry() async throws {
    let (root, service) = try await fixture(["discussionMutationGraphQLError": true])
    let state = GitHubPRDiscussionState(service: service)
    await state.load(request, at: root, valid: { true }); state.commentBody = "Retry me"
    state.start(.post(body: state.commentBody, thread: nil), request: request, at: root, valid: { true }, writable: { true })
    await state.operation?.value
    XCTAssertNil(state.uncertain); XCTAssertEqual(state.commentBody, "Retry me"); XCTAssertNotNil(state.error)
    try change(["discussionMutationGraphQLError": false], root)
    XCTAssertTrue(state.start(.post(body: state.commentBody, thread: nil), request: request, at: root, valid: { true }, writable: { true }))
    await state.operation?.value; XCTAssertEqual(state.commentBody, "")
    XCTAssertEqual(state.snapshot?.comments.filter { $0.body == "Retry me" }.count, 1)
  }

  @MainActor func testBackgroundRefreshKeepsEditorsAndLateCancelledReadCannotReplaceSnapshot() async throws {
    let (root, service) = try await fixture(), state = GitHubPRDiscussionState(service: service)
    await state.load(request, at: root, valid: { true })
    state.beginEdit(try XCTUnwrap(state.snapshot?.comment("issue-1")))
    state.drafts["issue-1"]?.text = "Unsaved"
    try change(["discussionDelay": 0.15, "discussionTimeline": [comment("issue-1", body: "Remote change")]], root)
    let load = Task { await state.load(self.request, at: root, valid: { true }) }
    while !state.refreshing { await Task.yield() }
    XCTAssertFalse(state.loading); XCTAssertEqual(state.drafts["issue-1"]?.text, "Unsaved")
    state.cancel(); await load.value
    XCTAssertEqual(state.snapshot?.comment("issue-1")?.body, "Original")
    XCTAssertFalse(state.refreshing)
    await state.load(request, at: root, valid: { true })
    XCTAssertEqual(state.snapshot?.comment("issue-1")?.body, "Remote change")
    XCTAssertEqual(state.drafts["issue-1"]?.text, "Unsaved")
  }

  @MainActor func testReadFailureKeepsDraftDisablesMutationsAndRetryRestoresSnapshot() async throws {
    let (root, service) = try await fixture(), state = GitHubPRDiscussionState(service: service)
    await state.load(request, at: root, valid: { true }); state.commentBody = "Keep draft"
    try change(["discussionFailure": true], root)
    await state.load(request, at: root, valid: { true })
    XCTAssertNotNil(state.readError); XCTAssertEqual(state.commentBody, "Keep draft")
    XCTAssertFalse(state.canWrite(request, writable: true))
    try change(["discussionFailure": false], root)
    await state.load(request, at: root, valid: { true })
    XCTAssertNil(state.readError); XCTAssertTrue(state.canWrite(request, writable: true))
  }

  func testReceiptUpdatesAllCommentKindsAndThreadResolutionDuringReadOutage() async throws {
    for action: GitHubPRDiscussionAction in [.edit(id: "issue-1", kind: .issue, body: "Edit accepted"),
      .delete(id: "issue-1", kind: .issue), .post(body: "Reply accepted", thread: "thread-1"),
      .resolve(thread: "thread-1", resolved: true), .review(body: "Review accepted", decision: .comment, head: head)] {
      let (root, service) = try await fixture(["discussionFailureAfterAction": true])
      let expected = try await service.discussion(for: request, at: root)
      let result = try await service.applyDiscussion(action, expected: expected, request: request, at: root)
      XCTAssertNotNil(result.notice)
      XCTAssertTrue(GitHubPRService.discussionConfirmed(action, baseline: expected, current: result.snapshot))
    }
  }

  @MainActor func testFailedDraftsKeepIndependentErrorsAcrossTypingAndRefresh() async throws {
    let (root, service) = try await fixture(["discussionMutationGraphQLError": true])
    let state = GitHubPRDiscussionState(service: service)
    await state.load(request, at: root, valid: { true })
    for id in ["issue-1", "code-1"] {
      state.beginEdit(try XCTUnwrap(state.snapshot?.comment(id))); state.drafts[id]?.text = "Changed " + id
      XCTAssertTrue(state.start(try XCTUnwrap(state.draftAction(id)), request: request, at: root,
        valid: { true }, writable: { true }, draftID: id))
      await state.operation?.value
      XCTAssertNotNil(state.message(for: .draft(id)))
    }
    await state.load(request, at: root, valid: { true })
    XCTAssertNotNil(state.message(for: .draft("issue-1"))); XCTAssertNotNil(state.message(for: .draft("code-1")))
    XCTAssertNil(state.message(for: .activity))
    state.drafts["code-1"]?.text = "New attempt"; state.clearError(.draft("code-1"))
    XCTAssertNil(state.message(for: .draft("code-1"))); XCTAssertNotNil(state.message(for: .draft("issue-1")))
    state.commentBody = "Other input"; state.clearError(.general)
    XCTAssertNotNil(state.message(for: .draft("issue-1")))
    try change(["discussionMutationGraphQLError": false], root)
    XCTAssertTrue(state.start(try XCTUnwrap(state.draftAction("code-1")), request: request, at: root,
      valid: { true }, writable: { true }, draftID: "code-1"))
    await state.operation?.value
    XCTAssertNil(state.drafts["code-1"]); XCTAssertNotNil(state.message(for: .draft("issue-1")))
    XCTAssertEqual(state.drafts["issue-1"]?.text, "Changed issue-1")
  }

  @MainActor func testGeneralReviewDeleteAndThreadErrorsStayAtTheirOwners() async throws {
    let (root, service) = try await fixture(["discussionMutationGraphQLError": true])
    let state = GitHubPRDiscussionState(service: service)
    await state.load(request, at: root, valid: { true })
    let actions: [(GitHubPRDiscussionAction, GitHubPRDiscussionErrorOwner)] = [
      (.post(body: "Comment", thread: nil), .general),
      (.review(body: "Review", decision: .comment, head: head), .review),
      (.delete(id: "issue-1", kind: .issue), .delete("issue-1")),
      (.resolve(thread: "thread-1", resolved: true), .thread("thread-1"))]
    for (action, owner) in actions {
      XCTAssertTrue(state.start(action, request: request, at: root, valid: { true }, writable: { true }))
      await state.operation?.value
      XCTAssertNotNil(state.message(for: owner)); XCTAssertNil(state.message(for: .activity))
    }
    state.clearError(.review)
    XCTAssertNil(state.message(for: .review))
    for owner: GitHubPRDiscussionErrorOwner in [.general, .delete("issue-1"), .thread("thread-1")] {
      XCTAssertNotNil(state.message(for: owner))
    }
  }

  @MainActor func testPendingInputLocksOnlyItsOwnEditorAndPreservesOtherDraft() async throws {
    let (root, service) = try await fixture(), state = GitHubPRDiscussionState(service: service)
    await state.load(request, at: root, valid: { true })
    let issue = try XCTUnwrap(state.snapshot?.comment("issue-1")), code = try XCTUnwrap(state.snapshot?.comment("code-1"))
    state.beginReply(issue, thread: nil, quote: false); state.drafts[issue.id]?.text = "Pending reply"
    try change(["discussionDelay": 0.1], root)
    XCTAssertTrue(state.start(try XCTUnwrap(state.draftAction(issue.id)), request: request, at: root,
      valid: { true }, writable: { true }, draftID: issue.id))
    XCTAssertEqual(state.pendingOwner, .draft(issue.id))
    XCTAssertFalse(state.canEdit(.draft(issue.id), writable: true))
    XCTAssertTrue(state.canEdit(.general, writable: true)); XCTAssertTrue(state.canEdit(.draft(code.id), writable: true))
    state.cancelDraft(issue.id); XCTAssertNotNil(state.drafts[issue.id])
    state.beginEdit(code); state.drafts[code.id]?.text = "Still editable"
    state.commentBody = "New general draft"
    XCTAssertFalse(state.start(.post(body: state.commentBody, thread: nil), request: request, at: root,
      valid: { true }, writable: { true }), "Writes still share PR ownership")
    await state.operation?.value
    XCTAssertNil(state.pendingOwner); XCTAssertNil(state.drafts[issue.id])
    XCTAssertEqual(state.drafts[code.id]?.text, "Still editable"); XCTAssertEqual(state.commentBody, "New general draft")
  }

  @MainActor func testUncertainReplyErrorSurvivesRefreshAndOtherEditorChanges() async throws {
    let (root, service) = try await fixture(["discussionFailAfterAction": true, "discussionFailureAfterAction": true])
    let state = GitHubPRDiscussionState(service: service)
    await state.load(request, at: root, valid: { true })
    let code = try XCTUnwrap(state.snapshot?.comment("code-1")), thread = try XCTUnwrap(state.snapshot?.threads.first)
    state.beginReply(code, thread: thread, quote: false); state.drafts[code.id]?.text = "Pending thread reply"
    XCTAssertTrue(state.start(try XCTUnwrap(state.draftAction(code.id)), request: request, at: root,
      valid: { true }, writable: { true }, draftID: code.id))
    await state.operation?.value
    XCTAssertEqual(state.uncertainOwner, .draft(code.id)); XCTAssertNotNil(state.message(for: .draft(code.id)))
    state.clearError(.draft(code.id)); XCTAssertNotNil(state.message(for: .draft(code.id)))
    state.commentBody = "Other draft"; state.clearError(.general)
    try change(["discussionFailureAfterAction": false], root)
    await state.load(request, at: root, valid: { true })
    XCTAssertNotNil(state.message(for: .draft(code.id))); XCTAssertNotNil(state.uncertain)
    XCTAssertFalse(state.canEdit(.draft(code.id), writable: true)); XCTAssertTrue(state.canEdit(.general, writable: true))
    XCTAssertTrue(state.confirm(request: request, at: root, valid: { true })); await state.operation?.value
    XCTAssertNil(state.uncertain); XCTAssertNil(state.message(for: .draft(code.id)))
    XCTAssertNil(state.drafts[code.id]); XCTAssertEqual(state.commentBody, "Other draft")
    XCTAssertEqual(try logs(root, mutationsOnly: true).count, 1)
  }

}
