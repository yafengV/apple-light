import AppKit
import SwiftUI
import XCTest
@testable import ShipiOS

@MainActor final class GitHubPRReviewerTests: XCTestCase {
  private let request = GitHubPullRequest(number: 42, url: "https://github.com/sample/project/pull/42",
    title: "Feature", isDraft: false, headRefName: "feature", baseRefName: "main", isCrossRepository: false)
  private func user(_ login: String) -> [String: Any] { ["__typename": "User", "login": login] }
  private func review(_ login: String, _ state: String) -> [String: Any] {
    ["id": "review-" + login, "state": state, "author": ["login": login]]
  }
  private func fixture(_ fields: [String: Any] = [:]) async throws -> (URL, GitHubPRService) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("pr-reviewers-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    _ = try await GitReviewService.checked(["init", "-q", "-b", "feature"], at: root)
    let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Fixtures/github_cli.py")
    let executable = root.appendingPathComponent(".git/gh-fixture")
    try FileManager.default.copyItem(at: source, to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    var state: [String: Any] = ["head": String(repeating: "a", count: 40), "viewer": "owner", "author": "owner",
      "pullRequests": [try JSONSerialization.jsonObject(with: JSONEncoder().encode(request))],
      "reviewerRequested": [user("alice"), ["__typename": "Team", "name": "Core Team", "slug": "core-team"]],
      "reviewerReviews": [review("bob", "APPROVED"), review("carol", "CHANGES_REQUESTED"), review("dave", "COMMENTED")],
      "reviewerCandidates": [["login": "alice"], ["login": "alex", "name": "Alexandra"], ["login": "owner"], ["login": "bert"]]]
    fields.forEach { state[$0.key] = $0.value }
    try JSONSerialization.data(withJSONObject: state).write(to: root.appendingPathComponent(".git/github-fixture.json"), options: .atomic)
    return (root, .init(executable: executable))
  }
  private func change(_ fields: [String: Any], at root: URL) throws {
    let file = root.appendingPathComponent(".git/github-fixture.json")
    var state = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
    fields.forEach { state[$0.key] = $0.value }
    try JSONSerialization.data(withJSONObject: state).write(to: file, options: .atomic)
  }
  private func logs(_ root: URL) throws -> [[String: Any]] {
    let file = root.appendingPathComponent(".git/github-requests.jsonl")
    guard FileManager.default.fileExists(atPath: file.path) else { return [] }
    return try String(contentsOf: file).split(separator: "\n").map {
      try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
    }
  }
  private func writes(_ root: URL) throws -> [[String: Any]] {
    try logs(root).filter { ($0["args"] as? [String])?.contains(where: { $0.hasSuffix("/requested_reviewers") }) == true }
  }

  func testPaginationCombinesTeamsRequestsAndLatestReviewStatuses() async throws {
    let (root, service) = try await fixture(["reviewerPageSize": 1,
      "reviewerReviews": [review("alice", "APPROVED"), review("bob", "APPROVED"), review("carol", "CHANGES_REQUESTED"), review("dave", "COMMENTED")]])
    let snapshot = try await service.reviewers(for: request, at: root)
    XCTAssertTrue(snapshot.canManage)
    XCTAssertEqual(snapshot.reviewers.map(\.label), ["alice", "Core Team", "bob", "carol", "dave"])
    XCTAssertEqual(snapshot.reviewers.map(\.status), [.approved, .waiting, .approved, .changesRequested, .waiting])
    XCTAssertEqual(snapshot.reviewers.filter(\.requested).count, 2)
    XCTAssertEqual(snapshot.reviewers[1].teamSlug, "core-team")
    XCTAssertEqual(try logs(root).count, 4)
  }

  func testChangedIdentityDuplicateAndDriftingPagesNeverReturnPartialLists() async throws {
    for extra: [String: Any] in [["reviewerMismatch": true], ["metadataRepository": "other/project"],
      ["reviewerGraphQLError": true], ["reviewerPageSize": 1, "reviewerDuplicatePage": true],
      ["reviewerPageSize": 1, "reviewerCountDrift": true], ["reviewerPageSize": 1, "reviewerRepeatCursor": true],
      ["reviewerPageSize": 1, "reviewerViewerAtRead": ["2": "another-user"]]] {
      let (root, service) = try await fixture(extra)
      do { _ = try await service.reviewers(for: request, at: root); XCTFail("Invalid list accepted: \(extra)") } catch { }
      XCTAssertTrue(try writes(root).isEmpty)
    }
  }

  func testBotAndMigratedReviewerRequestsDoNotHideTheWholeList() async throws {
    let (root, service) = try await fixture(["reviewerRequested": [
      ["__typename": "Bot", "login": "code-review[bot]"], ["__typename": "Mannequin", "login": "migrated-user"]]])
    let snapshot = try await service.reviewers(for: request, at: root)
    XCTAssertEqual(Array(snapshot.reviewers.prefix(2)).map(\.label), ["code-review[bot]", "migrated-user"])
    XCTAssertTrue(snapshot.reviewers[0].requested)
  }

  func testCollaboratorSearchSupportsNamesAndExcludesAuthorAndDuplicateUsers() async throws {
    let (root, service) = try await fixture(["reviewerCandidates": [["login": "alex", "name": "Alexandra"],
      ["login": "ALEX", "name": "Alexandra"], ["login": "owner", "name": "Alexandra"]]])
    let snapshot = try await service.reviewers(for: request, at: root)
    let users = try await service.reviewerCandidates(request: request, expected: snapshot, query: "Alexandra", at: root)
    XCTAssertEqual(users.map(\.login), ["alex"])
    try change(["viewer": "someone-else"], at: root)
    do { _ = try await service.reviewerCandidates(request: request, expected: snapshot, query: "Alexandra", at: root); XCTFail() } catch { }
  }

  func testRequestsAreDeduplicatedAndTeamRemovalUsesSlugWithPrivateJSONInput() async throws {
    let (root, service) = try await fixture()
    var current = try await service.reviewers(for: request, at: root)
    current = try await service.updateReviewers(.request(["alex", "ALEX", "alice", "bob"]), request: request, expected: current, at: root)
    XCTAssertTrue(current.reviewers.contains { $0.label == "alex" && $0.requested })
    let team = try XCTUnwrap(current.reviewers.first { $0.kind == .team })
    current = try await service.updateReviewers(.remove(team), request: request, expected: current, at: root)
    XCTAssertFalse(current.reviewers.contains { $0.kind == .team })
    let bob = try XCTUnwrap(current.reviewers.first { $0.label == "bob" })
    _ = try await service.updateReviewers(.remove(bob), request: request, expected: current, at: root)
    let writes = try writes(root)
    XCTAssertEqual(writes.count, 2)
    XCTAssertEqual((writes[0]["input"] as? [String: Any])?["reviewers"] as? [String], ["alex"])
    XCTAssertEqual((writes[1]["input"] as? [String: Any])?["team_reviewers"] as? [String], ["core-team"])
    for write in writes {
      XCTAssertEqual(write["inputMode"] as? String, "0o600"); XCTAssertEqual(write["folderMode"] as? String, "0o700")
      let args = try XCTUnwrap(write["args"] as? [String])
      let file = args[try XCTUnwrap(args.firstIndex(of: "--input")) + 1]
      XCTAssertFalse(FileManager.default.fileExists(atPath: file))
      XCTAssertFalse(args.contains("alex")); XCTAssertFalse(args.contains("core-team"))
    }
  }

  func testAccountClosedPRAndRevokedPermissionPreventRemoteWrites() async throws {
    for changes: [String: Any] in [["viewer": "someone-else"], ["detailState": "CLOSED"], ["detailState": "MERGED"]] {
      let (root, service) = try await fixture()
      let expected = try await service.reviewers(for: request, at: root)
      try change(changes, at: root)
      do { _ = try await service.updateReviewers(.request(["alex"]), request: request, expected: expected, at: root); XCTFail() } catch { }
      XCTAssertTrue(try writes(root).isEmpty)
    }
    let (root, service) = try await fixture()
    let snapshot = try await service.reviewers(for: request, at: root)
    var authorizations = 0
    do {
      _ = try await service.updateReviewers(.request(["alex"]), request: request, expected: snapshot, at: root) {
        authorizations += 1
        if authorizations == 2 { throw CancellationError() }
      }
      XCTFail()
    } catch is CancellationError { }
    XCTAssertEqual(authorizations, 2); XCTAssertTrue(try writes(root).isEmpty)
  }

  func testLostMutationResponseIsConfirmedByReadWithoutResendingRequest() async throws {
    let (root, service) = try await fixture(["reviewerLostResponse": true])
    let expected = try await service.reviewers(for: request, at: root)
    let result = try await service.updateReviewers(.request(["alex"]), request: request, expected: expected, at: root)
    XCTAssertTrue(result.reviewers.contains { $0.label == "alex" && $0.requested })
    _ = try await service.updateReviewers(.request(["alex"]), request: request, expected: result, at: root)
    XCTAssertEqual(try writes(root).count, 1)
  }

  func testReviewSubmittedBeforeRefreshStillConfirmsTheRequest() async throws {
    let (root, service) = try await fixture(["reviewerImmediateReview": true])
    let expected = try await service.reviewers(for: request, at: root)
    let result = try await service.updateReviewers(.request(["alex"]), request: request, expected: expected, at: root)
    let alex = try XCTUnwrap(result.reviewers.first { $0.label == "alex" })
    XCTAssertFalse(alex.requested); XCTAssertEqual(alex.status, .approved)
    XCTAssertEqual(try writes(root).count, 1)
  }

  func testUnconfirmedWriteBlocksNewMutationsUntilSuccessfulRefresh() async throws {
    let (root, service) = try await fixture(["reviewerReadFailureAfterAction": true])
    let state = GitHubPRReviewerState(service: service, coordinator: .init())
    await state.load(request, at: root, valid: { true })
    XCTAssertTrue(state.apply(.request(["alex"]), request: request, at: root, valid: { true }, writable: { true }, changed: {}))
    await state.operation?.value
    XCTAssertTrue(state.requiresRefresh); XCTAssertNotNil(state.error)
    XCTAssertFalse(state.canManage(request, writable: true))
    XCTAssertFalse(state.apply(.request(["alex"]), request: request, at: root, valid: { true }, writable: { true }, changed: {}))
    XCTAssertEqual(try writes(root).count, 1)
    try change(["reviewerReadFailureAfterAction": false], at: root)
    await state.load(request, at: root, valid: { true })
    XCTAssertFalse(state.requiresRefresh); XCTAssertNil(state.error)
    XCTAssertTrue(state.snapshot?.reviewers.contains { $0.label == "alex" && $0.requested } == true)
  }

  func testPickerStagingCancelAndSubmittedReviewsNeverMutateWithoutExplicitRequest() async throws {
    let (root, service) = try await fixture()
    let state = GitHubPRReviewerState(service: service, coordinator: .init(), debounce: .milliseconds(5))
    await state.load(request, at: root, valid: { true })
    XCTAssertFalse(state.canManage(request, writable: false))
    state.showingPicker = true
    let existing = try XCTUnwrap(state.options.first { $0.label == "bob" })
    state.toggle(existing); XCTAssertTrue(state.selected.isEmpty)
    state.setQuery("al", request: request, at: root, valid: { true }); await state.searchTask?.value
    let alex = try XCTUnwrap(state.options.first { $0.label == "alex" })
    state.toggle(alex); XCTAssertEqual(state.selected.map(\.login), ["alex"])
    state.toggle(alex); XCTAssertTrue(state.selected.isEmpty)
    state.toggle(alex); state.closePicker()
    XCTAssertTrue(state.selected.isEmpty); XCTAssertTrue(state.query.isEmpty); XCTAssertFalse(state.searching)
    XCTAssertTrue(try writes(root).isEmpty)
  }

  func testSearchDebounceDismissalAndErrorsDoNotPublishStaleCandidates() async throws {
    let (root, service) = try await fixture()
    let state = GitHubPRReviewerState(service: service, debounce: .milliseconds(30))
    await state.load(request, at: root, valid: { true }); state.showingPicker = true
    state.setQuery("al", request: request, at: root, valid: { true })
    state.setQuery("bert", request: request, at: root, valid: { true }); await state.searchTask?.value
    XCTAssertEqual(state.candidates.map(\.login), ["bert"])
    let queries = try logs(root).compactMap { (($0["input"] as? [String: Any])?["variables"] as? [String: Any])?["search"] as? String }
    XCTAssertEqual(queries, ["bert"])
    try change(["reviewerSearchDelay": 0.15], at: root)
    state.setQuery("al", request: request, at: root, valid: { true })
    let pending = state.searchTask
    try await Task.sleep(for: .milliseconds(60)); state.closePicker(); await pending?.value
    XCTAssertTrue(state.candidates.isEmpty); XCTAssertTrue(state.query.isEmpty)
    try change(["reviewerSearchDelay": 0, "reviewerSearchFailure": true], at: root)
    state.showingPicker = true; state.setQuery("al", request: request, at: root, valid: { true }); await state.searchTask?.value
    XCTAssertNotNil(state.searchError); XCTAssertTrue(state.options.isEmpty)
    try change(["reviewerSearchFailure": false], at: root)
    state.setQuery(state.query, request: request, at: root, valid: { true }); await state.searchTask?.value
    XCTAssertNil(state.searchError); XCTAssertTrue(state.candidates.contains { $0.login == "alex" })
  }

  func testSharedCoordinatorPreventsConcurrentReviewerAndOtherPRMutations() async throws {
    let (root, service) = try await fixture(), coordinator = GitHubPRActionCoordinator()
    let one = GitHubPRReviewerState(service: service, coordinator: coordinator)
    let two = GitHubPRReviewerState(service: service, coordinator: coordinator)
    await one.load(request, at: root, valid: { true }); await two.load(request, at: root, valid: { true })
    XCTAssertTrue(one.apply(.request(["alex"]), request: request, at: root, valid: { true }, writable: { true }, changed: {}))
    XCTAssertFalse(two.canManage(request, writable: true))
    XCTAssertFalse(two.apply(.request(["bert"]), request: request, at: root, valid: { true }, writable: { true }, changed: {}))
    await one.operation?.value
    XCTAssertTrue(two.canManage(request, writable: true)); XCTAssertEqual(try writes(root).count, 1)
  }

  func testNativePickerSearchEditingAndStagingAtPopoverWidth() async throws {
    let (root, service) = try await fixture()
    let state = GitHubPRReviewerState(service: service, debounce: .milliseconds(5))
    await state.load(request, at: root, valid: { true }); state.showingPicker = true
    let host = NSHostingView(rootView: PullRequestReviewerPicker(state: state, request: request, writable: true,
      search: { state.setQuery($0, request: self.request, at: root, valid: { true }) }, apply: { _ in XCTFail("No automatic write") })
      .frame(width: 312, height: 400).background(Color.white).environment(\.colorScheme, .light))
    let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 312, height: 400), styleMask: [.titled], backing: .buffered, defer: true)
    window.isReleasedWhenClosed = false; window.appearance = NSAppearance(named: .aqua); window.contentView = host
    defer { window.contentView = nil; window.close(); state.cancel() }
    try await Task.sleep(for: .milliseconds(500)); host.layoutSubtreeIfNeeded()
    func fields(_ view: NSView) -> [NSTextField] {
      ((view as? NSTextField).map { [$0] } ?? []) + view.subviews.flatMap(fields)
    }
    let field = try XCTUnwrap(fields(host).first { $0.isEditable })
    field.stringValue = "al"
    field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))
    try await Task.sleep(for: .milliseconds(80)); await state.searchTask?.value
    XCTAssertEqual(state.query, "al")
    let alex = try XCTUnwrap(state.options.first { $0.label == "alex" })
    state.toggle(alex); state.highlighted = alex.id
    try await Task.sleep(for: .milliseconds(100)); host.layoutSubtreeIfNeeded()
    XCTAssertEqual(state.selected.map(\.login), ["alex"])
    if let path = ProcessInfo.processInfo.environment["SHIPIOS_PR_REVIEWER_RENDER_PATH"] {
      let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
      host.cacheDisplay(in: host.bounds, to: bitmap)
      try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: path))
    }
    XCTAssertTrue(try writes(root).isEmpty)
  }
}
