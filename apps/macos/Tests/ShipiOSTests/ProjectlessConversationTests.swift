import XCTest

@testable import ShipiOS

final class ProjectlessConversationTests: XCTestCase {
  @MainActor func testRealAgentProjectSwitchKeepsBothHistoriesAndRestoresProjectlessSelection()
    async throws
  {
    var repository = URL(fileURLWithPath: #filePath)
    for _ in 0..<5 { repository.deleteLastPathComponent() }
    let agent = repository.appendingPathComponent("target/debug/shipios-agent")
    guard FileManager.default.isExecutableFile(atPath: agent.path) else {
      throw XCTSkip("Build shipios-agent before running the project-switch integration test")
    }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let project = root.appendingPathComponent("Project").resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    let projectRun = AgentRun(
      id: "project-chat", kind: "chat", project: project.path,
      status: "succeeded", createdAt: 1, updatedAt: 2, request: .null, result: nil)
    let standalone = sampleRun()
    var library = WorkspaceLibrary()
    library.projects = [project.path]
    library.lastWorkspace = project.path
    library.chatRuns = [projectRun, standalone]
    library.attach(projectRun, to: nil, note: "project")
    library.attach(standalone, to: nil, note: "standalone")
    library.projectSelections[project.path] = projectRun.id
    library.projectSelections[""] = standalone.id
    try library.save(to: root.appendingPathComponent("workspace.json"))
    let store = WorkspaceStore(dataRoot: root, agentExecutable: agent)
    await store.restore()
    XCTAssertTrue(store.connected, store.error ?? "Agent not connected")
    XCTAssertEqual(store.selection, projectRun.id)
    store.draft = "project draft"
    await store.newProjectlessTask()
    XCTAssertNil(store.project)
    XCTAssertFalse(store.connected)
    XCTAssertNil(store.workspace.root)
    XCTAssertNil(store.selection)
    XCTAssertEqual(store.library.drafts[projectRun.id], "project draft")
    store.selectTask(try XCTUnwrap(store.library.task(containing: standalone.id)))
    store.draft = "standalone draft"
    await store.navigate(back: true)
    XCTAssertNil(store.selection)
    await store.navigate(back: true)
    XCTAssertEqual(store.project?.path, project.path)
    XCTAssertTrue(store.connected, store.error ?? "Agent not reconnected")
    XCTAssertEqual(store.selection, projectRun.id)
    XCTAssertEqual(store.draft, "project draft")
    await store.navigate(back: false)
    XCTAssertNil(store.project)
    XCTAssertNil(store.selection)
    await store.navigate(back: false)
    XCTAssertEqual(store.selection, standalone.id)
    XCTAssertEqual(store.draft, "standalone draft")
    await store.shutdown()
    let restored = WorkspaceStore(dataRoot: root, agentExecutable: agent)
    await restored.restore()
    XCTAssertNil(restored.project)
    XCTAssertEqual(restored.selection, standalone.id)
    XCTAssertEqual(restored.draft, "standalone draft")
    await restored.shutdown()
  }

  private func sampleRun(_ id: String = "standalone", status: String = "succeeded") -> AgentRun {
    AgentRun(
      id: id, kind: "chat", project: "", status: status, createdAt: 1,
      updatedAt: 2, request: .object(["kind": .string("chat")]),
      result: .object(["response": .string("reply")]))
  }

  @MainActor func testRestoreStandaloneHistoryWithoutOpeningLastFolder() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    var library = WorkspaceLibrary()
    let run = sampleRun()
    library.chatRuns = [run]
    library.attach(run, to: nil, note: "standalone prompt")
    library.projects = [root.path]
    library.lastWorkspace = ""
    library.projectSelections[""] = run.id
    library.drafts[run.id] = "saved standalone draft"
    try library.save(to: root.appendingPathComponent("workspace.json"))
    let store = WorkspaceStore(dataRoot: root)
    await store.restore()
    XCTAssertNil(store.project)
    XCTAssertNil(store.workspace.root)
    XCTAssertNil(store.dataDirectory)
    XCTAssertFalse(store.connected)
    XCTAssertEqual(store.selection, run.id)
    XCTAssertEqual(store.draft, "saved standalone draft")
    XCTAssertEqual(store.conversationRuns, [run])
    XCTAssertTrue(store.canSend)
    XCTAssertTrue(store.canForkConversation)
    XCTAssertFalse(store.canStart)
    XCTAssertEqual(store.library.projects, [root.path])
    XCTAssertEqual(store.library.sidebarItems(in: SidebarLayout.projectless), [.task(run.id)])
    await store.shutdown()
    let restored = WorkspaceStore(dataRoot: root)
    await restored.restore()
    XCTAssertEqual(restored.draft, "saved standalone draft")
    XCTAssertEqual(restored.selectedTask?.id, run.id)
  }

