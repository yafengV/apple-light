import AppKit
import SwiftUI
import XCTest
@testable import ShipiOS

@MainActor final class GitHubPRInlineCommentTests: XCTestCase {
  private let head = String(repeating: "a", count: 40)
  private let pr = GitHubPullRequest(number: 42, url: "https://github.com/sample/project/pull/42",
    title: "Feature", isDraft: false, headRefName: "feature", baseRefName: "main", isCrossRepository: false)
  private let patch = "diff --git a/Sources/Main.swift b/Sources/Main.swift\n--- a/Sources/Main.swift\n+++ b/Sources/Main.swift\n@@ -8,3 +8,3 @@\n old\n-before\n+after\n tail\n"
  private func fixture(_ extra: [String: Any] = [:]) async throws -> (GitHubPRCodeRequest, GitHubPRService) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("pr-inline-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    _ = try await GitReviewService.checked(["init", "-q", "-b", "unrelated-local-branch"], at: root)
    let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/github_cli.py")
    let executable = root.appendingPathComponent(".git/gh-fixture")
    try FileManager.default.copyItem(at: source, to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    let item = try JSONSerialization.jsonObject(with: JSONEncoder().encode(pr))
    var state: [String: Any] = ["head": head, "pullRequests": [item], "prDiff": patch, "viewer": "reviewer"]
    extra.forEach { state[$0.key] = $0.value }; try write(state, root)
    return (.init(taskID: "task-a", root: root, pullRequest: pr, head: head), .init(executable: executable))
  }
  private func write(_ state: [String: Any], _ root: URL) throws {
    try JSONSerialization.data(withJSONObject: state).write(to: root.appendingPathComponent(".git/github-fixture.json"))
  }
  private func change(_ extra: [String: Any], _ root: URL) throws {
    var state = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent(".git/github-fixture.json"))) as! [String: Any]
    extra.forEach { state[$0.key] = $0.value }; try write(state, root)
  }
  private func writes(_ root: URL) throws -> [[String: Any]] {
    try String(contentsOf: root.appendingPathComponent(".git/github-requests.jsonl"), encoding: .utf8)
      .split(separator: "\n").map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any] }
      .filter { ($0["args"] as? [String])?.contains("POST") == true }
  }
  private func position(line: Int = 9, side: GitHubPRCommentPosition.Side = .right, start: Int? = nil,
    startSide: GitHubPRCommentPosition.Side? = nil, path: String = "Sources/Main.swift") -> GitHubPRCommentPosition {
    .init(path: path, line: line, side: side, startLine: start, startSide: startSide)
  }
  private func failure(_ work: () async throws -> Void) async -> Error? {
    do { try await work(); XCTFail("Expected failure"); return nil } catch { return error }
  }
  private func setup(_ extra: [String: Any] = [:], point: GitHubPRCommentPosition? = nil)
    async throws -> (GitHubPRCodeRequest, GitHubPRService, GitHubPRInlineAnchor, GitHubPRDiscussionSnapshot) {
    let (request, service) = try await fixture(extra)
    let code = try await service.codeSnapshot(request)
    let anchor = try GitHubPRInlineAnchor(position: point ?? position(), snapshot: code)
    let discussion = try await service.discussion(for: pr, at: request.root)
    return (request, service, anchor, discussion)
  }

  func testSingleBothSidesAndRangesPostActualCLIWithPrivateJSONAndCommit() async throws {
    for point in [position(), position(side: .left), position(line: 10, start: 8),
      position(line: 10, side: .left, start: 8), position(start: 9, startSide: .left)] {
      let (request, service, anchor, baseline) = try await setup(point: point)
      let result = try await service.applyDiscussion(.inline(body: "  评论 `code`\n\n正文  ", anchor: anchor),
        expected: baseline, request: pr, at: request.root)
      XCTAssertEqual(result.snapshot.threads.count, 1); XCTAssertNil(result.notice)
      XCTAssertTrue(GitHubPRService.inlineConfirmed("评论 `code`\n\n正文", anchor: anchor, baseline: baseline, current: result.snapshot))
      let record = try XCTUnwrap(writes(request.root).first), input = try XCTUnwrap(record["input"] as? [String: Any])
      XCTAssertEqual(input["commit_id"] as? String, head); XCTAssertEqual(input["path"] as? String, point.path)
      XCTAssertEqual(input["line"] as? Int, point.line); XCTAssertEqual(input["side"] as? String, point.side.rawValue.uppercased())
      XCTAssertEqual(input["start_line"] as? Int, point.startLine)
      XCTAssertEqual(input["start_side"] as? String, point.startLine.map { _ in (point.startSide ?? point.side).rawValue.uppercased() })
      XCTAssertEqual(record["inputMode"] as? String, "0o600"); XCTAssertEqual(record["folderMode"] as? String, "0o700")
      let args = try XCTUnwrap(record["args"] as? [String]); XCTAssertFalse(args.contains { $0.contains("评论") })
      XCTAssertEqual(args[1], "repos/sample/project/pulls/42/comments")
      let inputIndex = try XCTUnwrap(args.firstIndex(of: "--input"))
      XCTAssertFalse(FileManager.default.fileExists(atPath: args[inputIndex + 1]))
      XCTAssertEqual(try writes(request.root).count, 1)
    }
  }
  func testSelectionNormalizesReverseAndPreservesSameNumberCrossSide() {
    let same = GitHubPRCodePoint.position(path: "a.swift", from: .init(side: .left, line: 12), to: .init(side: .left, line: 8))
    XCTAssertEqual(same.startLine, 8); XCTAssertEqual(same.line, 12); XCTAssertNil(same.startSide)
    let cross = GitHubPRCodePoint.position(path: "a.swift", from: .init(side: .left, line: 9), to: .init(side: .right, line: 9))
    XCTAssertEqual(cross.startLine, 9); XCTAssertEqual(cross.startSide, .left); XCTAssertEqual(cross.side, .right)
  }
  func testInvalidBinaryMissingSideReverseSelectionsRejected() throws {
    let code = GitHubPRCodeSnapshot(identity: .init(nodeID: "pr-node", head: head, base: String(repeating: "b", count: 40),
      headBranch: "feature", baseBranch: "main", changedFiles: 1), files: try GitHubPRCodeFile.parse(patch + "@@ -20 +20 @@\n later\n"))
    for point in [position(line: 0), position(line: 999), position(startSide: .left), position(line: 8, start: 10),
      position(path: "../a"), position(path: "/a"), position(path: "missing"), position(path: "a\u{0}")] {
      XCTAssertThrowsError(try GitHubPRInlineAnchor(position: point, snapshot: code))
    }
    XCTAssertNoThrow(try GitHubPRInlineAnchor(position: position(line: 20, start: 8), snapshot: code))
    let added = GitHubPRCodeSnapshot(identity: code.identity, files: try GitHubPRCodeFile.parse("diff --git a/Sources/Main.swift b/Sources/Main.swift\nnew file mode 100644\n--- /dev/null\n+++ b/Sources/Main.swift\n@@ -0,0 +1 @@\n+new\n"))
    XCTAssertThrowsError(try GitHubPRInlineAnchor(position: position(line: 1, side: .left), snapshot: added))
    let binary = GitHubPRCodeSnapshot(identity: code.identity, files: [.init(path: "Sources/Main.swift", oldPath: nil, patch: patch, kind: .modified, binary: true)])
    XCTAssertThrowsError(try GitHubPRInlineAnchor(position: position(), snapshot: binary))
  }
  func testRenamedAndDeletedLeftLinesUseDisplayedPath() async throws {
    for source in [patch.replacingOccurrences(of: "a/Sources/Main.swift", with: "a/Old.swift")
      .replacingOccurrences(of: "--- a/Old.swift", with: "rename from Old.swift\nrename to Sources/Main.swift\n--- a/Old.swift"),
      "diff --git a/Sources/Main.swift b/Sources/Main.swift\ndeleted file mode 100644\n--- a/Sources/Main.swift\n+++ /dev/null\n@@ -9 +0,0 @@\n-before\n"] {
      let (request, service, anchor, baseline) = try await setup(["prDiff": source], point: position(side: .left))
      let result = try await service.applyDiscussion(.inline(body: "old line", anchor: anchor), expected: baseline, request: pr, at: request.root)
      XCTAssertEqual(result.snapshot.threads.first?.path, "Sources/Main.swift")
    }
  }
  func testHeadBaseDiffAccountAndNodeDriftDoNotWrite() async throws {
    for extra: [String: Any] in [["detailHead": String(repeating: "c", count: 40)], ["codeBase": String(repeating: "d", count: 40)],
      ["prDiff": patch.replacingOccurrences(of: "+after", with: "+changed")], ["viewer": "different"], ["codeNodeID": "other-node"]] {
      let (request, service, anchor, baseline) = try await setup()
      try change(extra, request.root)
      let error = await failure { _ = try await service.applyDiscussion(.inline(body: "text", anchor: anchor), expected: baseline, request: pr, at: request.root) }; XCTAssertNotNil(error)
      XCTAssertTrue(try writes(request.root).isEmpty)
    }
  }
  func testFinalBaseDriftAndAuthorizationRevocationDoNotWrite() async throws {
    let (request, service, anchor, baseline) = try await setup()
    try change(["codeBaseAtIdentityRead": ["3": String(repeating: "c", count: 40)]], request.root)
    let error = await failure { _ = try await service.applyDiscussion(.inline(body: "text", anchor: anchor), expected: baseline, request: pr, at: request.root) }; XCTAssertNotNil(error)
    XCTAssertTrue(try writes(request.root).isEmpty)
    let (other, second, secondAnchor, secondBaseline) = try await setup()
    var calls = 0
    let revoked = await failure {
      _ = try await second.applyDiscussion(.inline(body: "text", anchor: secondAnchor), expected: secondBaseline, request: pr, at: other.root) {
        calls += 1; if calls > 1 { throw CancellationError() }
      }
    }; XCTAssertNotNil(revoked)
    XCTAssertTrue(try writes(other.root).isEmpty)
  }
  func testCrossHunkRangePreservesBothEndpointsAndServerRejectionKeepsAttemptEditable() async throws {
    let (request, service, anchor, baseline) = try await setup(["prDiff": patch + "@@ -20 +20 @@\n later\n", "inlineStatus": 422],
      point: position(line: 20, start: 8))
    let error = await failure { _ = try await service.applyDiscussion(.inline(body: "across hunks", anchor: anchor), expected: baseline, request: pr, at: request.root) }
    XCTAssertNil((error as? GitHubPRDiscussionFailure)?.uncertain)
    let record = try XCTUnwrap(writes(request.root).first), input = try XCTUnwrap(record["input"] as? [String: Any])
    XCTAssertEqual(input["start_line"] as? Int, 8); XCTAssertEqual(input["line"] as? Int, 20)
  }
  func testLostResponseConfirmedWithoutAnotherPOST() async throws {
    let (request, service, anchor, baseline) = try await setup(["inlineLostResponse": true])
    let result = try await service.applyDiscussion(.inline(body: "text", anchor: anchor), expected: baseline, request: pr, at: request.root)
    XCTAssertEqual(result.snapshot.threads.count, 1); XCTAssertEqual(try writes(request.root).count, 1)
  }
  func testAcceptedReceiptWithRefreshOutageAcknowledgesWithoutFabricatedThread() async throws {
    let (request, service, anchor, baseline) = try await setup(["discussionFailureAfterAction": true])
    let result = try await service.applyDiscussion(.inline(body: "text", anchor: anchor), expected: baseline, request: pr, at: request.root)
    XCTAssertNotNil(result.notice); XCTAssertTrue(result.snapshot.threads.isEmpty)
    XCTAssertEqual(try writes(request.root).count, 1)
    try change(["discussionFailureAfterAction": false], request.root)
    let recovered = try await service.discussion(for: pr, at: request.root); XCTAssertEqual(recovered.threads.count, 1)
  }
  func testAmbiguousResultFreezesAttemptAndReadOnlyConfirmationDoesNotResend() async throws {
    for extra: [String: Any] in [["inlineNoAccept": true], ["inlineLostResponse": true, "inlineDuplicate": true]] {
      let (request, service, anchor, baseline) = try await setup(extra)
      let error = await failure { _ = try await service.applyDiscussion(.inline(body: "text", anchor: anchor), expected: baseline, request: pr, at: request.root) }
      let attempt = try XCTUnwrap((error as? GitHubPRDiscussionFailure)?.uncertain)
      let unresolved = await failure { _ = try await service.confirmDiscussion(attempt, request: pr, at: request.root) }; XCTAssertNotNil(unresolved)
      XCTAssertEqual(try writes(request.root).count, 1)
    }
  }
  func testUncertainLostReceiptCanRecoverByOnlyReading() async throws {
    let (request, service, anchor, baseline) = try await setup(["inlineLostResponse": true, "discussionFailureAfterAction": true])
    let error = await failure { _ = try await service.applyDiscussion(.inline(body: "text", anchor: anchor), expected: baseline, request: pr, at: request.root) }
    let attempt = try XCTUnwrap((error as? GitHubPRDiscussionFailure)?.uncertain)
    try change(["discussionFailureAfterAction": false], request.root)
    let result = try await service.confirmDiscussion(attempt, request: pr, at: request.root)
    XCTAssertEqual(result.snapshot.threads.count, 1); XCTAssertEqual(try writes(request.root).count, 1)
  }
  func testExplicitHTTPRejectionAllowsEditedRetry() async throws {
    for status in [401, 403, 422, 429] {
      let (request, service, anchor, baseline) = try await setup(["inlineStatus": status])
      let error = await failure { _ = try await service.applyDiscussion(.inline(body: "text", anchor: anchor), expected: baseline, request: pr, at: request.root) }
      XCTAssertNil((error as? GitHubPRDiscussionFailure)?.uncertain)
      XCTAssertTrue(error?.localizedDescription.contains("HTTP \(status)") == true)
      XCTAssertEqual(try writes(request.root).count, 1)
    }
  }
  func testWrongReceiptFieldsNeverAcknowledgeWhenRefreshCannotConfirm() async throws {
    for override: [String: Any] in [["node_id": ""], ["commit_id": String(repeating: "c", count: 40)], ["path": "wrong"],
      ["line": 8], ["side": "LEFT"], ["start_line": 8], ["user": ["login": "other"]],
      ["pull_request_url": "https://api.github.com/repos/other/project/pulls/42"], ["in_reply_to_id": 12]] {
      let (request, service, anchor, baseline) = try await setup(["inlineReceiptOverride": override, "discussionFailureAfterAction": true])
      let error = await failure { _ = try await service.applyDiscussion(.inline(body: "text", anchor: anchor), expected: baseline, request: pr, at: request.root) }
      XCTAssertNotNil((error as? GitHubPRDiscussionFailure)?.uncertain)
    }
  }
  func testEmptyAndOversizedBodiesDoNotWrite() async throws {
    let (request, service, anchor, baseline) = try await setup()
    for body in ["  \n", String(repeating: "中", count: 22_000)] {
      let error = await failure { _ = try await service.applyDiscussion(.inline(body: body, anchor: anchor), expected: baseline, request: pr, at: request.root) }; XCTAssertNotNil(error)
    }
    XCTAssertTrue(try writes(request.root).isEmpty)
  }
  func testDraftDedupeFocusPreservesTextAndExistingEndpointAvoidsNewDraft() async throws {
    let (request, service, anchor, _) = try await setup()
    let state = GitHubPRDiscussionState(service: service, coordinator: .init())
    await state.load(pr, at: request.root, valid: { true })
    let id = try XCTUnwrap(state.beginInline(anchor)); state.drafts[id]?.text = "keep"
    let focus = state.drafts[id]?.focus
    let code = try await service.codeSnapshot(request)
    let range = try GitHubPRInlineAnchor(position: position(start: 8), snapshot: code)
    XCTAssertEqual(state.beginInline(range), id); XCTAssertEqual(state.drafts[id]?.text, "keep")
    XCTAssertNotEqual(state.drafts[id]?.focus, focus); XCTAssertEqual(state.inlineDrafts.count, 1)
    state.cancelDraft(id); XCTAssertTrue(state.inlineDrafts.isEmpty)
    _ = try await service.applyDiscussion(.inline(body: "existing", anchor: anchor), expected: try XCTUnwrap(state.snapshot), request: pr, at: request.root)
    await state.load(pr, at: request.root, valid: { true }); XCTAssertNil(state.beginInline(anchor))
    let another = GitHubPRDiscussionState(service: service, coordinator: .init())
    await another.load(pr, at: request.root, valid: { true }); XCTAssertTrue(another.drafts.isEmpty)
  }
  func testDraftSubmissionAndUncertainOwnerKeepBodyUntilConfirmed() async throws {
    let (request, service, anchor, _) = try await setup(["inlineLostResponse": true, "discussionFailureAfterAction": true])
    let state = GitHubPRDiscussionState(service: service, coordinator: .init())
    await state.load(pr, at: request.root, valid: { true })
    let id = try XCTUnwrap(state.beginInline(anchor)); state.drafts[id]?.text = "draft"
    XCTAssertTrue(state.start(try XCTUnwrap(state.draftAction(id)), request: pr, at: request.root, valid: { true }, writable: { true }, draftID: id))
    state.cancelDraft(id); XCTAssertNotNil(state.drafts[id]); XCTAssertFalse(state.canEdit(.draft(id), writable: true))
    await state.operation?.value
    XCTAssertNotNil(state.uncertain); XCTAssertEqual(state.uncertainOwner, .draft(id)); XCTAssertEqual(state.drafts[id]?.text, "draft")
    state.cancelDraft(id); XCTAssertNotNil(state.drafts[id]); XCTAssertFalse(state.canWrite(pr, writable: true))
    try change(["discussionFailureAfterAction": false], request.root)
    XCTAssertTrue(state.confirm(request: pr, at: request.root, valid: { true })); await state.operation?.value
    XCTAssertNil(state.drafts[id]); XCTAssertNil(state.uncertain); XCTAssertEqual(try writes(request.root).count, 1)
  }
  func testReadOnlyAndStaleDraftRemainUnsubmittedAndEditableForCopy() async throws {
    let (request, service, anchor, _) = try await setup()
    let state = GitHubPRDiscussionState(service: service, coordinator: .init())
    await state.load(pr, at: request.root, valid: { true }); let id = try XCTUnwrap(state.beginInline(anchor))
    state.drafts[id]?.text = "keep"
    XCTAssertFalse(state.start(try XCTUnwrap(state.draftAction(id)), request: pr, at: request.root, valid: { true }, writable: { false }, draftID: id))
    try change(["codeBase": String(repeating: "c", count: 40)], request.root)
    let changed = try await service.codeSnapshot(request); XCTAssertFalse(anchor.matches(changed)); XCTAssertTrue(state.canEdit(.draft(id), writable: true))
    XCTAssertEqual(state.drafts[id]?.text, "keep"); XCTAssertTrue(try writes(request.root).isEmpty)
  }
  func testBaseOnlyChangeMarksOldCodeStaleAndExplicitRefreshAllowsNewRangeWithoutLosingBody() async throws {
    let (request, service, anchor, _) = try await setup()
    let discussion = GitHubPRDiscussionState(service: service, coordinator: .init())
    await discussion.load(pr, at: request.root, valid: { true })
    let code = GitHubPRCodeState(service: service); await code.load(request, valid: { true })
    let id = try XCTUnwrap(discussion.beginInline(anchor)); discussion.drafts[id]?.text = "keep old draft"
    try change(["codeBase": String(repeating: "c", count: 40)], request.root)
    XCTAssertTrue(discussion.start(try XCTUnwrap(discussion.draftAction(id)), request: pr, at: request.root, valid: { true }, writable: { true }, draftID: id))
    await discussion.operation?.value
    XCTAssertTrue(discussion.isCodeStale(anchor.identity)); XCTAssertNil(discussion.uncertain)
    XCTAssertEqual(discussion.drafts[id]?.text, "keep old draft"); XCTAssertNil(discussion.beginInline(anchor))
    XCTAssertFalse(discussion.start(try XCTUnwrap(discussion.draftAction(id)), request: pr, at: request.root, valid: { true }, writable: { true }, draftID: id))
    XCTAssertTrue(try writes(request.root).isEmpty)
    await code.refresh(request, valid: { true })
    let refreshed = try XCTUnwrap(code.snapshot)
    XCTAssertEqual(refreshed.identity.head, head); XCTAssertEqual(refreshed.identity.base, String(repeating: "c", count: 40))
    XCTAssertFalse(discussion.isCodeStale(refreshed.identity)); XCTAssertFalse(anchor.matches(refreshed))
    let newAnchor = try GitHubPRInlineAnchor(position: position(line: 10), snapshot: refreshed)
    let otherID = try XCTUnwrap(discussion.beginInline(newAnchor))
    XCTAssertEqual(discussion.drafts[id]?.text, "keep old draft"); discussion.drafts[otherID]?.text = "new version"
    XCTAssertTrue(discussion.start(try XCTUnwrap(discussion.draftAction(otherID)), request: pr, at: request.root, valid: { true }, writable: { true }, draftID: otherID))
    await discussion.operation?.value
    XCTAssertNil(discussion.drafts[otherID]); XCTAssertEqual(discussion.drafts[id]?.text, "keep old draft")
    XCTAssertEqual(try writes(request.root).count, 1)
  }
  func testHiddenCodePageRefreshClearsStaleMarkerEvenWhenIdentityIsUnchanged() async throws {
    let (request, service, anchor, _) = try await setup()
    let discussion = GitHubPRDiscussionState(service: service, coordinator: .init())
    await discussion.load(pr, at: request.root, valid: { true })
    let code = GitHubPRCodeState(service: service); await code.load(request, valid: { true })
    let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 900, height: 700), styleMask: [.titled], backing: .buffered, defer: true)
    window.isReleasedWhenClosed = false; defer { window.close() }
    let host = NSHostingView(rootView: TaskPullRequestCodeView(state: code, discussion: discussion, enabled: true,
      writable: true, mentionRequest: nil, open: { _ in }, submit: { _, _ in }, retry: {}, retryComments: {}).frame(width: 850, height: 650))
    window.contentView = host; try await Task.sleep(for: .milliseconds(150)); host.layoutSubtreeIfNeeded()
    let id = try XCTUnwrap(discussion.beginInline(anchor)); discussion.drafts[id]?.text = "keep old body"
    try change(["prDiff": patch.replacingOccurrences(of: "+after", with: "+different")], request.root)
    XCTAssertTrue(discussion.start(try XCTUnwrap(discussion.draftAction(id)), request: pr, at: request.root, valid: { true }, writable: { true }, draftID: id))
    await discussion.operation?.value
    XCTAssertTrue(discussion.isCodeStale(anchor.identity)); XCTAssertTrue(try writes(request.root).isEmpty)
    await code.refresh(request, valid: { true })
    try await Task.sleep(for: .milliseconds(150)); host.layoutSubtreeIfNeeded()
    let refreshed = try XCTUnwrap(code.snapshot)
    XCTAssertEqual(refreshed.identity, anchor.identity); XCTAssertFalse(anchor.matches(refreshed))
    XCTAssertFalse(discussion.isCodeStale(refreshed.identity)); XCTAssertEqual(discussion.drafts[id]?.text, "keep old body")
    let newAnchor = try GitHubPRInlineAnchor(position: position(line: 10), snapshot: refreshed)
    XCTAssertNotNil(discussion.beginInline(newAnchor)); XCTAssertFalse(window.isVisible)
  }
  func testDefiniteFailurePreservesDraftAndEditedRetrySucceeds() async throws {
    let (request, service, anchor, _) = try await setup(["inlineStatus": 422])
    let state = GitHubPRDiscussionState(service: service, coordinator: .init())
    await state.load(pr, at: request.root, valid: { true }); let id = try XCTUnwrap(state.beginInline(anchor))
    state.drafts[id]?.text = "first"
    XCTAssertTrue(state.start(try XCTUnwrap(state.draftAction(id)), request: pr, at: request.root, valid: { true }, writable: { true }, draftID: id))
    await state.operation?.value
    XCTAssertNil(state.uncertain); XCTAssertNotNil(state.message(for: .draft(id)))
    XCTAssertTrue(state.canEdit(.draft(id), writable: true)); XCTAssertEqual(state.drafts[id]?.text, "first")
    state.drafts[id]?.text = "edited"; try change(["inlineStatus": 201], request.root)
    XCTAssertTrue(state.start(try XCTUnwrap(state.draftAction(id)), request: pr, at: request.root, valid: { true }, writable: { true }, draftID: id))
    await state.operation?.value
    XCTAssertNil(state.drafts[id]); XCTAssertEqual(state.snapshot?.threads.first?.comments.first?.body, "edited")
    XCTAssertEqual(try writes(request.root).count, 2)
  }
  func testConfirmationMatchesRootAuthorCommitBodyAndRangeIncludingOutdatedPosition() async throws {
    let (request, service, anchor, baseline) = try await setup(point: position(line: 10, start: 8))
    let current = try await service.applyDiscussion(.inline(body: "text", anchor: anchor), expected: baseline, request: pr, at: request.root).snapshot
    for transform: (inout GitHubPRDiscussionSnapshot) -> Void in [
      { $0.threads[0].comments[0].commit = String(repeating: "c", count: 40); $0.threads[0].comments[0].originalCommit = String(repeating: "c", count: 40) },
      { $0.threads[0].comments[0] = .init(id: "other", kind: .code, body: "text", author: "other", authorType: "User", createdAt: "", url: nil, canUpdate: true, canDelete: true, commit: self.head) },
      { $0.threads[0].comments[0] = .init(id: "other", kind: .code, body: "different", author: "reviewer", authorType: "User", createdAt: "", url: nil, canUpdate: true, canDelete: true, commit: self.head) },
      { $0.threads[0].startLine = 9; $0.threads[0].originalStartLine = 9 },
      { $0.threads[0].startDiffSide = "LEFT" }
    ] {
      var wrong = current; transform(&wrong)
      XCTAssertFalse(GitHubPRService.inlineConfirmed("text", anchor: anchor, baseline: baseline, current: wrong))
    }
    let thread = try XCTUnwrap(current.threads.first)
    var outdated = current
    outdated.threads = [.init(id: thread.id, path: thread.path, line: nil, originalLine: 10,
      diffHunk: thread.diffHunk, isResolved: false, isOutdated: true, canReply: true, canResolve: true, canUnresolve: false,
      comments: thread.comments, diffSide: "RIGHT", startLine: nil, startDiffSide: "RIGHT", originalStartLine: 8)]
    outdated.threads[0].comments[0].commit = String(repeating: "c", count: 40)
    outdated.threads[0].comments[0].originalCommit = head
    XCTAssertTrue(GitHubPRService.inlineConfirmed("text", anchor: anchor, baseline: baseline, current: outdated))
  }
  func testHiddenCodeFileRendersInlineDraftAndKeepsItAcrossSplitAndStaleVersion() async throws {
    let (request, service, anchor, _) = try await setup()
    let discussion = GitHubPRDiscussionState(service: service, coordinator: .init())
    await discussion.load(pr, at: request.root, valid: { true })
    let code = GitHubPRCodeState(service: service); await code.load(request, valid: { true })
    let snapshot = try XCTUnwrap(code.snapshot)
    let controls = PullRequestInlineCommentControls(code: snapshot, discussion: discussion, enabled: true, writable: true, mentionRequest: nil, submit: { _, _ in })
    let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 900, height: 700), styleMask: [.titled], backing: .buffered, defer: true)
    window.isReleasedWhenClosed = false; defer { window.close() }
    let host = NSHostingView(rootView: TaskPullRequestCodeFileView(file: snapshot.files[0], state: code, threads: [], inline: controls,
      comment: { _ in EmptyView() }).frame(width: 850))
    window.contentView = host
    try await Task.sleep(for: .milliseconds(150)); host.layoutSubtreeIfNeeded(); let before = host.fittingSize.height
    let id = try XCTUnwrap(discussion.beginInline(anchor)); discussion.drafts[id]?.text = "keep body"
    try await Task.sleep(for: .milliseconds(150)); host.layoutSubtreeIfNeeded(); XCTAssertGreaterThan(host.fittingSize.height, before + 50)
    func gutters(_ view: NSView) -> [PullRequestCodeGutterView] {
      (view as? PullRequestCodeGutterView).map { [$0] } ?? view.subviews.flatMap(gutters)
    }
    XCTAssertFalse(gutters(host).isEmpty)
    code.split = true; try await Task.sleep(for: .milliseconds(150)); host.layoutSubtreeIfNeeded()
    XCTAssertEqual(discussion.inlineDrafts.count, 1); XCTAssertGreaterThan(host.fittingSize.height, before + 50)
    try change(["codeBase": String(repeating: "c", count: 40)], request.root)
    let changed = try await service.codeSnapshot(request)
    host.rootView = TaskPullRequestCodeFileView(file: changed.files[0], state: code, threads: [],
      inline: .init(code: changed, discussion: discussion, enabled: true, writable: true, mentionRequest: nil, submit: { _, _ in }),
      comment: { _ in EmptyView() }).frame(width: 850)
    try await Task.sleep(for: .milliseconds(150)); host.layoutSubtreeIfNeeded()
    XCTAssertFalse(anchor.matches(changed)); XCTAssertEqual(discussion.drafts[id]?.text, "keep body")
    XCTAssertFalse(window.isVisible)
  }
  func testHiddenNativeGuttersClickDragShiftKeyboardAccessibilityAndLifecycle() throws {
    let selection = PullRequestCodeSelection()
    let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 250, height: 160), styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; defer { window.close() }
    let content = NSView(frame: .init(x: 0, y: 0, width: 250, height: 160)); window.contentView = content
    var results: [GitHubPRCommentPosition] = []
    let cells = (8...10).map { line in
      let view = PullRequestCodeGutterView(frame: .init(x: 0, y: (10 - line) * 30, width: 46, height: 24))
      view.point = .init(side: .right, line: line, row: line); view.path = "a.swift"; view.selection = selection; view.enabled = true
      view.commit = { results.append($0) }; content.addSubview(view); selection.register(view); return view
    }
    func mouse(_ type: NSEvent.EventType, _ cell: NSView, flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
      try XCTUnwrap(NSEvent.mouseEvent(with: type, location: cell.convert(.init(x: 20, y: 12), to: nil), modifierFlags: flags,
        timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    }
    func key(_ code: UInt16, shift: Bool = false) throws -> NSEvent {
      try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: shift ? .shift : [], timestamp: 0,
        windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code))
    }
    cells[0].mouseDown(with: try mouse(.leftMouseDown, cells[0])); cells[0].mouseUp(with: try mouse(.leftMouseUp, cells[0]))
    XCTAssertEqual(results.last?.line, 8); XCTAssertNil(results.last?.startLine)
    cells[0].mouseDown(with: try mouse(.leftMouseDown, cells[0])); cells[0].mouseDragged(with: try mouse(.leftMouseDragged, cells[2])); cells[0].mouseUp(with: try mouse(.leftMouseUp, cells[2]))
    XCTAssertEqual(results.last?.startLine, 8); XCTAssertEqual(results.last?.line, 10)
    selection.clear(); window.makeFirstResponder(cells[0]); cells[0].keyDown(with: try key(125, shift: true))
    cells[1].keyDown(with: try key(125, shift: true)); cells[2].keyDown(with: try key(36))
    XCTAssertEqual(results.last?.startLine, 8); XCTAssertEqual(results.last?.line, 10)
    cells[2].keyDown(with: try key(53)); XCTAssertNil(selection.first)
    XCTAssertTrue(cells[1].accessibilityPerformPress()); XCTAssertEqual(results.last?.line, 9)
    cells[2].mouseDown(with: try mouse(.leftMouseDown, cells[2], flags: .shift)); cells[2].mouseUp(with: try mouse(.leftMouseUp, cells[2]))
    XCTAssertEqual(results.last?.startLine, 9); XCTAssertEqual(results.last?.line, 10)
    let left = PullRequestCodeGutterView(frame: .init(x: 70, y: 30, width: 46, height: 24))
    left.point = .init(side: .left, line: 9, row: 9); left.path = "a.swift"; left.selection = selection; left.enabled = true
    left.commit = { results.append($0) }; content.addSubview(left); selection.register(left)
    selection.clear(); cells[1].keyDown(with: try key(123, shift: true)); left.keyDown(with: try key(36))
    XCTAssertEqual(results.last?.startLine, 9); XCTAssertEqual(results.last?.startSide, .right); XCTAssertEqual(results.last?.side, .left)
    selection.clear(); left.mouseDown(with: try mouse(.leftMouseDown, left))
    left.mouseDragged(with: try mouse(.leftMouseDragged, cells[2])); left.mouseUp(with: try mouse(.leftMouseUp, cells[2]))
    XCTAssertEqual(results.last?.startLine, 9); XCTAssertEqual(results.last?.startSide, .left); XCTAssertEqual(results.last?.side, .right)
    selection.unregister(left)
    selection.unregister(cells[2]); XCTAssertEqual(selection.liveCells.count, 2)
    cells[1].enabled = false; XCTAssertFalse(cells[1].accessibilityPerformPress()); XCTAssertEqual(selection.liveCells.count, 1)
    XCTAssertFalse(window.isVisible)
  }
}
