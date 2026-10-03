import Foundation
import XCTest
@testable import ShipiOS

@MainActor final class AutomationPauseToolTests: XCTestCase {
  private func fixture() throws -> (WorkspaceStore, URL, ShipAutomation) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = WorkspaceStore(dataRoot: root)
    store.libraryLoaded = true
    store.automationsLoaded = true
    var watch = ShipAutomation(name: "Watch", prompt: "Monitor")
    watch.taskID = UUID().uuidString
    watch.project = root.path
    watch.cadence = .custom
    watch.customRule = "FREQ=MINUTELY;INTERVAL=10"
    watch.scheduleAnchor = .now
    watch.watchedPullRequest = .init(number: 17,
      url: "https://github.com/example/project/pull/17", title: "Fix", isDraft: false,
      headRefName: "fix", baseRefName: "main", isCrossRepository: false)
    store.library.tasks = [.init(id: watch.taskID!, project: "", title: "Watch", runIDs: ["run"])]
    store.library.chatRuns = [.init(id: "run", kind: "chat", project: "", status: "running",
      createdAt: 0, updatedAt: 0, request: .object(["automation_id": .string(watch.id.uuidString)]),
      result: .object(["response": .string("")]))]
    guard store.saveAutomation(watch) else {
      throw AgentFailure(message: store.automationsError ?? "Fixture schedule could not save")
    }
    return (store, root, watch)
  }

  private func call(_ arguments: String = #"{"reason":"Missing CI access"}"#) -> ModelFunctionCall {
    .init(id: UUID().uuidString, name: ModelAutomationPauseTool.name, arguments: arguments)
  }

  func testPausePersistsWithoutStoppingCurrentTurnAndKeepsFirstReason() throws {
    let (store, root, watch) = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    var other = watch
    other.id = UUID()
    other.taskID = UUID().uuidString
    XCTAssertTrue(store.saveAutomation(other))
    let output = try store.executeAutomationPauseTool(call(), runID: "run", expectedAutomationID: watch.id)
    XCTAssertTrue(output.contains("paused"))
    let paused = try XCTUnwrap(AutomationStorage.load(root: root).items.first { $0.id == watch.id })
    XCTAssertFalse(paused.enabled)
    XCTAssertEqual(paused.pauseReason, "Missing CI access")
    XCTAssertNotNil(paused.pausedAt)
    XCTAssertTrue(store.library.chatRuns[0].isActive)
    XCTAssertTrue(store.automationPreferences.items.first { $0.id == other.id }!.enabled)
    _ = try store.executeAutomationPauseTool(call(#"{"reason":"Different reason"}"#),
      runID: "run", expectedAutomationID: watch.id)
    XCTAssertEqual(store.automationPreferences.items.first { $0.id == watch.id }?.pausedAt, paused.pausedAt)
    XCTAssertEqual(store.automationPreferences.items.first { $0.id == watch.id }?.pauseReason, paused.pauseReason)
  }

  func testInvalidScopeArgumentsAndEndedRunCannotPause() throws {
    let (store, root, watch) = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    for (arguments, id) in [(#"{"reason":"Missing access"}"#, UUID()),
      (#"{"reason":"Missing access","automation_id":"another"}"#, watch.id),
      (#"{"reason":"  "}"#, watch.id)] {
      let result = try store.executeAutomationPauseTool(call(arguments), runID: "run", expectedAutomationID: id)
      XCTAssertTrue(result.contains("error"))
      XCTAssertTrue(store.automationPreferences.items[0].enabled)
    }
    store.replaceChat(store.library.chatRuns[0], status: "succeeded", response: "Complete")
    XCTAssertNil(store.pausableWatch(runID: "run"))
    let result = try store.executeAutomationPauseTool(call(), runID: "run", expectedAutomationID: watch.id)
    XCTAssertTrue(result.contains("error"))
    XCTAssertTrue(try AutomationStorage.load(root: root).items[0].enabled)
  }

  func testSaveFailureReturnsErrorAndDoesNotPretendPaused() throws {
    let (store, root, watch) = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("automations.json")
    try FileManager.default.removeItem(at: file)
    try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
    let output = try store.executeAutomationPauseTool(call(), runID: "run", expectedAutomationID: watch.id)
    XCTAssertTrue(output.contains("error"))
    XCTAssertTrue(store.automationPreferences.items[0].enabled)
    XCTAssertNil(store.automationPreferences.items[0].pausedAt)
  }

  func testUnattendedApprovalPausesWatchButLeavesOrdinaryScheduleEnabled() async throws {
    let (store, root, _) = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let execution = MCPToolExecution(callID: "approval", serverID: UUID(), serverName: "CI",
      toolName: "deploy", arguments: "{}", status: .awaitingApproval)
    let decision = await store.requestMCPApproval(execution, runID: "run")
    XCTAssertEqual(decision, .deny)
    XCTAssertFalse(store.automationPreferences.items[0].enabled)
    XCTAssertTrue(store.automationPreferences.items[0].pauseReason?.contains("CI / deploy") == true)
    store.automationPreferences.items[0].watchedPullRequest = nil
    store.automationPreferences.items[0].enabled = true
    let ordinary = await store.requestMCPApproval(execution, runID: "run")
    XCTAssertEqual(ordinary, .deny)
    XCTAssertTrue(store.automationPreferences.items[0].enabled)
  }

  func testUnattendedQuestionRetainsExactBlockerAndPausesSchedule() async throws {
    for blocking in [true, false] {
      let (store, root, watch) = try fixture()
      defer { try? FileManager.default.removeItem(at: root) }
      let event: JSONValue = .object(["type": .string("request_user_input"),
        "call_id": .string("question"), "turn_id": .string("turn"), "isBlocking": .bool(blocking),
        "questions": .array([.object(["id": .string("account"), "header": .string("Account"),
          "question": .string("Which CI account should be connected?")])])])
      do {
        try await store.handleCodexQuestion(runID: "run", taskID: watch.taskID!, event: event)
        XCTFail("Unattended question must finish the turn")
      } catch { XCTAssertTrue(error.localizedDescription.contains("需要回答问题")) }
      XCTAssertFalse(try AutomationStorage.load(root: root).items[0].enabled)
      XCTAssertTrue(store.automationPreferences.items[0].pauseReason?.contains("Which CI account") == true)
      XCTAssertEqual(store.library.chatRuns[0].codexQuestions.first?.status, .expired)
      XCTAssertTrue(store.codexPendingQuestions.isEmpty)
    }
  }

  func testStaleEditorCannotResumeAndExplicitResumeKeepsRetainedTask() throws {
    let (store, root, watch) = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    _ = try store.pauseWatchedAutomation(runID: "run", reason: "Missing access")
    var stale = watch
    stale.prompt = "Updated instruction"
    XCTAssertTrue(store.saveEditedAutomation(stale))
    XCTAssertFalse(store.automationPreferences.items[0].enabled)
    XCTAssertEqual(store.automationPreferences.items[0].pauseReason, "Missing access")
    store.setAutomationEnabled(true, id: watch.id)
    let resumed = try XCTUnwrap(AutomationStorage.load(root: root).items.first)
    XCTAssertTrue(resumed.enabled)
    XCTAssertNil(resumed.pauseReason)
    XCTAssertNil(resumed.pausedAt)
    XCTAssertEqual(resumed.taskID, watch.taskID)
    XCTAssertGreaterThan(resumed.nextRun, Date())
    XCTAssertEqual(store.library.tasks[0].runIDs, ["run"])
  }

  func testPauseRoundTripInBothModelProtocolsAndManualTurnHasNoControl() async throws {
    let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().appendingPathComponent("Fixtures/model_server.py")
    let server = Process()
    server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    server.arguments = ["-u", fixture.path]
    let pipe = Pipe()
    server.standardOutput = pipe
    server.standardError = FileHandle.nullDevice
    try server.run()
    defer { if server.isRunning { server.terminate(); server.waitUntilExit() } }
    let port = String(decoding: pipe.fileHandleForReading.availableData, as: UTF8.self)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard Int(port) != nil else { throw AgentFailure(message: "Local fixture could not bind") }
    let repository = fixture.deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    for api in [ModelAPIProtocol.chatCompletions, .codexResponses] {
      let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      defer { try? FileManager.default.removeItem(at: root) }
      let store = WorkspaceStore(dataRoot: root,
        agentExecutable: repository.appendingPathComponent("target/debug/shipios-agent"))
      await store.restore()
      var config = ModelConfiguration()
      config.baseURL = "http://127.0.0.1:\(port)/v1"
      config.model = api == .codexResponses ? "gpt-5.4" : "fixture"
      config.apiProtocol = api
      try store.saveModelConfiguration(config)
      store.notificationPreferences = .init(timing: .never)
      let taskID = UUID().uuidString
      store.library.tasks.append(.init(id: taskID, project: root.path, title: "Watch", runIDs: []))
      var watch = ShipAutomation(name: "Watch", prompt: "automation-pause-fixture")
      watch.taskID = taskID
      watch.project = root.path
      watch.cadence = .custom
      watch.customRule = "FREQ=MINUTELY;INTERVAL=10"
      watch.scheduleAnchor = .now
      watch.watchedPullRequest = .init(number: 17,
        url: "https://github.com/example/project/pull/17", title: "Fix", isDraft: false,
        headRefName: "fix", baseRefName: "main", isCrossRepository: false)
      XCTAssertTrue(store.saveAutomation(watch))
      let started = await store.startChat("automation-pause-fixture", taskID: taskID, automationID: watch.id)
      let runID = try XCTUnwrap(started, store.error ?? "Run not started")
      await store.modelTask(runID: runID)?.value
      let run = try XCTUnwrap(store.library.chatRuns.first { $0.id == runID })
      XCTAssertEqual(run.status, "succeeded", run.result?.pretty ?? "")
      XCTAssertTrue(run.result?["response"].text?.contains("Heartbeat paused") == true, run.result?.pretty ?? "")
      XCTAssertFalse(try AutomationStorage.load(root: root).items[0].enabled)
      await store.runAutomation(watch.id, readWatchedPullRequest: { _, _ in
        XCTFail("A paused watch must not run again")
        throw AgentFailure(message: "Paused")
      })
      let manual = await store.startChat("automation-pause-fixture manual", taskID: taskID)
      let manualID = try XCTUnwrap(manual, store.error ?? "Manual run not started")
      await store.modelTask(runID: manualID)?.value
      let manualRun = try XCTUnwrap(store.library.chatRuns.first { $0.id == manualID })
      XCTAssertEqual(manualRun.status, "succeeded", manualRun.result?.pretty ?? "")
      XCTAssertTrue(manualRun.result?["response"].text?.contains("Pause tool unavailable") == true,
        manualRun.result?.pretty ?? "")
      XCTAssertEqual(store.automationPreferences.items[0].taskID, taskID)
      await store.shutdown()
    }
  }
}