  @MainActor func testNewStandaloneTaskKeepsExistingDraftAndRestoresBlankSelection() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root)
    await store.restore()
    let run = sampleRun()
    store.library.chatRuns = [run]
    store.runs = [run]
    store.library.attach(run, to: nil, note: "old")
    store.selection = run.id
    store.draft = "old task draft"
    await store.newProjectlessTask()
    XCTAssertNil(store.selection)
    XCTAssertEqual(store.draft, "")
    XCTAssertEqual(store.library.drafts[run.id], "old task draft")
    store.draft = "new task draft"
    await store.shutdown()
    let restored = WorkspaceStore(dataRoot: root)
    await restored.restore()
    XCTAssertNil(restored.selection)
    XCTAssertEqual(restored.draft, "new task draft")
    await restored.navigate(back: true)
    XCTAssertEqual(restored.draft, "new task draft")
  }

  @MainActor func testProjectlessLocalActionsKeepPromptAndDoNotStartAgent() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root)
    await store.restore()
    for prompt in ["/doctor inspect", "/build compile"] {
      store.draft = prompt
      await store.sendDraft()
      XCTAssertEqual(store.draft, prompt)
      XCTAssertNotNil(store.error)
      XCTAssertFalse(store.connected)
      XCTAssertNil(store.dataDirectory)
      XCTAssertTrue(store.runs.isEmpty)
    }
  }

  @MainActor func testRunningStandaloneChatSurvivesProjectSwitchAndAllowsParallelTask() async {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root)
    await store.restore()
    let run = sampleRun(status: "running")
    store.library.chatRuns = [run]
    store.library.attach(run, to: nil, note: "running")
    store.runs = [run]
    store.selection = run.id
    let request = Task<Void, Never> { try? await Task.sleep(for: .seconds(5)) }
    store.installModelTask(request, runID: run.id)
    XCTAssertFalse(store.connected)
    let task = WorkspaceTask(id: "other", project: "/other", title: "other", runIDs: [])
    XCTAssertTrue(store.canSelectTask(task))
    await store.open(URL(fileURLWithPath: "/other"))
    XCTAssertEqual(store.project?.path, "/other")
    XCTAssertEqual(store.library.chatRuns.first?.id, "standalone")
    XCTAssertEqual(store.library.chatRuns.first?.status, "running")
    XCTAssertNotNil(store.modelTask(runID: run.id))
    XCTAssertTrue(store.canStartChat)
    request.cancel()
    store.removeModelTask(runID: run.id)
    await store.shutdown()
  }

  @MainActor func testPinGroupArchiveRestoreAndForkKeepStandaloneOwnership() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root)
    await store.restore()
    let run = sampleRun()
    store.runs = [run]
    store.library.chatRuns = [run]
    store.library.attach(run, to: nil, note: "standalone")
    store.selection = run.id
    store.updateTask(run.id, pin: true)
    XCTAssertEqual(store.library.sidebarItems(in: SidebarLayout.pinned), [.task(run.id)])
    store.updateTask(run.id, pin: false)
    store.updateTask(run.id, archive: true)
    XCTAssertTrue(store.library.sidebarItems(in: SidebarLayout.projectless).isEmpty)
    store.openSettings(.archived)
    store.updateTask(run.id, archive: false)
    XCTAssertEqual(store.destination, .settings)
    store.closeSettings()
    store.selectTask(try XCTUnwrap(store.library.tasks.first))
    let fork = try XCTUnwrap(store.forkConversation())
    XCTAssertEqual(fork.project, "")
    XCTAssertEqual(store.selectedTask?.id, fork.id)
    XCTAssertEqual(store.library.projects, [])
    XCTAssertEqual(
      store.library.chatContext(taskID: fork.id).map(\.content), ["standalone", "reply"])
  }

  @MainActor func testStandaloneNotificationOpensItsTaskInTheSameWindow() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root)
    await store.restore()
    let run = sampleRun()
    store.library.chatRuns = [run]
    store.runs = [run]
    store.library.attach(run, to: nil, note: "standalone")
    let destination = NotificationDestination(
      dataRoot: root.path, project: "", taskID: run.id, runID: run.id)
    XCTAssertEqual(NotificationDestination(userInfo: destination.userInfo), destination)
    store.openSettings(.general)
    let opened = await store.openNotification(destination)
    XCTAssertTrue(opened)
    XCTAssertEqual(store.destination, .workspace)
    XCTAssertEqual(store.selection, run.id)
    XCTAssertNil(store.project)
  }

  func testProjectlessLinksAllowWebButNeverResolveRelativePaths() throws {
    let web = URL(string: "https://example.com/page")!
    XCTAssertEqual(try MessageLink.target(web, root: nil), .web(web))
    XCTAssertThrowsError(try MessageLink.target(URL(string: "README.md")!, root: nil))
    XCTAssertThrowsError(try MessageLink.target(URL(fileURLWithPath: "/tmp/readme"), root: nil))
  }
}
