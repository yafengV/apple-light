import AppKit
import XCTest
@testable import ShipiOS

@MainActor final class PullRequestCommentAttachmentTests: XCTestCase {
  private let head = String(repeating: "a", count: 40)
  private func pr(_ number: Int = 42) -> GitHubPullRequest {
    .init(number: number, url: "https://github.com/sample/project/pull/\(number)", title: "Feature",
      isDraft: false, headRefName: "feature", baseRefName: "main", isCrossRepository: false, state: "OPEN")
  }
  private func check(_ id: String = "one", link: String? = nil, status: GitHubPRCheckStatus = .failing,
    name: String? = nil, workflow: String? = nil) -> GitHubPRCheck {
    .init(id: id, name: name ?? "CI \(id)", status: status, link: link, description: "Failure \(id)", workflow: workflow)
  }
  private func fixture() async throws -> WorkspaceStore {
    _ = NSApplication.shared
    let root = GitBranchService.canonicalRoot(FileManager.default.temporaryDirectory)
      .appendingPathComponent("pr-fix-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    _ = try await GitReviewService.checked(["init", "-q", "-b", "feature"], at: root)
    let store = WorkspaceStore(dataRoot: root.appendingPathComponent("data"),
      agentExecutable: try AgentTestExecutable.url())
    store.libraryLoaded = true; store.scopeLoaded = true; store.connected = true; store.project = root
    store.library.tasks = [.init(id: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", project: root.path, title: "A", runIDs: ["a-run"]),
      .init(id: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb", project: root.path, title: "B", runIDs: ["b-run"])]
    store.library.taskPullRequests = ["aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa": [pr(), pr(99)], "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb": [pr()]]
    store.selection = "a-run"
    addTeardownBlock { @MainActor in
      await store.shutdown()
      try? FileManager.default.removeItem(at: root)
    }
    return store
  }
  private func request(_ store: WorkspaceStore, taskID: String = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", number: Int = 42) -> GitHubPRChecksRequest {
    .init(taskID: taskID, root: URL(fileURLWithPath: store.library.tasks.first { $0.id == taskID }!.project),
      pullRequest: pr(number), headRevision: head)
  }
  private func attach(_ checks: [GitHubPRCheck], store: WorkspaceStore, taskID: String = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", number: Int = 42) async throws {
    let request = request(store, taskID: taskID, number: number)
    let attached = try await store.attachPullRequestChecks(checks, request: request,
      snapshot: .init(headRevision: head, checks: checks, complete: true, pullRequestState: "OPEN"))
    XCTAssertTrue(attached)
  }
  private func active(_ store: WorkspaceStore, taskID: String = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", protocol api: ModelAPIProtocol = .chatCompletions) {
    let id = store.library.tasks.first { $0.id == taskID }!.runIDs[0]
    let run = AgentRun(id: id, kind: "chat", project: store.library.tasks.first { $0.id == taskID }!.project,
      status: "running", createdAt: 0, updatedAt: 0,
      request: .object(["api_protocol": .string(api.rawValue)]), result: nil)
    store.library.chatRuns.append(run); store.runs.append(run)
  }

  private func thread(_ id: String = "one", resolved: Bool = false, side: String? = "RIGHT", line: Int? = 12) -> GitHubPRReviewThread {
    let comments = [GitHubPRComment(id: id + "-comment", kind: .code, body: "Feedback " + id, author: "reviewer",
      authorType: "User", createdAt: "2026-09-29T10:00:00Z", url: nil, canUpdate: true, canDelete: true),
      GitHubPRComment(id: id + "-reply", kind: .code, body: "Reply " + id, author: "author",
      authorType: "User", createdAt: "2026-09-29T11:00:00Z", url: nil, canUpdate: false, canDelete: false)]
    return .init(id: id, path: "Sources/Main.swift", line: line, originalLine: 10, diffHunk: "@@ -1 +1 @@\n-old\n+new",
      isResolved: resolved, isOutdated: false, canReply: true, canResolve: true, canUnresolve: true,
      comments: comments, diffSide: side, startLine: 8, startDiffSide: side, originalStartLine: 6)
  }
  private func snapshot(_ threads: [GitHubPRReviewThread], number: Int = 42, state: String = "OPEN", head: String? = nil) -> GitHubPRDiscussionSnapshot {
    .init(requestURL: pr(number).url, nodeID: "pr-node", viewer: "reviewer", author: "author", state: state,
      head: head ?? self.head, comments: [], threads: threads, events: [], omittedTypes: [])
  }
  private func attachComments(_ threads: [GitHubPRReviewThread], store: WorkspaceStore,
    taskID: String = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", number: Int = 42) async throws {
    let attached = try await store.attachPullRequestComments(threads, request: request(store, taskID: taskID, number: number),
      snapshot: snapshot(threads, number: number))
    XCTAssertTrue(attached)
  }

  func testOnlyUnresolvedPositionedThreadsAttachAndRepliesAreCaptured() async throws {
    let store = try await fixture()
    var unpositioned = thread("no-line", line: nil)
    unpositioned = .init(id: unpositioned.id, path: unpositioned.path, line: nil, originalLine: nil, diffHunk: "",
      isResolved: false, isOutdated: false, canReply: true, canResolve: true, canUnresolve: false,
      comments: unpositioned.comments, diffSide: "RIGHT")
    let selected = [thread(), thread("resolved", resolved: true), unpositioned, thread("no-side", side: nil)]
    try await attachComments(selected, store: store)
    let draft = try XCTUnwrap(store.pullRequestCheckDraft)
    XCTAssertEqual(draft.comments.map(\.id), ["one"]); XCTAssertTrue(draft.checks.isEmpty)
    XCTAssertTrue(draft.comments[0].body.contains("@author:\nReply one"))
    XCTAssertEqual(draft.comments[0].thread.startLine, 8); XCTAssertEqual(draft.comments[0].thread.startDiffSide, "RIGHT")
    XCTAssertTrue(store.library.chatRuns.isEmpty)
    let cold = try WorkspaceLibrary.load(from: store.dataRoot.appendingPathComponent("workspace.json"))
    XCTAssertEqual(cold.pullRequestCheckDrafts, store.library.pullRequestCheckDrafts)
  }

  func testOutdatedOriginalLocationAttachmentsSurviveColdRestoreAndQueue() async throws {
    let store = try await fixture(), item = thread("outdated", line: nil)
    try await attachComments([item], store: store)
    let attachment = try XCTUnwrap(store.pullRequestCheckDraft?.comments.first)
    XCTAssertEqual(attachment.position?.line, 10); XCTAssertEqual(attachment.position?.startLine, 6)
    let cold = try WorkspaceLibrary.load(from: store.dataRoot.appendingPathComponent("workspace.json"))
    XCTAssertEqual(cold.pullRequestCheckDrafts["aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"]?.comments.first, attachment)
    active(store); store.draft = "Fix outdated feedback"; await store.sendDraft()
    let queued = try XCTUnwrap(store.library.queuedMessages.first)
    XCTAssertEqual(queued.pullRequestChecks?.comments.first?.position, attachment.position)
    XCTAssertNil(queued.pullRequestChecks?.comments.first?.thread.line)
  }

  func testDeduplicationPreservesGuidanceAndManualPromptWhileAutoPromptCanBeReplaced() async throws {
    let store = try await fixture(); store.draft = "My custom instructions"
    try await attachComments([thread()], store: store); XCTAssertEqual(store.draft, "My custom instructions")
    XCTAssertTrue(store.setPullRequestCommentGuidance("  Exact guidance  ", id: "one", taskID: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"))
    try await attachComments([thread(), thread("two")], store: store)
    XCTAssertEqual(store.pullRequestCheckDraft?.comments.count, 2)
    XCTAssertEqual(store.pullRequestCheckDraft?.comments[0].guidance, "Exact guidance")
    XCTAssertEqual(store.draft, "My custom instructions")
    store.draft = ""; try await attachComments([thread()], store: store)
    XCTAssertEqual(store.draft, store.pullRequestCheckDraft?.commentFixPrompt)
    try await attach([check()], store: store)
    XCTAssertEqual(store.draft, store.pullRequestCheckDraft?.ciFixPrompt)
    try await attachComments([thread("three")], store: store)
    XCTAssertEqual(store.draft, store.pullRequestCheckDraft?.commentFixPrompt)
    XCTAssertEqual(store.pullRequestCheckDraft?.checks.count, 1); XCTAssertEqual(store.pullRequestCheckDraft?.comments.count, 3)
  }

  func testRemoveOnlySelectedThreadsClearsOnlyMatchingAutoPromptAndKeepsChecks() async throws {
    let store = try await fixture(); try await attach([check()], store: store)
    try await attachComments([thread(), thread("two")], store: store)
    XCTAssertFalse(store.removePullRequestComments(["one"], taskID: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", request: request(store, number: 99)))
    XCTAssertTrue(store.removePullRequestComments(["one"], taskID: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"))
    XCTAssertFalse(store.draft.isEmpty)
    XCTAssertTrue(store.removePullRequestComments(["two"], taskID: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"))
    XCTAssertTrue(store.draft.isEmpty); XCTAssertEqual(store.pullRequestCheckDraft?.checks.count, 1)
    try await attachComments([thread()], store: store); store.draft = "Keep my words"
    XCTAssertTrue(store.removePullRequestComments(["one"], taskID: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"))
    XCTAssertEqual(store.draft, "Keep my words")
    XCTAssertTrue(store.removePullRequestChecks(store.pullRequestCheckDraft!.keys, taskID: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"))
    XCTAssertNil(store.pullRequestCheckDraft)
  }

  func testAnotherPRReplacesBothKindsAndOtherTaskRemainsIndependent() async throws {
    let store = try await fixture(); try await attach([check()], store: store); try await attachComments([thread()], store: store)
    try await attachComments([thread("other-task")], store: store, taskID: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")
    let other = store.library.pullRequestCheckDrafts["bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"]
    try await attachComments([thread("replacement")], store: store, number: 99)
    XCTAssertEqual(store.pullRequestCheckDraft?.pullRequest.number, 99); XCTAssertTrue(store.pullRequestCheckDraft!.checks.isEmpty)
    XCTAssertEqual(store.pullRequestCheckDraft?.comments.map(\.id), ["replacement"])
    XCTAssertEqual(store.library.pullRequestCheckDrafts["bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"], other)
    XCTAssertEqual(store.selection, "a-run")
  }

  func testStaleHeadForeignThreadAndDraftChangeDuringBranchReadCannotAttach() async throws {
    let store = try await fixture(), item = thread(), scope = request(store)
    var reads = 0
    let stale = try await store.attachPullRequestComments([item], request: scope,
      snapshot: snapshot([item], head: String(repeating: "b", count: 40)), readBranch: { _ in reads += 1; return "feature" })
    let foreign = try await store.attachPullRequestComments([item], request: scope,
      snapshot: snapshot([thread("different")]), readBranch: { _ in reads += 1; return "feature" })
    XCTAssertFalse(stale); XCTAssertFalse(foreign); XCTAssertEqual(reads, 0)
    let late = try await store.attachPullRequestComments([item], request: scope, snapshot: snapshot([item]),
      readBranch: { _ in store.draft = "New text"; return "feature" })
    XCTAssertFalse(late); XCTAssertEqual(store.draft, "New text"); XCTAssertNil(store.pullRequestCheckDraft)
  }

  func testClosedPRWrongBranchAndInvalidAttachmentPreventWrites() async throws {
    let store = try await fixture(), scope = request(store), item = thread()
    for (state, branch) in [("CLOSED", "feature"), ("OPEN", "main")] {
      do { _ = try await store.attachPullRequestComments([item], request: scope, snapshot: snapshot([item], state: state),
        readBranch: { _ in branch }); XCTFail("Unavailable task") } catch {}
    }
    var invalid = item; invalid = .init(id: invalid.id, path: "../outside", line: 12, originalLine: nil, diffHunk: "",
      isResolved: false, isOutdated: false, canReply: true, canResolve: true, canUnresolve: true,
      comments: invalid.comments, diffSide: "RIGHT")
    XCTAssertFalse(PullRequestCommentAttachment(thread: invalid).isValid)
    XCTAssertNil(store.pullRequestCheckDraft)
  }

  func testQueuedSnapshotEditingAndRemovalCannotConsumeNewDraft() async throws {
    let store = try await fixture(); active(store)
    try await attachComments([thread()], store: store)
    let frozen = store.pullRequestCheckDraft; store.draft = "Frozen request"; await store.sendDraft()
    let message = try XCTUnwrap(store.library.queuedMessages.first)
    XCTAssertEqual(message.pullRequestChecks, frozen); XCTAssertNil(store.pullRequestCheckDraft)
    store.editQueuedMessage(message)
    XCTAssertEqual(store.pullRequestCheckDraft, frozen); XCTAssertEqual(store.draft, "Frozen request")
    XCTAssertTrue(store.setPullRequestCommentGuidance("New instruction", id: "one", taskID: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"))
    await store.sendDraft()
    XCTAssertEqual(store.library.queuedMessages.last?.pullRequestChecks?.comments[0].guidance, "New instruction")
    try await attachComments([thread("new")], store: store)
    let newDraft = store.pullRequestCheckDraft
    XCTAssertEqual(message.pullRequestChecks, frozen); XCTAssertNotEqual(message.pullRequestChecks, newDraft)
    let cold = try WorkspaceLibrary.load(from: store.dataRoot.appendingPathComponent("workspace.json"))
    XCTAssertEqual(cold.queuedMessages, store.library.queuedMessages)
  }

  func testLegacyCheckDraftMigrationAndAttachmentDeletion() async throws {
    let store = try await fixture(); try await attach([check()], store: store)
    let draft = try XCTUnwrap(store.pullRequestCheckDraft)
    var value = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(draft)) as? [String: Any])
    value["comments"] = nil; value["generatedPrompt"] = nil
    let old = try JSONDecoder().decode(PullRequestCheckDraft.self, from: JSONSerialization.data(withJSONObject: value))
    XCTAssertTrue(old.comments.isEmpty); XCTAssertNil(old.generatedPrompt); XCTAssertTrue(old.isValid)
    try await attachComments([thread()], store: store)
    store.library.tasks[0].archived = true; store.library.deleteArchivedTasks(["aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"])
    XCTAssertNil(store.library.pullRequestCheckDrafts["aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"])
  }

  private func server(_ log: URL) throws -> (Process, String) {
    let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Fixtures/model_server.py")
    let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    process.arguments = ["-u", script.path]; process.environment = ["CHECKS_REQUEST_LOG": log.path]
    let pipe = Pipe(); process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
    try process.run()
    let port = String(decoding: pipe.fileHandleForReading.availableData, as: UTF8.self)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard Int(port) != nil else { process.terminate(); throw AgentFailure(message: "Fixture did not start") }
    addTeardownBlock { if process.isRunning { process.terminate(); process.waitUntilExit() } }
    return (process, "http://127.0.0.1:\(port)/v1")
  }

  func testBothProtocolsReceiveThreadsRepliesPositionsAndGuidance() async throws {
    for api in [ModelAPIProtocol.chatCompletions, .codexResponses] {
      let store = try await fixture()
      let tasks = store.library.tasks, prs = store.library.taskPullRequests, root = try XCTUnwrap(store.project)
      store.scopeLoaded = false; store.libraryLoaded = false; store.project = nil
      await store.restore()
      store.library.tasks = tasks; store.library.taskPullRequests = prs
      store.project = root; store.scopeLoaded = true; store.connected = true; store.selection = "a-run"
      let log = root.appendingPathComponent("request.jsonl")
      let (_, endpoint) = try server(log)
      var configuration = ModelConfiguration(); configuration.apiProtocol = api
      configuration.baseURL = endpoint; configuration.model = api == .codexResponses ? "gpt-5.4" : "fixture-model"
      try store.saveModelConfiguration(configuration); store.notificationPreferences = .init(timing: .never)
      try await attachComments([thread("selected", line: nil)], store: store)
      XCTAssertTrue(store.setPullRequestCommentGuidance("Minimal change only", id: "selected", taskID: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"))
      let saved = try XCTUnwrap(store.pullRequestCheckDraft)
      XCTAssertNil(saved.comments[0].thread.line)
      XCTAssertEqual(saved.comments[0].position?.line, 10)
      XCTAssertEqual(saved.comments[0].position?.startLine, 6)
      if api == .chatCompletions {
        store.draft = "Check the selected CI"; await store.sendDraft()
      } else {
        let other = root.appendingPathComponent("other")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        store.library.tasks[1].project = other.path; store.project = other; store.selection = "b-run"
        store.draft = "Keep main draft"; store.setTaskWindowDraft("Check selected CI from popout", taskID: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")
        await store.sendTaskWindowDraft("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", mode: .standard)
        XCTAssertEqual(store.selection, "b-run"); XCTAssertEqual(store.draft, "Keep main draft")
      }
      let run = try XCTUnwrap(store.library.chatRuns.last, store.error ?? "No run")
      await store.modelTask(runID: run.id)?.value
      let completed = try XCTUnwrap(store.library.chatRuns.first { $0.id == run.id })
      XCTAssertEqual(completed.status, "succeeded", completed.result?["message"].text ?? "")
      XCTAssertEqual(try completed.request["pull_request_checks"].decode(PullRequestCheckDraft.self), saved)
      XCTAssertNil(store.library.pullRequestCheckDrafts["aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"])
      let received = try String(contentsOf: log, encoding: .utf8)
      XCTAssertTrue(received.contains("Feedback selected")); XCTAssertTrue(received.contains("Reply selected") && received.contains("Minimal change only") && received.contains("RIGHT"))
      XCTAssertTrue(received.contains("sample/project/pull/42")); XCTAssertTrue(received.contains(saved.headRevision))
      XCTAssertTrue(received.contains("start_line") && received.contains("position"))
      XCTAssertEqual(store.library.task(containing: run.id)?.id, "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")
      XCTAssertTrue(store.library.notes[run.id]?.contains("附加的 PR 审查线程") == true)
    }
  }

  func testRealCodexSteeringIncludesThreadsAndPersistsExpandedContext() async throws {
    let store = try await fixture()
    let tasks = store.library.tasks, prs = store.library.taskPullRequests, root = try XCTUnwrap(store.project)
    store.scopeLoaded = false; store.libraryLoaded = false; store.project = nil
    await store.restore(); store.library.tasks = tasks; store.library.taskPullRequests = prs
    store.project = root; store.scopeLoaded = true; store.connected = true; store.selection = "a-run"
    let log = root.appendingPathComponent("steer-request.jsonl"), (_, endpoint) = try server(log)
    var config = ModelConfiguration(); config.apiProtocol = .codexResponses
    config.baseURL = endpoint; config.model = "gpt-5.4"
    try store.saveModelConfiguration(config); store.notificationPreferences = .init(timing: .never)
    await store.startChat("slow-codex", taskID: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")
    let first = try XCTUnwrap(store.library.chatRuns.last, store.error ?? "No initial run")
    let deadline = Date().addingTimeInterval(10)
    while !store.codexTransport.canSteer(taskID: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"), store.activeChatRun(taskID: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa") != nil, Date() < deadline {
      try await Task.sleep(for: .milliseconds(100))
    }
    XCTAssertTrue(store.codexTransport.canSteer(taskID: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"))
    try await attachComments([thread("steered")], store: store)
    let saved = store.pullRequestCheckDraft
    store.followUpBehavior = .steer; store.draft = "steered-inflight-proof"
    await store.sendDraft()
    await store.modelTask(runID: first.id)?.value
    let finished = try XCTUnwrap(store.library.chatRuns.first { $0.id == first.id })
    XCTAssertEqual(finished.status, "succeeded", finished.result?["message"].text ?? "")
    let appended = try XCTUnwrap(finished.codexSteeredMessages.last)
    XCTAssertEqual(appended.pullRequestChecks, saved)
    XCTAssertTrue(appended.text.contains("附加的 PR 审查线程")); XCTAssertTrue(appended.text.contains("Feedback steered"))
    XCTAssertTrue(store.library.queuedMessages.isEmpty); XCTAssertNil(store.pullRequestCheckDraft)
    XCTAssertTrue(try String(contentsOf: log).contains("Feedback steered"))
    XCTAssertTrue(store.library.chatContext(taskID: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa").contains { $0.content.contains("Feedback steered") })
  }
  func testFailedConfigurationAndNonChatActionRetainComments() async throws {
    let store = try await fixture()
    try await attachComments([thread()], store: store)
    let saved = store.pullRequestCheckDraft
    store.modelConfiguration.model = ""; store.modelConfiguration.baseURL = "https://example.invalid/v1"
    await store.sendDraft()
    XCTAssertEqual(store.pullRequestCheckDraft, saved); XCTAssertFalse(store.draft.isEmpty)
    XCTAssertTrue(store.library.chatRuns.isEmpty)
    await store.sendTaskWindowDraft("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", mode: .standard)
    XCTAssertEqual(store.pullRequestCheckDraft, saved)
    store.action = .doctor; await store.sendDraft()
    XCTAssertTrue(store.error?.contains("模型会话") == true); XCTAssertEqual(store.pullRequestCheckDraft, saved)
  }

  func testFailedQueuePersistenceRetainsPromptAndAttachments() async throws {
    let store = try await fixture(); active(store)
    try await attachComments([thread()], store: store)
    let saved = store.pullRequestCheckDraft, prompt = store.draft
    try FileManager.default.removeItem(at: store.dataRoot.appendingPathComponent("workspace.json"))
    try FileManager.default.createDirectory(at: store.dataRoot.appendingPathComponent("workspace.json"), withIntermediateDirectories: false)
    await store.sendDraft()
    XCTAssertTrue(store.library.queuedMessages.isEmpty)
    XCTAssertEqual(store.pullRequestCheckDraft, saved); XCTAssertEqual(store.draft, prompt)
  }

  func testFailedAttachmentGuidanceAndRemovalPersistenceKeepOriginalDraft() async throws {
    let store = try await fixture()
    try await attachComments([thread()], store: store)
    let saved = store.pullRequestCheckDraft, prompt = store.draft
    try FileManager.default.removeItem(at: store.dataRoot.appendingPathComponent("workspace.json"))
    try FileManager.default.createDirectory(at: store.dataRoot.appendingPathComponent("workspace.json"), withIntermediateDirectories: false)
    do {
      try await attachComments([thread("two")], store: store)
      XCTFail("Persistence failure must not install the new attachment")
    } catch {}
    XCTAssertFalse(store.setPullRequestCommentGuidance("Unsaved", id: "one", taskID: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"))
    XCTAssertFalse(store.removePullRequestComments(["one"], taskID: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"))
    XCTAssertEqual(store.pullRequestCheckDraft, saved); XCTAssertEqual(store.draft, prompt)
    XCTAssertNotNil(store.error)
  }

  func testReadOnlyReviewAllowsPreparationAndLateScopeInvalidationCannotAttach() async throws {
    let store = try await fixture()
    store.library.gitPreferences.readOnlyReview = true
    try await attachComments([thread()], store: store)
    let saved = store.pullRequestCheckDraft, prompt = store.draft
    var valid = true
    let attached = try await store.attachPullRequestComments([thread("late")], request: request(store),
      snapshot: snapshot([thread("late")]), valid: { valid }, readBranch: { _ in valid = false; return "feature" })
    XCTAssertFalse(attached); XCTAssertEqual(store.pullRequestCheckDraft, saved); XCTAssertEqual(store.draft, prompt)
    XCTAssertTrue(store.library.chatRuns.isEmpty, "Preparing feedback must not launch a model turn or mutate Git")
  }

  func testQueuedDispatchUsesFrozenCommentSnapshotAndKeepsNewDraft() async throws {
    let store = try await fixture()
    let tasks = store.library.tasks, prs = store.library.taskPullRequests, root = try XCTUnwrap(store.project)
    store.scopeLoaded = false; store.libraryLoaded = false; store.project = nil
    await store.restore(); store.library.tasks = tasks; store.library.taskPullRequests = prs
    store.project = root; store.scopeLoaded = true; store.connected = true; store.selection = "a-run"
    let log = root.appendingPathComponent("queue-request.jsonl"), (_, endpoint) = try server(log)
    var config = ModelConfiguration(); config.baseURL = endpoint; config.model = "fixture-model"
    try store.saveModelConfiguration(config); store.notificationPreferences = .init(timing: .never)
    active(store); try await attachComments([thread("frozen")], store: store)
    store.draft = "Frozen queue"; await store.sendDraft()
    let message = try XCTUnwrap(store.library.queuedMessages.first)
    store.library.chatRuns.removeAll(); store.runs.removeAll()
    try await attachComments([thread("new")], store: store)
    let newDraft = store.pullRequestCheckDraft
    await store.sendQueuedMessage(message)
    let run = try XCTUnwrap(store.library.chatRuns.last, store.error ?? "Missing queue run")
    await store.modelTask(runID: run.id)?.value
    XCTAssertEqual(store.library.chatRuns.last?.status, "succeeded")
    XCTAssertEqual(store.pullRequestCheckDraft, newDraft); XCTAssertEqual(store.draft, newDraft?.fixPrompt)
    XCTAssertTrue(store.library.queuedMessages.isEmpty)
    let received = try String(contentsOf: log, encoding: .utf8)
    XCTAssertTrue(received.contains("Feedback frozen")); XCTAssertFalse(received.contains("Feedback new"))
  }


}
