import XCTest
@testable import ShipiOS

final class GitHubPRMergeTests: XCTestCase {
  private let request = GitHubPullRequest(number: 42,
    url: "https://github.com/sample/project/pull/42", title: "Feature",
    isDraft: false, headRefName: "feature/topic", baseRefName: "main", isCrossRepository: false)

  private func fixture() async throws -> (URL, GitHubPRService) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    for args in [["init", "-q", "-b", "feature/topic"], ["config", "user.name", "Fixture"],
      ["config", "user.email", "fixture@example.invalid"]] {
      _ = try await GitReviewService.checked(args, at: root)
    }
    try Data("unchanged\n".utf8).write(to: root.appendingPathComponent("file.txt"))
    _ = try await GitReviewService.checked(["add", "file.txt"], at: root)
    _ = try await GitReviewService.checked(["commit", "-qm", "fixture"], at: root)
    let head = try await GitReviewService.checked(["rev-parse", "HEAD"], at: root).trimmingCharacters(in: .whitespacesAndNewlines)
    let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Fixtures/github_cli.py")
    let executable = root.appendingPathComponent(".git/gh-fixture")
    try FileManager.default.copyItem(at: source, to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    let item = try JSONSerialization.jsonObject(with: JSONEncoder().encode(request))
    try save(["head": head, "base": head, "pullRequests": [item], "mergeable": "MERGEABLE"], at: root)
    return (root, GitHubPRService(executable: executable))
  }
  private func read(_ root: URL) throws -> [String: Any] {
    try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent(".git/github-fixture.json"))) as? [String: Any])
  }
  private func save(_ state: [String: Any], at root: URL) throws {
    try JSONSerialization.data(withJSONObject: state).write(to: root.appendingPathComponent(".git/github-fixture.json"))
  }
  private func change(_ root: URL, _ fields: [String: Any]) throws {
    var state = try read(root); fields.forEach { state[$0.key] = $0.value }; try save(state, at: root)
  }
  private func mutations(_ root: URL) throws -> [[String]] {
    let file = root.appendingPathComponent(".git/github-requests.jsonl")
    guard FileManager.default.fileExists(atPath: file.path) else { return [] }
    return try String(contentsOf: file, encoding: .utf8).split(separator: "\n").compactMap {
      let entry = try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
      let args = entry?["args"] as? [String]
      return args?.prefix(2) == ["pr", "merge"] ? args : nil
    }
  }
  private func failure(_ body: () async throws -> Void) async -> Error? {
    do { try await body(); XCTFail("Expected failure"); return nil } catch { return error }
  }

  @MainActor func testPreferenceMigrationPersistenceAndSearch() throws {
    XCTAssertEqual(try JSONDecoder().decode(GitPreferences.self, from: Data("{}".utf8)).pullRequestMergeMethod, .merge)
    XCTAssertEqual(try JSONDecoder().decode(GitPreferences.self,
      from: Data("{\"pullRequestMergeMethod\":\"future-method\"}".utf8)).pullRequestMergeMethod, .merge)
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root)
    store.libraryLoaded = true
    var preferences = store.library.gitPreferences; preferences.pullRequestMergeMethod = .squash
    XCTAssertTrue(store.saveGitPreferences(preferences))
    XCTAssertEqual(try WorkspaceLibrary.load(from: root.appendingPathComponent("workspace.json")).gitPreferences.pullRequestMergeMethod, .squash)
    XCTAssertTrue(SettingsSearch.results(for: "squash").contains { $0.field == .pullRequestMergeMethod && $0.page == .git })
  }

  func testSnapshotValidatesMetadataAndFiltersRepositoryMethods() async throws {
    let (root, service) = try await fixture()
    let snapshot = try await service.mergeSnapshot(for: request, at: root)
    XCTAssertTrue(snapshot.isAuthor); XCTAssertNil(snapshot.mergeDisabledReason)
    XCTAssertEqual(snapshot.allowedMethods, [.merge, .squash])
    try change(root, ["allowMerge": false, "viewer": "other"])
    let changed = try await service.mergeSnapshot(for: request, at: root)
    XCTAssertFalse(changed.showsActions); XCTAssertEqual(changed.allowedMethods, [.squash])
    XCTAssertEqual(changed.method(preferred: .merge), .squash)
    for fields: [String: Any] in [["metadataHead": String(repeating: "1", count: 40)],
      ["metadataHead": try read(root)["head"]!, "metadataRepository": "other/project"],
      ["metadataRepository": "sample/project", "graphqlError": true]] {
      try change(root, fields)
      _ = await failure { _ = try await service.mergeSnapshot(for: self.request, at: root) }
    }
    XCTAssertTrue(try mutations(root).isEmpty)
  }

  func testMergeUsesDisplayedHeadAndLeavesLocalGitUntouched() async throws {
    for method in GitHubPRMergeMethod.allCases {
      let (root, service) = try await fixture()
      let expected = try await service.mergeSnapshot(for: request, at: root)
      let result = try await service.apply(.merge(method), to: expected, request: request, at: root)
      XCTAssertEqual(result.snapshot.details.state, "MERGED"); XCTAssertNil(result.notice)
      let args = try XCTUnwrap(mutations(root).first)
      XCTAssertEqual(args, ["pr", "merge", "42", "--repo", "sample/project", method.cliFlag, "--match-head-commit", expected.headRevision!])
      let head = try await GitReviewService.checked(["rev-parse", "HEAD"], at: root).trimmingCharacters(in: .whitespacesAndNewlines)
      XCTAssertEqual(head, expected.headRevision)
      let branch = try await GitReviewService.checked(["branch", "--show-current"], at: root).trimmingCharacters(in: .whitespacesAndNewlines)
      XCTAssertEqual(branch, "feature/topic")
      let status = try await GitReviewService.checked(["status", "--porcelain"], at: root)
      XCTAssertTrue(status.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
  }

  func testPreflightRejectsChangedHeadAndBaseWithoutMutation() async throws {
    for head in [true, false] {
      let (root, service) = try await fixture()
      let expected = try await service.mergeSnapshot(for: request, at: root)
      if head { try change(root, ["detailHead": String(repeating: "1", count: 40)]) }
      else {
        var state = try read(root), item = try XCTUnwrap((state["pullRequests"] as? [[String: Any]])?.first)
        item["baseRefName"] = "release"; state["pullRequests"] = [item]; try save(state, at: root)
      }
      let error = await failure { _ = try await service.apply(.merge(.merge), to: expected, request: self.request, at: root) }
      XCTAssertTrue(error is GitHubPRMergeFailure); XCTAssertTrue(try mutations(root).isEmpty)
    }
  }

  func testChangedHeadBetweenPreflightAndServerIsRejectedAndRefreshed() async throws {
    let (root, service) = try await fixture()
    let expected = try await service.mergeSnapshot(for: request, at: root)
    try change(root, ["raceHead": String(repeating: "2", count: 40)])
    let error = await failure { _ = try await service.apply(.merge(.squash), to: expected, request: self.request, at: root) }
    let failure = try XCTUnwrap(error as? GitHubPRMergeFailure)
    XCTAssertEqual(failure.snapshot?.headRevision, String(repeating: "2", count: 40))
    XCTAssertEqual(failure.snapshot?.details.state, "OPEN"); XCTAssertEqual(try mutations(root).count, 1)
  }

  func testMergeEligibilityIsRecheckedImmediatelyBeforeWriting() async throws {
    let cases: [[String: Any]] = [
      ["detailState": "CLOSED"], ["mergeable": "CONFLICTING"], ["mergeable": "UNKNOWN"],
      ["mergeStateStatus": "BLOCKED"], ["mergeStateStatus": "BEHIND"], ["viewer": "other"],
      ["allowMerge": false], ["statusCheckRollup": [["name": "CI", "status": "IN_PROGRESS"]]],
      ["statusCheckRollup": [["name": "CI", "conclusion": "FAILURE"]]],
    ]
    for fields in cases {
      let (root, service) = try await fixture()
      let expected = try await service.mergeSnapshot(for: request, at: root)
      try change(root, fields)
      _ = await failure { _ = try await service.apply(.merge(.merge), to: expected, request: self.request, at: root) }
      XCTAssertTrue(try mutations(root).isEmpty, "Fields: \(fields)")
    }
  }

  func testDraftAndMissingRevisionCannotMerge() async throws {
    let (root, service) = try await fixture()
    var state = try read(root), item = try XCTUnwrap((state["pullRequests"] as? [[String: Any]])?.first)
    item["isDraft"] = true; state["pullRequests"] = [item]; try save(state, at: root)
    let draft = try await service.mergeSnapshot(for: request, at: root)
    XCTAssertNotNil(draft.mergeDisabledReason); XCTAssertNotNil(draft.autoMergeDisabledReason)
    item["isDraft"] = false; state["pullRequests"] = [item]; state["detailHead"] = "invalid"
    try save(state, at: root)
    let invalid = try await service.mergeSnapshot(for: request, at: root)
    XCTAssertNil(invalid.headRevision); XCTAssertNotNil(invalid.mergeDisabledReason)
    _ = await failure { _ = try await service.apply(.merge(.merge), to: invalid, request: self.request, at: root) }
    XCTAssertTrue(try mutations(root).isEmpty)
  }

  func testAutoMergeCanWaitForChecksAndCanBeDisabledInDraft() async throws {
    let (root, service) = try await fixture()
    try change(root, ["statusCheckRollup": [["name": "CI", "status": "IN_PROGRESS"]]])
    let expected = try await service.mergeSnapshot(for: request, at: root)
    XCTAssertNotNil(expected.mergeDisabledReason); XCTAssertNil(expected.autoMergeDisabledReason)
    let enabled = try await service.apply(.autoMerge(enabled: true, method: .squash), to: expected, request: request, at: root)
    XCTAssertTrue(enabled.snapshot.isAutoMergeEnabled)
    XCTAssertTrue(try mutations(root)[0].contains("--auto"))
    var state = try read(root), item = try XCTUnwrap((state["pullRequests"] as? [[String: Any]])?.first)
    item["isDraft"] = true; state["pullRequests"] = [item]; try save(state, at: root)
    let draft = try await service.mergeSnapshot(for: request, at: root)
    XCTAssertNil(draft.autoMergeDisabledReason)
    let disabled = try await service.apply(.autoMerge(enabled: false, method: .merge), to: draft, request: request, at: root)
    XCTAssertFalse(disabled.snapshot.isAutoMergeEnabled)
    XCTAssertEqual(try mutations(root)[1], ["pr", "merge", "42", "--repo", "sample/project", "--disable-auto"])
  }

  func testAcceptedRequestWithLostResponseRecoversWithoutDuplicateMerge() async throws {
    let (root, service) = try await fixture()
    let expected = try await service.mergeSnapshot(for: request, at: root)
    try change(root, ["failAfterAction": true])
    let result = try await service.apply(.merge(.squash), to: expected, request: request, at: root)
    XCTAssertEqual(result.snapshot.details.state, "MERGED")
    _ = try await service.apply(.merge(.squash), to: expected, request: request, at: root)
    XCTAssertEqual(try mutations(root).count, 1)
  }

  func testQueuedRequestIsNotReportedAsMerged() async throws {
    let (root, service) = try await fixture()
    let expected = try await service.mergeSnapshot(for: request, at: root)
    try change(root, ["mergeQueue": true])
    let result = try await service.apply(.merge(.merge), to: expected, request: request, at: root)
    XCTAssertEqual(result.snapshot.details.state, "OPEN"); XCTAssertNotNil(result.notice)
  }

  func testFailedMergeRefreshesActualStateAndCanRetryExplicitly() async throws {
    let (root, service) = try await fixture()
    let expected = try await service.mergeSnapshot(for: request, at: root)
    try change(root, ["mutationFailure": true])
    let error = await failure { _ = try await service.apply(.merge(.merge), to: expected, request: self.request, at: root) }
    XCTAssertEqual((error as? GitHubPRMergeFailure)?.snapshot?.details.state, "OPEN")
    try change(root, ["mutationFailure": false])
    let result = try await service.apply(.merge(.merge), to: expected, request: request, at: root)
    XCTAssertEqual(result.snapshot.details.state, "MERGED"); XCTAssertEqual(try mutations(root).count, 2)
  }

  func testUnavailableConfirmationDoesNotInventSuccessAndRetryRechecks() async throws {
    let (root, service) = try await fixture()
    let expected = try await service.mergeSnapshot(for: request, at: root)
    try change(root, ["detailFailureAfterAction": true])
    let error = await failure { _ = try await service.apply(.merge(.squash), to: expected, request: self.request, at: root) }
    XCTAssertNil((error as? GitHubPRMergeFailure)?.snapshot)
    try change(root, ["detailFailureAfterAction": false])
    let result = try await service.apply(.merge(.squash), to: expected, request: request, at: root)
    XCTAssertEqual(result.snapshot.details.state, "MERGED"); XCTAssertEqual(try mutations(root).count, 1)
  }

  @MainActor func testAuthorizationChangeDuringPreflightPreventsMutation() async throws {
    let (root, service) = try await fixture()
    let expected = try await service.mergeSnapshot(for: request, at: root)
    var authorizations = 0
    _ = await failure {
      _ = try await service.apply(.merge(.merge), to: expected, request: self.request, at: root) {
        authorizations += 1
        if authorizations == 2 { throw CancellationError() }
      }
    }
    XCTAssertEqual(authorizations, 2); XCTAssertTrue(try mutations(root).isEmpty)
  }

  @MainActor func testFailureKeepsConfirmationAndRestrictionFallsBackOnlyAfterSuccess() async throws {
    let (root, service) = try await fixture()
    let state = GitHubPRDetailState(service: service, coordinator: GitHubPRActionCoordinator())
    var records: [GitHubPullRequest] = [], saves = 0
    await state.refresh(request, at: root, preferred: .merge, valid: { true }, updated: { records.append($0) })
    state.openConfirmation(for: request, writable: true)
    try change(root, ["mergeRestriction": true])
    XCTAssertTrue(state.start(.merge(.merge), request: request, at: root, valid: { true }, writable: { true }, updated: { records.append($0) }, saveFallback: { saves += 1; return true }))
    await state.operation?.value
    XCTAssertTrue(state.showingMergeConfirmation); XCTAssertNotNil(state.error)
    XCTAssertTrue(state.fallbackToSquash); XCTAssertEqual(state.selectedMethod, .squash); XCTAssertEqual(saves, 0)
    XCTAssertTrue(state.start(.merge(.squash), request: request, at: root, valid: { true }, writable: { true }, updated: { records.append($0) }, saveFallback: { saves += 1; return true }))
    await state.operation?.value
    XCTAssertEqual(records.last?.state, "MERGED"); XCTAssertFalse(state.showingMergeConfirmation)
    XCTAssertNil(state.error); XCTAssertEqual(saves, 1)
    state.cancel()
    XCTAssertFalse(state.fallbackToSquash); XCTAssertEqual(state.selectedMethod, .merge)
  }

  @MainActor func testAcrossWindowsOnlyOneActionStartsAndCancellationDiscardsLateResult() async throws {
    let (root, service) = try await fixture()
    let coordinator = GitHubPRActionCoordinator()
    let first = GitHubPRDetailState(service: service, coordinator: coordinator)
    let second = GitHubPRDetailState(service: service, coordinator: coordinator)
    for state in [first, second] {
      await state.refresh(request, at: root, preferred: .merge, valid: { true }, updated: { _ in })
    }
    try change(root, ["mutationDelay": 0.2])
    var updated = 0
    XCTAssertTrue(first.start(.merge(.merge), request: request, at: root, valid: { true }, writable: { true }, updated: { _ in updated += 1 }))
    let operation = first.operation
    XCTAssertTrue(second.busy(for: request))
    XCTAssertFalse(second.start(.merge(.merge), request: request, at: root, valid: { true }, writable: { true }, updated: { _ in XCTFail("Other window updated") }))
    // Cancel after the fixture process has accepted the command, rather than before the task starts.
    let deadline = Date().addingTimeInterval(5)
    while try mutations(root).isEmpty && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
    XCTAssertEqual(try mutations(root).count, 1)
    first.cancel()
    await operation?.value
    XCTAssertNil(first.snapshot); XCTAssertNil(first.error); XCTAssertEqual(updated, 0)
    XCTAssertFalse(second.busy(for: request))
    XCTAssertEqual(try read(root)["detailState"] as? String, "MERGED")
  }

  @MainActor func testReadonlyAndDeletedOwnerDisableActionAndStaleRefreshCannotApply() async throws {
    let (root, service) = try await fixture()
    let state = GitHubPRDetailState(service: service, coordinator: GitHubPRActionCoordinator())
    await state.refresh(request, at: root, preferred: .merge, valid: { true }, updated: { _ in })
    XCTAssertFalse(state.start(.merge(.merge), request: request, at: root, valid: { true }, writable: { false }, updated: { _ in XCTFail() }))
    XCTAssertFalse(state.start(.merge(.merge), request: request, at: root, valid: { false }, writable: { true }, updated: { _ in XCTFail() }))
    var checks = 0
    await state.refresh(request, at: root, preferred: .merge, valid: { checks += 1; return checks == 1 }, updated: { _ in XCTFail("Stale owner saved") })
    XCTAssertNil(state.snapshot); XCTAssertFalse(state.loading)
    XCTAssertTrue(try mutations(root).isEmpty)
  }
}
