import XCTest
@testable import ShipiOS

@MainActor final class GitHubPRChecksTests: XCTestCase {
  private let head = String(repeating: "1", count: 40)
  private let pullRequest = GitHubPullRequest(number: 42, url: "https://github.com/sample/project/pull/42",
    title: "Feature", isDraft: false, headRefName: "feature", baseRefName: "main", isCrossRepository: false, state: "OPEN")

  private func fixture() throws -> (GitHubPRChecksRequest, GitHubPRService) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("checks-\(UUID())")
    try FileManager.default.createDirectory(at: root.appendingPathComponent(".git"), withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Fixtures/github_cli.py")
    let executable = root.appendingPathComponent(".git/gh-fixture")
    try FileManager.default.copyItem(at: file, to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    let record = try JSONSerialization.jsonObject(with: JSONEncoder().encode(pullRequest))
    try JSONSerialization.data(withJSONObject: ["head": head, "base": head, "pullRequests": [record]])
      .write(to: root.appendingPathComponent(".git/github-fixture.json"))
    return (.init(taskID: "owner", root: root, pullRequest: pullRequest, headRevision: head), .init(executable: executable))
  }
  private func change(_ root: URL, _ fields: [String: Any]) throws {
    let file = root.appendingPathComponent(".git/github-fixture.json")
    var state = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
    fields.forEach { state[$0.key] = $0.value }
    try JSONSerialization.data(withJSONObject: state).write(to: file)
  }
  private func run(_ id: Int, name: String? = nil, status: String = "completed", conclusion: String? = "success",
    sha: String? = nil, link: String? = nil) -> [String: Any] {
    ["id": id, "name": name ?? "check \(id)", "status": status, "conclusion": conclusion as Any? ?? NSNull(),
      "head_sha": sha ?? head, "details_url": link as Any? ?? NSNull(), "html_url": NSNull()]
  }
  private func runPages(_ rows: [[String: Any]], total: Int? = nil) -> [[String: Any]] {
    [["total_count": total ?? rows.count, "check_runs": rows]]
  }
  private func statusPages(_ rows: [[String: Any]], total: Int? = nil, sha: String? = nil) -> [[String: Any]] {
    [["sha": sha ?? head, "state": rows.contains { ["failure", "error"].contains($0["state"] as? String ?? "") } ? "failure" : rows.contains { $0["state"] as? String == "pending" } ? "pending" : "success", "total_count": total ?? rows.count, "statuses": rows]]
  }
  private func failure(_ body: () async throws -> Void) async -> Error? {
    do { try await body(); XCTFail("Expected failure"); return nil } catch { return error }
  }
  private func requests(_ root: URL) throws -> [[String]] {
    let file = root.appendingPathComponent(".git/github-requests.jsonl")
    guard FileManager.default.fileExists(atPath: file.path) else { return [] }
    return try String(contentsOf: file, encoding: .utf8).split(separator: "\n").map {
      let item = try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
      return try XCTUnwrap(item["args"] as? [String])
    }
  }

  func testCheckRunAndLegacyStatusesUseSixStatusesAndStableCodexOrder() async throws {
    let (request, service) = try fixture()
    let rows = [run(1), run(2, status: "in_progress", conclusion: nil), run(3, conclusion: "failure"),
      run(4, conclusion: "neutral"), run(5, conclusion: "skipped"), run(6, conclusion: "future_result"),
      run(7, conclusion: "error")]
    try change(request.root, ["checkRunsPages": runPages(rows), "commitStatusesPages": statusPages([
      ["context": "Legacy CI", "state": "success", "target_url": "https://ci.example.invalid/job/123", "description": "Built"],
      ["context": "Legacy errors", "state": "error"]])])
    let result = try await service.checks(request)
    XCTAssertTrue(result.complete); XCTAssertEqual(result.headRevision, head); XCTAssertEqual(result.pullRequestState, "OPEN")
    XCTAssertEqual(result.sortedChecks.map(\.status), [.failing, .failing, .failing, .pending, .neutral, .skipped, .unknown, .passing, .passing])
    XCTAssertEqual(result.sortedChecks.prefix(3).map(\.name), ["Legacy errors", "check 3", "check 7"])
    XCTAssertEqual(result.checks.last?.status, .failing); XCTAssertEqual(result.statusLabel, "检查失败")
    XCTAssertEqual(result.checks.first(where: { $0.name == "Legacy CI" })?.validatedLink?.host, "ci.example.invalid")
    let calls = try requests(request.root), api = calls.filter { $0.first == "api" }
    XCTAssertEqual(api.count, 3); XCTAssertEqual(calls.filter { $0.prefix(2) == ["pr", "view"] }.count, 2)
    XCTAssertTrue(api.allSatisfy { $0.contains("GET") && $0.contains("github.com") })
    XCTAssertTrue(api.allSatisfy { $0.contains(where: { $0.hasPrefix("repos/sample/project/commits/" + head) }) })
    XCTAssertFalse(calls.contains { $0.prefix(2) == ["pr", "merge"] })
  }

  func testAllPagesAndDuplicateIdentitiesDoNotLoseDistinctSameNameRuns() async throws {
    let (request, service) = try fixture()
    let rows = (1...125).map { run($0, name: "Same name") }
    try change(request.root, ["checkRunsPages": [
      ["total_count": 125, "check_runs": Array(rows.prefix(100))],
      ["total_count": 125, "check_runs": Array(rows.suffix(25))]],
      "commitStatusesPages": [
        ["sha": head, "state": "success", "total_count": 1, "statuses": [["context": "CI", "state": "success"]]],
        ["sha": head, "state": "success", "total_count": 1, "statuses": [["context": "ci", "state": "failure"]]]]])
    let result = try await service.checks(request)
    XCTAssertTrue(result.complete); XCTAssertEqual(result.checks.count, 126)
    XCTAssertEqual(Set(result.checks.map(\.id)).count, 126)
    XCTAssertEqual(result.checks.last?.status, .passing)
  }

  func testNoChecksIsDistinctFromMissingPagesPartialAndUnavailableSections() async throws {
    let (request, service) = try fixture()
    let empty = try await service.checks(request)
    XCTAssertTrue(empty.complete); XCTAssertTrue(empty.checks.isEmpty); XCTAssertEqual(empty.statusLabel, "没有 CI 检查")
    try change(request.root, ["checkRunsFailure": true])
    let partial = try await service.checks(request)
    XCTAssertFalse(partial.complete); XCTAssertTrue(partial.checks.isEmpty); XCTAssertNotNil(partial.notice)
    XCTAssertEqual(partial.statusLabel, "检查进行中")
    try change(request.root, ["commitStatusesFailure": true])
    let failure1 = await failure { _ = try await service.checks(request) }
    XCTAssertNotNil(failure1)
  }

  func testDuplicateChangingTotalAndLaterFailureRetainPrefixAsPartial() async throws {
    let rows = (1...100).map { run($0) }
    for second: [String: Any] in [
      ["total_count": 101, "check_runs": [rows[99], run(101)]],
      ["total_count": 102, "check_runs": [run(101)]]] {
      let (request, service) = try fixture()
      try change(request.root, ["checkRunsPages": [["total_count": 101, "check_runs": rows], second]])
      let result = try await service.checks(request)
      XCTAssertFalse(result.complete); XCTAssertEqual(result.checks.count, 101)
      XCTAssertTrue(result.hasPendingChecks); XCTAssertEqual(result.refreshSeconds, 15)
    }
    let (request, service) = try fixture()
    try change(request.root, ["checkRunsPages": [["total_count": 101, "check_runs": rows]], "checkRunsFailurePage": 2])
    let result = try await service.checks(request)
    XCTAssertFalse(result.complete); XCTAssertEqual(result.checks.count, 100)
  }

  func testSuiteLimitMissingOrWrongHeadNeverClaimsCompleteChecks() async throws {
    for suites: Any in [
      ["total_count": 1001, "check_suites": [["head_sha": head]]],
      ["total_count": 1, "check_suites": []],
      ["total_count": 1, "check_suites": [["head_sha": String(repeating: "2", count: 40)]]], "bad json"] {
      let (request, service) = try fixture(); try change(request.root, ["checkSuites": suites])
      let result = try await service.checks(request)
      XCTAssertFalse(result.complete); XCTAssertNotNil(result.notice); XCTAssertEqual(result.statusLabel, "检查进行中")
    }
  }

  func testTwentyPageLimitDoesNotFetchBeyondReferenceBound() async throws {
    let (request, service) = try fixture()
    let pages = (0..<21).map { page in
      ["total_count": 2100, "check_runs": (1...100).map { run(page * 100 + $0) }] as [String: Any]
    }
    try change(request.root, ["checkRunsPages": pages])
    let result = try await service.checks(request)
    XCTAssertFalse(result.complete); XCTAssertEqual(result.checks.count, 2000)
    let calls = try requests(request.root)
    XCTAssertEqual(calls.filter { $0.contains(where: { $0.contains("/check-runs?") }) }.count, 20)
    XCTAssertFalse(calls.contains { $0.contains(where: { $0.contains("page=21") }) })
  }

  func testCombinedPendingOrFailureAndUnknownRowsControlRefreshCadence() async throws {
    let (request, service) = try fixture()
    for overall in ["pending", "failure"] {
      var page = statusPages([["context": "CI", "state": "success"]])[0]; page["state"] = overall
      try change(request.root, ["commitStatusesPages": [page]])
      let result = try await service.checks(request)
      XCTAssertEqual(result.statusLabel, overall == "failure" ? "检查失败" : "检查进行中")
      XCTAssertEqual(result.refreshSeconds, overall == "pending" ? 15 : 60)
    }
    try change(request.root, ["commitStatusesPages": statusPages([]), "checkRunsPages": runPages([run(1, conclusion: "future")])])
    let unknown = try await service.checks(request)
    XCTAssertEqual(unknown.sortedChecks.first?.status, .unknown)
    XCTAssertEqual(unknown.statusLabel, "检查进行中"); XCTAssertEqual(unknown.refreshSeconds, 15)
  }

  func testClosedAndMergedPRsSkipCheckAPIsAndStopPeriodicReads() async throws {
    for closed in ["CLOSED", "MERGED"] {
      let (request, service) = try fixture(); try change(request.root, ["detailState": closed])
      let result = try await service.checks(request)
      XCTAssertTrue(result.complete); XCTAssertTrue(result.checks.isEmpty); XCTAssertNil(result.refreshSeconds)
      XCTAssertFalse(try requests(request.root).contains { $0.first == "api" })
    }
  }

  func testTruncatedPagesAndMalformedStreamKeepOnlyVerifiedOtherChecks() async throws {
    let (request, service) = try fixture()
    try change(request.root, ["checkRunsPages": runPages([run(1)], total: 2)])
    let truncated = try await service.checks(request)
    XCTAssertFalse(truncated.complete); XCTAssertEqual(truncated.checks.count, 1)
    try change(request.root, ["checkRunsPages": "bad json", "commitStatusesPages": statusPages([["context": "CI", "state": "pending"]])])
    let malformed = try await service.checks(request)
    XCTAssertFalse(malformed.complete); XCTAssertEqual(malformed.checks.map(\.name), ["CI"])
    XCTAssertEqual(malformed.statusLabel, "检查进行中")
  }

  func testInvalidHeadAndPRURLStopBeforeReadingGitHub() async throws {
    let (request, service) = try fixture()
    let invalid = GitHubPRChecksRequest(taskID: request.taskID, root: request.root, pullRequest: request.pullRequest, headRevision: "../../other")
    let failure2 = await failure { _ = try await service.checks(invalid) }
    XCTAssertNotNil(failure2)
    XCTAssertTrue(try requests(request.root).isEmpty)
    let badURL = GitHubPullRequest(number: 42, url: "https://example.invalid/pull/42", title: "Invalid",
      isDraft: false, headRefName: "feature", baseRefName: "main", isCrossRepository: false)
    let invalidURL = GitHubPRChecksRequest(taskID: request.taskID, root: request.root, pullRequest: badURL, headRevision: head)
    let urlFailure = await failure { _ = try await service.checks(invalidURL) }; XCTAssertNotNil(urlFailure)
    XCTAssertTrue(try requests(request.root).isEmpty)
    try change(request.root, ["detailHead": String(repeating: "2", count: 40)])
    let failure3 = await failure { _ = try await service.checks(request) }
    XCTAssertNotNil(failure3)
    XCTAssertFalse(try requests(request.root).contains { $0.first == "api" })
  }

  func testHeadAndBaseRaceRejectResultsAfterChecksRead() async throws {
    for fields: [String: Any] in [["headAfterChecks": String(repeating: "2", count: 40)], ["baseAfterChecks": "other-base"]] {
      let (request, service) = try fixture(); try change(request.root, fields)
      let error = await failure { _ = try await service.checks(request) }
      XCTAssertTrue(error is GitHubPRRefreshRequired)
    }
  }

  func testWrongRowCommitAndStatusSHAProducePartialInsteadOfMixedHeadData() async throws {
    let (request, service) = try fixture(), wrong = String(repeating: "2", count: 40)
    try change(request.root, ["checkRunsPages": runPages([run(1, sha: wrong)])])
    let partial = try await service.checks(request)
    XCTAssertFalse(partial.complete); XCTAssertTrue(partial.checks.isEmpty)
    try change(request.root, ["commitStatusesPages": statusPages([], sha: wrong)])
    let failure4 = await failure { _ = try await service.checks(request) }
    XCTAssertNotNil(failure4)
  }

  func testDetailsLinksCannotOpenExecutableSchemesOrEmbeddedCredentials() {
    for link in ["javascript:alert(1)", "file:///tmp/a", "data:text/html,a", "https://user:pass@example.invalid/job", "https:///job"] {
      XCTAssertNil(GitHubPRCheck(id: "a", name: "CI", status: .passing, link: link, description: nil).validatedLink)
    }
    for link in ["https://github.com/sample/project/actions/runs/1", "http://ci.example.invalid/job#log"] {
      XCTAssertEqual(GitHubPRCheck(id: "a", name: "CI", status: .passing, link: link, description: nil).validatedLink?.absoluteString, link)
    }
  }

  func testDetailsLinksFallBackToWebRunPageAndRefreshFlagClearsOnRetry() async throws {
    let (request, service) = try fixture()
    var check = run(1, link: "javascript:alert(1)")
    check["html_url"] = "https://github.com/sample/project/actions/runs/1"
    try change(request.root, ["checkRunsPages": runPages([check])])
    let result = try await service.checks(request)
    XCTAssertEqual(result.checks.first?.validatedLink?.absoluteString, "https://github.com/sample/project/actions/runs/1")
    let state = GitHubPRChecksState()
    await state.load(request, valid: { true }) { _ in throw GitHubPRRefreshRequired(message: "Changed") }
    XCTAssertTrue(state.requiresPullRequestRefresh)
    await state.load(request, valid: { true }) { _ in result }
    XCTAssertFalse(state.requiresPullRequestRefresh); XCTAssertEqual(state.snapshot, result)
  }

  func testKnownConclusionsPendingAndUnknownStatusesKeepTheirMeaning() {
    for value in ["FAILURE", "ERROR", "TIMED_OUT", "ACTION_REQUIRED", "CANCELLED", "STARTUP_FAILURE"] {
      XCTAssertEqual(GitHubPRCheckStatus.completed(value), .failing)
    }
    for value in ["queued", "in_progress", "waiting", "requested", "pending"] {
      XCTAssertEqual(GitHubPRCheckStatus.checkRun(status: value, conclusion: nil), .pending)
    }
    XCTAssertEqual(GitHubPRCheckStatus.checkRun(status: "completed", conclusion: nil), .unknown)
    XCTAssertEqual(GitHubPRCheckStatus.completed("future_value"), .unknown)
    XCTAssertEqual(GitHubPRCheckStatus.checkRun(status: "future_status", conclusion: "success"), .pending)
    XCTAssertEqual(GitHubPRCheckStatus.completed("successful"), .passing)
    XCTAssertEqual(GitHubPRCheckStatus.completed("expected"), .pending)
    XCTAssertEqual(GitHubPRCheckStatus.completed("neutral"), .neutral)
    XCTAssertEqual(GitHubPRCheckStatus.completed("skipped"), .skipped)
  }

  func testStateFailureRetryAndInvalidationKeepChecksIndependentOfPRMetadata() async throws {
    let (request, _) = try fixture(), state = GitHubPRChecksState()
    let result = GitHubPRChecksSnapshot(headRevision: head, checks: [], complete: true)
    await state.load(request, valid: { true }) { _ in result }; XCTAssertNotNil(state.snapshot)
    await state.load(request, valid: { true }) { _ in throw NSError(domain: "Fixture", code: 1) }
    XCTAssertNil(state.snapshot); XCTAssertNotNil(state.error); XCTAssertFalse(state.loading)
    await state.load(request, valid: { true }) { _ in result }; XCTAssertNil(state.error)
    var valid = true
    await state.load(request, valid: { valid }) { _ in valid = false; return result }
    XCTAssertNil(state.snapshot); XCTAssertFalse(state.loading)
    await state.load(nil, valid: { true }); XCTAssertNil(state.request); XCTAssertNil(state.error)
  }

  func testCancelledAndReplacedReadsIgnoreLateResultsAndErrors() async throws {
    let (request, _) = try fixture(), state = GitHubPRChecksState()
    var continuation: CheckedContinuation<GitHubPRChecksSnapshot, Error>?
    let result = GitHubPRChecksSnapshot(headRevision: head, checks: [], complete: true)
    let old = Task { await state.load(request, valid: { true }) { _ in
      try await withCheckedThrowingContinuation { continuation = $0 }
    } }
    for _ in 0..<1000 { if continuation != nil { break }; await Task.yield() }
    let captured = try XCTUnwrap(continuation); state.cancel(); captured.resume(returning: result); await old.value
    XCTAssertNil(state.snapshot); XCTAssertNil(state.request); XCTAssertFalse(state.loading)
    continuation = nil
    let late = Task { await state.load(request, valid: { true }) { _ in
      try await withCheckedThrowingContinuation { continuation = $0 }
    } }
    for _ in 0..<1000 { if continuation != nil { break }; await Task.yield() }
    let error = try XCTUnwrap(continuation)
    await state.load(request, valid: { true }) { _ in result }
    error.resume(throwing: NSError(domain: "Late", code: 1)); await late.value
    XCTAssertEqual(state.snapshot, result); XCTAssertNil(state.error)
  }

  func testStateRejectsSnapshotFromDifferentHead() async throws {
    let (request, _) = try fixture(), state = GitHubPRChecksState()
    await state.load(request, valid: { true }) { _ in
      .init(headRevision: String(repeating: "2", count: 40), checks: [], complete: true)
    }
    XCTAssertNil(state.snapshot); XCTAssertNotNil(state.error); XCTAssertTrue(state.requiresPullRequestRefresh)
    state.cancel(); XCTAssertFalse(state.requiresPullRequestRefresh)
  }
}
