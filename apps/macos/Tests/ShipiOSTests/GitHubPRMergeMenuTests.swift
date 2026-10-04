import AppKit
import SwiftUI
import XCTest
@testable import ShipiOS

@MainActor final class GitHubPRMergeMenuTests: XCTestCase {
  private let request = GitHubPullRequest(number: 42, url: "https://github.com/sample/project/pull/42",
    title: "Feature", isDraft: false, headRefName: "feature", baseRefName: "main", isCrossRepository: false)
  private func fixture(_ changes: [String: Any] = [:], draft: Bool = false) async throws -> (URL, GitHubPRService) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("pr-merge-menu-" + UUID().uuidString)
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
    var fields: [String: Any] = ["head": String(repeating: "a", count: 40), "viewer": "owner", "author": "owner",
      "mergeable": "MERGEABLE", "pullRequests": [item]]
    changes.forEach { fields[$0.key] = $0.value }
    try JSONSerialization.data(withJSONObject: fields).write(to: root.appendingPathComponent(".git/github-fixture.json"))
    return (root, .init(executable: executable))
  }
  private func state(_ root: URL, service: GitHubPRService) async -> GitHubPRDetailState {
    let state = GitHubPRDetailState(service: service, coordinator: .init())
    await state.refresh(request, at: root, preferred: .squash, valid: { true }, updated: { _ in })
    return state
  }
  private func presentation(_ state: GitHubPRDetailState, writable: Bool = true) -> GitHubPRMergePresentation {
    .init(snapshot: state.snapshot, action: state.action,
      mergeReason: state.mergeDisabledReason(for: request, writable: writable),
      autoReason: state.autoMergeDisabledReason(for: request, writable: writable))
  }
  private func writes(_ root: URL) throws -> [[String]] {
    let file = root.appendingPathComponent(".git/github-requests.jsonl")
    guard FileManager.default.fileExists(atPath: file.path) else { return [] }
    return try String(contentsOf: file).split(separator: "\n").compactMap {
      let entry = try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
      let args = entry?["args"] as? [String]
      return args?.prefix(2) == ["pr", "merge"] ? args : nil
    }
  }
  private func host<V: View>(_ view: V, width: CGFloat) -> (NSWindow, NSHostingView<V>) {
    let window = NSWindow(contentRect: .init(x: 0, y: 0, width: width, height: 80), styleMask: [.titled], backing: .buffered, defer: true)
    window.isReleasedWhenClosed = false; window.appearance = NSAppearance(named: .aqua)
    let host = NSHostingView(rootView: view); host.wantsLayer = true; host.layer?.backgroundColor = NSColor.white.cgColor
    window.contentView = host
    return (window, host)
  }
  private func controls(_ view: NSView) -> [SettingsMenuControl] {
    ((view as? SettingsMenuControl).map { [$0] } ?? []) + view.subviews.flatMap(controls)
  }
  private func settle(_ host: NSView) async throws {
    try await Task.sleep(for: .milliseconds(200)); host.layoutSubtreeIfNeeded()
  }
  private func render(_ host: NSView, name: String) throws {
    guard let directory = ProcessInfo.processInfo.environment["SHIPIOS_PR_MERGE_RENDER_DIR"] else { return }
    let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
    host.cacheDisplay(in: host.bounds, to: bitmap)
    try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
      .write(to: URL(fileURLWithPath: directory).appendingPathComponent(name + ".png"))
  }

  func testDraftClosedMergedAndNonAuthorControlsMatchSidePanelQualification() async throws {
    for (changes, draft, hidden): ([String: Any], Bool, Bool) in [([:], true, false),
      (["detailState": "CLOSED"], false, true), (["detailState": "MERGED"], false, true), (["viewer": "another-user"], false, true)] {
      let (root, service) = try await fixture(changes, draft: draft), state = await self.state(root, service: service)
      let value = presentation(state)
      XCTAssertEqual(value.mode, hidden ? .hidden : .disabled("请先将草稿标记为可供审查。"))
      for action in [GitHubPRMergePresentation.Selection.confirm, .enableAuto, .disableAuto] {
        XCTAssertNil(value.action(for: action, method: .merge))
      }
      XCTAssertTrue(try writes(root).isEmpty)
    }
  }

  func testAutoMergeReplacesMenuEvenForDraftAndReadonlyBlocksBothChoices() async throws {
    let (root, service) = try await fixture(["autoMerge": true], draft: true), state = await self.state(root, service: service)
    let value = presentation(state)
    XCTAssertEqual(value.mode, .disableAuto); XCTAssertTrue(value.items.isEmpty)
    XCTAssertEqual(value.action(for: .disableAuto, method: .squash), .apply(.autoMerge(enabled: false, method: .squash)))
    XCTAssertNil(value.action(for: .confirm, method: .merge))
    XCTAssertNil(value.action(for: .enableAuto, method: .merge))
    XCTAssertNil(presentation(state, writable: false).action(for: .disableAuto, method: .merge))
    let (otherRoot, otherService) = try await fixture(), other = await self.state(otherRoot, service: otherService)
    let blocked = presentation(other, writable: false)
    XCTAssertEqual(blocked.mode, .disabled("当前任务不能修改 PR。")); XCTAssertTrue(blocked.items.isEmpty)
  }

  func testFailingCIRetainsAutoMergeMenuAndDisabledMergeItem() async throws {
    let (root, service) = try await fixture(["statusCheckRollup": [["status": "COMPLETED", "conclusion": "FAILURE"]]])
    let state = await self.state(root, service: service), value = presentation(state)
    XCTAssertEqual(value.mode, .menu)
    let options = value.items.compactMap { if case .option(let option) = $0 { return option }; return nil }
    XCTAssertEqual(options.map(\.title), ["合并", "启用自动合并"])
    XCTAssertEqual(options.map(\.enabled), [false, true]); XCTAssertEqual(options[0].help, "请先修复失败的检查。")
    XCTAssertNil(value.action(for: .confirm, method: .merge))
    XCTAssertEqual(value.action(for: .enableAuto, method: .squash), .apply(.autoMerge(enabled: true, method: .squash)))
  }

  func testThreeRealOperationStatesKeepProgressAndRejectMenuActions() async throws {
    for action in [GitHubPRMergeAction.merge(.squash), .autoMerge(enabled: true, method: .squash), .autoMerge(enabled: false, method: .squash)] {
      let (root, service) = try await fixture(["autoMerge": action == .autoMerge(enabled: false, method: .squash), "mutationDelay": 0.1])
      let state = await self.state(root, service: service)
      XCTAssertTrue(state.start(action, request: request, at: root, valid: { true }, writable: { true }, updated: { _ in }))
      let value = presentation(state)
      XCTAssertEqual(value.mode, .progress(action.progressLabel)); XCTAssertTrue(value.items.isEmpty)
      XCTAssertNil(value.action(for: .confirm, method: .merge)); XCTAssertNil(value.action(for: .enableAuto, method: .merge))
      await state.operation?.value
      XCTAssertNil(state.action); XCTAssertNil(state.error)
    }
  }

  func testNativeSingleWideTriggerOpensConfirmationOnlyAndPreservesMethod() async throws {
    let (root, service) = try await fixture(), state = await self.state(root, service: service)
    let (window, host) = host(TaskPullRequestActionsView(state: state, request: request, writable: true,
      apply: { _ in XCTFail("Selecting merge must only open confirmation") }).frame(width: 284).padding(8), width: 300)
    defer { window.contentView = nil; window.close(); state.cancel() }
    try await settle(host)
    let menu = try XCTUnwrap(controls(host).first)
    XCTAssertEqual(controls(host).count, 1); XCTAssertTrue(menu.isTransparent); XCTAssertFalse(menu.isBordered)
    XCTAssertEqual(menu.alignmentRect(forFrame: menu.frame).width, 284, accuracy: 1)
    XCTAssertTrue(window.makeFirstResponder(menu)); XCTAssertTrue(window.firstResponder === menu)
    XCTAssertEqual(menu.focusRingMaskBounds, menu.bounds)
    XCTAssertEqual(menu.menu?.items.map(\.title), ["合并", "合并", "启用自动合并"])
    XCTAssertFalse(state.showingMergeConfirmation); XCTAssertTrue(try writes(root).isEmpty)
    menu.selectItem(at: 1); menu.sendAction(menu.action, to: menu.target)
    XCTAssertTrue(state.showingMergeConfirmation); XCTAssertEqual(state.selectedMethod, .squash)
    XCTAssertTrue(try writes(root).isEmpty)
    state.showingMergeConfirmation = false
    try await settle(host); try render(host, name: "merge-menu-284")
  }

  func testNativeDisabledMergeDoesNotActButAutoMergeRoutesToFixture() async throws {
    let (root, service) = try await fixture(["statusCheckRollup": [["status": "COMPLETED", "conclusion": "FAILURE"]]])
    let state = await self.state(root, service: service)
    var applied: [GitHubPRMergeAction] = []
    let (window, host) = host(TaskPullRequestActionsView(state: state, request: request, writable: true, apply: {
      applied.append($0)
      state.start($0, request: self.request, at: root, valid: { true }, writable: { true }, updated: { _ in })
    }).frame(width: 284).padding(8), width: 300)
    defer { window.contentView = nil; window.close(); state.cancel() }
    try await settle(host)
    let menu = try XCTUnwrap(controls(host).first)
    XCTAssertFalse(menu.item(at: 1)?.isEnabled ?? true); XCTAssertTrue(menu.item(at: 2)?.isEnabled ?? false)
    menu.selectItem(at: 1); menu.sendAction(menu.action, to: menu.target)
    XCTAssertFalse(state.showingMergeConfirmation); XCTAssertTrue(applied.isEmpty)
    menu.selectItem(at: 2); menu.sendAction(menu.action, to: menu.target)
    XCTAssertEqual(applied, [.autoMerge(enabled: true, method: .squash)])
    await state.operation?.value; try await settle(host)
    XCTAssertTrue(state.snapshot?.isAutoMergeEnabled == true); XCTAssertTrue(controls(host).isEmpty)
    XCTAssertTrue(try writes(root).first?.contains("--auto") == true)
    try render(host, name: "auto-merge-enabled-284")
  }

  func testReadonlyRemountInvalidatesOldNativeMenuAndRendersDisabledReason() async throws {
    let (root, service) = try await fixture(), state = await self.state(root, service: service)
    let content = TaskPullRequestActionsView(state: state, request: request, writable: true, apply: { _ in XCTFail() })
    let (window, host) = host(content.frame(width: 284).padding(8), width: 300)
    defer { window.contentView = nil; window.close(); state.cancel() }
    try await settle(host)
    let old = try XCTUnwrap(controls(host).first), target = old.target, action = old.action
    host.rootView = TaskPullRequestActionsView(state: state, request: request, writable: false, apply: { _ in XCTFail() })
      .frame(width: 284).padding(8)
    try await settle(host)
    XCTAssertTrue(controls(host).isEmpty)
    old.selectItem(at: 1); old.sendAction(action, to: target)
    XCTAssertFalse(state.showingMergeConfirmation); XCTAssertTrue(try writes(root).isEmpty)
    try render(host, name: "merge-readonly-284")
  }

  func testDisabledReasonControlCanReceiveFocusButNeverActivates() async throws {
    let (root, service) = try await fixture(draft: true), state = await self.state(root, service: service)
    let (window, host) = host(TaskPullRequestActionsView(state: state, request: request, writable: true,
      apply: { _ in XCTFail() }).frame(width: 284).padding(8), width: 300)
    defer { window.contentView = nil; window.close(); state.cancel() }
    try await settle(host)
    func buttons(_ view: NSView) -> [PullRequestUnavailableMergeButton] {
      ((view as? PullRequestUnavailableMergeButton).map { [$0] } ?? []) + view.subviews.flatMap(buttons)
    }
    let button = try XCTUnwrap(buttons(host).first)
    XCTAssertFalse(button.isEnabled); XCTAssertTrue(button.canBecomeKeyView)
    button.isEnabled = true
    XCTAssertFalse(button.isEnabled); XCTAssertFalse(button.cell?.isEnabled ?? true)
    XCTAssertTrue(button.accessibilityLabel()?.contains("请先将草稿标记为可供审查") == true)
    XCTAssertTrue(window.makeFirstResponder(button)); XCTAssertTrue(window.firstResponder === button)
    XCTAssertFalse(button.accessibilityPerformPress()); XCTAssertNil(button.action)
    XCTAssertFalse(state.showingMergeConfirmation); XCTAssertTrue(try writes(root).isEmpty)
    button.active = false
    XCTAssertFalse(button.acceptsFirstResponder); XCTAssertFalse(button.canBecomeKeyView)
    try render(host, name: "merge-draft-284")
  }

  func testWideTriggerOccupiesWholeRowAndKeepsOneAccessibleNativeControl() async throws {
    let (root, service) = try await fixture(), state = await self.state(root, service: service)
    let (window, host) = host(TaskPullRequestActionsView(state: state, request: request, writable: true,
      apply: { _ in XCTFail() }).frame(width: 700).padding(8), width: 716)
    defer { window.contentView = nil; window.close(); state.cancel() }
    try await settle(host)
    let menu = try XCTUnwrap(controls(host).first)
    XCTAssertEqual(controls(host).count, 1)
    XCTAssertEqual(menu.alignmentRect(forFrame: menu.frame).width, 700, accuracy: 1)
    XCTAssertEqual(menu.accessibilityLabel(), "PR 合并操作")
    XCTAssertFalse(state.showingMergeConfirmation); XCTAssertTrue(try writes(root).isEmpty)
    try render(host, name: "merge-menu-700")
  }
}
