import Foundation
import AppKit
import SwiftUI
import XCTest
@testable import ShipiOS

@MainActor private final class WatchFeedbackDelivery: NotificationDelivery {
  var notices: [CompletionNotice] = []
  var onPost: (() -> Void)?
  func permission() async -> NotificationPermission { .authorized }
  func requestPermission() async throws { }
  func post(_ notice: CompletionNotice) async throws {
    notices.append(notice); onPost?()
  }
}

@MainActor final class PullRequestWatchWorktreeTests: XCTestCase {
  private let request = GitHubPullRequest(number: 17,
    url: "https://github.com/example/project/pull/17", title: "Fix", isDraft: false,
    headRefName: "fix", baseRefName: "main", isCrossRepository: false)

  private func fixture() async throws -> (WorkspaceStore, URL, URL, ShipAutomation) {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let source = base.appendingPathComponent("Source")
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    _ = try await GitReviewService.checked(["init", "-q", "-b", "main"], at: source)
    _ = try await GitReviewService.checked(["config", "user.name", "ShipiOS Test"], at: source)
    _ = try await GitReviewService.checked(["config", "user.email", "qa@example.invalid"], at: source)
    try "committed\n".write(to: source.appendingPathComponent("file"), atomically: true, encoding: .utf8)
    _ = try await GitReviewService.checked(["add", "file"], at: source)
    _ = try await GitReviewService.checked(["commit", "-qm", "Initial"], at: source)
    try "user edit\n".write(to: source.appendingPathComponent("file"), atomically: true, encoding: .utf8)
    try "private note\n".write(to: source.appendingPathComponent("extra"), atomically: true, encoding: .utf8)
    let store = WorkspaceStore(dataRoot: base.appendingPathComponent("Data"),
      agentExecutable: try AgentTestExecutable.url())
    await store.restore()
    store.library.visit(source.path)
    store.notificationPreferences = .init(timing: .never)
    var watch = ShipAutomation(name: "Watch", prompt: "watch-lazy-fixture")
    watch.project = source.path
    watch.taskID = UUID().uuidString
    watch.watchedPullRequest = request
    watch.execution = .worktree
    watch.cadence = .custom; watch.customRule = "FREQ=MINUTELY;INTERVAL=10"
    watch.scheduleAnchor = .now; watch.nextRun = .now.addingTimeInterval(600)
    store.library.tasks = [.init(id: watch.taskID!, project: source.path, title: "Watch", runIDs: [])]
    XCTAssertTrue(store.saveLibrary())
    XCTAssertTrue(store.saveAutomation(watch))
    return (store, base, source, watch)
  }

  private func addInspection(_ store: WorkspaceStore, watch: ShipAutomation,
    status: String = "running", requested: Bool = false) -> String {
    let id = UUID().uuidString
    let run = AgentRun(id: id, kind: "chat", project: watch.project, status: status,
      createdAt: 0, updatedAt: 0, request: .object([
        "automation_id": .string(watch.id.uuidString), "watch_phase": .string("inspection")]),
      result: .object(requested ? ["watch_worktree_request": .string("PR compile error")] : [:]))
    store.library.chatRuns.append(run)
    store.library.tasks[0].runIDs.append(id)
    XCTAssertTrue(store.saveLibrary())
    return id
  }

  private func call(_ reason: String = "PR compile error") -> ModelFunctionCall {
    .init(id: UUID().uuidString, name: ModelWatchWorktreeTool.name,
      arguments: JSONValue.object(["reason": .string(reason)]).pretty)
  }

  private func startServer() throws -> (Process, String) {
    let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().appendingPathComponent("Fixtures/model_server.py")
    let process = Process(), pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    process.arguments = ["-u", fixture.path]
    process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
    try process.run()
    let port = String(decoding: pipe.fileHandleForReading.availableData, as: UTF8.self)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard Int(port) != nil else {
      if process.isRunning { process.terminate(); process.waitUntilExit() }
      throw AgentFailure(message: "Local fixture could not bind")
    }
    return (process, port)
  }

