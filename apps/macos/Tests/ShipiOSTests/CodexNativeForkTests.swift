import XCTest
@testable import ShipiOS

final class CodexNativeForkTests: XCTestCase {
  private var server: Process!
  private var endpoint = ""
  override func setUpWithError() throws {
    server = Process()
    server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().appendingPathComponent("Fixtures/model_server.py")
    server.arguments = ["-u", fixture.path]
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
  }

  @MainActor private func fixture() async throws -> (WorkspaceStore, URL, URL) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("native-fork-\(UUID())")
      .resolvingSymlinksInPath().standardizedFileURL
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    let project = root.appendingPathComponent("Project")
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    var repository = URL(fileURLWithPath: #filePath)
    for _ in 0..<5 { repository.deleteLastPathComponent() }
    let agent = repository.appendingPathComponent("target/debug/shipios-agent")
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
    let (store, project, agent) = try await fixture()
    let first = try await send("codex-handoff-cwd-probe", store: store)
    let parent = try XCTUnwrap(store.selectedTask)
    XCTAssertEqual(parent.codexWorkspacePath, project.path)
    XCTAssertNotNil(store.codexConversationPath(for: parent), "Use the real camelCase project-owned reference")
    let created = await store.forkTaskFromMenu(parent.id)
    let fork = try XCTUnwrap(created)
    XCTAssertEqual(fork.codexForkOrigin?.throughTurnID, first.result?["codex_turn_id"].text)
    XCTAssertNil(fork.codexThreadID)
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
    // An already-started child can fork an inherited turn, then fork that pending fork again.
    let historical = try reopened.forkTaskWindowConversation(child.id, through: child.runIDs[0])
    let nested = try reopened.forkTaskWindowConversation(historical.id, through: historical.runIDs[0])
    XCTAssertEqual(nested.codexForkOrigin?.taskID, child.id)
    XCTAssertEqual(nested.codexForkOrigin?.threadID, childThread)
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
      let child = try XCTUnwrap(store.forkConversation(), store.error ?? "")
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
    let fork = try store.forkTaskWindowConversation(source.id, through: second.id)
    let nested = try store.forkTaskWindowConversation(fork.id, through: fork.runIDs[0])
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
