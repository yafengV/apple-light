import AppKit
import Darwin
import XCTest
@testable import ShipiOS

/// Real Agent/Core persistence with no hosted or foreground product window.
@MainActor final class WorkspaceRecoveryIntegrationTests: XCTestCase {
  private struct Fixture {
    let store: WorkspaceStore
    let project: URL
    let agent: URL
    let trace: URL
    let launches: URL
  }

  private func fixture() async throws -> Fixture {
    _ = NSApplication.shared
    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("workspace-recovery-\(UUID())")
    try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    let root = temporary.resolvingSymlinksInPath()
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    let project = root.appendingPathComponent("Project", isDirectory: true)
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    try "original file\n".write(to: project.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
    let trace = root.appendingPathComponent("http.jsonl")
    let server = Process(), pipe = Pipe()
    server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().appendingPathComponent("Fixtures/model_server.py")
    server.arguments = ["-u", script.path]
    server.environment = ["FIXTURE_EVENT_LOG": trace.path]
    server.standardOutput = pipe; server.standardError = FileHandle.nullDevice
    try server.run()
    addTeardownBlock {
      if server.isRunning { server.terminate(); server.waitUntilExit() }
    }
    let port = String(decoding: pipe.fileHandleForReading.availableData, as: UTF8.self)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard Int(port) != nil else { throw AgentFailure(message: "Recovery fixture did not start") }

    // exec preserves the PID of our own real helper; no global process lookup or kill.
    let agent = root.appendingPathComponent("record-agent")
    try JSONEncoder().encode(try AgentTestExecutable.url().path).write(to: root.appendingPathComponent("agent.json"))
    try #"""
      #!/usr/bin/python3
      import json, os, pathlib, sys
      root = pathlib.Path(__file__).parent
      args = sys.argv[1:]
      with (root / 'launches.jsonl').open('a') as log:
          log.write(json.dumps({'pid': os.getpid(), 'project': args[args.index('--project') + 1],
                                'data': args[args.index('--data-dir') + 1]}) + '\n')
      helper = json.loads((root / 'agent.json').read_text())
      os.execv(helper, [helper] + args)
      """#.write(to: agent, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: agent.path)
    let store = WorkspaceStore(dataRoot: root.appendingPathComponent("Data"), agentExecutable: agent)
    addTeardownBlock { @MainActor in _ = await store.shutdown() }
    await store.restore(); await store.open(project)
    XCTAssertTrue(store.connected, store.error ?? "Agent not connected")
    var config = ModelConfiguration()
    config.apiProtocol = .codexResponses; config.baseURL = "http://127.0.0.1:\(port)/v1"; config.model = "gpt-5.4"
    try store.saveModelConfiguration(config)
    store.notificationPreferences = .init(timing: .never)
    return Fixture(store: store, project: project, agent: agent, trace: trace,
      launches: root.appendingPathComponent("launches.jsonl"))
  }

  private func send(_ prompt: String, store: WorkspaceStore) async throws -> WorkspaceTask {
    let started = await store.startChat(prompt)
    let id = try XCTUnwrap(started, store.error ?? "No Core run")
    let deadline = ContinuousClock.now.advanced(by: .seconds(20))
    while store.library.chatRuns.contains(where: { $0.id == id && $0.isActive }) {
      guard ContinuousClock.now < deadline else {
        await store.cancel()
        throw AgentFailure(message: "Recovery fixture run exceeded 20 seconds")
      }
      try await Task.sleep(for: .milliseconds(20))
    }
    await store.modelTask(runID: id)?.value
    let run = try XCTUnwrap(store.library.chatRuns.first { $0.id == id })
    XCTAssertEqual(run.status, "succeeded", run.result?["message"].text ?? "")
    XCTAssertNotNil(run.result?["codex_turn_id"].text)
    let task = try XCTUnwrap(store.library.task(containing: id))
    XCTAssertNotNil(task.codexThreadID)
    // In the product WorkspaceView reacts to selection changes; this test hosts no view.
    store.restoreWorkspaceTabLayout()
    return task
  }

  private func posts(_ trace: URL) throws -> Int {
    guard FileManager.default.fileExists(atPath: trace.path) else { return 0 }
    return try String(contentsOf: trace, encoding: .utf8).split(separator: "\n").map {
      try JSONDecoder().decode(JSONValue.self, from: Data($0.utf8))
    }.filter { $0["phase"].text == "post" }.count
  }

  private func checkRecovery(killLocalAgent: Bool) async throws {
    let f = try await fixture(), store = f.store
    let first = try await send("first recovery history", store: store)
    store.draft = "第一条会话草稿"
    store.newTask()
    let second = try await send("second recovery history", store: store)
    XCTAssertNotEqual(second.id, first.id)
    XCTAssertNotEqual(second.codexThreadID, first.codexThreadID)
    store.draft = "第二条会话草稿"
    store.selectTask(first)
    store.setTaskUnread(second.id, unread: true)
    XCTAssertTrue(store.openFileTab("notes.txt"))
    let tab = try XCTUnwrap(store.activeWorkspaceContentTab)
    let editor = store.fileTabWorkspace(tab)
    // Apply the same scope initialization as FileWorkspaceTabView.task.
    editor.setProject(try XCTUnwrap(store.workspaceFileTabRoot(tab)))
    await editor.openFile("notes.txt")
    XCTAssertEqual(editor.fileText, "original file\n")
    editor.beginEditingSelectedFile(); editor.editSelectedFile("未保存的文件草稿\n")
    XCTAssertTrue(editor.selectedFileEditor?.hasUnsavedChanges == true)
    // The normal unsaved-close flow pauses autosave until the user chooses an action.
    editor.closeFile("notes.txt")
    XCTAssertEqual(editor.fileCloseRequest, "notes.txt")
    let taskIDs = Set(store.library.tasks.map(\.id))
    let runIDs = Set(store.library.chatRuns.map(\.id))
    let threads = Dictionary(uniqueKeysWithValues: store.library.tasks.map { ($0.id, $0.codexThreadID) })
    let before = try posts(f.trace)
    XCTAssertEqual(before, 2)

    if killLocalAgent {
      let records = try String(contentsOf: f.launches, encoding: .utf8).split(separator: "\n").map {
        try JSONDecoder().decode(JSONValue.self, from: Data($0.utf8))
      }
      let scope = try XCTUnwrap(store.dataDirectory?.path)
      let record = try XCTUnwrap(records.last { $0["data"].text == scope && $0["project"].text == f.project.path })
      let pid = pid_t(try XCTUnwrap(record["pid"].int))
      XCTAssertEqual(kill(pid, SIGKILL), 0)
      let deadline = ContinuousClock.now.advanced(by: .seconds(5))
      while store.connected, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
      XCTAssertFalse(store.connected)
      XCTAssertTrue(store.error?.contains("Agent 已退出") == true)
      XCTAssertEqual(store.project, f.project)
      XCTAssertEqual(store.selectedTask?.id, first.id)
      XCTAssertEqual(store.draft, "第一条会话草稿")
      XCTAssertEqual(editor.fileText, "未保存的文件草稿\n")
      XCTAssertFalse(store.busy)
      await store.open(f.project)
      XCTAssertTrue(store.connected, store.error ?? "Explicit reconnect failed")
      XCTAssertEqual(store.selectedTask?.id, first.id)
      XCTAssertEqual(store.activeWorkspaceContentTab, tab)
      XCTAssertEqual(store.fileTabWorkspace(tab).fileText, "未保存的文件草稿\n")
      XCTAssertEqual(Set(store.library.tasks.map(\.id)), taskIDs)
      XCTAssertEqual(Set(store.library.chatRuns.map(\.id)), runIDs)
      XCTAssertEqual(try posts(f.trace), before, "Reconnect must not resubmit a model turn")
    }

    let stopped = await store.shutdown(); XCTAssertTrue(stopped)
    let recovered = WorkspaceStore(dataRoot: store.dataRoot, agentExecutable: f.agent)
    addTeardownBlock { @MainActor in _ = await recovered.shutdown() }
    await recovered.restore()
    XCTAssertTrue(recovered.connected, recovered.error ?? "Cold restore failed")
    XCTAssertFalse(recovered.busy); XCTAssertFalse(recovered.restoringLibrary)
    XCTAssertEqual(recovered.project, f.project)
    XCTAssertEqual(recovered.selectedTask?.id, first.id)
    XCTAssertEqual(recovered.draft, "第一条会话草稿")
    XCTAssertEqual(recovered.library.drafts[second.id], "第二条会话草稿")
    XCTAssertTrue(recovered.library.unreadTasks.contains(second.id))
    XCTAssertEqual(Set(recovered.library.tasks.map(\.id)), taskIDs)
    XCTAssertEqual(Set(recovered.library.chatRuns.map(\.id)), runIDs)
    XCTAssertEqual(Dictionary(uniqueKeysWithValues: recovered.library.tasks.map { ($0.id, $0.codexThreadID) }), threads)
    XCTAssertEqual(recovered.activeWorkspaceContentTab, tab)
    let restoredEditor = recovered.fileTabWorkspace(tab)
    restoredEditor.setProject(try XCTUnwrap(recovered.workspaceFileTabRoot(tab)))
    await restoredEditor.openFile("notes.txt")
    XCTAssertEqual(restoredEditor.fileText, "未保存的文件草稿\n")
    XCTAssertEqual(restoredEditor.selectedFileEditor?.baseText, "original file\n")
    XCTAssertEqual(try String(contentsOf: f.project.appendingPathComponent("notes.txt")), "original file\n")
    XCTAssertEqual(try posts(f.trace), before, "Cold restore must not resubmit a model turn")
    // Opening again is idempotent and explicit continuation uses the existing Core thread.
    await recovered.open(f.project)
    XCTAssertEqual(recovered.workspaceTabs.filter { $0 == tab }.count, 1)
    let continued = try await send("explicit recovery continuation", store: recovered)
    XCTAssertEqual(continued.id, first.id)
    XCTAssertEqual(continued.codexThreadID, threads[first.id] ?? nil)
    XCTAssertEqual(try posts(f.trace), before + 1)
    XCTAssertEqual(Set(recovered.library.tasks.map(\.id)), taskIDs)
    XCTAssertEqual(recovered.draft, "第一条会话草稿")
  }

  func testRealCoreColdRestoreKeepsProjectHistoryFileDraftAndUnreadWithoutDuplicateSubmission() async throws {
    try await checkRecovery(killLocalAgent: false)
  }

  func testActualAgentExitReconnectAndColdRestoreKeepSameScopeHistoryAndFileDraft() async throws {
    try await checkRecovery(killLocalAgent: true)
  }

  func testActualCoreAgentExitRetainsPartialAndColdRestoreRequiresExplicitContinuation() async throws {
    let f = try await fixture(), store = f.store
    let owner = try await send("completed history before crash", store: store)
    XCTAssertTrue(store.openFileTab("notes.txt"))
    let tab = try XCTUnwrap(store.activeWorkspaceContentTab)
    let editor = store.fileTabWorkspace(tab)
    editor.setProject(try XCTUnwrap(store.workspaceFileTabRoot(tab)))
    await editor.openFile("notes.txt")
    XCTAssertEqual(editor.fileText, "original file\n")
    editor.beginEditingSelectedFile(); editor.editSelectedFile("模型断联时的文件草稿\n")
    editor.closeFile("notes.txt")
    XCTAssertEqual(editor.fileCloseRequest, "notes.txt")
    // This fixture emits a real delta, then holds response.completed for five seconds.
    let started = await store.startChat("activity-archive-stream recovery crash")
    let id = try XCTUnwrap(started)
    store.draft = "模型断联时的会话草稿"
    store.restoreWorkspaceTabLayout()
    // Sending reveals the conversation. The user then selects the existing file again.
    store.activateWorkspaceTab(tab.id)
    XCTAssertEqual(store.activeWorkspaceContentTab, tab)
    XCTAssertEqual(store.workspaceLayoutActiveOwner, owner.id)
    let partialDeadline = ContinuousClock.now.advanced(by: .seconds(8))
    while (store.library.chatRuns.first { $0.id == id }?.result?["response"].text ?? "").isEmpty {
      guard ContinuousClock.now < partialDeadline else {
        await store.cancel()
        throw AgentFailure(message: "No real Core partial before crash")
      }
      try await Task.sleep(for: .milliseconds(20))
    }
    let active = try XCTUnwrap(store.library.chatRuns.first { $0.id == id })
    XCTAssertTrue(active.isActive, "Crash must happen during a live turn")
    let partial = try XCTUnwrap(active.result?["response"].text)
    let records = try String(contentsOf: f.launches, encoding: .utf8).split(separator: "\n").map {
      try JSONDecoder().decode(JSONValue.self, from: Data($0.utf8))
    }
    let record = try XCTUnwrap(records.last {
      $0["project"].text == f.project.path && ($0["data"].text ?? "").hasPrefix(store.dataRoot.path + "/CodexAgents/")
    })
    XCTAssertEqual(kill(pid_t(try XCTUnwrap(record["pid"].int)), SIGKILL), 0)
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while store.library.chatRuns.contains(where: { $0.id == id && $0.isActive }) {
      guard ContinuousClock.now < deadline else {
        await store.cancel()
        throw AgentFailure(message: "Core Agent exit did not end the run")
      }
      try await Task.sleep(for: .milliseconds(20))
    }
    await store.modelTask(runID: id)?.value
    let failed = try XCTUnwrap(store.library.chatRuns.first { $0.id == id })
    XCTAssertEqual(failed.status, "failed")
    XCTAssertEqual(failed.result?["response"].text, partial)
    XCTAssertFalse((failed.result?["message"].text ?? "").isEmpty)
    XCTAssertEqual(store.liveModelRequestCount, 0)
    XCTAssertEqual(store.draft, "模型断联时的会话草稿")
    XCTAssertEqual(editor.fileText, "模型断联时的文件草稿\n")
    XCTAssertEqual(store.activeWorkspaceContentTab, tab)
    let before = try posts(f.trace), runs = Set(store.library.chatRuns.map(\.id))
    XCTAssertEqual(before, 2)
    let stopped = await store.shutdown(); XCTAssertTrue(stopped)
    let recovered = WorkspaceStore(dataRoot: store.dataRoot, agentExecutable: f.agent)
    addTeardownBlock { @MainActor in _ = await recovered.shutdown() }
    await recovered.restore()
    XCTAssertFalse(recovered.restoringLibrary); XCTAssertFalse(recovered.busy)
    XCTAssertEqual(recovered.selectedTask?.id, owner.id)
    XCTAssertEqual(recovered.selectedTask?.codexThreadID, owner.codexThreadID)
    XCTAssertEqual(recovered.draft, "模型断联时的会话草稿")
    XCTAssertEqual(Set(recovered.library.chatRuns.map(\.id)), runs)
    XCTAssertEqual(recovered.library.chatRuns.first { $0.id == id }?.result?["response"].text, partial)
    XCTAssertEqual(recovered.activeWorkspaceContentTab, tab)
    let restoredEditor = recovered.fileTabWorkspace(tab)
    restoredEditor.setProject(try XCTUnwrap(recovered.workspaceFileTabRoot(tab)))
    await restoredEditor.openFile("notes.txt")
    XCTAssertEqual(restoredEditor.fileText, "模型断联时的文件草稿\n")
    XCTAssertEqual(try String(contentsOf: f.project.appendingPathComponent("notes.txt")), "original file\n")
    XCTAssertEqual(try posts(f.trace), before, "Agent failure and cold restore cannot auto-retry")
    let continued = try await send("explicit continuation after Agent crash", store: recovered)
    XCTAssertEqual(continued.id, owner.id)
    XCTAssertEqual(continued.codexThreadID, owner.codexThreadID)
    XCTAssertEqual(try posts(f.trace), before + 1)
    XCTAssertEqual(recovered.library.tasks.count, 1)
    XCTAssertEqual(recovered.library.chatRuns.count, runs.count + 1)
  }
}
