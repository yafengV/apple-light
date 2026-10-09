import AppKit
import XCTest
@testable import ShipiOS

final class CodexNativeForkTests: XCTestCase {
  private var server: Process!
  private var endpoint = ""
  private var trace = FileManager.default.temporaryDirectory.appendingPathComponent("native-fork-http-\(UUID()).jsonl")
  override func setUpWithError() throws {
    server = Process()
    server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().appendingPathComponent("Fixtures/model_server.py")
    server.arguments = ["-u", fixture.path]
    server.environment = ["FIXTURE_EVENT_LOG": trace.path]
    let pipe = Pipe()
    server.standardOutput = pipe; server.standardError = FileHandle.nullDevice
    try server.run()
    let port = String(decoding: pipe.fileHandleForReading.availableData, as: UTF8.self)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard Int(port) != nil else { throw AgentFailure(message: "Local fixture could not start") }
    endpoint = "http://127.0.0.1:\(port)/v1"
  }
  override func tearDown() {
    if server?.isRunning == true { server.terminate(); server.waitUntilExit() }
    try? FileManager.default.removeItem(at: trace)
  }

  private func modelRequestCount() throws -> Int {
    guard FileManager.default.fileExists(atPath: trace.path) else { return 0 }
    return try String(contentsOf: trace).split(separator: "\n").map {
      try JSONDecoder().decode(JSONValue.self, from: Data($0.utf8))
    }.filter { $0["phase"].text == "post" }.count
  }

