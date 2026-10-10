import Darwin
import XCTest
@testable import ShipiOS

final class CodexRequestRecoveryTests: XCTestCase {
  private var server: Process!
  private var endpoint = ""
  override func setUpWithError() throws {
    server = Process(); server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    server.arguments = ["-u", URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().appendingPathComponent("Fixtures/request_recovery_server.py").path]
    let output = Pipe(); server.standardOutput = output; server.standardError = FileHandle.nullDevice
    try server.run()
    let port = String(decoding: output.fileHandleForReading.availableData, as: UTF8.self)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    endpoint = "http://127.0.0.1:\(try XCTUnwrap(Int(port)))/v1"
  }
  override func tearDown() {
    if server?.isRunning == true { server.terminate(); server.waitUntilExit() }
  }
  @MainActor private func setup() async throws -> (WorkspaceStore, URL) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("request-recovery-\(UUID())")
    let project = root.appendingPathComponent("Project")
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    let store = WorkspaceStore(dataRoot: root.appendingPathComponent("Data"),
      agentExecutable: try AgentTestExecutable.url())
    addTeardownBlock { await store.shutdown(); try? FileManager.default.removeItem(at: root) }
    await store.restore(); await store.open(project)
    var config = ModelConfiguration(); config.baseURL = endpoint
    config.apiProtocol = .codexResponses; config.model = "gpt-5.4"
    try store.saveModelConfiguration(config); store.notificationPreferences = .init(timing: .never)
    return (store, root)
  }
  @MainActor private func waitFor(_ condition: @escaping @MainActor () -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(15))
    while !condition() {
      guard ContinuousClock.now < deadline else { throw AgentFailure(message: "Request recovery timed out") }
      try await Task.sleep(for: .milliseconds(20))
    }
  }
  private func killOwnedCoreAgent(root: URL) throws {
    let process = Process(), output = Pipe()
    process.executableURL = URL(fileURLWithPath: "/bin/ps")
    process.arguments = ["-axo", "pid=,command="]; process.standardOutput = output
    try process.run()
    let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    process.waitUntilExit(); XCTAssertEqual(process.terminationStatus, 0)
    let candidates = text.split(separator: "\n").filter {
      $0.contains(root.appendingPathComponent("Data/CodexAgents").path) && $0.contains("shipios-agent")
    }
    XCTAssertEqual(candidates.count, 1)
    let line = try XCTUnwrap(candidates.first)
    let pid = try XCTUnwrap(Int32(try XCTUnwrap(line.split(whereSeparator: { $0.isWhitespace }).first)))
    XCTAssertEqual(Darwin.kill(pid, SIGKILL), 0)
  }
  @MainActor func testDisconnectedApprovalExpiresAndRetryCannotApproveOldRequest() async throws {
    let (store, root) = try await setup()
    let started = await store.startChat("codex-approval")
    let run = try XCTUnwrap(started)
    let task = try XCTUnwrap(store.library.task(containing: run)?.id)
    try await waitFor { store.mcpPendingApprovals.values.contains { $0.runID == run } }
    let old = try XCTUnwrap(store.mcpPendingApprovals.values.first { $0.runID == run })
    try killOwnedCoreAgent(root: root)
    try await waitFor { store.library.chatRuns.first { $0.id == run }?.isActive == false }
    XCTAssertEqual(store.library.chatRuns.first { $0.id == run }?.status, "failed")
    XCTAssertNil(store.mcpPendingApprovals[old.execution.id])
    let retried = await store.startChat("approval retry", taskID: task)
    let retry = try XCTUnwrap(retried)
    try await waitFor { store.mcpPendingApprovals.values.contains { $0.runID == retry } }
    let current = try XCTUnwrap(store.mcpPendingApprovals.values.first { $0.runID == retry })
    store.resolveMCPApproval(old.execution.id, decision: .allowOnce)
    XCTAssertNotNil(store.mcpPendingApprovals[current.execution.id])
    let proof = root.appendingPathComponent("Project/approval-proof.txt")
    XCTAssertFalse(FileManager.default.fileExists(atPath: proof.path))
    store.resolveMCPApproval(current.execution.id, decision: .deny)
    try await waitFor { store.library.chatRuns.first { $0.id == retry }?.isActive == false }
    XCTAssertFalse(FileManager.default.fileExists(atPath: proof.path))
  }
  @MainActor func testDisconnectedQuestionExpiresAndRetryCannotAnswerOldRequest() async throws {
    let (store, root) = try await setup()
    let started = await store.startChat("codex-question")
    let run = try XCTUnwrap(started)
    let task = try XCTUnwrap(store.library.task(containing: run)?.id)
    try await waitFor { store.codexPendingQuestions.values.contains { $0.runID == run } }
    let old = try XCTUnwrap(store.codexPendingQuestions.values.first { $0.runID == run })
    try killOwnedCoreAgent(root: root)
    try await waitFor { store.library.chatRuns.first { $0.id == run }?.isActive == false }
    XCTAssertEqual(store.library.chatRuns.first { $0.id == run }?.status, "failed")
    XCTAssertEqual(store.library.chatRuns.first { $0.id == run }?.codexQuestions.first?.status, .expired)
    XCTAssertNil(store.codexPendingQuestions[old.request.id])
    let retried = await store.startChat("question retry", taskID: task)
    let retry = try XCTUnwrap(retried)
    try await waitFor { store.codexPendingQuestions.values.contains { $0.runID == retry } }
    let current = try XCTUnwrap(store.codexPendingQuestions.values.first { $0.runID == retry })
    await store.answerCodexQuestion(old.request.id, answers: ["credential": ["Provided value"]])
    XCTAssertNotNil(store.codexPendingQuestions[current.request.id])
    store.cancelCodexQuestion(current.request.id)
    try await waitFor { store.library.chatRuns.first { $0.id == retry }?.isActive == false }
    XCTAssertEqual(store.library.chatRuns.first { $0.id == retry }?.status, "cancelled")
    XCTAssertEqual(store.library.chatRuns.first { $0.id == retry }?.codexQuestions.last?.status, .cancelled)
    XCTAssertEqual(store.liveModelRequestCount, 0)
  }
  @MainActor func testBackgroundQuestionCancelLeavesForegroundApprovalLive() async throws {
    let (store, root) = try await setup()
    let firstStarted = await store.startChat("question background")
    let first = try XCTUnwrap(firstStarted)
    try await waitFor { store.codexPendingQuestions.values.contains { $0.runID == first } }
    let question = try XCTUnwrap(store.codexPendingQuestions.values.first { $0.runID == first })
    store.newTask()
    let secondStarted = await store.startChat("approval foreground")
    let second = try XCTUnwrap(secondStarted)
    try await waitFor { store.mcpPendingApprovals.values.contains { $0.runID == second } }
    let approval = try XCTUnwrap(store.mcpPendingApprovals.values.first { $0.runID == second })
    XCTAssertNotEqual(store.library.task(containing: first)?.id, store.library.task(containing: second)?.id)
    store.cancelCodexQuestion(question.request.id)
    try await waitFor { store.library.chatRuns.first { $0.id == first }?.isActive == false }
    XCTAssertEqual(store.library.chatRuns.first { $0.id == first }?.status, "cancelled")
    XCTAssertNotNil(store.mcpPendingApprovals[approval.execution.id])
    XCTAssertTrue(store.library.chatRuns.first { $0.id == second }?.isActive == true)
    store.resolveMCPApproval(approval.execution.id, decision: .allowOnce)
    try await waitFor { store.library.chatRuns.first { $0.id == second }?.isActive == false }
    XCTAssertEqual(store.library.chatRuns.first { $0.id == second }?.status, "succeeded")
    XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("Project/approval-proof.txt"),
      encoding: .utf8), "approved")
    XCTAssertTrue(store.mcpPendingApprovals.isEmpty)
    XCTAssertTrue(store.codexPendingQuestions.isEmpty)
  }
  @MainActor func testReadOnlyPatchDenialHasNoWriteAndAllowTargetsNewRequest() async throws {
    let (store, root) = try await setup()
    store.library.agentRuntimePreferences.sandboxMode = .readOnly
    let deniedStarted = await store.startChat("patch deny")
    let denied = try XCTUnwrap(deniedStarted)
    let owner = try XCTUnwrap(store.library.task(containing: denied)?.id)
    try await waitFor { store.mcpPendingApprovals.values.contains { $0.runID == denied } }
    let refusal = try XCTUnwrap(store.mcpPendingApprovals.values.first { $0.runID == denied })
    let proof = root.appendingPathComponent("Project/patch-proof.txt")
    XCTAssertFalse(FileManager.default.fileExists(atPath: proof.path))
    store.resolveMCPApproval(refusal.execution.id, decision: .deny)
    try await waitFor { store.library.chatRuns.first { $0.id == denied }?.isActive == false }
    XCTAssertFalse(FileManager.default.fileExists(atPath: proof.path))
    let allowedStarted = await store.startChat("patch allow", taskID: owner)
    let allowed = try XCTUnwrap(allowedStarted)
    try await waitFor { store.mcpPendingApprovals.values.contains { $0.runID == allowed } }
    let approval = try XCTUnwrap(store.mcpPendingApprovals.values.first { $0.runID == allowed })
    XCTAssertNotEqual(approval.execution.id, refusal.execution.id)
    store.resolveMCPApproval(refusal.execution.id, decision: .allowOnce)
    XCTAssertNotNil(store.mcpPendingApprovals[approval.execution.id])
    XCTAssertFalse(FileManager.default.fileExists(atPath: proof.path))
    store.resolveMCPApproval(approval.execution.id, decision: .allowOnce)
    try await waitFor { store.library.chatRuns.first { $0.id == allowed }?.isActive == false }
    XCTAssertEqual(try String(contentsOf: proof, encoding: .utf8), "patched\n")
    XCTAssertEqual(store.library.chatRuns.first { $0.id == allowed }?.toolExecutions.last?.status, .succeeded)
  }
  @MainActor func testBackgroundQuestionAnswerCannotResolveForegroundQuestion() async throws {
    let (store, _) = try await setup()
    let firstStarted = await store.startChat("question first")
    let first = try XCTUnwrap(firstStarted)
    try await waitFor { store.codexPendingQuestions.values.contains { $0.runID == first } }
    let firstQuestion = try XCTUnwrap(store.codexPendingQuestions.values.first { $0.runID == first })
    store.newTask()
    let secondStarted = await store.startChat("question second")
    let second = try XCTUnwrap(secondStarted)
    try await waitFor { store.codexPendingQuestions.values.contains { $0.runID == second } }
    let secondQuestion = try XCTUnwrap(store.codexPendingQuestions.values.first { $0.runID == second })
    await store.answerCodexQuestion(firstQuestion.request.id, answers: ["credential": ["Provided value"]])
    try await waitFor { store.library.chatRuns.first { $0.id == first }?.isActive == false }
    XCTAssertEqual(store.library.chatRuns.first { $0.id == first }?.codexQuestions.first?.status, .answered)
    XCTAssertNotNil(store.codexPendingQuestions[secondQuestion.request.id])
    XCTAssertTrue(store.library.chatRuns.first { $0.id == second }?.isActive == true)
    store.cancelCodexQuestion(secondQuestion.request.id)
    try await waitFor { store.library.chatRuns.first { $0.id == second }?.isActive == false }
    XCTAssertEqual(store.library.chatRuns.first { $0.id == second }?.status, "cancelled")
  }
  @MainActor func testActualCommandFailureRetainsOneFailedToolAndRestoresIt() async throws {
    let (store, root) = try await setup()
    let started = await store.startChat("tool failure")
    let run = try XCTUnwrap(started)
    try await waitFor { store.library.chatRuns.first { $0.id == run }?.isActive == false }
    let finished = try XCTUnwrap(store.library.chatRuns.first { $0.id == run })
    XCTAssertEqual(finished.status, "succeeded", finished.result?["message"].text ?? "")
    XCTAssertEqual(finished.toolExecutions.count, 1)
    let tool = try XCTUnwrap(finished.toolExecutions.first)
    XCTAssertEqual(tool.status, .failed)
    XCTAssertTrue(tool.output?.contains("T04_TOOL_FAILURE") == true, tool.output ?? "Missing error output")
    XCTAssertEqual(finished.responseItems?.filter {
      if case .tool = $0 { return true }; return false
    }.count, 1)
    XCTAssertTrue(store.mcpPendingApprovals.isEmpty)
    await store.shutdown()
    let restored = WorkspaceStore(dataRoot: root.appendingPathComponent("Data"),
      agentExecutable: try AgentTestExecutable.url())
    addTeardownBlock { await restored.shutdown() }
    await restored.restore()
    let saved = try XCTUnwrap(restored.library.chatRuns.first { $0.id == run })
    XCTAssertEqual(saved.toolExecutions, finished.toolExecutions)
    XCTAssertEqual(saved.responseItems, finished.responseItems)
    XCTAssertFalse(saved.isActive)
    XCTAssertTrue(restored.mcpPendingApprovals.isEmpty)
  }
  @MainActor func testActualCorePlanDocumentOpensOnlyForOwnerAndRestores() async throws {
    let (store, root) = try await setup()
    let started = await store.startChat("document plan", mode: .plan)
    let run = try XCTUnwrap(started)
    try await waitFor { store.library.chatRuns.first { $0.id == run }?.isActive == false }
    let finished = try XCTUnwrap(store.library.chatRuns.first { $0.id == run })
    XCTAssertEqual(finished.status, "succeeded", finished.result?["message"].text ?? "")
    let document = try XCTUnwrap(finished.codexPlanDocument, "Native Core Plan item was not retained")
    XCTAssertEqual(document.title, "T04 release plan")
    XCTAssertEqual(document.text.trimmingCharacters(in: .whitespacesAndNewlines),
      "# T04 release plan\n\n1. Inspect the project\n2. Verify behavior")
    XCTAssertFalse(finished.result?["response"].text?.contains("<proposed_plan>") == true)
    XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Project/patch-proof.txt").path))
    let owner = try XCTUnwrap(store.library.task(containing: run))
    XCTAssertTrue(store.openPlanDocument(runID: run))
    XCTAssertEqual(store.activeWorkspaceContentTab, .plan(run, owner: owner.id))
    store.newTask()
    let peerStarted = await store.startChat("unrelated reply")
    let peer = try XCTUnwrap(peerStarted)
    try await waitFor { store.library.chatRuns.first { $0.id == peer }?.isActive == false }
    XCTAssertFalse(store.openPlanDocument(runID: run))
    store.selectTask(owner)
    XCTAssertTrue(store.openPlanDocument(runID: run))
    await store.shutdown()
    let restored = WorkspaceStore(dataRoot: root.appendingPathComponent("Data"),
      agentExecutable: try AgentTestExecutable.url())
    addTeardownBlock { await restored.shutdown() }
    await restored.restore()
    XCTAssertEqual(restored.library.chatRuns.first { $0.id == run }?.codexPlanDocument, document)
    XCTAssertTrue(restored.openPlanDocument(runID: run))
    XCTAssertEqual(restored.activeWorkspaceContentTab, .plan(run, owner: owner.id))
  }
  @MainActor func testCancelledApprovalDoesNotWriteAndOldCardCannotApproveRetry() async throws {
    let (store, root) = try await setup()
    let started = await store.startChat("approval cancel")
    let run = try XCTUnwrap(started)
    let owner = try XCTUnwrap(store.library.task(containing: run)?.id)
    try await waitFor { store.mcpPendingApprovals.values.contains { $0.runID == run } }
    let old = try XCTUnwrap(store.mcpPendingApprovals.values.first { $0.runID == run })
    await store.cancel(taskID: owner)
    try await waitFor { store.library.chatRuns.first { $0.id == run }?.isActive == false }
    XCTAssertEqual(store.library.chatRuns.first { $0.id == run }?.status, "cancelled")
    XCTAssertNil(store.mcpPendingApprovals[old.execution.id])
    let proof = root.appendingPathComponent("Project/approval-proof.txt")
    XCTAssertFalse(FileManager.default.fileExists(atPath: proof.path))
    let nextStarted = await store.startChat("approval after cancel", taskID: owner)
    let next = try XCTUnwrap(nextStarted)
    try await waitFor { store.mcpPendingApprovals.values.contains { $0.runID == next } }
    let current = try XCTUnwrap(store.mcpPendingApprovals.values.first { $0.runID == next })
    store.resolveMCPApproval(old.execution.id, decision: .allowOnce)
    XCTAssertNotNil(store.mcpPendingApprovals[current.execution.id])
    XCTAssertFalse(FileManager.default.fileExists(atPath: proof.path))
    store.resolveMCPApproval(current.execution.id, decision: .allowOnce)
    try await waitFor { store.library.chatRuns.first { $0.id == next }?.isActive == false }
    XCTAssertEqual(try String(contentsOf: proof, encoding: .utf8), "approved")
  }
  @MainActor func testBackgroundApprovalCompletesOnlyItsRequestAndPeerCanBeDenied() async throws {
    let (store, _) = try await setup()
    let firstStarted = await store.startChat("approval background")
    let first = try XCTUnwrap(firstStarted)
    try await waitFor { store.mcpPendingApprovals.values.contains { $0.runID == first } }
    let firstApproval = try XCTUnwrap(store.mcpPendingApprovals.values.first { $0.runID == first })
    store.newTask()
    let peerStarted = await store.startChat("approval foreground peer")
    let peer = try XCTUnwrap(peerStarted)
    try await waitFor { store.mcpPendingApprovals.values.contains { $0.runID == peer } }
    let peerApproval = try XCTUnwrap(store.mcpPendingApprovals.values.first { $0.runID == peer })
    store.resolveMCPApproval(firstApproval.execution.id, decision: .allowOnce)
    try await waitFor { store.library.chatRuns.first { $0.id == first }?.isActive == false }
    XCTAssertEqual(store.library.chatRuns.first { $0.id == first }?.toolExecutions.last?.status, .succeeded)
    XCTAssertNotNil(store.mcpPendingApprovals[peerApproval.execution.id])
    XCTAssertTrue(store.library.chatRuns.first { $0.id == peer }?.isActive == true)
    store.resolveMCPApproval(peerApproval.execution.id, decision: .deny)
    try await waitFor { store.library.chatRuns.first { $0.id == peer }?.isActive == false }
    XCTAssertEqual(store.library.chatRuns.first { $0.id == peer }?.toolExecutions.last?.status, .denied)
    XCTAssertTrue(store.mcpPendingApprovals.isEmpty)
  }
}
