import AppKit
import XCTest
@testable import ShipiOS

@MainActor final class PullRequestCheckAttachmentTests: XCTestCase {
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
    let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let store = WorkspaceStore(dataRoot: root.appendingPathComponent("data"),
      agentExecutable: repository.appendingPathComponent("target/debug/shipios-agent"))
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

  func testFixAllDeduplicatesByReferenceAttachmentIdentityAndRemovalPreservesPrompt() async throws {
    let store = try await fixture()
    let first = check("one", link: "https://ci.example/job/1")
    let sameLink = check("two", link: first.link)
    let noLink = check("three", name: "shared")
    let sameName = check("four", name: "shared")
    let otherWorkflow = check("five", name: "shared", workflow: "other")
    try await attach([first], store: store)
    let token = try XCTUnwrap(store.pullRequestCheckDraft?.id)
    try await attach([first, sameLink, noLink, sameName, otherWorkflow, check("pass", status: .passing)], store: store)
    let draft = try XCTUnwrap(store.pullRequestCheckDraft)
    XCTAssertEqual(draft.checks.map(\.id), ["one", "three", "five"])
    XCTAssertNotEqual(draft.id, token); XCTAssertEqual(store.draft, draft.fixPrompt)
    XCTAssertTrue(store.draft.contains("gh run view")); XCTAssertTrue(store.draft.contains("提交并推送"))
    XCTAssertTrue(store.removePullRequestChecks([first.attachmentKey], taskID: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", request: request(store)))
    XCTAssertEqual(store.pullRequestCheckDraft?.checks.count, 2)
    XCTAssertTrue(store.removePullRequestChecks(draft.keys, taskID: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", request: request(store)))
    XCTAssertNil(store.pullRequestCheckDraft); XCTAssertEqual(store.draft, draft.fixPrompt)
    XCTAssertTrue(store.library.chatRuns.isEmpty)
  }

  func testPRReplacementTaskIsolationAndColdPersistence() async throws {
    let store = try await fixture()
    try await attach([check()], store: store)
    let old = store.pullRequestCheckDraft
    try await attach([check("second")], store: store, taskID: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")
    XCTAssertEqual(store.selection, "a-run"); XCTAssertEqual(store.pullRequestCheckDraft, old)
    try await attach([check("replacement")], store: store, number: 99)
    XCTAssertEqual(store.pullRequestCheckDraft?.pullRequest.number, 99)
    XCTAssertEqual(store.pullRequestCheckDraft?.checks.map(\.id), ["replacement"])
    XCTAssertFalse(store.removePullRequestChecks([check("replacement").attachmentKey], taskID: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", request: request(store)))
    let cold = try WorkspaceLibrary.load(from: store.dataRoot.appendingPathComponent("workspace.json"))
    XCTAssertEqual(cold.pullRequestCheckDrafts, store.library.pullRequestCheckDrafts)
    XCTAssertTrue(try JSONDecoder().decode(WorkspaceLibrary.self, from: Data("{}".utf8)).pullRequestCheckDrafts.isEmpty)
  }

  func testFixEligibilityUsesActualTaskAndBranchButAllowsRemovingAfterClosure() async throws {
    let store = try await fixture(), request = request(store)
    XCTAssertNil(store.pullRequestCheckFixReason(request, state: "OPEN", branch: "feature"))
    XCTAssertNotNil(store.pullRequestCheckFixReason(request, state: "OPEN", branch: "main"))
    XCTAssertNotNil(store.pullRequestCheckFixReason(request, state: "OPEN", branch: nil))
    XCTAssertNotNil(store.pullRequestCheckFixReason(request, state: "CLOSED", branch: "feature"))
    XCTAssertNotNil(store.pullRequestCheckFixReason(request, state: "MERGED", branch: "feature"))
    store.library.gitPreferences.readOnlyReview = true
    try await attach([check()], store: store)
    store.library.taskPullRequests["aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"] = []
    XCTAssertNotNil(store.pullRequestCheckFixReason(request, state: "OPEN", branch: "feature"))
    XCTAssertTrue(store.removePullRequestChecks([check().attachmentKey], taskID: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", request: request))
    store.library.tasks[0].archived = true
    XCTAssertNotNil(store.pullRequestCheckFixReason(request, state: "OPEN", branch: "feature"))
  }

  func testChangedGitBranchDisablesFixWithoutChangingCheckout() async throws {
    let store = try await fixture(), root = try XCTUnwrap(store.project)
    _ = try await GitReviewService.checked(["symbolic-ref", "HEAD", "refs/heads/other"], at: root)
    do { try await attach([check()], store: store); XCTFail("Wrong branch") } catch {
      XCTAssertTrue(error.localizedDescription.contains("分支"))
    }
    XCTAssertNil(store.pullRequestCheckDraft)
    let branch = try await WorkspaceStore.pullRequestCheckBranch(at: root)
    XCTAssertEqual(branch, "other")
  }

  func testStaleHeadMissingCheckAndCancellationDoNotPrepareDraft() async throws {
    let store = try await fixture(), request = request(store), selected = check()
    var reads = 0
    let wrongHead = try await store.attachPullRequestChecks([selected], request: request,
      snapshot: .init(headRevision: String(repeating: "b", count: 40), checks: [selected], complete: true),
      readBranch: { _ in reads += 1; return "feature" })
    let missing = try await store.attachPullRequestChecks([selected], request: request,
      snapshot: .init(headRevision: head, checks: [], complete: true), readBranch: { _ in reads += 1; return "feature" })
    XCTAssertFalse(wrongHead); XCTAssertFalse(missing); XCTAssertEqual(reads, 0)
    let cancelled = Task { @MainActor in
      try await store.attachPullRequestChecks([selected], request: request,
        snapshot: .init(headRevision: self.head, checks: [selected], complete: true, pullRequestState: "OPEN"),
        readBranch: { _ in try await Task.sleep(for: .seconds(2)); return "feature" })
    }
    cancelled.cancel()
    do { let result = try await cancelled.value; XCTAssertFalse(result) } catch { XCTAssertTrue(error is CancellationError) }
    XCTAssertNil(store.pullRequestCheckDraft)
  }

  func testDraftEditsAndRemovedTaskDuringBranchReadRejectLateAttachment() async throws {
    let store = try await fixture(), request = request(store), selected = check()
    let snapshot = GitHubPRChecksSnapshot(headRevision: head, checks: [selected], complete: true, pullRequestState: "OPEN")
    let changed = try await store.attachPullRequestChecks([selected], request: request, snapshot: snapshot,
      readBranch: { _ in store.draft = "New user text"; return "feature" })
    XCTAssertFalse(changed); XCTAssertEqual(store.draft, "New user text"); XCTAssertNil(store.pullRequestCheckDraft)
    do {
      _ = try await store.attachPullRequestChecks([selected], request: request, snapshot: snapshot,
        readBranch: { _ in store.library.tasks.removeAll { $0.id == "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa" }; return "feature" })
      XCTFail("Removed task")
    } catch { XCTAssertTrue(error.localizedDescription.contains("工作区")) }
    XCTAssertNil(store.library.pullRequestCheckDrafts["aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"])
  }

  func testInvalidationAndConcurrentReplacementPreserveNewestDraft() async throws {
    let store = try await fixture(), request = request(store), selected = check()
    let snapshot = GitHubPRChecksSnapshot(headRevision: head, checks: [selected], complete: true, pullRequestState: "OPEN")
    var valid = true
    let result = try await store.attachPullRequestChecks([selected], request: request, snapshot: snapshot,
      valid: { valid }, readBranch: { _ in valid = false; return "feature" })
    XCTAssertFalse(result)
    let late = try await store.attachPullRequestChecks([selected], request: request, snapshot: snapshot,
      readBranch: { _ in try await self.attach([self.check("new")], store: store); return "feature" })
    XCTAssertFalse(late); XCTAssertEqual(store.pullRequestCheckDraft?.checks.first?.id, "new")
  }

  func testUnsafeLinksAreSanitizedAndMalformedPayloadIsRejected() async throws {
    let store = try await fixture()
    try await attach([check(link: "https://secret@ci.example/job")], store: store)
    let saved = try XCTUnwrap(store.pullRequestCheckDraft)
    XCTAssertNil(saved.checks.first?.link)
    let prompt = try store.promptWithPullRequestChecks("", checks: saved, taskID: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")
    XCTAssertTrue(prompt.contains("先核对最新运行")); XCTAssertFalse(prompt.contains("secret@"))
    var broken = saved; broken.checks = [check(status: .passing)]
    XCTAssertThrowsError(try store.promptWithPullRequestChecks("Fix", checks: broken, taskID: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"))
    store.library.tasks[0].project += "/changed"
    XCTAssertThrowsError(try store.promptWithPullRequestChecks("Fix", checks: saved, taskID: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"))
  }

  func testMainAndTaskWindowQueueFreezeContextsAndPreserveOtherDrafts() async throws {
    let store = try await fixture()
    active(store); active(store, taskID: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")
    try await attach([check()], store: store)
    let savedA = store.pullRequestCheckDraft
    try await attach([check("two")], store: store, taskID: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")
    let savedB = store.library.pullRequestCheckDrafts["bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"]
    store.draft = "Fix A"; store.setTaskWindowDraft("Fix B", taskID: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")
    await store.sendDraft()
    XCTAssertNil(store.pullRequestCheckDraft); XCTAssertEqual(store.library.pullRequestCheckDrafts["bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"], savedB)
    XCTAssertEqual(store.library.queuedMessages.first?.text, "Fix A")
    XCTAssertEqual(store.library.queuedMessages.first?.pullRequestChecks, savedA)
    await store.sendTaskWindowDraft("bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb", mode: .standard)
    XCTAssertEqual(store.library.queuedMessages.map(\.taskID), ["aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"])
    XCTAssertEqual(store.library.queuedMessages.last?.pullRequestChecks, savedB)
    XCTAssertEqual(store.selection, "a-run"); XCTAssertTrue(store.draft.isEmpty)
    let cold = try WorkspaceLibrary.load(from: store.dataRoot.appendingPathComponent("workspace.json"))
    XCTAssertEqual(cold.queuedMessages, store.library.queuedMessages)
    store.editQueuedMessage(store.library.queuedMessages[0])
    XCTAssertEqual(store.draft, "Fix A"); XCTAssertEqual(store.pullRequestCheckDraft, savedA)
    XCTAssertEqual(store.library.queuedMessages.map(\.taskID), ["bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"])
    _ = store.removePullRequestChecks(savedA!.keys, taskID: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")
    await store.sendDraft()
    XCTAssertNil(store.library.queuedMessages.last?.pullRequestChecks)
  }

  func testQueueEditCannotReplaceExistingUnsentCheckSelection() async throws {
    let store = try await fixture()
    try await attach([check()], store: store)
    let draft = store.pullRequestCheckDraft; store.draft = ""
    let queued = QueuedMessage(taskID: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", text: "Queued text")
    store.library.queuedMessages.append(queued)
    store.editQueuedMessage(queued)
    XCTAssertEqual(store.library.queuedMessages, [queued]); XCTAssertEqual(store.pullRequestCheckDraft, draft)
    XCTAssertTrue(store.error?.contains("现有草稿") == true)
  }

  func testFailedConfigurationAndNonChatActionRetainChecks() async throws {
    let store = try await fixture()
    try await attach([check()], store: store)
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
    try await attach([check()], store: store)
    let saved = store.pullRequestCheckDraft, prompt = store.draft
    try FileManager.default.removeItem(at: store.dataRoot.appendingPathComponent("workspace.json"))
    try FileManager.default.createDirectory(at: store.dataRoot.appendingPathComponent("workspace.json"), withIntermediateDirectories: false)
    await store.sendDraft()
    XCTAssertTrue(store.library.queuedMessages.isEmpty)
    XCTAssertEqual(store.pullRequestCheckDraft, saved); XCTAssertEqual(store.draft, prompt)
  }

  func testDeletionCleansOnlyOwningTaskAndOldQueueDecodes() async throws {
    let store = try await fixture()
    try await attach([check()], store: store); try await attach([check("two")], store: store, taskID: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")
    let savedB = store.library.pullRequestCheckDrafts["bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"]
    store.library.tasks[0].archived = true
    store.library.deleteArchivedTasks(["aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"])
    XCTAssertNil(store.library.pullRequestCheckDrafts["aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"]); XCTAssertEqual(store.library.pullRequestCheckDrafts["bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"], savedB)
    let old = QueuedMessage(taskID: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb", text: "Old")
    let decoded = try JSONDecoder().decode(QueuedMessage.self, from: JSONEncoder().encode(old))
    XCTAssertNil(decoded.pullRequestChecks)
    XCTAssertFalse(store.focusPullRequestCheckTaskWindow("missing"))
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

  func testBothProtocolsReceiveSelectedCheckContextThroughRealSendPaths() async throws {
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
      try await attach([check(link: "https://ci.example/job/actual")], store: store)
      let saved = try XCTUnwrap(store.pullRequestCheckDraft)
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
      XCTAssertTrue(received.contains("CI one")); XCTAssertTrue(received.contains("https://ci.example/job/actual"))
      XCTAssertTrue(received.contains("sample/project/pull/42")); XCTAssertTrue(received.contains(saved.headRevision))
      XCTAssertEqual(store.library.task(containing: run.id)?.id, "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")
      XCTAssertTrue(store.library.notes[run.id]?.contains("附加的 PR 失败检查") == true)
    }
  }

  func testQueuedDispatchUsesFrozenCheckSnapshotAndKeepsNewDraft() async throws {
    let store = try await fixture()
    let tasks = store.library.tasks, prs = store.library.taskPullRequests, root = try XCTUnwrap(store.project)
    store.scopeLoaded = false; store.libraryLoaded = false; store.project = nil
    await store.restore(); store.library.tasks = tasks; store.library.taskPullRequests = prs
    store.project = root; store.scopeLoaded = true; store.connected = true; store.selection = "a-run"
    let log = root.appendingPathComponent("queue-request.jsonl"), (_, endpoint) = try server(log)
    var config = ModelConfiguration(); config.baseURL = endpoint; config.model = "fixture-model"
    try store.saveModelConfiguration(config); store.notificationPreferences = .init(timing: .never)
    active(store); try await attach([check("frozen")], store: store)
    store.draft = "Frozen queue"; await store.sendDraft()
    let message = try XCTUnwrap(store.library.queuedMessages.first)
    store.library.chatRuns.removeAll(); store.runs.removeAll()
    try await attach([check("new")], store: store)
    let newDraft = store.pullRequestCheckDraft
    await store.sendQueuedMessage(message)
    let run = try XCTUnwrap(store.library.chatRuns.last, store.error ?? "Missing queue run")
    await store.modelTask(runID: run.id)?.value
    XCTAssertEqual(store.library.chatRuns.last?.status, "succeeded")
    XCTAssertEqual(store.pullRequestCheckDraft, newDraft); XCTAssertEqual(store.draft, newDraft?.fixPrompt)
    XCTAssertTrue(store.library.queuedMessages.isEmpty)
    let received = try String(contentsOf: log, encoding: .utf8)
    XCTAssertTrue(received.contains("CI frozen")); XCTAssertFalse(received.contains("CI new"))
  }

  func testRealCodexSteeringIncludesChecksAndPersistsExpandedContext() async throws {
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
    try await attach([check("steered")], store: store)
    let saved = store.pullRequestCheckDraft
    store.followUpBehavior = .steer; store.draft = "steered-inflight-proof"
    await store.sendDraft()
    await store.modelTask(runID: first.id)?.value
    let finished = try XCTUnwrap(store.library.chatRuns.first { $0.id == first.id })
    XCTAssertEqual(finished.status, "succeeded", finished.result?["message"].text ?? "")
    let appended = try XCTUnwrap(finished.codexSteeredMessages.last)
    XCTAssertEqual(appended.pullRequestChecks, saved)
    XCTAssertTrue(appended.text.contains("附加的 PR 失败检查")); XCTAssertTrue(appended.text.contains("CI steered"))
    XCTAssertTrue(store.library.queuedMessages.isEmpty); XCTAssertNil(store.pullRequestCheckDraft)
    XCTAssertTrue(try String(contentsOf: log).contains("CI steered"))
    XCTAssertTrue(store.library.chatContext(taskID: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa").contains { $0.content.contains("CI steered") })
  }

}
