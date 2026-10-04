import AppKit
import SwiftUI
import XCTest
@testable import ShipiOS

@MainActor final class GitHubPRStatusTests: XCTestCase {
  private let request = GitHubPullRequest(number: 42, url: "https://github.com/sample/project/pull/42",
    title: "Feature", isDraft: false, headRefName: "feature", baseRefName: "main", isCrossRepository: false)
  private func fixture(_ fields: [String: Any] = [:], draft: Bool = false) async throws -> (URL, GitHubPRService) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("pr-status-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    _ = try await GitReviewService.checked(["init", "-q", "-b", "feature"], at: root)
    let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Fixtures/github_cli.py")
    let executable = root.appendingPathComponent(".git/gh-fixture")
    try FileManager.default.copyItem(at: source, to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    var item = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
    item["isDraft"] = draft
    var state: [String: Any] = ["head": String(repeating: "a", count: 40), "viewer": "owner", "author": "owner",
      "pullRequests": [item]]
    fields.forEach { state[$0.key] = $0.value }
    try JSONSerialization.data(withJSONObject: state).write(to: root.appendingPathComponent(".git/github-fixture.json"))
    return (root, .init(executable: executable))
  }
  private func change(_ fields: [String: Any], at root: URL) throws {
    let file = root.appendingPathComponent(".git/github-fixture.json")
    var state = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
    fields.forEach { state[$0.key] = $0.value }
    try JSONSerialization.data(withJSONObject: state).write(to: file, options: .atomic)
  }
  private func writes(_ root: URL) throws -> [[String: Any]] {
    let file = root.appendingPathComponent(".git/github-requests.jsonl")
    guard FileManager.default.fileExists(atPath: file.path) else { return [] }
    return try String(contentsOf: file).split(separator: "\n").map {
      try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
    }.filter { (($0["input"] as? [String: Any])?["query"] as? String)?.contains("ShipiOSPRStatusMutation") == true }
  }
  private func failure(_ body: () async throws -> Void) async -> Error? {
    do { try await body(); XCTFail("Expected failure"); return nil } catch { return error }
  }
  private func loaded(_ service: GitHubPRService, root: URL, coordinator: GitHubPRActionCoordinator? = nil) async -> GitHubPRDetailState {
    let state = GitHubPRDetailState(service: service, coordinator: coordinator ?? .init())
    await state.refresh(request, at: root, preferred: .merge, valid: { true }, updated: { _ in })
    return state
  }

  func testMenuOrderCheckmarksAndClosedDraftRestriction() {
    for current in GitHubPRStatus.allCases {
      let options = TaskPullRequestStatusView.items(current: current, enabled: true).compactMap {
        if case .option(let option) = $0 { return option }; return nil
      }
      XCTAssertEqual(options.map(\.title), ["草稿", "可供审查", "已关闭"])
      XCTAssertEqual(options.filter(\.selected).map(\.value), current == .merged ? [] : [current])
      XCTAssertEqual(options.filter(\.enabled).map(\.value),
        current == .closed ? [.open] : current == .merged ? [] : current == .draft ? [.open, .closed] : [.draft, .closed])
    }
  }

  func testDraftReadyCloseTransitionsAndPrivateMutationInputs() async throws {
    for (initialDraft, desired): (Bool, GitHubPRStatus) in [(false, .draft), (true, .open), (false, .closed), (true, .closed)] {
      let (root, service) = try await fixture(draft: initialDraft)
      let expected = try await service.mergeSnapshot(for: request, at: root)
      XCTAssertEqual(expected.nodeID, "pr-node"); XCTAssertEqual(expected.viewer, "owner")
      let result = try await service.updateStatus(desired, expected: expected, request: request, at: root)
      XCTAssertEqual(GitHubPRStatus(result.details), desired)
      let logs = try writes(root); XCTAssertEqual(logs.count, 1)
      let log = try XCTUnwrap(logs.first), input = try XCTUnwrap(log["input"] as? [String: Any])
      let variables = try XCTUnwrap(input["variables"] as? [String: Any])
      XCTAssertEqual((variables["input"] as? [String: String])?["pullRequestId"], "pr-node")
      XCTAssertEqual(log["inputMode"] as? String, "0o600"); XCTAssertEqual(log["folderMode"] as? String, "0o700")
      let args = try XCTUnwrap(log["args"] as? [String])
      XCTAssertFalse(args.contains("pr-node")); XCTAssertEqual(args[1], "graphql")
      let path = args[try XCTUnwrap(args.firstIndex(of: "--input")) + 1]
      XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }
  }

  func testReopenDraftUsesTwoOrderedMutationsAndNormalReopenUsesOne() async throws {
    for draft in [true, false] {
      let (root, service) = try await fixture(["detailState": "CLOSED"], draft: draft)
      let expected = try await service.mergeSnapshot(for: request, at: root)
      let result = try await service.updateStatus(.open, expected: expected, request: request, at: root)
      XCTAssertEqual(GitHubPRStatus(result.details), .open); XCTAssertFalse(result.details.isDraft)
      let queries = try writes(root).compactMap { ($0["input"] as? [String: Any])?["query"] as? String }
      XCTAssertEqual(queries.count, draft ? 2 : 1)
      XCTAssertTrue(queries[0].contains("action:reopenPullRequest"))
      if draft { XCTAssertTrue(queries[1].contains("action:markPullRequestReadyForReview")) }
    }
  }

  func testClosedToDraftAndMergedRequestsNeverWrite() async throws {
    for value in ["CLOSED", "MERGED"] {
      let (root, service) = try await fixture(["detailState": value])
      let expected = try await service.mergeSnapshot(for: request, at: root)
      _ = await failure { _ = try await service.updateStatus(.draft, expected: expected, request: self.request, at: root) }
      XCTAssertTrue(try writes(root).isEmpty)
    }
  }

  func testChangedAccountAuthorNodeAndPRIdentityPreventWrites() async throws {
    for changes: [String: Any] in [["viewer": "another-user"], ["author": "another-author"],
      ["statusNode": "another-node"], ["metadataRepository": "other/project"], ["detailMismatch": true]] {
      let (root, service) = try await fixture()
      let expected = try await service.mergeSnapshot(for: request, at: root)
      try change(changes, at: root)
      _ = await failure { _ = try await service.updateStatus(.closed, expected: expected, request: self.request, at: root) }
      XCTAssertTrue(try writes(root).isEmpty)
    }
  }

  func testAlreadySelectedAndLostResponsesDoNotRepeatMutation() async throws {
    let (root, service) = try await fixture(["statusLostResponse": true])
    let expected = try await service.mergeSnapshot(for: request, at: root)
    let current = try await service.updateStatus(.draft, expected: expected, request: request, at: root)
    XCTAssertEqual(GitHubPRStatus(current.details), .draft)
    _ = try await service.updateStatus(.draft, expected: expected, request: request, at: root)
    XCTAssertEqual(try writes(root).count, 1)
    let (otherRoot, otherService) = try await fixture(["detailState": "CLOSED", "statusLostResponse": true], draft: true)
    let closed = try await otherService.mergeSnapshot(for: request, at: otherRoot)
    let ready = try await otherService.updateStatus(.open, expected: closed, request: request, at: otherRoot)
    XCTAssertEqual(GitHubPRStatus(ready.details), .open); XCTAssertEqual(try writes(otherRoot).count, 2)
  }

  func testRejectedSecondStepRecordsActualReopenedDraftAndError() async throws {
    let (root, service) = try await fixture(["detailState": "CLOSED", "statusRejected": ["markPullRequestReadyForReview"]], draft: true)
    let state = await loaded(service, root: root)
    var records: [GitHubPullRequest] = [], reported: [String] = [], changes = 0
    XCTAssertTrue(state.startStatus(.open, request: request, at: root, valid: { true }, writable: { true },
      updated: { records.append($0) }, changed: { changes += 1 }, reportError: { reported.append($0) }))
    await state.operation?.value
    XCTAssertEqual(GitHubPRStatus(try XCTUnwrap(state.snapshot).details), .draft)
    XCTAssertEqual(records.last?.state, "OPEN"); XCTAssertEqual(records.last?.isDraft, true)
    XCTAssertTrue(state.error?.contains("部分更新") == true); XCTAssertEqual(reported.count, 1); XCTAssertEqual(changes, 1)
    XCTAssertFalse(state.statusRequiresRefresh); XCTAssertNil(state.statusAction); XCTAssertEqual(try writes(root).count, 2)
  }

  func testUnconfirmedMutationBlocksStatusAndMergeUntilSuccessfulRefresh() async throws {
    let (root, service) = try await fixture(["statusReadFailureAfterAction": true])
    let state = await loaded(service, root: root)
    let displayed = try XCTUnwrap(state.snapshot)
    XCTAssertTrue(state.startStatus(.closed, request: request, at: root, valid: { true }, writable: { true }, updated: { _ in XCTFail() }))
    await state.operation?.value
    XCTAssertNil(state.snapshot); XCTAssertTrue(state.statusRequiresRefresh); XCTAssertNotNil(state.error)
    XCTAssertNotNil(state.metadataError)
    XCTAssertFalse(state.startStatus(.open, request: request, at: root, valid: { true }, writable: { true }, updated: { _ in XCTFail() }))
    XCTAssertNotNil(state.mergeDisabledReason(for: request, writable: true))
    XCTAssertNotNil(state.autoMergeDisabledReason(for: request, writable: true))
    state.acceptMetadata(displayed)
    XCTAssertTrue(state.statusRequiresRefresh, "An editor's old metadata cannot confirm a status write")
    XCTAssertNotNil(state.statusDisabledReason(for: request, writable: true))
    await state.refresh(request, at: root, preferred: .merge, valid: { true }, updated: { _ in XCTFail() })
    XCTAssertTrue(state.statusRequiresRefresh)
    try change(["statusReadFailureAfterAction": false], at: root)
    await state.refresh(request, at: root, preferred: .merge, valid: { true }, updated: { _ in })
    XCTAssertFalse(state.statusRequiresRefresh); XCTAssertNil(state.error)
    XCTAssertEqual(GitHubPRStatus(try XCTUnwrap(state.snapshot).details), .closed)
    XCTAssertEqual(try writes(root).count, 1)
  }

  func testRejectedAndUnchangedResultsNeverInventSelectedStatus() async throws {
    for fields: [String: Any] in [["statusRejected": ["closePullRequest"]], ["statusNoChange": true]] {
      let (root, service) = try await fixture(fields)
      let state = await loaded(service, root: root)
      XCTAssertTrue(state.startStatus(.closed, request: request, at: root, valid: { true }, writable: { true }, updated: { _ in }))
      await state.operation?.value
      XCTAssertEqual(GitHubPRStatus(try XCTUnwrap(state.snapshot).details), .open)
      XCTAssertNotNil(state.error); XCTAssertNil(state.metadataError)
      XCTAssertFalse(state.statusRequiresRefresh); XCTAssertEqual(try writes(root).count, 1)
    }
  }

  func testReadOnlyDeletedAndNonAuthorCannotStart() async throws {
    let (root, service) = try await fixture()
    let state = await loaded(service, root: root)
    for (valid, writable) in [(false, true), (true, false)] {
      XCTAssertFalse(state.startStatus(.draft, request: request, at: root, valid: { valid }, writable: { writable }, updated: { _ in XCTFail() }))
    }
    try change(["viewer": "another-user"], at: root)
    await state.refresh(request, at: root, preferred: .merge, valid: { true }, updated: { _ in })
    XCTAssertFalse(state.startStatus(.draft, request: request, at: root, valid: { true }, writable: { true }, updated: { _ in XCTFail() }))
    XCTAssertTrue(try writes(root).isEmpty)
  }

  func testAuthorizationIsRecheckedImmediatelyBeforeWritesAndBetweenSteps() async throws {
    for stopAt in [2, 3, 4] {
      let (root, service) = try await fixture(["detailState": "CLOSED"], draft: true)
      let expected = try await service.mergeSnapshot(for: request, at: root)
      var authorizations = 0
      let error = await failure {
        _ = try await service.updateStatus(.open, expected: expected, request: self.request, at: root) {
          authorizations += 1
          if authorizations == stopAt { throw CancellationError() }
        }
      }
      XCTAssertEqual(authorizations, stopAt); XCTAssertEqual(try writes(root).count, stopAt == 2 ? 0 : 1)
      if stopAt > 2 {
        XCTAssertEqual(GitHubPRStatus(try XCTUnwrap((error as? GitHubPRStatusFailure)?.snapshot).details), .draft)
      }
    }
  }

  func testAcrossWindowsStatusOwnsMergeCoordinatorAndLateCancellationDoesNotPublish() async throws {
    let (root, service) = try await fixture(["statusMutationDelay": 0.3])
    let coordinator = GitHubPRActionCoordinator()
    let one = await loaded(service, root: root, coordinator: coordinator)
    let two = await loaded(service, root: root, coordinator: coordinator)
    var updates = 0, changes = 0
    XCTAssertTrue(one.startStatus(.closed, request: request, at: root, valid: { true }, writable: { true },
      updated: { _ in updates += 1 }, changed: { changes += 1 }))
    let operation = one.operation
    XCTAssertTrue(two.busy(for: request))
    XCTAssertFalse(two.startStatus(.draft, request: request, at: root, valid: { true }, writable: { true }, updated: { _ in XCTFail() }))
    XCTAssertFalse(two.start(.merge(.merge), request: request, at: root, valid: { true }, writable: { true }, updated: { _ in XCTFail() }))
    let deadline = Date().addingTimeInterval(5)
    while try writes(root).isEmpty, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
    XCTAssertEqual(try writes(root).count, 1)
    one.cancel(); await operation?.value
    XCTAssertEqual(updates, 0); XCTAssertEqual(changes, 0); XCTAssertNil(one.snapshot); XCTAssertNil(one.error)
    XCTAssertFalse(two.busy(for: request))
    await two.refresh(request, at: root, preferred: .merge, valid: { true }, updated: { _ in })
    XCTAssertEqual(GitHubPRStatus(try XCTUnwrap(two.snapshot).details), .closed)
  }

  func testAccountChangesAfterReopenStopSecondMutationAndExposeActualState() async throws {
    let (root, service) = try await fixture(["detailState": "CLOSED", "statusViewerAfterAction": "another-user"], draft: true)
    let expected = try await service.mergeSnapshot(for: request, at: root)
    let error = await failure {
      _ = try await service.updateStatus(.open, expected: expected, request: self.request, at: root)
    }
    let result = try XCTUnwrap(error as? GitHubPRStatusFailure)
    XCTAssertTrue(result.requiresRefresh)
    XCTAssertEqual(GitHubPRStatus(try XCTUnwrap(result.snapshot).details), .draft)
    XCTAssertEqual(result.snapshot?.viewer, "another-user"); XCTAssertFalse(result.snapshot?.isAuthor ?? true)
    XCTAssertEqual(try writes(root).count, 1)
  }

  func testLatestWritableSettingIsCheckedAfterPreflight() async throws {
    let (root, service) = try await fixture()
    let state = await loaded(service, root: root)
    var checks = 0
    XCTAssertTrue(state.startStatus(.draft, request: request, at: root, valid: { true },
      writable: { checks += 1; return checks < 3 }, updated: { _ in XCTFail() }))
    await state.operation?.value
    XCTAssertEqual(checks, 3); XCTAssertTrue(try writes(root).isEmpty)
    XCTAssertEqual(GitHubPRStatus(try XCTUnwrap(state.snapshot).details), .open)
    XCTAssertNotNil(state.error)
  }

  func testNativeStatusMenuInvokesConfirmedOperationAndRebuildsCheckmark() async throws {
    let (root, service) = try await fixture()
    let state = await loaded(service, root: root)
    let host = NSHostingView(rootView: TaskPullRequestStatusView(state: state, request: request, writable: true,
      select: { value in
        state.startStatus(value, request: self.request, at: root, valid: { true }, writable: { true }, updated: { _ in })
      }).padding(12).frame(width: 260, height: 56).background(Color.white).environment(\.colorScheme, .light))
    let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 260, height: 56), styleMask: [.titled], backing: .buffered, defer: true)
    window.isReleasedWhenClosed = false; window.appearance = NSAppearance(named: .aqua); window.contentView = host
    defer { window.contentView = nil; window.close(); state.cancel() }
    func controls(_ view: NSView) -> [SettingsMenuControl] {
      ((view as? SettingsMenuControl).map { [$0] } ?? []) + view.subviews.flatMap(controls)
    }
    try await Task.sleep(for: .milliseconds(200)); host.layoutSubtreeIfNeeded()
    let menu = try XCTUnwrap(controls(host).first)
    XCTAssertFalse(menu.isBordered); XCTAssertEqual(menu.accessibilityLabel(), "更改 PR 状态")
    XCTAssertEqual(menu.menu?.items.map(\.title), ["可供审查", "草稿", "可供审查", "已关闭"])
    XCTAssertEqual(menu.menu?.items.filter { $0.state == .on }.map(\.title), ["可供审查"])
    menu.selectItem(at: 2); menu.sendAction(menu.action, to: menu.target)
    XCTAssertNil(state.operation)
    menu.selectItem(at: 1); menu.sendAction(menu.action, to: menu.target)
    XCTAssertEqual(state.statusAction, .draft)
    await state.operation?.value
    try await Task.sleep(for: .milliseconds(200)); host.layoutSubtreeIfNeeded()
    XCTAssertEqual(menu.item(at: 0)?.title, "草稿")
    XCTAssertEqual(menu.menu?.items.filter { $0.state == .on }.map(\.title), ["草稿"])
    XCTAssertFalse(menu.item(at: 1)?.isEnabled ?? true); XCTAssertTrue(menu.item(at: 2)?.isEnabled ?? false)
    XCTAssertEqual(try writes(root).count, 1)
    if let path = ProcessInfo.processInfo.environment["SHIPIOS_PR_STATUS_RENDER_PATH"] {
      let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
      host.cacheDisplay(in: host.bounds, to: bitmap)
      try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: path))
    }
  }

  func testNativeStatusMenuIsStaticForNonAuthorsAndMergedAndDisabledForReadonly() async throws {
    for (fields, writable): ([String: Any], Bool) in [(["viewer": "another-user"], true), (["detailState": "MERGED"], true), ([:], false)] {
      let (root, service) = try await fixture(fields)
      let state = await loaded(service, root: root)
      var selections = 0
      let host = NSHostingView(rootView: TaskPullRequestStatusView(state: state, request: request, writable: writable,
        select: { _ in selections += 1 }).frame(width: 260, height: 56))
      let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 260, height: 56), styleMask: [.titled], backing: .buffered, defer: true)
      window.isReleasedWhenClosed = false; window.contentView = host
      defer { window.contentView = nil; window.close(); state.cancel() }
      func controls(_ view: NSView) -> [SettingsMenuControl] {
        ((view as? SettingsMenuControl).map { [$0] } ?? []) + view.subviews.flatMap(controls)
      }
      try await Task.sleep(for: .milliseconds(200)); host.layoutSubtreeIfNeeded()
      if writable { XCTAssertTrue(controls(host).isEmpty) }
      else {
        let menu = try XCTUnwrap(controls(host).first)
        XCTAssertFalse(menu.isEnabled)
        menu.selectItem(at: 1); menu.sendAction(menu.action, to: menu.target)
      }
      XCTAssertEqual(selections, 0); XCTAssertTrue(try writes(root).isEmpty)
    }
  }
}