  @MainActor private func fixture() async throws -> (WorkspaceStore, URL, URL) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("native-fork-\(UUID())")
      .resolvingSymlinksInPath().standardizedFileURL
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    let project = root.appendingPathComponent("Project")
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    let agent = try AgentTestExecutable.url()
    let store = WorkspaceStore(dataRoot: root.appendingPathComponent("Data"), agentExecutable: agent)
    await store.restore(); await store.open(project)
    var config = ModelConfiguration()
    config.baseURL = endpoint; config.model = "gpt-5.4"; config.apiProtocol = .codexResponses
    try store.saveModelConfiguration(config)
    store.notificationPreferences = .init(timing: .never)
    return (store, project, agent)
  }

  @MainActor private func send(_ prompt: String, store: WorkspaceStore) async throws -> AgentRun {
    let started = await store.startChat(prompt)
    let id = try XCTUnwrap(started, store.error ?? "No actual Core run")
    await store.modelTask(runID: id)?.value
    let run = try XCTUnwrap(store.library.chatRuns.first { $0.id == id })
    guard run.status == "succeeded" else {
      throw AgentFailure(message: "Core fixture run failed: \(run.result?.pretty ?? store.error ?? run.status)")
    }
    XCTAssertNotNil(run.result?["codex_turn_id"].text)
    return run
  }

  @MainActor func testNativeForkRetainsToolHistoryAndFixedBoundaryAcrossRestart() async throws {
    _ = NSApplication.shared
    let (store, project, agent) = try await fixture()
    let first = try await send("codex-handoff-cwd-probe", store: store)
    let parent = try XCTUnwrap(store.selectedTask)
    XCTAssertEqual(parent.codexWorkspacePath, project.path)
    XCTAssertNotNil(store.codexConversationPath(for: parent), "Use the real camelCase project-owned reference")
    store.newBrowserTab(in: .right)
    store.pinWorkspaceTab(try XCTUnwrap(store.focusedWorkspaceContentTab?.id))
    let browserContext = try XCTUnwrap(store.pinnedBrowserActionContext(
      try XCTUnwrap(store.library.pinnedContentTabs.first).id))
    let requestsBeforeFork = try modelRequestCount()
    let created = await store.forkPinnedBrowser(browserContext, to: .currentWorkspace)
    let fork = try XCTUnwrap(created)
    XCTAssertEqual(fork.codexForkOrigin?.throughTurnID, first.result?["codex_turn_id"].text)
    XCTAssertNotNil(fork.codexThreadID, "The menu creates the actual Core fork before continuation")
    XCTAssertNotEqual(fork.codexThreadID, parent.codexThreadID)
    XCTAssertTrue(store.codexTransport.isConnected(taskID: fork.id))
    let initialForkPath = try XCTUnwrap(store.codexConversationPath(for: fork))
    XCTAssertTrue(try String(contentsOf: initialForkPath).contains("forked_from_id"))
    XCTAssertEqual(fork.title, parent.title)
    XCTAssertNil(store.activeRun(taskID: fork.id), "Creating a fork must not submit a model turn")
    XCTAssertEqual(try modelRequestCount(), requestsBeforeFork, "No model HTTP turn is sent by the fork menu")
    store.selectTask(parent)
    _ = try await send("later-source-proof", store: store)
    store.draft = "preserve source draft"
    let dataRoot = store.dataRoot
    await store.shutdown()

    let reopened = WorkspaceStore(dataRoot: dataRoot, agentExecutable: agent)
    await reopened.restore(); await reopened.open(project)
    let restoredFork = try XCTUnwrap(reopened.library.tasks.first { $0.id == fork.id })
    reopened.selectTask(restoredFork)
    let continued = try await send("skill-dependency-request-echo", store: reopened)
    let body = try JSONDecoder().decode(JSONValue.self,
      from: Data(try XCTUnwrap(continued.result?["response"].text).utf8))
    XCTAssertTrue(body.pretty.contains("swift-handoff-cwd-call"))
    XCTAssertTrue(body.pretty.contains("function_call_output"), "Native fork retains actual command output")
    XCTAssertFalse(body.pretty.contains("later-source-proof"), "Fork boundary must not advance while closed")
    let child = try XCTUnwrap(reopened.selectedTask)
    XCTAssertNotNil(child.codexThreadID)
    XCTAssertNotEqual(child.codexThreadID, parent.codexThreadID)
    let path = try XCTUnwrap(reopened.codexConversationPath(for: child))
    let history = try String(contentsOf: path)
    XCTAssertTrue(history.contains("forked_from_id"))
    XCTAssertTrue(history.contains(try XCTUnwrap(parent.codexThreadID)))
    XCTAssertEqual(reopened.library.drafts[parent.id], "preserve source draft")
    let childThread = child.codexThreadID
    // Each historical window fork creates its own actual Core thread before continuation.
    let historical = try await reopened.forkTaskWindowConversation(child.id, through: child.runIDs[0])
    let nested = try await reopened.forkTaskWindowConversation(historical.id, through: historical.runIDs[0])
    XCTAssertNotNil(historical.codexThreadID)
    XCTAssertNotNil(nested.codexThreadID)
    XCTAssertNotEqual(nested.codexThreadID, historical.codexThreadID)
    XCTAssertEqual(nested.codexForkOrigin?.taskID, historical.id)
    XCTAssertEqual(nested.codexForkOrigin?.threadID, historical.codexThreadID)
    reopened.selectTask(nested)
    let nestedResult = try await send("skill-dependency-request-echo", store: reopened)
    let nestedBody = try JSONDecoder().decode(JSONValue.self,
      from: Data(try XCTUnwrap(nestedResult.result?["response"].text).utf8))
    XCTAssertTrue(nestedBody.pretty.contains("function_call_output"), "Preserve grandparent's actual tool output")
    let nestedInput = try nestedBody["input"].decode([JSONValue].self)
    XCTAssertEqual(nestedInput.filter { $0["role"].text == "user"
      && $0.pretty.contains("skill-dependency-request-echo") }.count, 1,
      "Do not inherit the started child's later prompt when forking an older inherited turn")
    await reopened.shutdown()

    let resumed = WorkspaceStore(dataRoot: dataRoot, agentExecutable: agent)
    await resumed.restore(); await resumed.open(project)
    resumed.selectTask(try XCTUnwrap(resumed.library.tasks.first { $0.id == fork.id }))
    _ = try await send("followup after native fork", store: resumed)
    XCTAssertEqual(resumed.selectedTask?.codexThreadID, childThread, "Resume the child; do not fork again")
    await resumed.shutdown()
  }

  @MainActor func testHandoffKeepsNativeThreadToolHistoryAndForksAcrossCheckoutHistory() async throws {
    let (store, project, agent) = try await fixture()
    do {
      _ = try await GitReviewService.checked(["init", "-q"], at: project)
      _ = try await GitReviewService.checked(["config", "user.name", "Fixture"], at: project)
      _ = try await GitReviewService.checked(["config", "user.email", "fixture@example.invalid"], at: project)
      try Data("initial\n".utf8).write(to: project.appendingPathComponent("tracked"))
      _ = try await GitReviewService.checked(["add", "."], at: project)
      _ = try await GitReviewService.checked(["commit", "-qm", "Initial"], at: project)
      let first = try await send("codex-handoff-cwd-probe", store: store)
      let source = try XCTUnwrap(store.selectedTask)
      let threadID = try XCTUnwrap(source.codexThreadID)
      let historyWorkspace = try XCTUnwrap(source.codexWorkspacePath)
      let originalPath = try XCTUnwrap(store.codexConversationPath(for: source))
      let moved = await store.handOffTaskToWorktree(source.id)
      XCTAssertTrue(moved, store.worktreeError ?? "")
      let movedTask = try XCTUnwrap(store.library.tasks.first { $0.id == source.id })
      XCTAssertNotEqual(movedTask.project, project.path)
      XCTAssertTrue(store.canForkTaskWindow(source.id), "Moving a task must not disable historical fork points")
      let second = try await send("codex-handoff-cwd-probe-local skill-dependency-request-echo", store: store)
      let body = try JSONDecoder().decode(JSONValue.self,
        from: Data(try XCTUnwrap(second.result?["response"].text).utf8))
      let input = try body["input"].decode([JSONValue].self)
      XCTAssertTrue(input.contains { $0["type"].text == "function_call_output"
        && $0["call_id"].text == "swift-handoff-cwd-call"
        && $0.pretty.contains(project.path) }, "Preserve native source tool output in its original directory")
      XCTAssertTrue(input.contains { $0["type"].text == "function_call_output"
        && $0["call_id"].text == "swift-handoff-local-call" && $0.pretty.contains(movedTask.project) })
      XCTAssertEqual(store.selectedTask?.codexThreadID, threadID)
      XCTAssertEqual(store.selectedTask?.codexWorkspacePath, historyWorkspace)
      XCTAssertEqual(store.codexConversationPath(for: try XCTUnwrap(store.selectedTask)), originalPath)
      let fork = try await store.forkTaskWindowConversation(source.id, through: first.id)
      XCTAssertEqual(store.taskWindowRuns(fork.id).first?.project, project.path,
        "The copied execution keeps its actual historical directory")
      XCTAssertEqual(fork.project, movedTask.project)
      store.selectTask(fork)
      let inherited = try await send("skill-dependency-request-echo", store: store)
      let forkBody = try JSONDecoder().decode(JSONValue.self,
        from: Data(try XCTUnwrap(inherited.result?["response"].text).utf8))
      XCTAssertTrue(forkBody.pretty.contains("swift-handoff-cwd-call"))
      XCTAssertFalse(forkBody.pretty.contains("swift-handoff-local-call"), "Keep the selected old boundary")
      XCTAssertNotEqual(store.selectedTask?.codexThreadID, threadID)
      store.selectTask(try XCTUnwrap(store.library.tasks.first { $0.id == source.id }))
      let local = await store.handOffTaskToLocal(source.id)
      XCTAssertTrue(local, store.worktreeError ?? "")
      let returned = try await send("codex-handoff-cwd-probe-return skill-dependency-request-echo", store: store)
      let returnedBody = try JSONDecoder().decode(JSONValue.self,
        from: Data(try XCTUnwrap(returned.result?["response"].text).utf8))
      XCTAssertTrue(returnedBody.pretty.contains("swift-handoff-local-call"))
      XCTAssertTrue(returnedBody.pretty.contains(project.path))
      XCTAssertEqual(store.selectedTask?.codexThreadID, threadID)
      let dataRoot = store.dataRoot
      await store.shutdown()
      let reopened = WorkspaceStore(dataRoot: dataRoot, agentExecutable: agent)
      do {
        await reopened.restore()
        let current = try XCTUnwrap(reopened.library.tasks.first { $0.id == source.id })
        let selected = await reopened.selectTaskAwaitingScope(current)
        XCTAssertTrue(selected)
        _ = try await send("skill-dependency-request-echo", store: reopened)
        XCTAssertEqual(reopened.selectedTask?.codexThreadID, threadID)
        XCTAssertTrue(reopened.canForkConversation)
        let nestedResult = await reopened.forkConversation(through: second.id)
        let nested = try XCTUnwrap(nestedResult, reopened.error ?? "")
        XCTAssertEqual(nested.project, project.path)
        let nestedRun = try await send("skill-dependency-request-echo", store: reopened)
        let nestedBody = try JSONDecoder().decode(JSONValue.self,
          from: Data(try XCTUnwrap(nestedRun.result?["response"].text).utf8))
        XCTAssertTrue(nestedBody.pretty.contains("swift-handoff-cwd-call"))
        XCTAssertTrue(nestedBody.pretty.contains("swift-handoff-local-call"))
        XCTAssertFalse(nestedBody.pretty.contains("swift-handoff-return-call"))
        XCTAssertTrue(reopened.canForkConversation, "Local forks retain their inherited directory provenance")
        let nextResult = await reopened.forkConversation(through: nested.runIDs[1])
        let next = try XCTUnwrap(nextResult)
        XCTAssertEqual(next.project, project.path)
        let nextRun = try await send("skill-dependency-request-echo", store: reopened)
        XCTAssertTrue(nextRun.result?["response"].text?.contains("swift-handoff-local-call") == true)
        XCTAssertFalse(nextRun.result?["response"].text?.contains("swift-handoff-return-call") == true)
        await reopened.shutdown()
      } catch { await reopened.shutdown(); throw error }
    } catch { await store.shutdown(); throw error }
  }

  @MainActor func testSharedHandoffResumesOriginalNativeHistoryAfterCheckoutIsPruned() async throws {
    let (store, project, agent) = try await fixture()
    do {
      _ = try await GitReviewService.checked(["init", "-q"], at: project)
      _ = try await GitReviewService.checked(["config", "user.name", "Fixture"], at: project)
      _ = try await GitReviewService.checked(["config", "user.email", "fixture@example.invalid"], at: project)
      try Data("initial\n".utf8).write(to: project.appendingPathComponent("tracked"))
      _ = try await GitReviewService.checked(["add", "."], at: project)
      _ = try await GitReviewService.checked(["commit", "-qm", "Initial"], at: project)
      store.library.newTaskEnvironmentSelections[project.path] = WorktreeEnvironmentChoice.none
      _ = try await send("codex-handoff-cwd-probe", store: store)
      let local = try XCTUnwrap(store.selectedTask)
      let created = await store.forkTaskToNewWorktree(local.id)
      let owner = try XCTUnwrap(created)
      _ = try await send("codex-handoff-cwd-probe-local", store: store)
      let childResult = await store.forkConversation()
      let child = try XCTUnwrap(childResult)
      _ = try await send("skill-dependency-request-echo", store: store)
      let startedChild = try XCTUnwrap(store.selectedTask)
      let nativeID = try XCTUnwrap(startedChild.codexThreadID)
      let historyWorkspace = try XCTUnwrap(startedChild.codexWorkspacePath)
      XCTAssertEqual(historyWorkspace, owner.project)
      let historyPath = try XCTUnwrap(store.codexConversationPath(for: startedChild))
      let handedOff = await store.handOffTaskToLocal(child.id)
      XCTAssertTrue(handedOff, store.worktreeError ?? "")
      XCTAssertEqual(store.selectedTask?.project, project.path)
      await store.pruneManagedWorktreeIfEligible(owner.id, dueToLimit: true)
      XCTAssertFalse(FileManager.default.fileExists(atPath: owner.project))
      XCTAssertEqual(store.library.managedWorktree(forTaskID: child.id)?.archivedPruned, true)
      let dataRoot = store.dataRoot
      await store.shutdown()
      let reopened = WorkspaceStore(dataRoot: dataRoot, agentExecutable: agent)
      do {
        await reopened.restore()
        let target = try XCTUnwrap(reopened.library.tasks.first { $0.id == child.id })
        let opened = await reopened.selectTaskAwaitingScope(target)
        XCTAssertTrue(opened)
        let returned = try await send("codex-handoff-cwd-probe-return skill-dependency-request-echo", store: reopened)
        let body = try JSONDecoder().decode(JSONValue.self,
          from: Data(try XCTUnwrap(returned.result?["response"].text).utf8))
        let input = try body["input"].decode([JSONValue].self)
        XCTAssertTrue(input.contains { $0["type"].text == "function_call_output"
          && $0["call_id"].text == "swift-handoff-local-call" && $0.pretty.contains(owner.project) })
        XCTAssertTrue(input.contains { $0["type"].text == "function_call_output"
          && $0["call_id"].text == "swift-handoff-return-call" && $0.pretty.contains(project.path) })
        XCTAssertEqual(reopened.selectedTask?.codexThreadID, nativeID)
        XCTAssertEqual(reopened.selectedTask?.codexWorkspacePath, historyWorkspace)
        XCTAssertEqual(reopened.codexConversationPath(for: try XCTUnwrap(reopened.selectedTask)), historyPath)
        XCTAssertFalse(FileManager.default.fileExists(atPath: owner.project), "Resume must not recreate old execution cwd")
        XCTAssertTrue(reopened.canForkConversation)
        let continuedResult = await reopened.forkConversation()
        let continued = try XCTUnwrap(continuedResult)
        XCTAssertEqual(continued.project, project.path)
        _ = try await send("skill-dependency-request-echo", store: reopened)
        XCTAssertNotEqual(reopened.selectedTask?.codexThreadID, nativeID)
        await reopened.shutdown()
      } catch { await reopened.shutdown(); throw error }
    } catch { await store.shutdown(); throw error }
  }

  @MainActor func testSameManagedCheckoutForkPreservesNativeHistoryAndSharedLifetime() async throws {
    let (store, project, agent) = try await fixture()
    do {
      _ = try await GitReviewService.checked(["init", "-q"], at: project)
      _ = try await GitReviewService.checked(["config", "user.name", "Fixture"], at: project)
      _ = try await GitReviewService.checked(["config", "user.email", "fixture@example.invalid"], at: project)
      try Data("initial\n".utf8).write(to: project.appendingPathComponent("tracked"))
      _ = try await GitReviewService.checked(["add", "."], at: project)
      _ = try await GitReviewService.checked(["commit", "-qm", "Initial"], at: project)
      store.library.newTaskEnvironmentSelections[project.path] = WorktreeEnvironmentChoice.none
      _ = try await send("codex-handoff-cwd-probe", store: store)
      let local = try XCTUnwrap(store.selectedTask)
      let created = await store.forkTaskToNewWorktree(local.id)
      let parent = try XCTUnwrap(created, store.error ?? "")
      _ = try await send("codex-handoff-cwd-probe", store: store)
      let startedParent = try XCTUnwrap(store.selectedTask)
      store.setTaskWindowDraft("preserve shared source draft", taskID: parent.id)
      XCTAssertTrue(store.canForkConversation)
      let childResult = await store.forkConversation()
      let child = try XCTUnwrap(childResult, store.error ?? "")
      XCTAssertEqual(child.project, parent.project)
      let echoed = try await send("skill-dependency-request-echo", store: store)
      let body = try JSONDecoder().decode(JSONValue.self,
        from: Data(try XCTUnwrap(echoed.result?["response"].text).utf8))
      XCTAssertTrue(body.pretty.contains("function_call_output"))
      XCTAssertTrue(body.pretty.contains("swift-handoff-cwd-call"))
      let startedChild = try XCTUnwrap(store.selectedTask)
      XCTAssertNotEqual(startedChild.codexThreadID, startedParent.codexThreadID)
      XCTAssertEqual(store.library.managedWorktrees.count, 1)
      await store.archiveTask(parent.id)
      await store.managedArchiveCleanupTask?.value
      XCTAssertTrue(FileManager.default.fileExists(atPath: child.project))
      XCTAssertEqual(store.library.drafts[parent.id], "preserve shared source draft")
      let dataRoot = store.dataRoot
      await store.shutdown()
      let reopened = WorkspaceStore(dataRoot: dataRoot, agentExecutable: agent)
      do {
        await reopened.restore()
        let restoredChild = try XCTUnwrap(reopened.library.tasks.first { $0.id == child.id })
        let opened = await reopened.selectTaskAwaitingScope(restoredChild)
        XCTAssertTrue(opened, reopened.error ?? "")
        _ = try await send("codex-handoff-cwd-probe-return", store: reopened)
        XCTAssertEqual(reopened.selectedTask?.codexThreadID, startedChild.codexThreadID)
        XCTAssertEqual(reopened.library.managedWorktree(forTaskID: child.id)?.taskID, parent.id)
        XCTAssertEqual(reopened.library.sidebarProject(for: restoredChild), project.path)
        await reopened.archiveTask(child.id)
        await reopened.managedArchiveCleanupTask?.value
        XCTAssertFalse(FileManager.default.fileExists(atPath: child.project))
        let restored = await reopened.restoreManagedArchiveIfNeeded(child.id)
        XCTAssertTrue(restored, reopened.archivedTaskDeletionError ?? "")
        XCTAssertTrue(reopened.restoreArchivedTask(child.id))
        let selected = await reopened.selectTaskAwaitingScope(
          try XCTUnwrap(reopened.library.tasks.first { $0.id == child.id }))
        XCTAssertTrue(selected)
        let resumed = try await send("codex-handoff-cwd-probe-return skill-dependency-request-echo", store: reopened)
        let resumedBody = try JSONDecoder().decode(JSONValue.self,
          from: Data(try XCTUnwrap(resumed.result?["response"].text).utf8))
        XCTAssertTrue(resumedBody.pretty.contains(child.project))
        XCTAssertEqual(reopened.selectedTask?.codexThreadID, startedChild.codexThreadID)
        await reopened.shutdown()
      } catch { await reopened.shutdown(); throw error }
    } catch { await store.shutdown(); throw error }
  }

  @MainActor func testHistoricalNestedForkKeepsCompletedPrefixWhileSourceRuns() async throws {
    let (store, _, _) = try await fixture()
    let first = try await send("codex-handoff-cwd-probe", store: store)
    let source = try XCTUnwrap(store.selectedTask)
    let second = try await send("completed-but-excluded", store: store)
    let fork = try await store.forkTaskWindowConversation(source.id, through: second.id)
    let nested = try await store.forkTaskWindowConversation(fork.id, through: fork.runIDs[0])
    XCTAssertEqual(nested.codexForkOrigin?.throughTurnID, first.result?["codex_turn_id"].text)
    let started = await store.startChat("activity-archive-stream")
    let activeID = try XCTUnwrap(started)
    let sourceHandle = try XCTUnwrap(store.modelTask(runID: activeID))
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while store.library.chatRuns.first(where: { $0.id == activeID })?.result?["response"].text?.isEmpty != false {
      guard ContinuousClock.now < deadline else {
        XCTFail("Source stream unavailable before fork"); await store.shutdown(); return
      }
      try await Task.sleep(for: .milliseconds(25))
    }
    let requestsBeforeFork = try modelRequestCount()
    let createdWhileRunning = await store.forkTaskFromMenu(source.id)
    let eager = try XCTUnwrap(createdWhileRunning, store.error ?? "No native fork while source runs")
    XCTAssertNotNil(eager.codexThreadID)
    XCTAssertNotEqual(eager.codexThreadID, source.codexThreadID)
    XCTAssertEqual(eager.codexForkOrigin?.throughTurnID, second.result?["codex_turn_id"].text)
    XCTAssertEqual(store.activeRun(taskID: source.id)?.id, activeID)
    XCTAssertNil(store.activeRun(taskID: eager.id))
    XCTAssertEqual(try modelRequestCount(), requestsBeforeFork)
    store.selectTask(nested)
    let child = try await send("skill-dependency-request-echo", store: store)
    let body = try JSONDecoder().decode(JSONValue.self,
      from: Data(try XCTUnwrap(child.result?["response"].text).utf8))
    XCTAssertTrue(body.pretty.contains("function_call_output"))
    XCTAssertFalse(body.pretty.contains("completed-but-excluded"))
    XCTAssertFalse(body.pretty.contains("activity-archive-stream"))
    XCTAssertEqual(store.activeRun(taskID: source.id)?.id, activeID)
    await store.cancel(taskID: source.id)
    await sourceHandle.value
    await store.shutdown()
  }

  @MainActor func testMenuRejectsActualCoreInvalidBoundaryWithoutTextFallbackOrParentInterruption() async throws {
    let (store, _, _) = try await fixture()
    let first = try await send("codex-handoff-cwd-probe", store: store)
    let source = try XCTUnwrap(store.selectedTask)
    let index = try XCTUnwrap(store.library.chatRuns.firstIndex { $0.id == first.id })
    var result = try XCTUnwrap(first.result)
    var object = try result.decode([String: JSONValue].self)
    let invalidTurnID = UUID().uuidString
    object["codex_turn_id"] = .string(invalidTurnID)
    result = .object(object)
    let corrupted = AgentRun(id: first.id, kind: first.kind, project: first.project,
      status: first.status, createdAt: first.createdAt, updatedAt: first.updatedAt,
      request: first.request, result: result)
    store.library.chatRuns[index] = corrupted
    store.runs[try XCTUnwrap(store.runs.firstIndex { $0.id == first.id })] = corrupted
    XCTAssertEqual(store.taskWindowRuns(source.id).first?.result?["codex_turn_id"].text, invalidTurnID,
      "The real menu reads the current run cache before persisted local history")
    let tasksBefore = store.library.tasks, copiedBefore = store.library.forkRuns
    let requestsBeforeFork = try modelRequestCount()
    let rejected = await store.forkTaskFromMenu(source.id)
    XCTAssertNil(rejected)
    XCTAssertEqual(store.library.tasks, tasksBefore)
    XCTAssertEqual(store.library.forkRuns.map(\.id), copiedBefore.map(\.id))
    XCTAssertEqual(store.selectedTask?.id, source.id)
    XCTAssertTrue(store.codexTransport.isConnected(taskID: source.id))
    XCTAssertEqual(try modelRequestCount(), requestsBeforeFork)
    XCTAssertTrue(store.canForkTaskFromMenu(source.id))
    XCTAssertEqual(store.notices.items.first?.title, "创建聊天分支失败")
    let continued = try await send("skill-dependency-request-echo", store: store)
    XCTAssertEqual(continued.status, "succeeded")
    XCTAssertEqual(store.selectedTask?.codexThreadID, source.codexThreadID)
    XCTAssertTrue(try XCTUnwrap(continued.result?["response"].text).contains("function_call_output"))
    await store.shutdown()
  }

  @MainActor func testProjectlessNativeForkUsesOwnWorkspaceAndInheritedToolOutput() async throws {
    let (store, _, _) = try await fixture()
    await store.newProjectlessTask()
    _ = try await send("codex-handoff-cwd-probe", store: store)
    let parent = try XCTUnwrap(store.selectedTask)
    XCTAssertEqual(parent.project, "")
    XCTAssertNotNil(store.codexConversationPath(for: parent))
    let created = await store.forkTaskFromMenu(parent.id)
    let fork = try XCTUnwrap(created)
    let result = try await send("codex-handoff-cwd-probe-local skill-dependency-request-echo", store: store)
    let body = try JSONDecoder().decode(JSONValue.self,
      from: Data(try XCTUnwrap(result.result?["response"].text).utf8))
    let child = try XCTUnwrap(store.library.tasks.first { $0.id == fork.id })
    XCTAssertEqual(child.project, "")
    XCTAssertNotEqual(child.codexWorkspacePath, parent.codexWorkspacePath)
    XCTAssertTrue(body.pretty.contains("swift-handoff-cwd-call"))
    XCTAssertTrue(body.pretty.contains("swift-handoff-local-call"))
    let input = try body["input"].decode([JSONValue].self)
    let output = try XCTUnwrap(input.first { $0["type"].text == "function_call_output"
      && $0["call_id"].text == "swift-handoff-local-call" })
    XCTAssertTrue(output.pretty.contains(try XCTUnwrap(child.codexWorkspacePath)), "New command runs in child's directory")
    XCTAssertNotNil(store.codexConversationPath(for: child))
    await store.shutdown()
  }

  @MainActor func testNewWorktreeForkPreservesNativeToolsRunsInOwnCheckoutAndResumes() async throws {
    let (store, project, agent) = try await fixture()
    _ = try await GitReviewService.checked(["init", "-q"], at: project)
    _ = try await GitReviewService.checked(["config", "user.name", "Fixture"], at: project)
    _ = try await GitReviewService.checked(["config", "user.email", "fixture@example.invalid"], at: project)
    try Data("initial\n".utf8).write(to: project.appendingPathComponent("tracked"))
    _ = try await GitReviewService.checked(["add", "."], at: project)
    _ = try await GitReviewService.checked(["commit", "-qm", "Initial"], at: project)
    store.library.newTaskEnvironmentSelections[project.path] = WorktreeEnvironmentChoice.none
    let first = try await send("codex-handoff-cwd-probe", store: store)
    let parent = try XCTUnwrap(store.selectedTask)
    store.draft = "preserve parent draft"
    try Data("dirty captured\n".utf8).write(to: project.appendingPathComponent("tracked"))
    store.library.newTaskEnvironmentSelections[project.path] = WorktreeEnvironmentChoice.legacy
    store.library.profiles[project.path] = BuildProfile(worktreeSetupScript: "sleep 6")
    let started = await store.startChat("activity-archive-stream")
    let active = try XCTUnwrap(started)
    let sourceHandle = try XCTUnwrap(store.modelTask(runID: active))
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while store.library.chatRuns.first(where: { $0.id == active })?.result?["response"].text?.isEmpty != false {
      guard ContinuousClock.now < deadline else {
        XCTFail("Source stream unavailable before worktree fork"); await store.shutdown(); return
      }
      try await Task.sleep(for: .milliseconds(25))
    }
    store.library.queuedMessages.append(QueuedMessage(taskID: parent.id, text: "source queue must continue"))
    let created = await store.forkTaskToNewWorktree(parent.id)
    let fork = try XCTUnwrap(created, store.error ?? "")
    XCTAssertEqual(store.selectedTask?.id, fork.id)
    XCTAssertNotEqual(fork.project, parent.project)
    XCTAssertEqual(fork.codexForkOrigin?.throughTurnID, first.result?["codex_turn_id"].text)
    await sourceHandle.value
    let queueDeadline = ContinuousClock.now.advanced(by: .seconds(5))
    while store.library.queuedMessages.contains(where: { $0.taskID == parent.id }) {
      guard ContinuousClock.now < queueDeadline else {
        XCTFail("Source queue was stranded by fork preparation"); await store.shutdown(); return
      }
      try await Task.sleep(for: .milliseconds(25))
    }
    let sourceFollowup = try XCTUnwrap(store.library.tasks.first { $0.id == parent.id }?.runIDs.last)
    XCTAssertNotEqual(sourceFollowup, active)
    await store.modelTask(runID: sourceFollowup)?.value
    XCTAssertEqual(store.library.chatRuns.first { $0.id == sourceFollowup }?.status, "succeeded")
    let continued = try await send("codex-handoff-cwd-probe-local skill-dependency-request-echo", store: store)
    let body = try JSONDecoder().decode(JSONValue.self,
      from: Data(try XCTUnwrap(continued.result?["response"].text).utf8))
    let input = try body["input"].decode([JSONValue].self)
    XCTAssertTrue(body.pretty.contains("swift-handoff-cwd-call"), "Inherit source's real tool call")
    XCTAssertFalse(body.pretty.contains("activity-archive-stream"), "Exclude the source's active suffix")
    XCTAssertFalse(body.pretty.contains("source queue must continue"), "Keep the original fixed fork boundary")
    let output = try XCTUnwrap(input.first { $0["type"].text == "function_call_output"
      && $0["call_id"].text == "swift-handoff-local-call" })
    XCTAssertTrue(output.pretty.contains(fork.project), "Execute new tools in the independent checkout")
    let child = try XCTUnwrap(store.selectedTask)
    XCTAssertNotEqual(child.codexThreadID, parent.codexThreadID)
    XCTAssertNotNil(store.codexConversationPath(for: child))
    _ = try await send("codex-patch", store: store)
    XCTAssertTrue(FileManager.default.fileExists(atPath: URL(fileURLWithPath: fork.project)
      .appendingPathComponent("patch-proof.txt").path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: project.appendingPathComponent("patch-proof.txt").path))
    XCTAssertEqual(try String(contentsOf: project.appendingPathComponent("tracked")), "dirty captured\n")
    XCTAssertEqual(store.library.drafts[parent.id], "preserve parent draft")
    let dataRoot = store.dataRoot
    await store.shutdown()

    let reopened = WorkspaceStore(dataRoot: dataRoot, agentExecutable: agent)
    await reopened.restore()
    let restored = try XCTUnwrap(reopened.library.tasks.first { $0.id == fork.id })
    let opened = await reopened.selectTaskAwaitingScope(restored)
    XCTAssertTrue(opened, reopened.error ?? "")
    _ = try await send("resume worktree child", store: reopened)
    XCTAssertEqual(reopened.selectedTask?.codexThreadID, child.codexThreadID)
    let nestedCreated = await reopened.forkTaskToNewWorktree(fork.id)
    let nested = try XCTUnwrap(nestedCreated, reopened.error ?? "")
    XCTAssertNotEqual(nested.project, fork.project)
    // The nested child has not opened a Core thread yet. Its source checkout can already be
    // archived, while the private source rollout and copied files remain available.
    XCTAssertNil(reopened.library.tasks.first { $0.id == nested.id }?.codexThreadID)
    reopened.updateTask(fork.id, archive: true)
    await reopened.managedArchiveCleanupTask?.value
    XCTAssertFalse(FileManager.default.fileExists(atPath: fork.project))
    XCTAssertEqual(reopened.library.managedWorktrees.first { $0.taskID == fork.id }?.archivedPruned, true)
    let result: AgentRun
    do { result = try await send("codex-handoff-cwd-probe-return skill-dependency-request-echo", store: reopened) }
    catch { await reopened.shutdown(); throw error }
    let nestedBody = try JSONDecoder().decode(JSONValue.self,
      from: Data(try XCTUnwrap(result.result?["response"].text).utf8))
    XCTAssertTrue(nestedBody.pretty.contains("swift-handoff-cwd-call"))
    XCTAssertTrue(nestedBody.pretty.contains("swift-handoff-local-call"))
    let nestedInput = try nestedBody["input"].decode([JSONValue].self)
    let nestedOutput = try XCTUnwrap(nestedInput.first { $0["type"].text == "function_call_output"
      && $0["call_id"].text == "swift-handoff-return-call" })
    XCTAssertTrue(nestedOutput.pretty.contains(nested.project), "New commands use the surviving child checkout")
    let nativeNested = try XCTUnwrap(reopened.selectedTask)
    XCTAssertNotEqual(nativeNested.codexThreadID, child.codexThreadID)
    XCTAssertNotNil(reopened.codexConversationPath(for: nativeNested))
    XCTAssertEqual(reopened.library.managedWorktrees.first { $0.taskID == nested.id }?.source,
      GitBranchService.canonicalRoot(project).path)
    await reopened.shutdown()

    let resumed = WorkspaceStore(dataRoot: dataRoot, agentExecutable: agent)
    await resumed.restore()
    let savedNested = try XCTUnwrap(resumed.library.tasks.first { $0.id == nested.id })
    let reopenedNested = await resumed.selectTaskAwaitingScope(savedNested)
    XCTAssertTrue(reopenedNested, resumed.error ?? "")
    _ = try await send("resume child without source checkout", store: resumed)
    XCTAssertEqual(resumed.selectedTask?.codexThreadID, nativeNested.codexThreadID)
    XCTAssertFalse(FileManager.default.fileExists(atPath: fork.project), "Resuming does not recreate source")
    await resumed.shutdown()
  }
}
