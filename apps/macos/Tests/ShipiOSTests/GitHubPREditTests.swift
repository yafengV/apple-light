import AppKit
import SwiftUI
import XCTest
@testable import ShipiOS

final class GitHubPREditTests: XCTestCase {
  private let request = GitHubPullRequest(number: 42, url: "https://github.com/sample/project/pull/42",
    title: "Feature", isDraft: false, headRefName: "feature/topic", baseRefName: "main", isCrossRepository: false)
  private func fixture() async throws -> (URL, GitHubPRService) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("pr-edit-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    _ = try await GitReviewService.checked(["init", "-q", "-b", "feature/topic"], at: root)
    let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Fixtures/github_cli.py")
    let executable = root.appendingPathComponent(".git/gh-fixture")
    try FileManager.default.copyItem(at: source, to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    let item = try JSONSerialization.jsonObject(with: JSONEncoder().encode(request))
    try write(["head": String(repeating: "a", count: 40), "pullRequests": [item],
      "detailBody": "Original body", "mergeable": "MERGEABLE"], root)
    return (root, .init(executable: executable))
  }
  private func read(_ root: URL) throws -> [String: Any] {
    try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent(".git/github-fixture.json"))) as? [String: Any])
  }
  private func write(_ value: [String: Any], _ root: URL) throws {
    try JSONSerialization.data(withJSONObject: value).write(to: root.appendingPathComponent(".git/github-fixture.json"))
  }
  private func change(_ fields: [String: Any], _ root: URL) throws {
    var state = try read(root); fields.forEach { state[$0.key] = $0.value }; try write(state, root)
  }
  private func logs(_ root: URL, command: String) throws -> [[String: Any]] {
    let url = root.appendingPathComponent(".git/github-requests.jsonl")
    guard FileManager.default.fileExists(atPath: url.path) else { return [] }
    return try String(contentsOf: url, encoding: .utf8).split(separator: "\n").compactMap {
      let value = try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
      return (value?["args"] as? [String])?.prefix(2) == ["pr", command] ? value : nil
    }
  }
  private func fails(_ body: () async throws -> Void) async -> Error? {
    do { try await body(); XCTFail("Expected failure"); return nil } catch { return error }
  }

  @MainActor func testTitleDraftRulesAndIndependentDescriptionEditing() async throws {
    let (root, service) = try await fixture(), state = GitHubPREditState(service: service)
    let snapshot = try await service.mergeSnapshot(for: request, at: root)
    state.begin(.title, snapshot: snapshot, request: request, writable: true)
    XCTAssertFalse(state.canSave(.title, snapshot: snapshot, request: request, writable: true))
    state.change(.title, text: "  Feature  ")
    XCTAssertFalse(state.canSave(.title, snapshot: snapshot, request: request, writable: true))
    state.change(.title, text: "\r\n  ")
    XCTAssertFalse(state.canSave(.title, snapshot: snapshot, request: request, writable: true))
    state.change(.title, text: " A\r\n\nB\rC ")
    XCTAssertEqual(state.title?.text, " A B C ")
    XCTAssertTrue(state.canSave(.title, snapshot: snapshot, request: request, writable: true))
    state.begin(.body, snapshot: snapshot, request: request, writable: true)
    state.change(.body, text: "")
    XCTAssertTrue(state.canSave(.body, snapshot: snapshot, request: request, writable: true))
    state.cancel(.title, request: request)
    XCTAssertNil(state.title); XCTAssertEqual(state.body?.text, ""); XCTAssertNotNil(state.returnTitleFocus)
  }

  @MainActor func testDraftRegistrySharesPRWindowsAndCheckoutsButSeparatesApplication() async throws {
    let (root, service) = try await fixture(), registry = GitHubPREditRegistry()
    let data = root.appendingPathComponent("data")
    let a = registry.state(dataRoot: data, root: root, request: request)
    let b = registry.state(dataRoot: data, root: root, request: request)
    XCTAssertTrue(a === b)
    XCTAssertFalse(a === registry.state(dataRoot: root, root: root, request: request))
    XCTAssertTrue(a === registry.state(dataRoot: data, root: data, request: request))
    let snapshot = try await service.mergeSnapshot(for: request, at: root)
    a.begin(.title, snapshot: snapshot, request: request, writable: true)
    a.change(.title, text: "shared draft")
    XCTAssertEqual(b.title?.text, "shared draft")
    let one = UUID(), two = UUID(); a.attach(one); b.attach(two); a.detach(one); b.detach(two)
    XCTAssertEqual(a.title?.text, "shared draft", "Closing the last window does not persist or discard ephemeral input")
  }

  func testBodyPreservesLiteralMultilineEmptyAndPrivateFileCleanup() async throws {
    let (root, service) = try await fixture()
    for body in ["## 描述\n\n`$(do-not-execute)` + \"literal\"\r\n\n", ""] {
      let result = try await service.edit(.body, text: body, request: request, at: root)
      XCTAssertEqual(result.details.body, body)
      let log = try XCTUnwrap(logs(root, command: "edit").last)
      XCTAssertEqual(log["body"] as? String, body)
      XCTAssertEqual(log["bodyMode"] as? String, "0o600")
      XCTAssertEqual(log["folderMode"] as? String, "0o700")
      let args = try XCTUnwrap(log["args"] as? [String])
      XCTAssertEqual(Array(args.prefix(5)), ["pr", "edit", "42", "--repo", "sample/project"])
      let file = args[try XCTUnwrap(args.firstIndex(of: "--body-file")) + 1]
      XCTAssertFalse(FileManager.default.fileExists(atPath: file))
      XCTAssertFalse(FileManager.default.fileExists(atPath: URL(fileURLWithPath: file).deletingLastPathComponent().path))
    }
  }

  func testTitlePermissionIsServerControlledEvenForClosedNonAuthorPR() async throws {
    let (root, service) = try await fixture()
    try change(["viewer": "other", "detailState": "CLOSED"], root)
    let result = try await service.edit(.title, text: "  修复\n标题  ", request: request, at: root)
    XCTAssertEqual(result.details.title, "修复 标题"); XCTAssertFalse(result.isAuthor)
    XCTAssertEqual(result.details.state, "CLOSED")
    try change(["editFailure": true], root)
    let error = await fails { _ = try await service.edit(.title, text: "denied", request: self.request, at: root) }
    XCTAssertTrue(error is GitHubPREditFailure)
  }

  func testDescriptionRechecksAuthorAndOpenStatusBeforeMutation() async throws {
    for fields: [String: Any] in [["viewer": "other"], ["detailState": "CLOSED"], ["detailState": "MERGED"]] {
      let (root, service) = try await fixture()
      try change(fields, root)
      _ = await fails { _ = try await service.edit(.body, text: "new", request: self.request, at: root) }
      XCTAssertTrue(try logs(root, command: "edit").isEmpty)
    }
  }

  func testInvalidTextNeverInvokesGitHubCLI() async throws {
    let (root, service) = try await fixture()
    for (field, text): (GitHubPREditField, String) in [(.title, "  \n "), (.title, String(repeating: "a", count: 257)),
      (.body, String(repeating: "界", count: 22_000))] {
      _ = await fails { _ = try await service.edit(field, text: text, request: self.request, at: root) }
    }
    XCTAssertTrue(try logs(root, command: "view").isEmpty)
    XCTAssertTrue(try logs(root, command: "edit").isEmpty)
  }

  func testAcceptedDisconnectedWriteIsConfirmedAndRetryDoesNotDuplicate() async throws {
    let (root, service) = try await fixture()
    try change(["failAfterAction": true], root)
    let first = try await service.edit(.title, text: "Accepted", request: request, at: root)
    XCTAssertEqual(first.details.title, "Accepted")
    _ = try await service.edit(.title, text: "Accepted", request: request, at: root)
    XCTAssertEqual(try logs(root, command: "edit").count, 1)
  }

  @MainActor func testUnconfirmedSaveRetainsDraftAndCanReconcileWithoutSecondWrite() async throws {
    let (root, service) = try await fixture(), state = GitHubPREditState(service: service)
    let snapshot = try await service.mergeSnapshot(for: request, at: root)
    state.begin(.body, snapshot: snapshot, request: request, writable: true); state.change(.body, text: "Saved remotely")
    try change(["detailFailureAfterAction": true], root)
    XCTAssertTrue(state.save(.body, snapshot: snapshot, request: request, at: root,
      valid: { true }, writable: { true }, updated: { _ in }))
    await state.operation?.value
    XCTAssertEqual(state.body?.text, "Saved remotely"); XCTAssertTrue(state.body?.error?.contains("尚未确认") == true)
    try change(["detailFailureAfterAction": false], root)
    XCTAssertTrue(state.save(.body, snapshot: snapshot, request: request, at: root,
      valid: { true }, writable: { true }, updated: { _ in }))
    await state.operation?.value
    XCTAssertNil(state.body); XCTAssertNotNil(state.returnBodyFocus)
    XCTAssertEqual(try logs(root, command: "edit").count, 1)
  }

  @MainActor func testFailedSaveRetainsDraftClearsErrorOnTypingAndPublishesSuccess() async throws {
    let (root, service) = try await fixture(), state = GitHubPREditState(service: service)
    let snapshot = try await service.mergeSnapshot(for: request, at: root)
    state.begin(.title, snapshot: snapshot, request: request, writable: true); state.change(.title, text: "Typed")
    try change(["editFailure": true], root)
    var updated: GitHubPullRequest?
    state.save(.title, snapshot: snapshot, request: request, at: root,
      valid: { true }, writable: { true }, updated: { updated = $0 })
    await state.operation?.value
    XCTAssertEqual(state.title?.text, "Typed"); XCTAssertNotNil(state.title?.error)
    state.change(.title, text: "Retried"); XCTAssertNil(state.title?.error)
    try change(["editFailure": false], root)
    state.save(.title, snapshot: snapshot, request: request, at: root,
      valid: { true }, writable: { true }, updated: { updated = $0 })
    await state.operation?.value
    XCTAssertNil(state.title); XCTAssertEqual(updated?.title, "Retried"); XCTAssertEqual(state.snapshot?.details.title, "Retried")
  }

  @MainActor func testSharedMutationOwnershipBlocksMergeAndOtherEditorUntilFinished() async throws {
    let (root, service) = try await fixture(), coordinator = GitHubPRActionCoordinator()
    let state = GitHubPREditState(service: service, coordinator: coordinator)
    let other = GitHubPREditState(service: service, coordinator: coordinator)
    let merge = GitHubPRDetailState(service: service, coordinator: coordinator)
    await merge.refresh(request, at: root, preferred: .merge, valid: { true }, updated: { _ in })
    let snapshot = try XCTUnwrap(merge.snapshot)
    for draft in [state, other] {
      draft.begin(.body, snapshot: snapshot, request: request, writable: true); draft.change(.body, text: "new")
    }
    try change(["editDelay": 0.2], root)
    XCTAssertTrue(state.save(.body, snapshot: snapshot, request: request, at: root, valid: { true }, writable: { true }, updated: { _ in }))
    XCTAssertFalse(other.save(.body, snapshot: snapshot, request: request, at: root, valid: { true }, writable: { true }, updated: { _ in }))
    XCTAssertFalse(merge.start(.merge(.merge), request: request, at: root, valid: { true }, writable: { true }, updated: { _ in }))
    state.cancel(.body, request: request); XCTAssertNotNil(state.body)
    await state.operation?.value
    XCTAssertFalse(coordinator.isBusy(request.url)); XCTAssertEqual(try logs(root, command: "edit").count, 1)
  }

  @MainActor func testLostAuthorizationOrScopeNeverWritesAndDoesNotPublishLateResult() async throws {
    let (root, service) = try await fixture(), state = GitHubPREditState(service: service)
    let snapshot = try await service.mergeSnapshot(for: request, at: root)
    var calls = 0
    _ = await fails {
      _ = try await service.edit(.body, text: "blocked", request: self.request, at: root) {
        calls += 1; if calls > 1 { throw CancellationError() }
      }
    }
    XCTAssertEqual(calls, 2); XCTAssertTrue(try logs(root, command: "edit").isEmpty)
    state.begin(.title, snapshot: snapshot, request: request, writable: true); state.change(.title, text: "old task")
    XCTAssertTrue(state.save(.title, snapshot: snapshot, request: request, at: root,
      valid: { false }, writable: { true }, updated: { _ in XCTFail("Old scope must not update task") }) == false)
    XCTAssertTrue(try logs(root, command: "edit").isEmpty)
  }

  @MainActor func testDetachOnlyCancelsWorkAfterLastOwnerAndKeepsDraft() async throws {
    let (root, service) = try await fixture(), state = GitHubPREditState(service: service)
    let snapshot = try await service.mergeSnapshot(for: request, at: root)
    let one = UUID(), two = UUID(); state.attach(one); state.attach(two)
    let received = expectation(description: "generation started"), gate = GenerationEditGate()
    state.generate(snapshot: snapshot, request: request, instructions: "", at: root,
      valid: { true }, writable: { true }, generate: { _ in received.fulfill(); return await gate.wait() }, updated: { _ in })
    await fulfillment(of: [received], timeout: 5)
    let operation = state.generationTask
    state.detach(one); XCTAssertTrue(state.generating)
    state.detach(two); XCTAssertFalse(state.generating); XCTAssertEqual(state.body?.text, "Original body")
    await gate.finish("late"); await operation?.value
    XCTAssertEqual(state.body?.text, "Original body")
  }

  @MainActor func testLateSaveAfterTaskInvalidationCannotPublishOrLoseDraft() async throws {
    let (root, service) = try await fixture(), state = GitHubPREditState(service: service)
    let snapshot = try await service.mergeSnapshot(for: request, at: root)
    state.begin(.title, snapshot: snapshot, request: request, writable: true); state.change(.title, text: "old task")
    var current = true
    try change(["editDelay": 0.25], root)
    XCTAssertTrue(state.save(.title, snapshot: snapshot, request: request, at: root,
      valid: { current }, writable: { true }, updated: { _ in XCTFail("Invalid task must not receive result") }))
    let operation = state.operation
    for _ in 0..<200 {
      if try !logs(root, command: "edit").isEmpty { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertEqual(try logs(root, command: "edit").count, 1)
    current = false; await operation?.value
    XCTAssertEqual(state.title?.text, "old task"); XCTAssertNil(state.snapshot)
    XCTAssertNil(state.saving)
  }

  @MainActor func testMetadataBroadcastInvalidatesAnOlderReadWithoutResettingMergeAction() async throws {
    let (root, service) = try await fixture(), detail = GitHubPRDetailState(service: service)
    let snapshot = try await service.mergeSnapshot(for: request, at: root)
    detail.acceptMetadata(snapshot)
    XCTAssertEqual(detail.snapshot, snapshot); XCTAssertFalse(detail.loading)
    try change(["detailReadGate": true], root)
    let held = root.appendingPathComponent(".git/detail-read-held"), release = root.appendingPathComponent(".git/detail-read-release")
    defer { _ = FileManager.default.createFile(atPath: release.path, contents: Data()) }
    let old = Task { await detail.refresh(request, at: root, preferred: .merge,
      valid: { true }, updated: { _ in XCTFail("Superseded read must not publish") }) }
    for _ in 0..<200 {
      if FileManager.default.fileExists(atPath: held.path) { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertTrue(FileManager.default.fileExists(atPath: held.path), "Old read must be held before broadcasting new metadata")
    XCTAssertTrue(detail.loading)
    try change(["detailReadGate": false], root)
    let updated = try await service.edit(.title, text: "new title", request: request, at: root)
    detail.acceptMetadata(updated)
    XCTAssertTrue(FileManager.default.createFile(atPath: release.path, contents: Data()))
    await old.value
    XCTAssertEqual(detail.snapshot?.details.title, "new title")
    XCTAssertFalse(detail.loading)
  }

  @MainActor func testGenerationUsesCanonicalDiffAndRetainsDraftUntilExplicitSave() async throws {
    let (root, service) = try await fixture(), state = GitHubPREditState(service: service)
    let snapshot = try await service.mergeSnapshot(for: request, at: root)
    state.begin(.body, snapshot: snapshot, request: request, writable: true)
    state.change(.body, text: "Accurate testing notes")
    XCTAssertTrue(state.generate(snapshot: snapshot, request: request, instructions: "Use Chinese", at: root,
      valid: { true }, writable: { true }, generate: { messages in
        XCTAssertTrue(messages.last?.content.contains("Accurate testing notes") == true)
        XCTAssertTrue(messages.last?.content.contains("Use Chinese") == true)
        XCTAssertTrue(messages.last?.content.contains("diff --git") == true)
        return "  ## 生成描述\n\n已保留准确内容。  "
      }, updated: { _ in }))
    XCTAssertTrue(state.generating)
    state.change(.body, text: "cannot edit during generation")
    XCTAssertEqual(state.body?.text, "Accurate testing notes")
    await state.generationTask?.value
    XCTAssertFalse(state.generating); XCTAssertEqual(state.body?.text, "## 生成描述\n\n已保留准确内容。")
    XCTAssertTrue(try logs(root, command: "edit").isEmpty)
    XCTAssertEqual(try read(root)["detailBody"] as? String, "Original body")
  }

  @MainActor func testDiffCaptureDriftNeverReachesGenerator() async throws {
    let (root, service) = try await fixture(), snapshot = try await service.mergeSnapshot(for: request, at: root)
    try change(["headAfterDiff": String(repeating: "b", count: 40)], root)
    _ = await fails {
      _ = try await service.generateDescription(request: self.request, expected: snapshot, body: "", instructions: "", at: root,
        generate: { _ in XCTFail("Drifted diff must not reach model"); return "wrong" })
    }
    XCTAssertTrue(try logs(root, command: "edit").isEmpty)
  }

  @MainActor func testHeadChangeDuringGenerationPreservesOriginalDraftAndError() async throws {
    let (root, service) = try await fixture(), state = GitHubPREditState(service: service)
    let snapshot = try await service.mergeSnapshot(for: request, at: root)
    state.generate(snapshot: snapshot, request: request, instructions: "", at: root,
      valid: { true }, writable: { true }, generate: { _ in
        try self.change(["detailHead": String(repeating: "b", count: 40)], root)
        return "must not replace"
      }, updated: { _ in XCTFail("Changed head must not publish generated result") })
    await state.generationTask?.value
    XCTAssertEqual(state.body?.text, "Original body"); XCTAssertNotNil(state.body?.error)
  }

  @MainActor func testStoppingGenerationKeepsEditorAndDiscardsLateModelCompletion() async throws {
    let (root, service) = try await fixture(), state = GitHubPREditState(service: service)
    let snapshot = try await service.mergeSnapshot(for: request, at: root)
    let received = expectation(description: "model received diff")
    let gate = GenerationEditGate()
    state.generate(snapshot: snapshot, request: request, instructions: "", at: root,
      valid: { true }, writable: { true }, generate: { _ in
        received.fulfill(); return await gate.wait()
      }, updated: { _ in XCTFail("Cancelled generation must not publish") })
    await fulfillment(of: [received], timeout: 5)
    let running = state.generationTask
    state.cancel(.body, request: request)
    XCTAssertFalse(state.generating); XCTAssertEqual(state.body?.text, "Original body")
    state.change(.body, text: "New manual draft")
    await gate.finish("late output"); await running?.value
    XCTAssertEqual(state.body?.text, "New manual draft"); XCTAssertNil(state.body?.error)
  }

  @MainActor func testEmptyAndRejectedGenerationKeepsEmptyViewDraftAndRecovers() async throws {
    let (root, service) = try await fixture(), state = GitHubPREditState(service: service)
    try change(["detailBody": ""], root)
    let snapshot = try await service.mergeSnapshot(for: request, at: root)
    state.generate(snapshot: snapshot, request: request, instructions: "", at: root,
      valid: { true }, writable: { true }, generate: { _ in " \n " }, updated: { _ in })
    XCTAssertTrue(state.body?.startedFromEmptyView == true)
    await state.generationTask?.value
    XCTAssertEqual(state.body?.text, ""); XCTAssertNotNil(state.body?.error)
    XCTAssertTrue(state.canSave(.body, snapshot: snapshot, request: request, writable: true))
    state.change(.body, text: "manual")
    XCTAssertFalse(state.body?.startedFromEmptyView == true); XCTAssertNil(state.body?.error)
  }

  @MainActor func testRealChatAndCoreResponsesDescriptionGenerationRoutes() async throws {
    let (root, service) = try await fixture(), server = try GitGenerationFixture(root: root)
    defer { server.stop() }
    let snapshot = try await service.mergeSnapshot(for: request, at: root)
    for api: ModelAPIProtocol in [.chatCompletions, .codexResponses] {
      var config = server.config; config.apiProtocol = api
      let generate = GitTextGenerator.make(config: config, key: nil, repository: root,
        dataRoot: root.appendingPathComponent("private"), executable: GitGenerationFixture.binary)
      let (text, _) = try await service.generateDescription(request: request, expected: snapshot,
        body: "Preserve these tests", instructions: "Use Chinese", at: root, generate: generate)
      XCTAssertEqual(text, "## Summary\n\nGenerated PR description.")
    }
    let records = try server.records()
    XCTAssertEqual(records.map { $0["path"].text }, ["/v1/chat/completions", "/v1/responses"])
    XCTAssertTrue(records[1]["body"]["tools"].items.isEmpty)
    let json = String(decoding: try JSONEncoder().encode(records), as: UTF8.self)
    XCTAssertTrue(json.contains("Canonical pull request diff")); XCTAssertTrue(json.contains("Preserve these tests"))
    let folders = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("private/GitGenerations"), includingPropertiesForKeys: nil)
    XCTAssertTrue(folders.isEmpty)
    XCTAssertTrue(try logs(root, command: "edit").isEmpty)
  }

  @MainActor func testPromptBoundsAndBalancesTruncatedMarkdownFences() async throws {
    let (root, service) = try await fixture(), snapshot = try await service.mergeSnapshot(for: request, at: root)
    let messages = PullRequestDescriptionPrompt.messages(snapshot: snapshot,
      body: "```swift\n" + String(repeating: "a", count: 7_000), instructions: String(repeating: "b", count: 5_000),
      diff: String(repeating: "c", count: 19_000))
    let content = try XCTUnwrap(messages.last?.content)
    XCTAssertTrue(content.contains("…\n```")); XCTAssertFalse(content.contains(String(repeating: "a", count: 6_001)))
    XCTAssertFalse(content.contains(String(repeating: "b", count: 4_001)))
    XCTAssertFalse(content.contains(String(repeating: "c", count: 18_001)))
  }

  @MainActor func testNativeEditorReturnEscapeMultilineAndIME() throws {
    let editor = PullRequestTextEditor.TextView(frame: NSRect(x: 0, y: 0, width: 300, height: 120))
    editor.isRichText = false; editor.isEditable = true
    var saves = 0, cancels = 0
    editor.submit = { saves += 1 }; editor.cancel = { cancels += 1 }
    func key(_ code: UInt16, _ chars: String, _ modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
      try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
        timestamp: 0, windowNumber: 0, context: nil, characters: chars,
        charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code))
    }
    editor.field = .title
    editor.keyDown(with: try key(36, "\r")); editor.keyDown(with: try key(53, "\u{1b}"))
    XCTAssertEqual(saves, 1); XCTAssertEqual(cancels, 1); XCTAssertEqual(editor.string, "")
    editor.field = .body
    editor.keyDown(with: try key(36, "\r")); XCTAssertEqual(editor.string, "\n")
    editor.keyDown(with: try key(36, "\r", .command)); editor.keyDown(with: try key(36, "\r", .control))
    XCTAssertEqual(saves, 3)
    editor.field = .title
    editor.setMarkedText("拼音", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
    XCTAssertTrue(editor.hasMarkedText())
    editor.keyDown(with: try key(36, "\r"))
    XCTAssertEqual(saves, 3, "IME composition must never submit the PR")
    editor.unmarkText(); editor.isEditable = false
    editor.keyDown(with: try key(36, "\r")); XCTAssertEqual(saves, 3)
  }

  @MainActor func testFocusProbeRejectsUnrelatedFirstResponder() {
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
      styleMask: [.titled], backing: .buffered, defer: true)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    let editor = PullRequestTextEditor.TextView(frame: NSRect(x: 0, y: 0, width: 200, height: 80))
    let other = NSTextView(frame: NSRect(x: 0, y: 100, width: 200, height: 80))
    window.contentView?.addSubview(editor); window.contentView?.addSubview(other)
    let probe = PullRequestEditorFocusProbe(); probe.record(editor)
    window.makeFirstResponder(editor); XCTAssertTrue(probe.mayReturnFocus)
    window.makeFirstResponder(other); XCTAssertFalse(probe.mayReturnFocus)
    window.makeFirstResponder(nil); XCTAssertTrue(probe.mayReturnFocus)
  }

  @MainActor func testNativeTitlePasteNormalizationKeepsUndoRedoAndSelection() throws {
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
      styleMask: [.titled], backing: .buffered, defer: true)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    var draft = ""
    let view = PullRequestTextEditor(text: Binding(get: { draft }, set: { draft = $0 }),
      field: .title, focus: nil, submit: {}, cancel: {})
    let coordinator = view.makeCoordinator()
    let editor = PullRequestTextEditor.TextView(frame: NSRect(x: 0, y: 0, width: 300, height: 80))
    editor.isRichText = false; editor.allowsUndo = true; editor.delegate = coordinator
    window.contentView?.addSubview(editor); window.makeFirstResponder(editor)
    editor.insertText("中文\r\n\n标题", replacementRange: NSRange(location: 0, length: 0))
    editor.breakUndoCoalescing()
    XCTAssertEqual(editor.string, "中文 标题"); XCTAssertEqual(draft, "中文 标题")
    XCTAssertEqual(editor.selectedRange(), NSRange(location: 5, length: 0))
    let undo = try XCTUnwrap(editor.undoManager)
    XCTAssertTrue(undo.canUndo); undo.undo()
    XCTAssertEqual(editor.string, ""); XCTAssertEqual(draft, "")
    XCTAssertTrue(undo.canRedo); undo.redo()
    XCTAssertEqual(editor.string, "中文 标题"); XCTAssertEqual(draft, "中文 标题")
  }

  @MainActor func testReopenedPRKeepsFreshRemoteReadInsteadOfOldEditorSnapshot() async throws {
    let (root, service) = try await fixture(), editor = GitHubPREditState(service: service)
    let snapshot = try await service.mergeSnapshot(for: request, at: root)
    editor.begin(.body, snapshot: snapshot, request: request, writable: true); editor.change(.body, text: "first saved")
    editor.save(.body, snapshot: snapshot, request: request, at: root, valid: { true }, writable: { true }, updated: { _ in })
    await editor.operation?.value
    let detail = GitHubPRDetailState(service: service); detail.trackEditor(editor)
    try change(["detailBody": "changed on GitHub"], root)
    await detail.refresh(request, at: root, preferred: .merge, valid: { true }, updated: { _ in })
    XCTAssertNil(detail.acceptEditorChanges(editor))
    XCTAssertEqual(detail.snapshot?.details.body, "changed on GitHub")
    editor.begin(.body, snapshot: try XCTUnwrap(detail.snapshot), request: request, writable: true)
    editor.change(.body, text: "new saved")
    editor.save(.body, snapshot: detail.snapshot, request: request, at: root, valid: { true }, writable: { true }, updated: { _ in })
    await editor.operation?.value
    XCTAssertNotNil(detail.acceptEditorChanges(editor))
    XCTAssertEqual(detail.snapshot?.details.body, "new saved")
  }
}

private actor GenerationEditGate {
  private var continuation: CheckedContinuation<String, Never>?
  func wait() async -> String { await withCheckedContinuation { continuation = $0 } }
  func finish(_ text: String) { continuation?.resume(returning: text); continuation = nil }
}