  private func configure(_ store: WorkspaceStore, port: String, api: ModelAPIProtocol) throws {
    var configuration = ModelConfiguration()
    configuration.baseURL = "http://127.0.0.1:\(port)/v1"
    configuration.apiProtocol = api
    configuration.model = api == .codexResponses ? "gpt-5.4" : "fixture"
    try store.saveModelConfiguration(configuration)
  }

  private func liveDetails() -> GitHubPRDetails {
    .init(number: 17, url: request.url, title: request.title, body: nil, state: "OPEN",
      isDraft: false, headRefName: "fix", baseRefName: "main", reviewDecision: nil,
      mergeable: "MERGEABLE", statusCheckRollup: [])
  }

  func testRequestPersistsWithoutCreatingAndRepeatedCallKeepsFirstReason() async throws {
    let (store, base, source, watch) = try await fixture()
    defer { try? FileManager.default.removeItem(at: base) }
    let id = addInspection(store, watch: watch)
    let output = try store.executeWatchWorktreeTool(call(), runID: id, expectedAutomationID: watch.id)
    XCTAssertTrue(output.contains("requested")); XCTAssertTrue(output.contains("false"))
    _ = try store.executeWatchWorktreeTool(call("Another reason"), runID: id, expectedAutomationID: watch.id)
    let loaded = try WorkspaceLibrary.load(from: store.dataRoot.appendingPathComponent("workspace.json"))
    XCTAssertEqual(loaded.chatRuns[0].result?["watch_worktree_request"].text, "PR compile error")
    XCTAssertTrue(loaded.managedWorktrees.isEmpty)
    XCTAssertEqual(loaded.tasks[0].project, source.path)
    XCTAssertFalse(FileManager.default.fileExists(atPath: store.worktreeRoot.path))
    await store.shutdown()
  }

  func testInvalidScopePausedWatchAndReasonNeverRequestCreation() async throws {
    let (store, base, _, watch) = try await fixture()
    defer { try? FileManager.default.removeItem(at: base) }
    let id = addInspection(store, watch: watch)
    for (reason, target) in [("PR compile error", UUID()), ("  ", watch.id),
      (String(repeating: "x", count: 4097), watch.id), ("bad\0reason", watch.id)] {
      let result = try store.executeWatchWorktreeTool(call(reason), runID: id, expectedAutomationID: target)
      XCTAssertTrue(result.contains("error"))
    }
    store.setAutomationEnabled(false, id: watch.id)
    XCTAssertTrue(try store.executeWatchWorktreeTool(call(), runID: id,
      expectedAutomationID: watch.id).contains("error"))
    XCTAssertNil(store.library.chatRuns[0].result?["watch_worktree_request"].text)
    XCTAssertTrue(store.library.managedWorktrees.isEmpty)
    await store.shutdown()
  }

  func testFailedCancelledAndPausedInspectionsDoNotPrepare() async throws {
    for status in ["failed", "cancelled", "interrupted", "succeeded"] {
      let (store, base, _, watch) = try await fixture()
      defer { try? FileManager.default.removeItem(at: base) }
      let id = addInspection(store, watch: watch, status: status, requested: true)
      if status == "succeeded" { store.setAutomationEnabled(false, id: watch.id) }
      let results = try await store.continueWatchInWorktree(id: watch.id,
        project: watch.project, taskID: watch.taskID!, inspectionRunID: id)
      XCTAssertEqual(results, [id]); XCTAssertTrue(store.library.managedWorktrees.isEmpty)
      await store.shutdown()
    }
  }

  func testRequestSaveFailureDoesNotAcknowledgeOrCreate() async throws {
    let (store, base, _, watch) = try await fixture()
    defer { try? FileManager.default.removeItem(at: base) }
    let id = addInspection(store, watch: watch)
    let file = store.dataRoot.appendingPathComponent("workspace.json")
    try FileManager.default.removeItem(at: file)
    try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
    XCTAssertThrowsError(try store.executeWatchWorktreeTool(call(), runID: id, expectedAutomationID: watch.id))
    XCTAssertNil(store.library.chatRuns[0].result?["watch_worktree_request"].text)
    XCTAssertTrue(store.library.managedWorktrees.isEmpty)
    await store.shutdown()
  }

  func testForeignInspectionCannotPrepareAndPauseDuringSetupCannotStartRepair() async throws {
    let (store, base, source, watch) = try await fixture()
    defer { try? FileManager.default.removeItem(at: base) }
    let id = addInspection(store, watch: watch, status: "succeeded", requested: true)
    do {
      _ = try await store.continueWatchInWorktree(id: UUID(), project: watch.project,
        taskID: watch.taskID!, inspectionRunID: id)
      XCTFail("A foreign automation cannot consume the inspection")
    } catch { }
    XCTAssertTrue(store.library.managedWorktrees.isEmpty)
    store.library.profiles[source.path] = BuildProfile(
      worktreeSetupScript: "sleep 0.5; printf ready > setup-marker")
    XCTAssertTrue(store.saveLibrary())
    let preparation = Task {
      try await store.continueWatchInWorktree(id: watch.id, project: watch.project,
        taskID: watch.taskID!, inspectionRunID: id)
    }
    let deadline = Date().addingTimeInterval(5)
    while store.library.managedWorktrees.first?.ready != true && Date() < deadline {
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTAssertTrue(store.library.managedWorktrees.first?.ready == true)
    store.setAutomationEnabled(false, id: watch.id)
    let result = try await preparation.value
    XCTAssertEqual(result, [id])
    XCTAssertEqual(store.library.chatRuns.count, 1)
    XCTAssertEqual(store.library.tasks[0].project, source.path)
    XCTAssertFalse(store.automationPreferences.items[0].enabled)
    XCTAssertFalse(FileManager.default.fileExists(atPath: source.appendingPathComponent("setup-marker").path))
    await store.shutdown()
  }

  func testInspectionWithoutRepairKeepsSourceInBothProtocols() async throws {
    let (server, port) = try startServer()
    defer { if server.isRunning { server.terminate(); server.waitUntilExit() } }
    for api in [ModelAPIProtocol.chatCompletions, .codexResponses] {
      let (store, base, source, watch) = try await fixture()
      defer { try? FileManager.default.removeItem(at: base) }
      try configure(store, port: port, api: api)
      store.library.gitPreferences.pullRequestWatchInstructions = "watch-lazy-fixture watch-lazy-nochange"
      let details = liveDetails()
      await store.runAutomation(watch.id, readWatchedPullRequest: { _, _ in details })
      let run = try XCTUnwrap(store.library.chatRuns.last, store.automationsError ?? store.error ?? "")
      XCTAssertEqual(run.status, "succeeded", run.result?.pretty ?? "")
      XCTAssertEqual(run.request["watch_phase"].text, "inspection")
      XCTAssertEqual(run.project, source.path)
      XCTAssertTrue(run.result?["response"].text?.contains("no authorized code change") == true)
      XCTAssertTrue(store.library.managedWorktrees.isEmpty)
      XCTAssertEqual(store.library.tasks[0].project, source.path)
      XCTAssertEqual(store.automationPreferences.items[0].unresolvedRunIDs, [run.id])
      XCTAssertGreaterThan(store.automationPreferences.items[0].nextRun, Date())
      await store.shutdown()
    }
  }

  func testModelRequestsRepairThenContinuesInOneCleanCheckoutInBothProtocols() async throws {
    let (server, port) = try startServer()
    defer { if server.isRunning { server.terminate(); server.waitUntilExit() } }
    for api in [ModelAPIProtocol.chatCompletions, .codexResponses] {
      let (store, base, source, watch) = try await fixture()
      defer { try? FileManager.default.removeItem(at: base) }
      try configure(store, port: port, api: api)
      store.library.gitPreferences.pullRequestWatchInstructions = "watch-lazy-fixture watch-lazy-write-attempt"
      let details = liveDetails()
      await store.runAutomation(watch.id, readWatchedPullRequest: { _, _ in details })
      XCTAssertEqual(store.library.chatRuns.count, 2, store.automationsError ?? store.error ?? "")
      let inspection = try XCTUnwrap(store.library.chatRuns.first)
      let repair = try XCTUnwrap(store.library.chatRuns.last)
      XCTAssertEqual(inspection.status, "succeeded", inspection.result?.pretty ?? "")
      XCTAssertEqual(repair.status, "succeeded", repair.result?.pretty ?? "")
      XCTAssertEqual(repair.request["watch_inspection_run_id"].text, inspection.id)
      let record = try XCTUnwrap(store.library.managedWorktrees.first, store.automationsError ?? "")
      XCTAssertEqual(store.library.managedWorktrees.count, 1)
      XCTAssertEqual(record.taskID, watch.taskID)
      XCTAssertEqual(inspection.project, source.path); XCTAssertEqual(repair.project, record.path)
      XCTAssertEqual(store.library.tasks[0].runIDs, [inspection.id, repair.id])
      XCTAssertEqual(store.library.tasks[0].project, record.path)
      XCTAssertEqual(store.automationPreferences.items[0].unresolvedRunIDs, [inspection.id, repair.id])
      XCTAssertEqual(try String(contentsOf: URL(fileURLWithPath: record.path).appendingPathComponent("file")), "committed\n")
      XCTAssertFalse(FileManager.default.fileExists(atPath: URL(fileURLWithPath: record.path).appendingPathComponent("extra").path))
      XCTAssertEqual(try String(contentsOf: source.appendingPathComponent("file")), "user edit\n")
      XCTAssertFalse(FileManager.default.fileExists(atPath: source.appendingPathComponent("source-must-not-change.txt").path))
      XCTAssertFalse(FileManager.default.fileExists(atPath: source.appendingPathComponent("lazy-repair-proof.txt").path))
      if api == .codexResponses {
        XCTAssertEqual(try String(contentsOf: URL(fileURLWithPath: record.path).appendingPathComponent("lazy-repair-proof.txt")), "repaired only in isolation\n")
      }
      let recovered = try await store.continueWatchInWorktree(id: watch.id, project: watch.project,
        taskID: watch.taskID!, inspectionRunID: repair.id)
      XCTAssertEqual(recovered, [inspection.id, repair.id])
      XCTAssertEqual(store.library.chatRuns.count, 2)
      await store.shutdown()
    }
  }

  func testModelPauseAfterRequestPreventsCreationInBothProtocols() async throws {
    let (server, port) = try startServer()
    defer { if server.isRunning { server.terminate(); server.waitUntilExit() } }
    for api in [ModelAPIProtocol.chatCompletions, .codexResponses] {
      let (store, base, source, watch) = try await fixture()
      defer { try? FileManager.default.removeItem(at: base) }
      try configure(store, port: port, api: api)
      store.library.gitPreferences.pullRequestWatchInstructions = "watch-lazy-fixture watch-lazy-pause"
      let details = liveDetails()
      await store.runAutomation(watch.id, readWatchedPullRequest: { _, _ in details })
      XCTAssertEqual(store.library.chatRuns.count, 1)
      XCTAssertEqual(store.library.chatRuns[0].status, "succeeded", store.library.chatRuns[0].result?.pretty ?? "")
      XCTAssertNotNil(store.library.chatRuns[0].result?["watch_worktree_request"].text)
      XCTAssertFalse(store.automationPreferences.items[0].enabled)
      XCTAssertTrue(store.library.managedWorktrees.isEmpty)
      XCTAssertEqual(store.library.tasks[0].project, source.path)
      await store.shutdown()
    }
  }

  func testSavedRequestWithPreparedCheckoutResumesWithoutCreatingAnother() async throws {
    let (server, port) = try startServer()
    defer { if server.isRunning { server.terminate(); server.waitUntilExit() } }
    let (store, base, source, original) = try await fixture()
    defer { try? FileManager.default.removeItem(at: base) }
    try configure(store, port: port, api: .chatCompletions)
    let inspectionID = addInspection(store, watch: original, status: "succeeded", requested: true)
    let prepared = try await store.prepareAutomationWorktree(sourcePath: source.path,
      taskID: original.taskID!, environmentSelection: WorktreeEnvironmentChoice.none,
      includeSourceChanges: false)
    store.library.tasks[0].project = prepared.path
    XCTAssertTrue(store.saveLibrary())
    var watch = original
    watch.activeOccurrenceAt = .now
    watch.preparingTaskIDs = [source.path: original.taskID!]
    XCTAssertTrue(store.saveAutomation(watch))
    await store.shutdown()
    let restored = WorkspaceStore(dataRoot: store.dataRoot)
    await restored.restore()
    restored.notificationPreferences = .init(timing: .never)
    await restored.runAutomation(watch.id, readWatchedPullRequest: { _, _ in
      XCTFail("Resume does not repeat the completed PR preflight")
      throw CancellationError()
    })
    XCTAssertEqual(restored.library.managedWorktrees.map(\.id), [prepared.id])
    XCTAssertEqual(restored.library.tasks[0].project, prepared.path)
    XCTAssertEqual(restored.library.chatRuns.count, 2, restored.automationsError ?? restored.error ?? "")
    XCTAssertEqual(restored.library.chatRuns.last?.status, "succeeded")
    XCTAssertEqual(restored.library.chatRuns.last?.request["watch_inspection_run_id"].text, inspectionID)
    XCTAssertNil(restored.automationPreferences.items[0].activeOccurrenceAt)
    await restored.shutdown()
  }

  func testManualCoreTurnAfterInspectionRestoresNormalPermissionsAndNoWatchTools() async throws {
    let (server, port) = try startServer()
    defer { if server.isRunning { server.terminate(); server.waitUntilExit() } }
    let (store, base, source, watch) = try await fixture()
    defer { try? FileManager.default.removeItem(at: base) }
    try configure(store, port: port, api: .codexResponses)
    let started = await store.startChat("watch-lazy-fixture watch-lazy-nochange",
      taskID: watch.taskID, automationID: watch.id)
    let runID = try XCTUnwrap(started, store.error ?? "")
    await store.modelTask(runID: runID)?.value
    XCTAssertEqual(store.library.chatRuns.last?.status, "succeeded")
    let manual = await store.startChat("codex-after-plan", taskID: watch.taskID)
    let manualID = try XCTUnwrap(manual, store.error ?? "")
    await store.modelTask(runID: manualID)?.value
    XCTAssertEqual(store.library.chatRuns.last?.status, "succeeded", store.library.chatRuns.last?.result?.pretty ?? "")
    XCTAssertTrue(FileManager.default.fileExists(atPath: source.appendingPathComponent("after-plan-write-proof.txt").path))
    XCTAssertNil(store.library.chatRuns.last?.request["watch_phase"].text)
    XCTAssertTrue(store.library.managedWorktrees.isEmpty)
    await store.shutdown()
  }

  func testInspectionFromExistingManagedCheckoutCreatesItsOwnRepairCheckout() async throws {
    let (server, port) = try startServer()
    defer { if server.isRunning { server.terminate(); server.waitUntilExit() } }
    let (store, base, source, original) = try await fixture()
    defer { try? FileManager.default.removeItem(at: base) }
    try configure(store, port: port, api: .chatCompletions)
    let configured = try await store.prepareAutomationWorktree(sourcePath: source.path,
      taskID: UUID().uuidString, environmentSelection: WorktreeEnvironmentChoice.none,
      includeSourceChanges: false)
    try "configured worktree edit\n".write(to: URL(fileURLWithPath: configured.path)
      .appendingPathComponent("file"), atomically: true, encoding: .utf8)
    var watch = original
    watch.project = configured.path
    store.library.tasks[0].project = configured.path
    XCTAssertTrue(store.saveAutomation(watch))
    let inspection = addInspection(store, watch: watch, status: "succeeded", requested: true)
    let results = try await store.continueWatchInWorktree(id: watch.id, project: configured.path,
      taskID: watch.taskID!, inspectionRunID: inspection)
    let repair = try XCTUnwrap(store.library.managedWorktree(forTaskID: watch.taskID!))
    XCTAssertNotEqual(repair.path, configured.path)
    XCTAssertEqual(repair.source, source.path)
    XCTAssertEqual(store.library.managedWorktrees.count, 2)
    XCTAssertEqual(results.count, 2)
    XCTAssertEqual(try String(contentsOf: URL(fileURLWithPath: configured.path).appendingPathComponent("file")), "configured worktree edit\n")
    XCTAssertEqual(try String(contentsOf: URL(fileURLWithPath: repair.path).appendingPathComponent("file")), "committed\n")
    await store.shutdown()
  }

  private func notifications(_ store: WorkspaceStore) -> WatchFeedbackDelivery {
    let delivery = WatchFeedbackDelivery()
    store.notifications = CompletionNotificationCenter(delivery: delivery)
    store.notificationPreferences = .init(timing: .always)
    return delivery
  }

  private func waitForPreparation(_ store: WorkspaceStore, taskID: String) async throws -> AgentRun {
    let deadline = Date().addingTimeInterval(10)
    while Date() < deadline {
      if let run = store.watchWorktreePreparationRun(taskID: taskID),
        run.toolExecutions.contains(where: {
          $0.callID == "watch-worktree-preparation:" + run.id && $0.status == .running
        }), store.library.managedWorktrees.first?.ready == true { return run }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    throw AgentFailure(message: "Preparation not observed: " + (store.automationsError ?? store.error ?? ""))
  }

  private func holdSetup(_ store: WorkspaceStore, source: URL) {
    store.library.profiles[source.path] = BuildProfile(worktreeSetupScript:
      "watch_test_attempt=0; while [ \"$watch_test_attempt\" -lt 200 ]; do "
      + "if [ -f .release-preparation ]; then exit 0; fi; "
      + "watch_test_attempt=$((watch_test_attempt+1)); sleep 0.05; done; exit 1")
  }

  func testLivePreparationPreservesDraftAndOnlyFinalRepairNotifiesInBothProtocols() async throws {
    let (server, port) = try startServer()
    defer { if server.isRunning { server.terminate(); server.waitUntilExit() } }
    for api in [ModelAPIProtocol.chatCompletions, .codexResponses] {
      let (store, base, source, watch) = try await fixture()
      defer { try? FileManager.default.removeItem(at: base) }
      try configure(store, port: port, api: api)
      store.project = source
      let delivery = notifications(store)
      let delivered = expectation(description: "Only final repair notifies: " + api.rawValue)
      delivery.onPost = { delivered.fulfill() }
      store.library.gitPreferences.pullRequestWatchInstructions = "watch-lazy-fixture"
      holdSetup(store, source: source)
      let details = liveDetails()
      let occurrence = Task { await store.runAutomation(watch.id, readWatchedPullRequest: { _, _ in details }) }
      let inspection = try await waitForPreparation(store, taskID: watch.taskID!)
      XCTAssertTrue(delivery.notices.isEmpty)
      XCTAssertTrue(store.isPreparingWatchWorktree(runID: inspection.id))
      XCTAssertFalse(store.canStartChat(taskID: watch.taskID))
      XCTAssertFalse(store.library.unreadTasks.contains(watch.taskID!))
      store.setTaskWindowDraft("Keep this guidance", taskID: watch.taskID!)
      await store.sendTaskWindowDraft(watch.taskID!, mode: .standard)
      XCTAssertEqual(store.taskWindowDraft(watch.taskID!), "Keep this guidance")
      XCTAssertEqual(store.library.chatRuns.count, 1)
      store.observeCompletions([inspection])
      XCTAssertTrue(delivery.notices.isEmpty)
      let path = try XCTUnwrap(store.library.managedWorktrees.first?.path)
      try "continue".write(to: URL(fileURLWithPath: path).appendingPathComponent(".release-preparation"),
        atomically: true, encoding: .utf8)
      await occurrence.value
      await fulfillment(of: [delivered], timeout: 2)
      let repair = try XCTUnwrap(store.library.chatRuns.last)
      XCTAssertEqual(repair.status, "succeeded", repair.result?.pretty ?? "")
      XCTAssertEqual(delivery.notices.count, 1)
      XCTAssertEqual(delivery.notices[0].destination?.runID, repair.id)
      XCTAssertEqual(delivery.notices[0].destination?.project, path)
      XCTAssertEqual(delivery.notices[0].title, "任务已完成")
      XCTAssertEqual(store.taskWindowDraft(watch.taskID!), "Keep this guidance")
      XCTAssertNil(store.watchWorktreePreparationRun(taskID: watch.taskID!))
      XCTAssertTrue(store.canStartChat(taskID: watch.taskID))
      let preparation = try XCTUnwrap(store.library.chatRuns.first?.toolExecutions.first {
        $0.callID == "watch-worktree-preparation:" + inspection.id
      })
      XCTAssertEqual(preparation.status, .succeeded)
      XCTAssertTrue(preparation.output?.contains(path) == true)
      let opened = await store.openNotification(try XCTUnwrap(delivery.notices[0].destination))
      XCTAssertTrue(opened)
      XCTAssertEqual(store.conversationReveal?.runID, repair.id)
      await store.shutdown()
    }
  }

  func testFailedPreparationShowsActualFailureAndDoesNotNotifyCompleted() async throws {
    let (server, port) = try startServer()
    defer { if server.isRunning { server.terminate(); server.waitUntilExit() } }
    let (store, base, source, watch) = try await fixture()
    defer { try? FileManager.default.removeItem(at: base) }
    try configure(store, port: port, api: .chatCompletions)
    store.project = source
    let delivery = notifications(store)
    store.library.gitPreferences.pullRequestWatchInstructions = "watch-lazy-fixture"
    store.library.profiles[source.path] = BuildProfile(worktreeSetupScript: "printf 'setup failed' >&2; exit 1")
    let details = liveDetails()
    await store.runAutomation(watch.id, readWatchedPullRequest: { _, _ in details })
    let inspection = try XCTUnwrap(store.library.chatRuns.first)
    XCTAssertEqual(inspection.status, "succeeded")
    let preparation = try XCTUnwrap(inspection.toolExecutions.first {
      $0.callID == "watch-worktree-preparation:" + inspection.id
    })
    XCTAssertEqual(preparation.status, .failed)
    XCTAssertTrue(preparation.output?.contains("setup failed") == true)
    XCTAssertTrue(store.notices.items.contains { $0.title.contains("准备失败") })
    XCTAssertEqual(store.library.tasks[0].project, source.path)
    XCTAssertEqual(store.library.chatRuns.count, 1)
    XCTAssertTrue(delivery.notices.isEmpty)
    XCTAssertNil(store.watchWorktreePreparationRun(taskID: watch.taskID!))
    XCTAssertTrue(store.canStartChat(taskID: watch.taskID))
    XCTAssertGreaterThan(store.automationPreferences.items[0].nextRun.timeIntervalSinceNow, 290)
    XCTAssertNotNil(store.automationPreferences.items[0].activeOccurrenceAt)
    await store.shutdown()
  }

  func testSinglePhaseChecksAndModelPauseStillNotifyOnceInBothProtocols() async throws {
    let (server, port) = try startServer()
    defer { if server.isRunning { server.terminate(); server.waitUntilExit() } }
    for api in [ModelAPIProtocol.chatCompletions, .codexResponses] {
      for marker in ["watch-lazy-nochange", "watch-lazy-pause"] {
        let (store, base, source, watch) = try await fixture()
        defer { try? FileManager.default.removeItem(at: base) }
        try configure(store, port: port, api: api)
        store.project = source
        let delivery = notifications(store)
        let delivered = expectation(description: marker + api.rawValue)
        delivery.onPost = { delivered.fulfill() }
        store.library.gitPreferences.pullRequestWatchInstructions = "watch-lazy-fixture " + marker
        let details = liveDetails()
        await store.runAutomation(watch.id, readWatchedPullRequest: { _, _ in details })
        await fulfillment(of: [delivered], timeout: 2)
        XCTAssertEqual(store.library.chatRuns.count, 1)
        XCTAssertEqual(delivery.notices.count, 1)
        XCTAssertEqual(delivery.notices[0].destination?.runID, store.library.chatRuns[0].id)
        XCTAssertTrue(store.library.managedWorktrees.isEmpty)
        XCTAssertNil(store.watchWorktreePreparationRun(taskID: watch.taskID!))
        await store.shutdown()
      }
    }
  }

  func testRestartCancelsUnconfirmedHostPreparationWithoutChangingModelResult() async throws {
    let (store, base, _, watch) = try await fixture()
    defer { try? FileManager.default.removeItem(at: base) }
    let id = addInspection(store, watch: watch, status: "succeeded", requested: true)
    let preparation = MCPToolExecution(callID: "watch-worktree-preparation:" + id,
      serverID: ModelAutomationPauseTool.serverID, serverName: "ShipiOS", toolName: "准备 PR 修复工作树",
      arguments: "{}", status: .running)
    try store.saveToolExecution(preparation, runID: id)
    store.restoreInterruptedChats()
    let restored = try XCTUnwrap(store.library.chatRuns.first)
    XCTAssertEqual(restored.status, "succeeded")
    XCTAssertEqual(restored.toolExecutions[0].status, .cancelled)
    XCTAssertTrue(restored.toolExecutions[0].output?.contains("尚未确认") == true)
    XCTAssertFalse(store.isPreparingWatchWorktree(runID: id))
    XCTAssertTrue(store.canStartChat(taskID: watch.taskID))
    let disk = try WorkspaceLibrary.load(from: store.dataRoot.appendingPathComponent("workspace.json"))
    XCTAssertEqual(disk.chatRuns[0].toolExecutions[0].status, .cancelled)
    await store.shutdown()
  }

  func testNativeProgressKeepsEditableComposerDuringRealWorktreeSetup() async throws {
    let (server, port) = try startServer()
    defer { if server.isRunning { server.terminate(); server.waitUntilExit() } }
    let (store, base, source, watch) = try await fixture()
    defer { try? FileManager.default.removeItem(at: base) }
    try configure(store, port: port, api: .chatCompletions)
    store.project = source
    store.library.taskPullRequests[watch.taskID!] = [request]
    store.library.gitPreferences.pullRequestWatchInstructions = "watch-lazy-fixture"
    holdSetup(store, source: source)
    store.draft = "source draft"
    store.setTaskWindowDraft("watch draft", taskID: watch.taskID!)
    let details = liveDetails()
    let occurrence = Task { await store.runAutomation(watch.id, readWatchedPullRequest: { _, _ in details }) }
    let inspection = try await waitForPreparation(store, taskID: watch.taskID!)
    let tab = WorkspaceContentTab.pullRequestWatch(watch.id, task: watch.taskID!, owner: watch.taskID!)
    let host = NSHostingView(rootView: PullRequestWatchProgressView(store: store, tab: tab, close: {})
      .frame(width: 430, height: 680))
    let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 430, height: 680),
      styleMask: [.titled], backing: .buffered, defer: true)
    window.isReleasedWhenClosed = false; window.contentView = host
    defer { window.contentView = nil; window.close() }
    try await Task.sleep(for: .milliseconds(700)); host.layoutSubtreeIfNeeded()
    func editors(_ view: NSView) -> [ComposerNativeTextView] {
      ((view as? ComposerNativeTextView).map { [$0] } ?? []) + view.subviews.flatMap(editors)
    }
    let editor = try XCTUnwrap(editors(host).first)
    XCTAssertTrue(editor.isEditable)
    editor.selectAll(nil); editor.insertText("Notes while preparing", replacementRange: editor.selectedRange())
    try await Task.sleep(for: .milliseconds(100))
    XCTAssertEqual(store.taskWindowDraft(watch.taskID!), "Notes while preparing")
    XCTAssertEqual(store.draft, "source draft")
    XCTAssertTrue(store.isPreparingWatchWorktree(runID: inspection.id))
    XCTAssertFalse(store.canStartChat(taskID: watch.taskID))
    if let path = ProcessInfo.processInfo.environment["SHIPIOS_PR_WATCH_FEEDBACK_RENDER_PATH"] {
      let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
      host.cacheDisplay(in: host.bounds, to: bitmap)
      try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: path))
    }
    let path = try XCTUnwrap(store.library.managedWorktrees.first?.path)
    try "continue".write(to: URL(fileURLWithPath: path).appendingPathComponent(".release-preparation"),
      atomically: true, encoding: .utf8)
    await occurrence.value
    XCTAssertEqual(store.library.chatRuns.count, 2)
    await store.shutdown()
  }
}
