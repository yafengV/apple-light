import AppKit
import CoreText
import XCTest

@testable import ShipiOS

final class DesktopFeaturesTests: XCTestCase {
  @MainActor func testCodexRejectedSteeringKeepsQueuedMessage() async {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root)
    store.libraryLoaded = true
    let run = AgentRun(id: UUID().uuidString, kind: "chat", project: "/project",
      status: "running", createdAt: 0, updatedAt: 0,
      request: .object(["api_protocol": .string(ModelAPIProtocol.codexResponses.rawValue)]),
      result: .object(["response": .string("")]))
    store.library.chatRuns = [run]
    store.library.tasks = [WorkspaceTask(id: "task", project: "/project",
      title: "Task", runIDs: [run.id])]
    let message = QueuedMessage(taskID: "task", text: "Keep me queued")
    store.library.queuedMessages = [message]
    await store.steerActiveChat(with: message)
    XCTAssertEqual(store.library.queuedMessages, [message])
    XCTAssertEqual(store.library.chatRuns, [run])
    XCTAssertTrue(store.codexSteeringMessages.isEmpty)
    store.setTaskWindowDraft("Plan this", taskID: "task")
    await store.sendTaskWindowDraft("task", mode: .plan)
    XCTAssertEqual(store.taskWindowDraft("task"), "Plan this")
    XCTAssertEqual(store.library.queuedMessages, [message])
    XCTAssertNotNil(store.error)
  }

  func testCodexPlanUpdateKeepsTimelineIdentityAndStatuses() throws {
    let first: JSONValue = .object([
      "type": .string("plan_update"), "explanation": .string("Inspect then verify"),
      "plan": .array([.object(["step": .string("Inspect"), "status": .string("in_progress")])]),
    ])
    let initial = try CodexPlan.update(first, existing: nil)
    let next = try CodexPlan.update(.object([
      "type": .string("plan_update"), "plan": .array([
        .object(["step": .string("Inspect"), "status": .string("completed")]),
        .object(["step": .string("Verify"), "status": .string("in_progress")]),
      ]),
    ]), existing: initial)
    XCTAssertEqual(next.id, initial.id)
    XCTAssertEqual(next.steps.map(\.status), [.completed, .inProgress])
    let items: [ChatResponseItem] = [.message(id: UUID(), text: "Starting"), .plan(next.id),
      .message(id: UUID(), text: "Done")]
    let run = AgentRun(id: UUID().uuidString, kind: "chat", project: "/project",
      status: "succeeded", createdAt: 0, updatedAt: 0,
      request: .object(["api_protocol": .string("codexResponses")]),
      result: .object([
        "response": .string("StartingDone"), "response_items": try ChatResponseItem.json(items),
        "codex_plan": try JSONDecoder().decode(JSONValue.self,
          from: JSONEncoder().encode(next)),
      ]))
    let restored = try JSONDecoder().decode(AgentRun.self, from: JSONEncoder().encode(run))
    XCTAssertEqual(restored.responseItems, items)
    XCTAssertEqual(restored.codexPlan, next)
  }

  func testCodexQuestionValidationAndTimelineRoundTrip() throws {
    let event: JSONValue = .object([
      "type": .string("request_user_input"), "call_id": .string("question-1"),
      "turn_id": .string("turn-1"), "isBlocking": .bool(true),
      "questions": .array([.object([
        "id": .string("credential"), "header": .string("Account"),
        "question": .string("Enter a value"), "isSecret": .bool(true),
      ])]),
    ])
    let question = try CodexQuestionRequest.parse(event)
    XCTAssertTrue(question.questions[0].isSecret)
    XCTAssertTrue(question.validAnswers(["credential": ["private-answer"]]))
    XCTAssertFalse(question.validAnswers(["credential": [""]]))
    let items: [ChatResponseItem] = [.question(question.id), .message(id: UUID(), text: "Done")]
    let run = AgentRun(id: UUID().uuidString, kind: "chat", project: "/project",
      status: "succeeded", createdAt: 0, updatedAt: 0,
      request: .object(["api_protocol": .string("codexResponses")]),
      result: .object([
        "response": .string("Done"), "response_items": try ChatResponseItem.json(items),
        "codex_questions": try JSONDecoder().decode(JSONValue.self,
          from: JSONEncoder().encode([question])),
      ]))
    let restored = try JSONDecoder().decode(AgentRun.self, from: JSONEncoder().encode(run))
    XCTAssertEqual(restored.responseItems, items)
    XCTAssertEqual(restored.codexQuestions, [question])
    XCTAssertFalse(String(decoding: try JSONEncoder().encode(restored), as: UTF8.self)
      .contains("private-answer"))
  }

  @MainActor func testNonblockingCodexQuestionExpiresWithoutStallingTurn() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root)
    store.libraryLoaded = true
    let run = AgentRun(id: UUID().uuidString, kind: "chat", project: "/project",
      status: "running", createdAt: 0, updatedAt: 0,
      request: .object(["api_protocol": .string("codexResponses")]),
      result: .object(["response": .string("")]))
    store.library.chatRuns.append(run)
    let event: JSONValue = .object([
      "type": .string("request_user_input"), "call_id": .string("question-1"),
      "turn_id": .string("turn-1"), "isBlocking": .bool(false),
      "questions": .array([.object([
        "id": .string("choice"), "header": .string("Choice"),
        "question": .string("Choose a value"),
        "options": .array([.object(["label": .string("A"), "description": .string("First")])]),
      ])]),
    ])
    try await store.handleCodexQuestion(runID: run.id, taskID: run.id, event: event)
    XCTAssertEqual(store.codexPendingQuestions.count, 1)
    XCTAssertEqual(store.library.chatRuns[0].codexQuestions.first?.status, .awaiting)
    XCTAssertEqual(store.library.chatRuns[0].responseItems?.count, 1)
    store.expireCodexQuestions(runID: run.id)
    XCTAssertTrue(store.codexPendingQuestions.isEmpty)
    XCTAssertEqual(store.library.chatRuns[0].codexQuestions.first?.status, .expired)
  }

  func testCodexCommandEventsKeepOneOrderedToolRowAndOutput() throws {
    var executions: [MCPToolExecution] = []
    var items: [ChatResponseItem] = [.message(id: UUID(), text: "先检查项目。")]
    let begin: JSONValue = .object([
      "type": .string("exec_command_begin"), "call_id": .string("call-1"),
      "command": .array([.string("rg"), .string("--files")]),
      "cwd": .string("/project"),
    ])
    XCTAssertTrue(CodexCommandTimeline.apply(begin, executions: &executions, items: &items))
    XCTAssertEqual(executions.count, 1)
    XCTAssertEqual(executions[0].status, .running)
    XCTAssertEqual(executions[0].arguments, "/project\n$ rg --files")
    XCTAssertEqual(items.count, 2)
    let end: JSONValue = .object([
      "type": .string("exec_command_end"), "call_id": .string("call-1"),
      "status": .string("completed"), "exit_code": .number(0),
      "aggregated_output": .string("Package.swift\n"),
    ])
    XCTAssertTrue(CodexCommandTimeline.apply(end, executions: &executions, items: &items))
    XCTAssertEqual(executions.count, 1)
    XCTAssertEqual(items.count, 2)
    XCTAssertEqual(executions[0].status, .succeeded)
    XCTAssertEqual(executions[0].output, "Package.swift\n")
    XCTAssertEqual(items[1], .tool(executions[0].id))
    XCTAssertFalse(CodexCommandTimeline.apply(.object(["type": .string("exec_command_output_delta")]),
      executions: &executions, items: &items))
    XCTAssertEqual(try ChatResponseItem.json(items).decode([ChatResponseItem].self), items)
    let run = AgentRun(id: UUID().uuidString, kind: "chat", project: "/project",
      status: "succeeded", createdAt: 0, updatedAt: 0,
      request: .object(["api_protocol": .string("codexResponses")]),
      result: .object([
        "response": .string("先检查项目。"),
        "response_items": try ChatResponseItem.json(items),
        "tool_executions": try JSONDecoder().decode(JSONValue.self,
          from: JSONEncoder().encode(executions)),
      ]))
    let restored = try JSONDecoder().decode(AgentRun.self, from: JSONEncoder().encode(run))
    XCTAssertEqual(restored.responseItems, items)
    XCTAssertEqual(restored.toolExecutions, executions)
  }

  func testCodexApprovalAndPatchEventsStayInOneToolRow() {
    let choices = CodexCommandTimeline.approvalChoices(.object([
      "available_decisions": .array([.string("approved_for_session"),
        .object(["network_policy_amendment": .object([:])])]),
    ]))
    XCTAssertFalse(choices.once)
    XCTAssertTrue(choices.task)
    let defaults = CodexCommandTimeline.approvalChoices(.object([:]))
    XCTAssertTrue(defaults.once)
    XCTAssertFalse(defaults.task)
    var executions: [MCPToolExecution] = []
    var items: [ChatResponseItem] = []
    let approval: JSONValue = .object([
      "type": .string("apply_patch_approval_request"), "call_id": .string("patch-1"),
      "reason": .string("更新测试文件"),
      "changes": .object(["Tests.swift": .object(["type": .string("update")])]),
    ])
    XCTAssertTrue(CodexCommandTimeline.apply(approval, executions: &executions, items: &items))
    XCTAssertEqual(executions[0].status, .awaitingApproval)
    XCTAssertEqual(executions[0].toolName, "补丁")
    XCTAssertTrue(executions[0].arguments.contains("Tests.swift"))
    CodexCommandTimeline.resolve(callID: "patch-1", patch: true, allowed: true,
      executions: &executions)
    XCTAssertEqual(executions[0].status, .running)
    let begin: JSONValue = .object([
      "type": .string("patch_apply_begin"), "call_id": .string("patch-1"),
      "changes": .object([:]),
    ])
    XCTAssertTrue(CodexCommandTimeline.apply(begin, executions: &executions, items: &items))
    let end: JSONValue = .object([
      "type": .string("patch_apply_end"), "call_id": .string("patch-1"),
      "success": .bool(true), "stdout": .string("Done"), "stderr": .string(""),
    ])
    XCTAssertTrue(CodexCommandTimeline.apply(end, executions: &executions, items: &items))
    XCTAssertEqual(items.count, 1)
    XCTAssertEqual(executions.count, 1)
    XCTAssertEqual(executions[0].status, .succeeded)
    XCTAssertEqual(executions[0].output, "Done")
    let denied: JSONValue = .object([
      "type": .string("exec_approval_request"), "call_id": .string("exec-2"),
      "command": .array([.string("git"), .string("push")]),
    ])
    XCTAssertTrue(CodexCommandTimeline.apply(denied, executions: &executions, items: &items))
    CodexCommandTimeline.resolve(callID: "exec-2", patch: false, allowed: false,
      executions: &executions)
    XCTAssertEqual(executions[1].status, .denied)
    XCTAssertEqual(items.count, 2)
  }

  func testCommandWarningsDoNotCorruptStructuredOutput() async throws {
    let result = try await LocalWorkspaceService.command(
      "/bin/sh", ["-c", "printf 'warning' >&2; printf 'valid'"],
      at: FileManager.default.temporaryDirectory)
    XCTAssertEqual(result.status, 0)
    XCTAssertEqual(result.text, "valid")
  }
  func testFilesInIgnoredProjectRoot() async throws {
    let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let root = parent.appendingPathComponent("ignored", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: parent) }
    _ = try await LocalWorkspaceService.git(["init", "-q"], at: parent)
    try Data("ignored/\n".utf8).write(to: parent.appendingPathComponent(".gitignore"))
    try Data("source".utf8).write(to: root.appendingPathComponent("main.swift"))
    let files = try await LocalWorkspaceService.files(at: root)
    XCTAssertEqual(files, ["main.swift"])
    let tree = WorkspaceFileNode.tree(["A/B.swift", "A/C.swift", "main.swift"])
    XCTAssertEqual(tree[0].children?.map(\.path), ["A/B.swift", "A/C.swift"])
  }
  func testConfigurationAndStreamParsing() throws {
    var config = ModelConfiguration()
    for url in [
      "http://example.com/v1", "https://user:secret@example.com/v1",
      "https://example.com/v1?key=secret", "file:///tmp/key",
    ] {
      config.baseURL = url
      XCTAssertThrowsError(try config.endpoint("models"))
    }
    config.baseURL = "https://example.com/v1/"
    XCTAssertEqual(
      try config.endpoint("chat/completions").absoluteString,
      "https://example.com/v1/chat/completions")
    config.baseURL = "http://127.0.0.1:8080/v1"
    XCTAssertEqual(try config.endpoint("models").path, "/v1/models")
    XCTAssertNil(try ChatStreamDelta.parse(": heartbeat"))
    XCTAssertEqual(try ChatStreamDelta.parse("data: [DONE]")?.finished, true)
    XCTAssertEqual(
      try ChatStreamDelta.parse(
        #"data: {"choices":[{"delta":{"content":"你好"},"finish_reason":null}]}"#)?.text, "你好")
    let usage = try ChatStreamDelta.parse(
      #"data: {"choices":[],"usage":{"prompt_tokens":12,"completion_tokens":5,"total_tokens":17,"prompt_tokens_details":{"cached_tokens":2}}}"#)?.usage
    XCTAssertEqual(usage, ModelTokenUsage(inputTokens: 12, outputTokens: 5, totalTokens: 17, cachedInputTokens: 2))
    XCTAssertThrowsError(try ChatStreamDelta.parse(#"data: {"error":{"message":"secret"}}"#))
  }

  func testLegacyLibraryAndQueueRoundTrip() throws {
    let legacy = Data(
      #"{"tasks":[],"projects":["/project"],"notes":{},"drafts":{"new:/project":"draft"},"profiles":{}}"#
        .utf8)
    var library = try JSONDecoder().decode(WorkspaceLibrary.self, from: legacy)
    XCTAssertTrue(library.chatRuns.isEmpty)
    XCTAssertEqual(library.drafts["new:/project"], "draft")
    XCTAssertEqual(library.followUpBehavior, .queue)
    XCTAssertTrue(library.browserHistory.isEmpty)
    library.queuedMessages.append(QueuedMessage(taskID: "task-a", text: "follow up"))
    library.pinnedProjects.insert("/project")
    library.followUpBehavior = .steer
    let restored = try JSONDecoder().decode(
      WorkspaceLibrary.self, from: JSONEncoder().encode(library))
    XCTAssertEqual(restored.queuedMessages, library.queuedMessages)
    XCTAssertEqual(restored.pinnedProjects, ["/project"])
    XCTAssertEqual(restored.followUpBehavior, .steer)
  }

  func testFileReadRejectsTraversalSymlinksAndBinary() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try Data("source\n".utf8).write(to: root.appendingPathComponent("file.swift"))
    XCTAssertEqual(try LocalWorkspaceService.read("file.swift", root: root), "source\n")
    XCTAssertThrowsError(try LocalWorkspaceService.resolvedFile("../outside", root: root))
    try FileManager.default.createSymbolicLink(
      at: root.appendingPathComponent("outside"),
      withDestinationURL: root.deletingLastPathComponent())
    XCTAssertThrowsError(try LocalWorkspaceService.read("outside/secret", root: root))
    try Data([1, 0, 2]).write(to: root.appendingPathComponent("binary"))
    XCTAssertThrowsError(try LocalWorkspaceService.read("binary", root: root))
  }

  @MainActor func testGitStageUnstageRenameAndLiteralPaths() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    _ = try await LocalWorkspaceService.git(["init", "-q"], at: root)
    let name = ":(glob)* file.txt"
    try Data("first\n".utf8).write(to: root.appendingPathComponent(name))
    try Data("untouched\n".utf8).write(to: root.appendingPathComponent("other.txt"))
    let workspace = DeveloperWorkspace()
    workspace.root = root
    await workspace.refreshGit()
    XCTAssertEqual(workspace.gitFiles.count, 2)
    await workspace.stage(name, undo: false)
    XCTAssertNil(workspace.error)
    XCTAssertEqual(workspace.gitFiles.filter(\.staged).map(\.path), [name])
    await workspace.stage(name, undo: true)
    XCTAssertNil(workspace.error)
    XCTAssertTrue(workspace.gitFiles.allSatisfy(\.untracked))
    let renamed = GitFile.parse("R  new name.txt\0old name.txt\0 M other.txt\0")
    XCTAssertEqual(renamed.map(\.path), ["new name.txt", "other.txt"])
    XCTAssertTrue(renamed[0].staged)
    XCTAssertTrue(renamed[1].unstaged)
  }

  @MainActor func testQueueOwnershipAndDraftPreservation() async {
    let store = WorkspaceStore()
    store.project = URL(fileURLWithPath: "/project")
    store.connected = true
    let run = AgentRun(
      id: "run-a", kind: "chat", project: "/project", status: "running", createdAt: 0, updatedAt: 0,
      request: .null, result: nil)
    store.runs = [run]
    store.library.attach(run, to: nil, note: "first")
    store.selection = "run-a"
    store.draft = "second"
    await store.sendDraft()
    XCTAssertEqual(store.library.queuedMessages.first?.taskID, "run-a")
    XCTAssertTrue(store.draft.isEmpty)
    store.newTask()
    store.draft = "different task"
    await store.sendDraft()
    XCTAssertEqual(store.library.queuedMessages.count, 1)
    XCTAssertEqual(store.draft, "different task")
    XCTAssertNotNil(store.error)
    store.selection = "run-a"
    store.draft = "keep my draft"
    store.editQueuedMessage(store.library.queuedMessages[0])
    XCTAssertEqual(store.draft, "keep my draft")
    XCTAssertEqual(store.library.queuedMessages.count, 1)
  }
}

actor StreamCollector {
  var text = ""
  func append(_ value: String) { text += value }
}

final class ModelTransportTests: XCTestCase {
  private var server: Process!
  private var config = ModelConfiguration()
  private static let pixelData = Data([
    137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82, 0, 0, 0, 2, 0, 0,
    0, 2, 8, 2, 0, 0, 0, 253, 212, 154, 115, 0, 0, 0, 18, 73, 68, 65, 84, 120, 156,
    99, 84, 104, 120, 192, 192, 192, 192, 196, 0, 6, 0, 17, 106, 1, 132, 39,
    161, 5, 66, 0, 0, 0, 0, 73, 69, 78, 68, 174, 66, 96, 130,
  ])
  override func setUpWithError() throws {
    server = Process()
    server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().appendingPathComponent("Fixtures/model_server.py")
    server.arguments = ["-u", fixture.path]
    let pipe = Pipe()
    server.standardOutput = pipe
    server.standardError = FileHandle.nullDevice
    try server.run()
    let port = String(decoding: pipe.fileHandleForReading.availableData, as: UTF8.self)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard Int(port) != nil else { throw AgentFailure(message: "Fixture server failed to start") }
    config.baseURL = "http://127.0.0.1:\(port)/v1"
    config.model = "fixture-model"
  }
  override func tearDown() {
    if server?.isRunning == true {
      server.terminate()
      server.waitUntilExit()
    }
  }
  @MainActor func testCodexResponsesChatUsesAgentAndKeepsTaskReply() async throws {
    let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent()
    let binary = repository.appendingPathComponent("target/debug/shipios-agent")
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let project = root.appendingPathComponent("Project", isDirectory: true)
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root.appendingPathComponent("Data"), agentExecutable: binary)
    await store.restore()
    config.apiProtocol = .codexResponses
    try store.saveModelConfiguration(config)
    store.notificationPreferences = .init(timing: .never)
    await store.open(project)
    XCTAssertTrue(store.connected, store.error ?? "Agent did not connect")
    await store.startChat("Codex fixture request")
    let run = try XCTUnwrap(store.library.chatRuns.last)
    XCTAssertEqual(run.request["api_protocol"].text, "codexResponses")
    await store.modelTask(runID: run.id)?.value
    let finished = try XCTUnwrap(store.library.chatRuns.first { $0.id == run.id })
    XCTAssertEqual(finished.status, "succeeded", finished.result?["message"].text ?? "")
    XCTAssertEqual(finished.result?["response"].text, "Codex fixture reply")
    store.modelConfiguration.apiProtocol = .chatCompletions
    XCTAssertEqual(store.modelConfiguration(for: run.id).apiProtocol, .codexResponses)
    await store.startChat("Follow-up", taskID: run.id)
    let followUp = try XCTUnwrap(store.library.chatRuns.last)
    await store.modelTask(runID: followUp.id)?.value
    let next = try XCTUnwrap(store.library.chatRuns.first { $0.id == followUp.id })
    XCTAssertEqual(next.status, "succeeded", next.result?["message"].text ?? "")
    XCTAssertEqual(next.result?["response"].text, "Codex fixture reply")
    await store.startChat("slow-codex", taskID: run.id)
    let interrupted = try XCTUnwrap(store.library.chatRuns.last)
    let running = try XCTUnwrap(store.modelTask(runID: interrupted.id))
    await store.cancel(taskID: run.id)
    await running.value
    XCTAssertEqual(store.library.chatRuns.first { $0.id == interrupted.id }?.status, "cancelled")
    await store.shutdown()
    let restored = WorkspaceStore(dataRoot: root.appendingPathComponent("Data"), agentExecutable: binary)
    restored.notificationPreferences = .init(timing: .never)
    await restored.restore()
    await restored.open(project)
    XCTAssertTrue(restored.connected, restored.error ?? "Agent did not reconnect")
    await restored.startChat("After restart", taskID: run.id)
    let resumedRun = try XCTUnwrap(restored.library.chatRuns.last)
    await restored.modelTask(runID: resumedRun.id)?.value
    let resumed = try XCTUnwrap(restored.library.chatRuns.first { $0.id == resumedRun.id })
    XCTAssertEqual(resumed.status, "succeeded", resumed.result?["message"].text ?? "")
    XCTAssertEqual(resumed.result?["response"].text, "Codex fixture reply")
    let image = try ImageAttachmentStorage.importData(Self.pixelData, name: "pixel.png",
      root: root.appendingPathComponent("Data"))
    await restored.startChat("", taskID: run.id, images: [image])
    let imageRun = try XCTUnwrap(restored.library.chatRuns.last)
    await restored.modelTask(runID: imageRun.id)?.value
    XCTAssertEqual(restored.library.chatRuns.first { $0.id == imageRun.id }?.status, "succeeded")
    XCTAssertEqual(restored.library.runImages[imageRun.id], [image])
    await restored.shutdown()
  }
  @MainActor func testCodexApprovalCardResumesCommandAndPersistsTimeline() async throws {
    let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent()
    let binary = repository.appendingPathComponent("target/debug/shipios-agent")
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let project = root.appendingPathComponent("Project", isDirectory: true)
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root.appendingPathComponent("Data"), agentExecutable: binary)
    await store.restore()
    config.apiProtocol = .codexResponses
    try store.saveModelConfiguration(config)
    store.notificationPreferences = .init(timing: .never)
    await store.open(project)
    XCTAssertTrue(store.connected, store.error ?? "Agent did not connect")
    await store.startChat("codex-approval")
    let run = try XCTUnwrap(store.library.chatRuns.last)
    var approval: MCPApprovalContext?
    for _ in 0..<150 {
      approval = store.mcpPendingApprovals.values.first { $0.runID == run.id }
      if approval != nil { break }
      try await Task.sleep(nanoseconds: 100_000_000)
    }
    let pending = try XCTUnwrap(approval, "Codex did not show an approval card")
    XCTAssertEqual(pending.execution.serverID, CodexCommandTimeline.serverID)
    XCTAssertEqual(pending.execution.status, .awaitingApproval)
    XCTAssertTrue(pending.execution.arguments.contains("approval-proof.txt"))
    XCTAssertFalse(FileManager.default.fileExists(atPath: project.appendingPathComponent("approval-proof.txt").path))
    store.resolveMCPApproval(pending.execution.id, decision: .allowOnce)
    await store.modelTask(runID: run.id)?.value
    let finished = try XCTUnwrap(store.library.chatRuns.first { $0.id == run.id })
    XCTAssertEqual(finished.status, "succeeded", finished.result?["message"].text ?? "")
    XCTAssertEqual(finished.toolExecutions.count, 1)
    XCTAssertEqual(finished.toolExecutions[0].status, .succeeded)
    XCTAssertEqual(finished.responseItems?.count, 2)
    XCTAssertEqual(try String(contentsOf: project.appendingPathComponent("approval-proof.txt"),
      encoding: .utf8), "approved")
    await store.shutdown()
  }
  @MainActor func testCodexPatchAppearsInTimelineAndWritesProjectFile() async throws {
    let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent()
    let binary = repository.appendingPathComponent("target/debug/shipios-agent")
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let project = root.appendingPathComponent("Project", isDirectory: true)
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root.appendingPathComponent("Data"), agentExecutable: binary)
    await store.restore()
    config.apiProtocol = .codexResponses
    config.model = "gpt-5.4"
    try store.saveModelConfiguration(config)
    store.notificationPreferences = .init(timing: .never)
    await store.open(project)
    XCTAssertTrue(store.connected, store.error ?? "Agent did not connect")
    await store.startChat("codex-patch")
    let run = try XCTUnwrap(store.library.chatRuns.last)
    await store.modelTask(runID: run.id)?.value
    let finished = try XCTUnwrap(store.library.chatRuns.first { $0.id == run.id })
    XCTAssertEqual(finished.status, "succeeded", finished.result?["message"].text ?? "")
    XCTAssertEqual(finished.toolExecutions.count, 1)
    XCTAssertEqual(finished.toolExecutions[0].toolName, "补丁")
    XCTAssertEqual(finished.toolExecutions[0].status, .succeeded)
    XCTAssertEqual(finished.responseItems?.count, 2)
    XCTAssertEqual(try String(contentsOf: project.appendingPathComponent("patch-proof.txt"),
      encoding: .utf8), "patched\n")
    await store.shutdown()
  }
  @MainActor func testCodexStructuredQuestionResumesAndPersistsWithoutAnswer() async throws {
    let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent()
    let binary = repository.appendingPathComponent("target/debug/shipios-agent")
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let project = root.appendingPathComponent("Project", isDirectory: true)
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root.appendingPathComponent("Data"), agentExecutable: binary)
    await store.restore()
    config.apiProtocol = .codexResponses
    config.model = "gpt-5.4"
    try store.saveModelConfiguration(config)
    store.notificationPreferences = .init(timing: .never)
    await store.open(project)
    XCTAssertTrue(store.connected, store.error ?? "Agent did not connect")
    await store.startChat("codex-question")
    let run = try XCTUnwrap(store.library.chatRuns.last)
    var pending: CodexQuestionContext?
    for _ in 0..<150 {
      pending = store.codexPendingQuestions.values.first { $0.runID == run.id }
      if pending != nil { break }
      try await Task.sleep(nanoseconds: 100_000_000)
    }
    let current = store.library.chatRuns.first { $0.id == run.id }
    let question = try XCTUnwrap(pending, "Codex did not show a question card: status=\(current?.status ?? "missing") "
      + "message=\(current?.result?["message"].text ?? "") response=\(current?.result?["response"].text ?? "") "
      + "store=\(store.error ?? "")")
    XCTAssertEqual(question.request.questions.first?.id, "credential")
    XCTAssertTrue(question.request.questions.first?.isSecret == true)
    XCTAssertEqual(store.library.chatRuns.first { $0.id == run.id }?.codexQuestions.first?.status,
      .awaiting)
    await store.answerCodexQuestion(question.request.id,
      answers: ["credential": ["private-fixture-answer-6db5"]])
    await store.modelTask(runID: run.id)?.value
    let finished = try XCTUnwrap(store.library.chatRuns.first { $0.id == run.id })
    XCTAssertEqual(finished.status, "succeeded", finished.result?["message"].text ?? "")
    XCTAssertEqual(finished.codexQuestions.first?.status, .answered)
    XCTAssertEqual(finished.responseItems?.count, 2)
    XCTAssertFalse(try String(contentsOf: root.appendingPathComponent("Data/workspace.json"),
      encoding: .utf8).contains("private-fixture-answer-6db5"))
    await store.shutdown()
  }
  @MainActor func testCodexPlanToolAppearsInTimelineAndPersists() async throws {
    let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent()
    let binary = repository.appendingPathComponent("target/debug/shipios-agent")
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let project = root.appendingPathComponent("Project", isDirectory: true)
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root.appendingPathComponent("Data"), agentExecutable: binary)
    await store.restore()
    config.apiProtocol = .codexResponses
    config.model = "gpt-5.4"
    try store.saveModelConfiguration(config)
    store.notificationPreferences = .init(timing: .never)
    await store.open(project)
    XCTAssertTrue(store.connected, store.error ?? "Agent did not connect")
    await store.startChat("codex-plan")
    let run = try XCTUnwrap(store.library.chatRuns.last)
    await store.modelTask(runID: run.id)?.value
    let finished = try XCTUnwrap(store.library.chatRuns.first { $0.id == run.id })
    XCTAssertEqual(finished.status, "succeeded", finished.result?["message"].text ?? "")
    XCTAssertEqual(finished.codexPlan?.steps.map(\.status), [.completed, .completed])
    XCTAssertEqual(finished.responseItems?.filter({
      if case .plan = $0 { return true }
      return false
    }).count, 1)
    let restored = try JSONDecoder().decode(AgentRun.self, from: JSONEncoder().encode(finished))
    XCTAssertEqual(restored.codexPlan, finished.codexPlan)
    XCTAssertEqual(restored.responseItems, finished.responseItems)
    await store.shutdown()
  }
  @MainActor func testCodexSteeringKeepsOneLiveRunAndRecordsUserMessage() async throws {
    let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent()
    let binary = repository.appendingPathComponent("target/debug/shipios-agent")
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let project = root.appendingPathComponent("Project", isDirectory: true)
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root.appendingPathComponent("Data"), agentExecutable: binary)
    await store.restore()
    config.apiProtocol = .codexResponses
    config.model = "gpt-5.4"
    try store.saveModelConfiguration(config)
    store.notificationPreferences = .init(timing: .never)
    await store.open(project)
    XCTAssertTrue(store.connected, store.error ?? "Agent did not connect")
    store.followUpBehavior = .steer
    await store.startChat("slow-codex")
    let run = try XCTUnwrap(store.library.chatRuns.last)
    let taskID = try XCTUnwrap(store.library.task(containing: run.id)?.id)
    for _ in 0..<150 {
      if store.codexTransport.canSteer(taskID: taskID) { break }
      try await Task.sleep(nanoseconds: 100_000_000)
    }
    XCTAssertTrue(store.codexTransport.canSteer(taskID: taskID))
    let source = root.appendingPathComponent("steering.txt")
    try Data("STEER_FILE_PROOF".utf8).write(to: source)
    let file = try FileAttachmentStorage.importFile(source, root: root.appendingPathComponent("Data"))
    store.draft = "steered-inflight-proof"
    store.library.draftFiles[store.draftKey] = [file]
    await store.sendDraft()
    XCTAssertEqual(store.library.chatRuns.count, 1)
    XCTAssertTrue(store.library.queuedMessages.isEmpty, store.error ?? "Steering stayed queued")
    XCTAssertEqual(store.library.chatRuns[0].codexSteeredMessages.map(\.text),
      ["steered-inflight-proof"])
    XCTAssertEqual(store.library.chatRuns[0].codexSteeredMessages.first?.files, [file])
    XCTAssertEqual(store.library.fileReferences[file.id], file)
    await store.modelTask(runID: run.id)?.value
    let finished = try XCTUnwrap(store.library.chatRuns.first)
    XCTAssertEqual(finished.status, "succeeded", finished.result?["message"].text ?? "")
    XCTAssertTrue(finished.result?["response"].text?.contains("Steered fixture reply") == true)
    XCTAssertEqual(finished.responseItems?.filter({
      if case .user = $0 { return true }
      return false
    }).count, 1)
    XCTAssertTrue(store.library.chatContext(taskID: taskID).contains {
      $0.role == "user" && $0.content == "steered-inflight-proof" && $0.files == [file]
    })
    XCTAssertFalse(ConversationSearch.find(
      ConversationSearch.inputs([finished], library: store.library),
      query: "steered-inflight-proof").isEmpty)
    let task = try XCTUnwrap(store.library.task(containing: run.id))
    let results = TaskSearchRequest(query: "steered-inflight-proof", tasks: [task],
      names: [:], notes: store.library.notes, branches: [:], runs: [finished]).search()
    XCTAssertEqual(results.first?.task.id, taskID)
    XCTAssertTrue((try FileManager.default.contentsOfDirectory(atPath:
      root.appendingPathComponent("Data/CodexStaging").path)).isEmpty)
    await store.shutdown()
  }
  @MainActor func testDetachedTaskDraftCanSteerActiveCodexRun() async throws {
    let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent()
    let binary = repository.appendingPathComponent("target/debug/shipios-agent")
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let project = root.appendingPathComponent("Project", isDirectory: true)
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root.appendingPathComponent("Data"), agentExecutable: binary)
    await store.restore()
    config.apiProtocol = .codexResponses
    config.model = "gpt-5.4"
    try store.saveModelConfiguration(config)
    store.notificationPreferences = .init(timing: .never)
    await store.open(project)
    store.followUpBehavior = .steer
    await store.startChat("slow-codex")
    let run = try XCTUnwrap(store.library.chatRuns.last)
    let taskID = try XCTUnwrap(store.library.task(containing: run.id)?.id)
    for _ in 0..<150 {
      if store.codexTransport.canSteer(taskID: taskID) { break }
      try await Task.sleep(nanoseconds: 100_000_000)
    }
    XCTAssertTrue(store.codexTransport.canSteer(taskID: taskID))
    store.setTaskWindowDraft("steered-inflight-proof", taskID: taskID)
    await store.sendTaskWindowDraft(taskID, mode: .standard)
    XCTAssertEqual(store.library.chatRuns.count, 1)
    XCTAssertTrue(store.library.queuedMessages.isEmpty, store.error ?? "Window steering stayed queued")
    XCTAssertTrue(store.taskWindowDraft(taskID).isEmpty)
    XCTAssertEqual(store.library.chatRuns[0].codexSteeredMessages.map(\.text),
      ["steered-inflight-proof"])
    await store.modelTask(runID: run.id)?.value
    XCTAssertEqual(store.library.chatRuns[0].status, "succeeded")
    await store.shutdown()
  }
  @MainActor func testCodexExternalInterruptEndsActiveRunWithoutSpinner() async throws {
    let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent()
    let binary = repository.appendingPathComponent("target/debug/shipios-agent")
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let project = root.appendingPathComponent("Project", isDirectory: true)
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root.appendingPathComponent("Data"), agentExecutable: binary)
    await store.restore()
    config.apiProtocol = .codexResponses
    config.model = "gpt-5.4"
    try store.saveModelConfiguration(config)
    store.notificationPreferences = .init(timing: .never)
    await store.open(project)
    await store.startChat("slow-codex")
    let run = try XCTUnwrap(store.library.chatRuns.last)
    let taskID = try XCTUnwrap(store.library.task(containing: run.id)?.id)
    for _ in 0..<150 {
      if store.codexTransport.canSteer(taskID: taskID) { break }
      try await Task.sleep(nanoseconds: 100_000_000)
    }
    XCTAssertTrue(store.codexTransport.canSteer(taskID: taskID))
    await store.codexTransport.interrupt(taskID: taskID)
    for _ in 0..<150 {
      if store.library.chatRuns.first(where: { $0.id == run.id })?.isActive == false { break }
      try await Task.sleep(nanoseconds: 100_000_000)
    }
    let ended = try XCTUnwrap(store.library.chatRuns.first { $0.id == run.id })
    XCTAssertEqual(ended.status, "cancelled", ended.result?["message"].text ?? "")
    XCTAssertFalse(store.codexTransport.canSteer(taskID: taskID))
    await store.shutdown()
  }
  @MainActor func testCodexRetryStatusAppearsThenClearsOnReply() async throws {
    let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent()
    let binary = repository.appendingPathComponent("target/debug/shipios-agent")
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let project = root.appendingPathComponent("Project", isDirectory: true)
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root.appendingPathComponent("Data"), agentExecutable: binary)
    await store.restore()
    config.apiProtocol = .codexResponses
    config.model = "gpt-5.4"
    try store.saveModelConfiguration(config)
    store.notificationPreferences = .init(timing: .never)
    await store.open(project)
    await store.startChat("codex-retry")
    let run = try XCTUnwrap(store.library.chatRuns.last)
    var retryStatus: String?
    for _ in 0..<200 {
      retryStatus = store.library.chatRuns.first(where: { $0.id == run.id })?
        .result?["codex_runtime_status"].text
      if retryStatus != nil { break }
      try await Task.sleep(nanoseconds: 50_000_000)
    }
    XCTAssertNotNil(retryStatus, "Core retry status was not shown")
    await store.modelTask(runID: run.id)?.value
    let finished = try XCTUnwrap(store.library.chatRuns.first { $0.id == run.id })
    XCTAssertEqual(finished.status, "succeeded", finished.result?["message"].text ?? "")
    XCTAssertNil(finished.result?["codex_runtime_status"].text)
    XCTAssertEqual(finished.result?["response"].text, "Codex fixture reply")
    await store.shutdown()
  }
  @MainActor func testCodexTerminalProviderErrorFailsRun() async throws {
    let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent()
    let binary = repository.appendingPathComponent("target/debug/shipios-agent")
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let project = root.appendingPathComponent("Project", isDirectory: true)
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root.appendingPathComponent("Data"), agentExecutable: binary)
    await store.restore()
    config.apiProtocol = .codexResponses
    config.model = "gpt-5.4"
    try store.saveModelConfiguration(config)
    store.notificationPreferences = .init(timing: .never)
    await store.open(project)
    await store.startChat("codex-terminal-error")
    let run = try XCTUnwrap(store.library.chatRuns.last)
    await store.modelTask(runID: run.id)?.value
    let finished = try XCTUnwrap(store.library.chatRuns.first { $0.id == run.id })
    XCTAssertEqual(finished.status, "failed")
    XCTAssertFalse((finished.result?["message"].text ?? "").isEmpty)
    await store.shutdown()
  }
  @MainActor func testCodexResponsesImageOnlyStartsProjectTask() async throws {
    let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent()
    let binary = repository.appendingPathComponent("target/debug/shipios-agent")
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let project = root.appendingPathComponent("Project", isDirectory: true)
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root.appendingPathComponent("Data"), agentExecutable: binary)
    await store.restore()
    config.apiProtocol = .codexResponses
    try store.saveModelConfiguration(config)
    store.notificationPreferences = .init(timing: .never)
    await store.open(project)
    XCTAssertTrue(store.connected, store.error ?? "Agent did not connect")
    let image = try ImageAttachmentStorage.importData(Self.pixelData, name: "pixel.png",
      root: root.appendingPathComponent("Data"))
    await store.startChat("", images: [image])
    let run = try XCTUnwrap(store.library.chatRuns.last)
    await store.modelTask(runID: run.id)?.value
    let finished = try XCTUnwrap(store.library.chatRuns.first { $0.id == run.id })
    XCTAssertEqual(finished.status, "succeeded", finished.result?["message"].text ?? "")
    XCTAssertEqual(finished.result?["response"].text, "Codex fixture reply")
    XCTAssertEqual(store.library.runImages[run.id], [image])
    await store.shutdown()
  }
  @MainActor func testCodexResponsesLargeFileStartsProjectTaskWithoutLargeRPCFrame() async throws {
    let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent()
    let binary = repository.appendingPathComponent("target/debug/shipios-agent")
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let project = root.appendingPathComponent("Project", isDirectory: true)
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root.appendingPathComponent("Data"), agentExecutable: binary)
    await store.restore()
    config.apiProtocol = .codexResponses
    try store.saveModelConfiguration(config)
    store.notificationPreferences = .init(timing: .never)
    await store.open(project)
    XCTAssertTrue(store.connected, store.error ?? "Agent did not connect")
    let source = root.appendingPathComponent("long.txt")
    try Data((String(repeating: "x", count: 80_000) + "\nFILE_MARKER_END").utf8)
      .write(to: source)
    let file = try FileAttachmentStorage.importFile(source, root: root.appendingPathComponent("Data"))
    await store.startChat("", files: [file])
    let run = try XCTUnwrap(store.library.chatRuns.last)
    await store.modelTask(runID: run.id)?.value
    let finished = try XCTUnwrap(store.library.chatRuns.first { $0.id == run.id })
    XCTAssertEqual(finished.status, "succeeded", finished.result?["message"].text ?? "")
    XCTAssertEqual(finished.result?["response"].text, "Codex fixture reply")
    XCTAssertEqual(store.library.runFiles[run.id], [file])
    let staged = root.appendingPathComponent("Data/CodexStaging")
    XCTAssertTrue((try FileManager.default.contentsOfDirectory(atPath: staged.path)).isEmpty)
    let pdfData = NSMutableData()
    let consumer = try XCTUnwrap(CGDataConsumer(data: pdfData))
    var page = CGRect(x: 0, y: 0, width: 300, height: 200)
    let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &page, nil))
    context.beginPDFPage(nil)
    context.textPosition = CGPoint(x: 20, y: 100)
    CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: "PDF context text")), context)
    context.endPDFPage(); context.closePDF()
    let pdf = root.appendingPathComponent("document.pdf")
    try (pdfData as Data).write(to: pdf)
    let pdfAttachment = try FileAttachmentStorage.importFile(pdf, root: root.appendingPathComponent("Data"))
    XCTAssertTrue(pdfAttachment.isPDF)
    await store.startChat("", taskID: run.id, files: [pdfAttachment])
    let pdfRun = try XCTUnwrap(store.library.chatRuns.last)
    await store.modelTask(runID: pdfRun.id)?.value
    XCTAssertEqual(store.library.chatRuns.first { $0.id == pdfRun.id }?.status, "succeeded")
    XCTAssertEqual(store.library.runFiles[pdfRun.id], [pdfAttachment])
    XCTAssertTrue((try FileManager.default.contentsOfDirectory(atPath: staged.path)).isEmpty)
    await store.shutdown()
  }
  @MainActor func testTaskModelOverrideReachesRequestAndChangingItDoesNotRewriteInflightRun() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root)
    await store.restore()
    store.modelConfiguration = config
    store.notificationPreferences = .init(timing: .never)
    store.library.tasks = [
      .init(id: "one", project: "", title: "One", runIDs: []),
      .init(id: "two", project: "", title: "Two", runIDs: [])]
    store.selectTask(store.library.tasks[0])
    try store.selectModel("task-specific", reasoning: "high", taskID: "two")
    store.setTaskWindowDraft("configuration", taskID: "two")
    await store.sendTaskWindowDraft("two", mode: .standard)
    let first = try XCTUnwrap(store.library.chatRuns.last)
    let running = try XCTUnwrap(store.modelTask(runID: first.id))
    try store.selectModel("next-model", reasoning: "", taskID: "two")
    await running.value
    let result = try XCTUnwrap(store.library.chatRuns.first { $0.id == first.id })
    let echoed = try JSONDecoder().decode([String: String].self, from: Data((result.result?["response"].text ?? "").utf8))
    XCTAssertEqual(echoed, ["model": "task-specific", "reasoning_effort": "high"])
    XCTAssertEqual(result.request["model"].text, "task-specific")
    XCTAssertEqual(store.modelConfiguration(for: "two").model, "next-model")
    XCTAssertEqual(store.modelConfiguration(for: "one").model, "fixture-model")
    XCTAssertEqual(store.selectedTask?.id, "one")
    store.setTaskWindowDraft("configuration", taskID: "two")
    await store.sendTaskWindowDraft("two", mode: .standard)
    let next = try XCTUnwrap(store.library.chatRuns.last)
    await store.modelTask(runID: next.id)?.value
    let secondResult = try XCTUnwrap(store.library.chatRuns.first { $0.id == next.id })
    let secondEcho = try JSONDecoder().decode([String: String].self, from: Data((secondResult.result?["response"].text ?? "").utf8))
    XCTAssertEqual(secondEcho, ["model": "next-model"])
    XCTAssertEqual(store.modelConfiguration.model, "fixture-model")
    await store.shutdown()
  }

  @MainActor func testDifferentTasksStreamInParallelAndKeepIndependentOwnership() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root)
    await store.restore()
    store.modelConfiguration = config
    store.notificationPreferences = .init(timing: .never)

    store.draft = "parallel-one"
    await store.sendDraft()
    let firstRun = try XCTUnwrap(store.library.chatRuns.last)
    let firstTaskID = try XCTUnwrap(store.selectedTask?.id)
    let firstRequest = try XCTUnwrap(store.modelTask(runID: firstRun.id))

    store.newTask()
    store.draft = "parallel-two"
    await store.sendDraft()
    let secondRun = try XCTUnwrap(store.library.chatRuns.last)
    let secondTaskID = try XCTUnwrap(store.selectedTask?.id)
    let secondRequest = try XCTUnwrap(store.modelTask(runID: secondRun.id))

    XCTAssertNotEqual(firstTaskID, secondTaskID)
    XCTAssertEqual(store.liveModelRequestCount, 2)
    XCTAssertEqual(store.activeChatRun(taskID: firstTaskID)?.id, firstRun.id)
    XCTAssertEqual(store.activeChatRun(taskID: secondTaskID)?.id, secondRun.id)
    XCTAssertTrue(store.library.queuedMessages.isEmpty)

    await firstRequest.value
    await secondRequest.value
    XCTAssertEqual(store.liveModelRequestCount, 0)
    XCTAssertEqual(store.library.chatRuns.map(\.status), ["succeeded", "succeeded"])
    XCTAssertEqual(
      store.library.tasks.first(where: { $0.id == firstTaskID })?.runIDs, [firstRun.id])
    XCTAssertEqual(
      store.library.tasks.first(where: { $0.id == secondTaskID })?.runIDs, [secondRun.id])
    XCTAssertEqual(store.library.notes[firstRun.id], "parallel-one")
    XCTAssertEqual(store.library.notes[secondRun.id], "parallel-two")
    await store.shutdown()
  }
  @MainActor func testTaskWindowCanSubmitAcrossMainProjectScope() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root)
    await store.restore()
    store.modelConfiguration = config
    store.notificationPreferences = .init(timing: .never)
    store.library.tasks = [
      .init(id: "remote-task", project: "/other/project", title: "Other", runIDs: [])
    ]
    store.setTaskWindowDraft("context", taskID: "remote-task")

    await store.sendTaskWindowDraft("remote-task", mode: .standard)
    let run = try XCTUnwrap(store.library.chatRuns.last)
    let request = try XCTUnwrap(store.modelTask(runID: run.id))
    await request.value

    XCTAssertEqual(store.currentProjectKey, "")
    XCTAssertEqual(run.project, "/other/project")
    XCTAssertEqual(store.library.tasks[0].runIDs, [run.id])
    XCTAssertTrue(store.taskWindowDraft("remote-task").isEmpty)
    let response = try XCTUnwrap(
      store.library.chatRuns.first(where: { $0.id == run.id })?.result?["response"].text)
    let messages = try JSONDecoder().decode([ChatMessage].self, from: Data(response.utf8))
    XCTAssertEqual(messages.last?.content, "context")
    await store.shutdown()
  }
  @MainActor func testStoppingOneTaskDoesNotCancelAnotherModelRequest() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root)
    await store.restore()
    store.modelConfiguration = config
    store.notificationPreferences = .init(timing: .never)

    store.draft = "slow-one"
    await store.sendDraft()
    let firstRun = try XCTUnwrap(store.library.chatRuns.last)
    let firstTaskID = try XCTUnwrap(store.selectedTask?.id)
    let firstRequest = try XCTUnwrap(store.modelTask(runID: firstRun.id))
    store.newTask()
    store.draft = "slow-two"
    await store.sendDraft()
    let secondRun = try XCTUnwrap(store.library.chatRuns.last)
    let secondTaskID = try XCTUnwrap(store.selectedTask?.id)
    let secondRequest = try XCTUnwrap(store.modelTask(runID: secondRun.id))

    await store.cancel(taskID: firstTaskID)
    await firstRequest.value
    XCTAssertEqual(
      store.library.chatRuns.first(where: { $0.id == firstRun.id })?.status, "cancelled")
    XCTAssertEqual(store.activeChatRun(taskID: secondTaskID)?.id, secondRun.id)
    XCTAssertNotNil(store.modelTask(runID: secondRun.id))

    await store.cancel(taskID: secondTaskID)
    await secondRequest.value
    XCTAssertEqual(
      store.library.chatRuns.first(where: { $0.id == secondRun.id })?.status, "cancelled")
    XCTAssertEqual(store.liveModelRequestCount, 0)
    await store.shutdown()
  }
  @MainActor func testSubmittingFirstChatAdoptsDraftTerminalAndFollowupKeepsIt() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root)
    await store.restore()
    store.project = root
    store.modelConfiguration = config
    store.notificationPreferences = .init(timing: .never)
    let draftScope = try XCTUnwrap(store.terminalScope)
    let shell = store.workspace.terminals.session(for: draftScope)
    defer { store.workspace.terminals.shutdown() }
    store.draft = "hello"
    await store.sendDraft()
    let first = try XCTUnwrap(store.modelTask)
    let scope = try XCTUnwrap(store.terminalScope)
    XCTAssertNotEqual(scope, draftScope)
    XCTAssertTrue(store.workspace.terminals.session(for: scope) === shell)
    await first.value
    store.draft = "context"
    await store.sendDraft()
    let followup = try XCTUnwrap(store.modelTask)
    XCTAssertEqual(store.terminalScope, scope)
    XCTAssertTrue(store.workspace.terminals.session(for: scope) === shell)
    await followup.value
    XCTAssertEqual(store.conversationRuns.count, 2)
    await store.shutdown()
  }
  @MainActor func testImageOnlyMessageAndQueuedImageReachActualHTTPHistory() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root)
    await store.restore()
    store.modelConfiguration = config
    store.notificationPreferences = .init(timing: .never)
    let png = try AttachmentFixture.png()
    let added = await store.importImages([.bytes(png, name: "first.png")])
    XCTAssertTrue(added)
    await store.sendDraft()
    let first = try XCTUnwrap(store.modelTask)
    XCTAssertEqual(store.selectedTask?.title, "first.png")
    XCTAssertTrue(store.draftImages.isEmpty)
    // Enqueue without an asynchronous import so the first short fixture reply cannot finish first.
    let secondImage = try ImageAttachmentStorage.importData(png, name: "second.png", root: root)
    store.library.draftImages[store.draftKey] = [secondImage]
    store.draft = "image-context"
    await store.sendDraft()
    XCTAssertEqual(store.library.queuedMessages.first?.images, [secondImage])
    await first.value
    if let next = store.modelTask { await next.value }
    XCTAssertTrue(store.library.queuedMessages.isEmpty)
    XCTAssertEqual(store.library.chatRuns.count, 2)
    XCTAssertTrue(store.library.chatRuns.allSatisfy { $0.status == "succeeded" })
    let response = try XCTUnwrap(store.library.chatRuns.last?.result?["response"].text)
    let received = try JSONDecoder().decode(JSONValue.self, from: Data(response.utf8)).items
    XCTAssertEqual(received.map { $0["role"].text }, ["system", "user", "assistant", "user"])
    let expected = "data:image/png;base64," + png.base64EncodedString()
    XCTAssertEqual(received[1]["content"].items[0]["image_url"]["url"].text, expected)
    XCTAssertEqual(received[3]["content"].items[0]["text"].text, "image-context")
    XCTAssertEqual(received[3]["content"].items[1]["image_url"]["url"].text, expected)
    let taskID = store.selectedTask?.id
    await store.shutdown()
    let restored = WorkspaceStore(dataRoot: root)
    await restored.restore()
    XCTAssertEqual(restored.library.chatContext(taskID: taskID).filter { !$0.images.isEmpty }.count, 2)
  }

  @MainActor func testFileOnlyMessageQueueAndRestartKeepActualHTTPFileContents() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root)
    await store.restore()
    store.modelConfiguration = config
    store.notificationPreferences = .init(timing: .never)
    let source = root.appendingPathComponent("first.txt")
    try Data("original file 世界".utf8).write(to: source)
    let added = await store.importFiles([source])
    XCTAssertTrue(added)
    let firstFiles = store.draftFiles
    await store.sendDraft()
    let first = try XCTUnwrap(store.modelTask)
    XCTAssertEqual(store.selectedTask?.title, "first.txt")
    XCTAssertTrue(store.draftFiles.isEmpty)
    try Data("queued second file".utf8).write(to: source)
    let second = try FileAttachmentStorage.importFile(source, root: root)
    store.library.draftFiles[store.draftKey] = [second]
    store.draft = "file-context"
    await store.sendDraft()
    XCTAssertEqual(store.library.queuedMessages.first?.files, [second])
    await first.value
    if let pending = store.modelTask { await pending.value }
    XCTAssertEqual(store.library.chatRuns.count, 2)
    XCTAssertTrue(store.library.chatRuns.allSatisfy { $0.status == "succeeded" })
    XCTAssertTrue(store.library.queuedMessages.isEmpty)
    let response = try XCTUnwrap(store.library.chatRuns.last?.result?["response"].text)
    let messages = try JSONDecoder().decode([ChatMessage].self, from: Data(response.utf8))
    XCTAssertEqual(messages.map(\.role), ["system", "user", "assistant", "user"])
    XCTAssertTrue(messages[1].content.contains("original file 世界"))
    XCTAssertTrue(messages[3].content.contains("queued second file"))
    XCTAssertFalse(messages[1].content.contains(root.path))
    let taskID = store.selectedTask?.id
    await store.shutdown()
    let restored = WorkspaceStore(dataRoot: root)
    await restored.restore()
    XCTAssertEqual(restored.library.chatContext(taskID: taskID).first?.files, firstFiles)
    XCTAssertEqual(restored.library.chatContext(taskID: taskID).last?.role, "assistant")
    XCTAssertEqual(restored.library.chatContext(taskID: taskID).filter { !$0.files.isEmpty }.count, 2)
    await restored.shutdown()
  }

  @MainActor func testHTTPFailureAndRetryPreserveFileContext() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root)
    await store.restore()
    store.modelConfiguration = config
    store.notificationPreferences = .init(timing: .never)
    let source = root.appendingPathComponent("retry.txt")
    try Data("retain file context".utf8).write(to: source)
    let added = await store.importFiles([source])
    XCTAssertTrue(added)
    let files = store.draftFiles
    store.draft = "file-http-error"
    await store.sendDraft()
    if let pending = store.modelTask { await pending.value }
    XCTAssertEqual(store.selectedRun?.status, "failed")
    XCTAssertEqual(store.library.runFiles[try XCTUnwrap(store.selection)], files)
    await store.rerun()
    if let pending = store.modelTask { await pending.value }
    XCTAssertEqual(store.library.chatRuns.count, 2)
    XCTAssertEqual(store.library.runFiles[try XCTUnwrap(store.selection)], files)
    XCTAssertTrue(store.selectedRun?.result?["message"].text?.contains("HTTP 401") == true)
    await store.shutdown()
  }

  @MainActor func testProviderFailureAndRetryRetainOriginalImageAttachment() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root)
    await store.restore()
    store.modelConfiguration = config
    store.notificationPreferences = .init(timing: .never)
    let added = await store.importImages([.bytes(try AttachmentFixture.png(), name: "screen.png")])
    XCTAssertTrue(added)
    let images = store.draftImages
    store.draft = "http-error"
    await store.sendDraft()
    if let running = store.modelTask { await running.value }
    XCTAssertEqual(store.selectedRun?.status, "failed")
    XCTAssertEqual(store.library.runImages[store.selection!], images)
    await store.rerun()
    if let running = store.modelTask { await running.value }
    XCTAssertEqual(store.library.chatRuns.count, 2)
    XCTAssertEqual(store.library.runImages[store.selection!], images)
    XCTAssertTrue(store.selectedRun?.result?["message"].text?.contains("HTTP 401") == true)
    XCTAssertFalse(store.selectedRun?.result?["message"].text?.contains("credentials must never") == true)
  }
  @MainActor func testProjectlessStoreStreamsQueuesAndRestoresRealConversation() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root)
    await store.restore()
    store.modelConfiguration = config
    store.notificationPreferences = .init(timing: .never)
    store.draft = "hello"
    await store.sendDraft()
    let first = try XCTUnwrap(store.modelTask)
    let taskID = try XCTUnwrap(store.selectedTask?.id)
    XCTAssertNil(store.project)
    XCTAssertFalse(store.connected)
    XCTAssertEqual(store.draft, "")
    store.draft = "context"
    await store.sendDraft()
    XCTAssertEqual(store.library.queuedMessages.count, 1)
    await first.value
    if let followup = store.modelTask { await followup.value }
    XCTAssertEqual(store.library.chatRuns.count, 2)
    XCTAssertTrue(store.library.queuedMessages.isEmpty)
    XCTAssertTrue(store.library.chatRuns.allSatisfy { $0.status == "succeeded" && $0.project.isEmpty })
    let response = try XCTUnwrap(store.library.chatRuns.last?.result?["response"].text)
    let received = try JSONDecoder().decode([ChatMessage].self, from: Data(response.utf8))
    XCTAssertEqual(received.map(\.role), ["system", "user", "assistant", "user"])
    XCTAssertEqual(Array(received.map(\.content).dropFirst()), ["hello", "Hello 世界!", "context"])
    await store.shutdown()
    let restored = WorkspaceStore(dataRoot: root)
    await restored.restore()
    XCTAssertNil(restored.project)
    XCTAssertEqual(restored.selectedTask?.id, taskID)
    XCTAssertEqual(restored.conversationRuns.count, 2)
    XCTAssertNil(restored.activeRun)
    XCTAssertTrue(restored.library.projects.isEmpty)
  }

  @MainActor func testProjectlessStoreCancellationRetainsQueueAndPartialReply() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root)
    await store.restore()
    store.modelConfiguration = config
    store.notificationPreferences = .init(timing: .never)
    store.draft = "slow"
    await store.sendDraft()
    let running = try XCTUnwrap(store.modelTask)
    store.draft = "follow up"
    await store.sendDraft()
    try await Task.sleep(for: .milliseconds(300))
    await store.cancel()
    await running.value
    XCTAssertEqual(store.library.chatRuns.first?.status, "cancelled")
    XCTAssertFalse(store.library.chatRuns.first?.result?["response"].text?.isEmpty ?? true)
    XCTAssertEqual(store.library.queuedMessages.map(\.text), ["follow up"])
    XCTAssertNil(store.activeRun)
    XCTAssertNil(store.modelTask)
    XCTAssertTrue(store.canStartChat)
  }
  @MainActor func testSteeringCancelsCurrentStreamAndContinuesWithPartialReply() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root)
    await store.restore()
    store.modelConfiguration = config
    store.notificationPreferences = .init(timing: .never)
    store.followUpBehavior = .steer
    store.draft = "slow"
    await store.sendDraft()
    let first = try XCTUnwrap(store.modelTask)
    try await Task.sleep(for: .milliseconds(300))
    XCTAssertFalse(store.library.chatRuns[0].result?["response"].text?.isEmpty ?? true)

    store.draft = "context"
    await store.sendDraft()
    await first.value
    let continuation = try XCTUnwrap(store.modelTask)
    await continuation.value

    XCTAssertEqual(store.library.chatRuns.count, 2)
    XCTAssertEqual(store.library.chatRuns.map(\.status), ["cancelled", "succeeded"])
    XCTAssertTrue(store.library.queuedMessages.isEmpty)
    let partial = try XCTUnwrap(store.library.chatRuns[0].result?["response"].text)
    XCTAssertFalse(partial.isEmpty)
    let response = try XCTUnwrap(store.library.chatRuns[1].result?["response"].text)
    let received = try JSONDecoder().decode([ChatMessage].self, from: Data(response.utf8))
    XCTAssertEqual(received.map(\.role), ["system", "user", "assistant", "user"])
    XCTAssertEqual(Array(received.map(\.content).dropFirst()), ["slow", partial, "context"])
    let restored = try WorkspaceLibrary.load(from: root.appendingPathComponent("workspace.json"))
    XCTAssertEqual(restored.followUpBehavior, .steer)
    await store.shutdown()
  }
  @MainActor func testSteeringRunsBeforeMessagesAlreadyWaitingInQueue() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root)
    await store.restore()
    store.modelConfiguration = config
    store.notificationPreferences = .init(timing: .never)
    store.draft = "slow"
    await store.sendDraft()
    let first = try XCTUnwrap(store.modelTask)

    store.draft = "queued"
    await store.sendDraft()
    store.followUpBehavior = .steer
    store.draft = "context"
    await store.sendDraft()
    await first.value
    if let steering = store.modelTask { await steering.value }
    if let queued = store.modelTask { await queued.value }

    XCTAssertEqual(store.library.chatRuns.map { store.library.notes[$0.id] }, ["slow", "context", "queued"])
    XCTAssertEqual(store.library.chatRuns.map(\.status), ["cancelled", "succeeded", "succeeded"])
    XCTAssertTrue(store.library.queuedMessages.isEmpty)
    await store.shutdown()
  }
  func testStreamingUTF8AndModelList() async throws {
    let count = try await ModelAPIClient().test(config: config, key: nil)
    XCTAssertEqual(count, 1)
    let models = try await ModelAPIClient().models(config: config, key: nil)
    XCTAssertEqual(models, ["fixture-model"])
    let collector = StreamCollector()
    config.includeUsage = true
    let usage = try await ModelAPIClient().stream(
      config: config, key: nil, messages: [.init(role: "user", content: "hello")]
    ) { await collector.append($0) }
    let text = await collector.text
    XCTAssertEqual(text, "Hello 世界!")
    XCTAssertEqual(
      usage,
      ModelTokenUsage(
        inputTokens: 42, outputTokens: 7, totalTokens: 49,
        cachedInputTokens: 3, reasoningOutputTokens: 2))
  }
  @MainActor func testStorePersistsAuthoritativeUsageAndCanNavigateFromUsagePage() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root)
    await store.restore()
    config.includeUsage = true
    config.reasoning = "high"
    store.modelConfiguration = config
    store.notificationPreferences = .init(timing: .never)
    store.draft = "usage persistence"
    await store.sendDraft()
    await store.modelTask?.value

    let record = try XCTUnwrap(store.library.modelUsageRecords.first)
    XCTAssertEqual(record.reasoning, "high")
    XCTAssertEqual(store.library.chatRuns.first?.request["reasoning_effort"].text, "high")
    XCTAssertEqual(
      record.usage,
      ModelTokenUsage(
        inputTokens: 42, outputTokens: 7, totalTokens: 49,
        cachedInputTokens: 3, reasoningOutputTokens: 2))
    store.openSettings(.usage)
    let opened = await store.openUsageRecord(taskID: record.taskID, runID: record.runID)
    XCTAssertTrue(opened)
    XCTAssertEqual(store.destination, .workspace)
    XCTAssertEqual(store.selectedTask?.id, record.taskID)
    XCTAssertEqual(store.selection, record.runID)

    let restored = try WorkspaceLibrary.load(from: root.appendingPathComponent("workspace.json"))
    XCTAssertEqual(restored.modelUsageRecords.first?.usage, record.usage)
    await store.shutdown()
  }
  @MainActor func testProjectlessChatCreatesDedicatedWorkspaceAndSendsItInContext() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let outputRoot = root.appendingPathComponent("Standalone", isDirectory: true)
    let store = WorkspaceStore(dataRoot: root.appendingPathComponent("Data"))
    await store.restore()
    store.modelConfiguration = config
    store.notificationPreferences = .init(timing: .never)
    store.setProjectlessWorkspaceRoot(outputRoot)
    store.draft = "context"

    await store.sendDraft()
    try await XCTUnwrap(store.modelTask).value

    let run = try XCTUnwrap(store.library.chatRuns.last)
    let taskID = try XCTUnwrap(store.library.task(containing: run.id)?.id)
    let workspace = try XCTUnwrap(run.request["workspace"].text)
    XCTAssertEqual(store.library.projectlessTaskDirectories[taskID], workspace)
    var isDirectory: ObjCBool = false
    XCTAssertTrue(FileManager.default.fileExists(atPath: workspace, isDirectory: &isDirectory))
    XCTAssertTrue(isDirectory.boolValue)
    XCTAssertTrue(workspace.hasPrefix(outputRoot.path + "/"))
    let messages = try JSONDecoder().decode(
      [ChatMessage].self, from: Data(try XCTUnwrap(run.result?["response"].text).utf8))
    XCTAssertTrue(messages.first?.content.contains(workspace) == true)
    XCTAssertEqual(store.workspaceRoot(for: run)?.path, workspace)
    await store.shutdown()
  }
  @MainActor func testNewPopoutTaskPromotesOnlyAfterItsFirstRealModelRun() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root)
    await store.restore()
    store.modelConfiguration = config
    store.notificationPreferences = .init(timing: .never)
    store.popoutWindowProjectlessDefault = true
    let task = try XCTUnwrap(store.createPopoutTask())
    store.setTaskWindowDraft("popout first prompt", taskID: task.id)

    XCTAssertTrue(store.library.visible(project: "", query: "", archived: false).isEmpty)
    await store.sendTaskWindowDraft(task.id, mode: .standard)
    let run = try XCTUnwrap(store.library.chatRuns.last)
    try await XCTUnwrap(store.modelTask(runID: run.id)).value

    let promoted = try XCTUnwrap(store.library.tasks.first { $0.id == task.id })
    XCTAssertFalse(promoted.isPopoutDraft)
    XCTAssertEqual(promoted.title, "popout first prompt")
    XCTAssertEqual(promoted.runIDs, [run.id])
    XCTAssertEqual(store.library.notes[run.id], "popout first prompt")
    XCTAssertEqual(store.library.visible(project: "", query: "", archived: false).map(\.id), [task.id])
    XCTAssertNotNil(run.request["workspace"].text)
    await store.shutdown()
  }
  func testHTTPMalformedAndPrematureFailure() async {
    for prompt in ["http-error", "broken", "truncated"] {
      do {
        _ = try await ModelAPIClient().stream(
          config: config, key: nil, messages: [.init(role: "user", content: prompt)]
        ) { _ in }
        XCTFail("Expected error: \(prompt)")
      } catch { XCTAssertFalse(error.localizedDescription.contains("credentials must never")) }
    }
  }
  func testSelectedModelAndReasoningAreSentWithServiceDefaultOmitted() async throws {
    config.model = "another-fixture-model"
    for effort in ["high", ""] {
      config.reasoning = effort
      let collector = StreamCollector()
      _ = try await ModelAPIClient().stream(
        config: config, key: nil, messages: [.init(role: "user", content: "configuration")]
      ) { await collector.append($0) }
      let text = await collector.text
      let request = try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
      XCTAssertEqual(request["model"].text, "another-fixture-model")
      XCTAssertEqual(request["reasoning_effort"].text, effort.isEmpty ? nil : effort)
    }
  }
  func testForkSendsOnlyCopiedHistoryAndNewPrompt() async throws {
    var library = WorkspaceLibrary()
    let runs = (1...3).map { index in
      AgentRun(
        id: "source-\(index)", kind: "chat", project: "/fixture", status: "succeeded",
        createdAt: Double(index), updatedAt: Double(index), request: .null,
        result: .object(["response": .string("reply-\(index)")]))
    }
    for (index, run) in runs.enumerated() {
      library.attach(run, to: runs.first?.id, note: "prompt-\(index + 1)")
      library.chatRuns.append(run)
    }
    let fork = try library.forkConversation(
      taskID: runs[0].id, through: runs[1].id, availableRuns: runs)
    let collector = StreamCollector()
    _ = try await ModelAPIClient().stream(
      config: config, key: nil,
      messages: library.chatContext(taskID: fork.id) + [ChatMessage(role: "user", content: "context")]
    ) { await collector.append($0) }
    let text = await collector.text
    let received = try JSONDecoder().decode([ChatMessage].self, from: Data(text.utf8))
    XCTAssertEqual(received.map(\.content), ["prompt-1", "reply-1", "prompt-2", "reply-2", "context"])
    XCTAssertEqual(received.map(\.role), ["user", "assistant", "user", "assistant", "user"])
  }
  func testPersonalizationIsPresentInActualRequest() async throws {
    let instructions = Personalization(personality: .pragmatic).systemInstructions(custom: "Prefer SwiftUI")
    let collector = StreamCollector()
    _ = try await ModelAPIClient().stream(
      config: config, key: nil,
      messages: [ChatMessage(role: "system", content: instructions), ChatMessage(role: "user", content: "context")]
    ) { await collector.append($0) }
    let text = await collector.text
    let received = try JSONDecoder().decode([ChatMessage].self, from: Data(text.utf8))
    XCTAssertEqual(received.first, ChatMessage(role: "system", content: instructions))
    XCTAssertTrue(received[0].content.contains("Prefer SwiftUI"))
    XCTAssertTrue(received[0].content.contains(ResponsePersonality.pragmatic.instruction))
  }
  @MainActor func testEnabledMemoryReachesActualRequestAndDisabledMemoryDoesNot() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root)
    await store.restore()
    store.modelConfiguration = config
    store.notificationPreferences = .init(timing: .never)
    XCTAssertTrue(store.addMemory("这个项目只使用 SwiftUI。"))
    store.draft = "context"
    await store.sendDraft()
    try await XCTUnwrap(store.modelTask).value
    let enabledResponse = try XCTUnwrap(store.library.chatRuns.last?.result?["response"].text)
    let enabledMessages = try JSONDecoder().decode([ChatMessage].self, from: Data(enabledResponse.utf8))
    XCTAssertTrue(enabledMessages.first?.content.contains("这个项目只使用 SwiftUI。") == true)

    XCTAssertTrue(store.saveMemoryEnabled(false))
    store.newTask()
    store.draft = "context"
    await store.sendDraft()
    try await XCTUnwrap(store.modelTask).value
    let disabledResponse = try XCTUnwrap(store.library.chatRuns.last?.result?["response"].text)
    let disabledMessages = try JSONDecoder().decode([ChatMessage].self, from: Data(disabledResponse.utf8))
    XCTAssertFalse(disabledMessages.first?.content.contains("这个项目只使用 SwiftUI。") == true)
    await store.shutdown()
  }
  @MainActor func testExplicitPluginMentionAddsEnabledSkillToActualRequest() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("PluginSource")
    let manifest = source.appendingPathComponent(".codex-plugin/plugin.json")
    try FileManager.default.createDirectory(
      at: manifest.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(
      #"{"id":"fixture-plugin","name":"Fixture Plugin","version":"1.0.0"}"#.utf8
    ).write(to: manifest)
    let skill = source.appendingPathComponent("skills/example/SKILL.md")
    try FileManager.default.createDirectory(
      at: skill.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("# Fixture plugin instructions\nReturn a structured answer.".utf8).write(to: skill)

    let store = WorkspaceStore(dataRoot: root.appendingPathComponent("Data"))
    await store.restore()
    XCTAssertTrue(store.installPlugin(from: source))
    store.modelConfiguration = config
    store.notificationPreferences = .init(timing: .never)
    store.draft = "@fixture-plugin plugin-context"
    await store.sendDraft()
    try await XCTUnwrap(store.modelTask).value

    let response = try XCTUnwrap(store.library.chatRuns.last?.result?["response"].text)
    let request = try JSONDecoder().decode(JSONValue.self, from: Data(response.utf8))
    XCTAssertTrue(
      request["messages"].items.first?["content"].text?.contains("Fixture plugin instructions")
        == true)
    XCTAssertEqual(request["messages"].items.last?["content"].text, "@fixture-plugin plugin-context")
    XCTAssertEqual(
      store.library.chatRuns.last?.request["plugins"].items.compactMap(\.text),
      ["fixture-plugin"])
    let previousTaskID = try XCTUnwrap(store.selectedTask?.id)
    store.draft = "保留原任务草稿"
    let previousRunCount = store.library.chatRuns.count
    XCTAssertTrue(store.trySkill("fixture-plugin/example"))
    let trialID = try XCTUnwrap(store.selectedTask?.id)
    XCTAssertEqual(store.library.chatRuns.count, previousRunCount)
    XCTAssertEqual(store.draft, "$fixture-plugin/example ")
    store.draft += "plugin-context"
    await store.sendDraft()
    try await XCTUnwrap(store.modelTask).value
    XCTAssertEqual(store.selectedTask?.id, trialID)
    XCTAssertEqual(store.selectedTask?.runIDs.count, 1)
    XCTAssertEqual(store.library.drafts[previousTaskID], "保留原任务草稿")
    let trialResponse = try XCTUnwrap(store.library.chatRuns.last?.result?["response"].text)
    let trialRequest = try JSONDecoder().decode(JSONValue.self, from: Data(trialResponse.utf8))
    XCTAssertTrue(trialRequest["messages"].items.first?["content"].text?.contains("Fixture plugin instructions") == true)
    await store.shutdown()
  }
  @MainActor func testStandaloneSkillTrialSendsRegisteredFileContext() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("review")
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    try Data("# Local Review\nSTANDALONE-CONTEXT".utf8).write(to: source.appendingPathComponent("SKILL.md"))
    let store = WorkspaceStore(dataRoot: root.appendingPathComponent("Data (local)"))
    await store.restore()
    XCTAssertTrue(store.installStandaloneSkill(from: source))
    store.modelConfiguration = config
    store.notificationPreferences = .init(timing: .never)
    XCTAssertTrue(store.trySkill("user:review"))
    XCTAssertTrue(store.library.chatRuns.isEmpty)
    let taskID = try XCTUnwrap(store.selectedTask?.id)
    store.draft += "plugin-context"
    await store.sendDraft()
    try await XCTUnwrap(store.modelTask).value
    XCTAssertEqual(store.selectedTask?.id, taskID)
    let run = try XCTUnwrap(store.library.chatRuns.last)
    let response = try XCTUnwrap(run.result?["response"].text)
    let request = try JSONDecoder().decode(JSONValue.self, from: Data(response.utf8))
    XCTAssertTrue(request["messages"].items.first?["content"].text?.contains("STANDALONE-CONTEXT") == true)
    XCTAssertTrue(run.request["plugins"].items.isEmpty)
    XCTAssertEqual(run.request["skills"].items.compactMap(\.text), ["review"])
    XCTAssertTrue(store.setSkillEnabled(false, id: "user:review"))
    store.newTask()
    store.draft = "$review plugin-context"
    await store.sendDraft()
    try await XCTUnwrap(store.modelTask).value
    let disabledResponse = try XCTUnwrap(store.library.chatRuns.last?.result?["response"].text)
    let disabledRequest = try JSONDecoder().decode(JSONValue.self, from: Data(disabledResponse.utf8))
    XCTAssertFalse(disabledRequest["messages"].items.first?["content"].text?.contains("STANDALONE-CONTEXT") == true)
    await store.shutdown()
  }

  @MainActor func testExplicitSkillMentionAddsOnlySelectedSkillToActualRequest() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("PluginSource")
    let manifest = source.appendingPathComponent(".codex-plugin/plugin.json")
    try FileManager.default.createDirectory(
      at: manifest.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(
      #"{"id":"fixture-plugin","name":"Fixture Plugin","version":"1.0.0"}"#.utf8
    ).write(to: manifest)
    let selected = source.appendingPathComponent("skills/selected/SKILL.md")
    try FileManager.default.createDirectory(
      at: selected.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("# Selected Skill\nSELECTED-SKILL-CONTEXT".utf8).write(to: selected)
    let omitted = source.appendingPathComponent("skills/omitted/SKILL.md")
    try FileManager.default.createDirectory(
      at: omitted.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("# Omitted Skill\nOMITTED-SKILL-CONTEXT".utf8).write(to: omitted)

    let store = WorkspaceStore(dataRoot: root.appendingPathComponent("Data"))
    await store.restore()
    XCTAssertTrue(store.installPlugin(from: source))
    store.modelConfiguration = config
    store.notificationPreferences = .init(timing: .never)
    store.draft = "$selected plugin-context"
    await store.sendDraft()
    try await XCTUnwrap(store.modelTask).value

    let response = try XCTUnwrap(store.library.chatRuns.last?.result?["response"].text)
    let request = try JSONDecoder().decode(JSONValue.self, from: Data(response.utf8))
    let system = request["messages"].items.first?["content"].text
    XCTAssertTrue(system?.contains("SELECTED-SKILL-CONTEXT") == true)
    XCTAssertFalse(system?.contains("OMITTED-SKILL-CONTEXT") == true)
    XCTAssertEqual(
      store.library.chatRuns.last?.request["skills"].items.compactMap(\.text), ["selected"])
    XCTAssertEqual(
      store.library.chatRuns.last?.request["plugins"].items.compactMap(\.text),
      ["fixture-plugin"])
    await store.shutdown()
  }
  @MainActor func testPlanModeReachesActualRequestAndResetsAfterSubmission() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root)
    await store.restore()
    store.modelConfiguration = config
    store.notificationPreferences = .init(timing: .never)
    store.chatMode = .plan
    store.draft = "plan plugin-context"
    await store.sendDraft()
    try await XCTUnwrap(store.modelTask).value

    let run = try XCTUnwrap(store.library.chatRuns.last)
    XCTAssertEqual(run.request["mode"].text, "plan")
    XCTAssertEqual(run.title, "计划 · fixture-model")
    XCTAssertEqual(store.chatMode, .standard)
    let response = try XCTUnwrap(run.result?["response"].text)
    let request = try JSONDecoder().decode(JSONValue.self, from: Data(response.utf8))
    XCTAssertTrue(
      request["messages"].items.first?["content"].text?.contains("当前回合处于计划模式")
        == true)
    XCTAssertEqual(request["messages"].items.last?["content"].text, "plan plugin-context")
    await store.shutdown()
  }
  @MainActor func testGoalModeReachesActualRequestAndPersistsCompletion() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root)
    await store.restore()
    store.modelConfiguration = config
    store.notificationPreferences = .init(timing: .never)
    XCTAssertTrue(store.configureGoal(GoalDefinition(
      objective: "完成目标请求", successCriteria: ["请求带有成功标准", "状态可以持久化"],
      maxIterations: 3)))
    store.draft = "goal-request"
    await store.sendDraft()
    await store.modelTask?.value

    let run = try XCTUnwrap(store.library.chatRuns.last)
    let taskID = try XCTUnwrap(store.selectedTask?.id)
    XCTAssertEqual(run.request["mode"].text, "goal")
    XCTAssertEqual(run.request["goal_objective"].text, "完成目标请求")
    XCTAssertEqual(
      run.request["goal_success_criteria"].items.compactMap(\.text),
      ["请求带有成功标准", "状态可以持久化"])
    XCTAssertEqual(run.request["goal_iteration"].int, 1)
    XCTAssertEqual(run.request["goal_max_iterations"].int, 3)
    XCTAssertEqual(store.library.goalSessions[taskID]?.status, .completed)
    XCTAssertEqual(store.library.goalSessions[taskID]?.iteration, 1)
    XCTAssertFalse(
      run.result?["response"].text?.hasSuffix("\n\nSHIPIOS_GOAL_STATUS: complete") == true)
    let request = try JSONDecoder().decode(
      JSONValue.self, from: Data(try XCTUnwrap(run.result?["response"].text).utf8))
    let system = request["messages"].items.first?["content"].text
    XCTAssertTrue(system?.contains("目标：\n完成目标请求") == true)
    XCTAssertTrue(system?.contains("1. 请求带有成功标准") == true)
    XCTAssertTrue(system?.contains("SHIPIOS_GOAL_STATUS: complete") == true)
    let restored = try WorkspaceLibrary.load(from: root.appendingPathComponent("workspace.json"))
    XCTAssertEqual(restored.goalSessions[taskID], store.library.goalSessions[taskID])
    await store.shutdown()
  }
  @MainActor func testGoalModeAutomaticallyContinuesUntilComplete() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root)
    await store.restore()
    store.modelConfiguration = config
    store.notificationPreferences = .init(timing: .never)
    XCTAssertTrue(store.configureGoal(GoalDefinition(
      objective: "执行两轮", successCriteria: ["第一轮继续", "第二轮完成"],
      maxIterations: 4)))
    store.draft = "goal-continue"
    await store.sendDraft()

    let deadline = Date().addingTimeInterval(4)
    while Date() < deadline {
      if store.library.chatRuns.count == 2, store.modelTask == nil { break }
      try await Task.sleep(for: .milliseconds(25))
    }
    let taskID = try XCTUnwrap(store.selectedTask?.id)
    XCTAssertEqual(store.library.chatRuns.count, 2)
    XCTAssertEqual(store.library.chatRuns.map { $0.request["goal_iteration"].int }, [1, 2])
    XCTAssertEqual(
      store.library.chatRuns.map { store.library.notes[$0.id] },
      ["goal-continue", GoalResponseParser.continuationPrompt])
    XCTAssertEqual(store.library.goalSessions[taskID]?.status, .completed)
    XCTAssertEqual(store.library.goalSessions[taskID]?.iteration, 2)
    XCTAssertEqual(store.library.chatRuns[0].result?["response"].text, "第一轮仍需继续。")
    XCTAssertEqual(store.library.chatRuns[1].result?["response"].text, "全部成功标准已经满足。")
    await store.shutdown()
  }
  @MainActor func testGoalModePausesWhenProviderOmitsStatus() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root)
    await store.restore()
    store.modelConfiguration = config
    store.notificationPreferences = .init(timing: .never)
    XCTAssertTrue(store.configureGoal(GoalDefinition(
      objective: "安全暂停", successCriteria: ["没有明确状态时不循环"], maxIterations: 3)))
    store.draft = "hello"
    await store.sendDraft()
    await store.modelTask?.value

    let taskID = try XCTUnwrap(store.selectedTask?.id)
    XCTAssertEqual(store.library.chatRuns.count, 1)
    XCTAssertEqual(store.library.goalSessions[taskID]?.status, .paused)
    XCTAssertEqual(store.chatMode, .standard)
    await store.shutdown()
  }
  @MainActor func testGoalModeStopsAtConfiguredIterationLimit() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root)
    await store.restore()
    store.modelConfiguration = config
    store.notificationPreferences = .init(timing: .never)
    XCTAssertTrue(store.configureGoal(GoalDefinition(
      objective: "限制轮次", successCriteria: ["不会无限循环"], maxIterations: 1)))
    store.draft = "goal-continue"
    await store.sendDraft()
    await store.modelTask?.value

    let taskID = try XCTUnwrap(store.selectedTask?.id)
    XCTAssertEqual(store.library.chatRuns.count, 1)
    XCTAssertEqual(store.library.goalSessions[taskID]?.status, .paused)
    XCTAssertEqual(store.library.goalSessions[taskID]?.iteration, 1)
    await store.shutdown()
  }
  @MainActor func testAutomationRunCreatesReviewableTaskFromActualRequest() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root)
    await store.restore()
    store.modelConfiguration = config
    store.notificationPreferences = .init(timing: .never)
    var automation = ShipAutomation(
      name: "Fixture automation", prompt: "automation plugin-context")
    automation.nextRun = Date().addingTimeInterval(60)
    XCTAssertTrue(store.saveAutomation(automation))

    await store.runAutomation(automation.id)

    let saved = try XCTUnwrap(store.automationPreferences.items.first)
    XCTAssertTrue(saved.needsReview)
    XCTAssertNotNil(saved.taskID)
    XCTAssertGreaterThan(saved.nextRun, .now)
    let run = try XCTUnwrap(store.library.chatRuns.first(where: { $0.id == saved.lastRunID }))
    XCTAssertEqual(run.status, "succeeded")
    XCTAssertEqual(run.request["automation_id"].text, automation.id.uuidString)
    let request = try JSONDecoder().decode(JSONValue.self, from: Data(try XCTUnwrap(run.result?["response"].text).utf8))
    XCTAssertEqual(request["messages"].items.last?["content"].text, "automation plugin-context")
    store.openAutomationResult(automation.id)
    XCTAssertEqual(store.destination, .workspace)
    XCTAssertEqual(store.selectedTask?.id, saved.taskID)
    XCTAssertFalse(store.automationPreferences.items[0].needsReview)
    await store.shutdown()
  }
  @MainActor func testTaskWindowSubmissionConsumesOnlyItsDraftAndUsesTaskProject() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root.appendingPathComponent("Data"))
    await store.restore()
    store.project = root
    store.modelConfiguration = config
    store.notificationPreferences = .init(timing: .never)
    let task = WorkspaceTask(
      id: "window-task", project: root.path, title: "Window task", runIDs: [])
    store.library.tasks = [task]
    store.library.drafts[task.id] = "file-context"
    store.library.drafts["new:\(root.path)"] = "main draft"
    store.beginReviewComment(
      .init(
        project: root.path, path: "Hello.swift", scope: "未暂存", revision: "working tree",
        fingerprint: "fixture", oldLine: 1, newLine: 1, code: "let value = 1"),
      taskID: task.id)
    let commentID = try XCTUnwrap(store.reviewComments(taskID: task.id).first?.id)
    store.updateReviewComment(commentID, text: "Preserve this task review", taskID: task.id)
    store.saveReviewComment(commentID, taskID: task.id)
    let source = root.appendingPathComponent("window.txt")
    try Data("task window file payload".utf8).write(to: source)
    let imported = await store.importFiles([source], draft: task.id)
    XCTAssertTrue(imported)

    await store.sendTaskWindowDraft(task.id, mode: .standard)
    try await XCTUnwrap(store.modelTask).value

    XCTAssertEqual(store.library.drafts[task.id], "")
    XCTAssertEqual(store.library.drafts["new:\(root.path)"], "main draft")
    let run = try XCTUnwrap(store.library.chatRuns.last)
    XCTAssertEqual(run.project, root.path)
    XCTAssertEqual(store.library.task(containing: run.id)?.id, task.id)
    XCTAssertEqual(run.status, "succeeded")
    XCTAssertEqual(store.library.runFiles[run.id]?.map(\.name), ["window.txt"])
    XCTAssertTrue(store.reviewComments(taskID: task.id).isEmpty)
    let messages = try JSONDecoder().decode(
      [ChatMessage].self, from: Data(try XCTUnwrap(run.result?["response"].text).utf8))
    XCTAssertTrue(messages.last?.content.contains("task window file payload") == true)
    XCTAssertTrue(messages.last?.content.contains("Preserve this task review") == true)
    await store.shutdown()
  }
  @MainActor func testInlineCodeReviewUsesCurrentTaskAndSendsImmutableDiffContext() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let repository = root.appendingPathComponent("Project")
    try await makeReviewRepository(repository)
    let store = WorkspaceStore(dataRoot: root.appendingPathComponent("Data"))
    await store.restore()
    store.project = repository
    store.workspace.setProject(repository)
    store.modelConfiguration = config
    store.notificationPreferences = .init(timing: .never)
    let taskID = seedReviewTask(store, project: repository.path)
    store.library.drafts[taskID] = "保留当前草稿"
    store.library.gitPreferences.reviewDelivery = .inline
    store.showingReviewMode = true
    store.reviewModeProject = repository.path

    await store.startCodeReview(.uncommitted)
    let started = try XCTUnwrap(store.library.chatRuns.last)
    try await XCTUnwrap(store.modelTask(runID: started.id)).value
    let run = try XCTUnwrap(store.library.chatRuns.first { $0.id == started.id })

    XCTAssertEqual(store.library.task(containing: run.id)?.id, taskID)
    XCTAssertEqual(store.library.drafts[taskID], "保留当前草稿")
    XCTAssertEqual(run.request["conversation_kind"].text, "review")
    XCTAssertEqual(run.request["review_scope"].text, "uncommitted")
    XCTAssertEqual(run.request["review_delivery"].text, "inline")
    XCTAssertGreaterThan(run.request["review_diff_bytes"].int ?? 0, 0)
    XCTAssertEqual(run.title, "代码审查 · fixture-model")
    let messages = try JSONDecoder().decode(
      [ChatMessage].self, from: Data(try XCTUnwrap(run.result?["response"].text).utf8))
    XCTAssertTrue(messages.first?.content.contains("当前回合是代码审查") == true)
    XCTAssertTrue(messages.last?.content.contains("<git_diff>") == true)
    XCTAssertTrue(messages.last?.content.contains("+let value = 3") == true)
    XCTAssertFalse(store.showingReviewMode)
    await store.shutdown()
  }

  @MainActor func testDetachedCodeReviewCreatesAndSelectsSeparateTaskWithoutConsumingDraft() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let repository = root.appendingPathComponent("Project")
    try await makeReviewRepository(repository)
    let store = WorkspaceStore(dataRoot: root.appendingPathComponent("Data"))
    await store.restore()
    store.project = repository
    store.workspace.setProject(repository)
    store.modelConfiguration = config
    store.notificationPreferences = .init(timing: .never)
    let originalTaskID = seedReviewTask(store, project: repository.path)
    store.library.drafts[originalTaskID] = "不要覆盖这条草稿"
    store.library.gitPreferences.reviewDelivery = .detached
    store.showingReviewMode = true
    store.reviewModeProject = repository.path

    await store.startCodeReview(.branch("refs/heads/main"))
    XCTAssertNil(store.reviewModeError, store.reviewModeError ?? "")
    XCTAssertNil(store.error, store.error ?? "")
    XCTAssertEqual(store.library.chatRuns.count, 2, store.reviewModeError ?? store.error ?? "")
    let started = try XCTUnwrap(store.library.chatRuns.last)
    try await XCTUnwrap(store.modelTask(runID: started.id)).value
    let reviewTask = try XCTUnwrap(store.library.task(containing: started.id))

    XCTAssertNotEqual(reviewTask.id, originalTaskID)
    XCTAssertEqual(store.selectedTask?.id, reviewTask.id)
    XCTAssertEqual(reviewTask.title, "审查相对于 main 的更改")
    XCTAssertEqual(store.library.drafts[originalTaskID], "不要覆盖这条草稿")
    XCTAssertEqual(started.request["review_delivery"].text, "detached")
    XCTAssertEqual(started.request["review_scope"].text, "branch")
    XCTAssertEqual(started.request["review_selection"].text, "refs/heads/main")
    XCTAssertFalse(reviewTask.isPopoutDraft)
    XCTAssertFalse(store.library.tasks.contains { $0.isPopoutDraft && $0.runIDs.isEmpty })
    await store.shutdown()
  }

  @MainActor private func seedReviewTask(_ store: WorkspaceStore, project: String) -> String {
    let now = Date().timeIntervalSince1970 * 1000
    let seed = AgentRun(
      id: UUID().uuidString, kind: "chat", project: project, status: "succeeded",
      createdAt: now, updatedAt: now,
      request: .object(["model": .string("fixture-model"), "mode": .string("standard")]),
      result: .object(["response": .string("已有回复")]))
    store.library.attach(seed, to: nil, note: "已有任务")
    store.library.chatRuns.append(seed)
    store.runs = [seed]
    store.selection = seed.id
    return store.library.task(containing: seed.id)!.id
  }

  private func makeReviewRepository(_ repository: URL) async throws {
    try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
    _ = try await GitReviewService.checked(["init", "-q", "-b", "main"], at: repository)
    _ = try await GitReviewService.checked(
      ["config", "user.name", "ShipiOS Test"], at: repository)
    _ = try await GitReviewService.checked(
      ["config", "user.email", "qa@example.invalid"], at: repository)
    try Data("let value = 1\n".utf8).write(
      to: repository.appendingPathComponent("Review.swift"))
    _ = try await GitReviewService.checked(["add", "--all"], at: repository)
    _ = try await GitReviewService.checked(
      ["commit", "-q", "-m", "Initial"], at: repository)
    _ = try await GitReviewService.checked(["checkout", "-q", "-b", "feature"], at: repository)
    try Data("let value = 2\n".utf8).write(
      to: repository.appendingPathComponent("Review.swift"))
    _ = try await GitReviewService.checked(["add", "--all"], at: repository)
    _ = try await GitReviewService.checked(
      ["commit", "-q", "-m", "Feature"], at: repository)
    try Data("let value = 3\n".utf8).write(
      to: repository.appendingPathComponent("Review.swift"))
  }
  func testCancellationPreservesPartialOutput() async throws {
    let collector = StreamCollector()
    let config = self.config
    let request = Task {
      _ = try await ModelAPIClient().stream(
        config: config, key: nil, messages: [.init(role: "user", content: "slow")]
      ) { await collector.append($0) }
    }
    try await Task.sleep(for: .milliseconds(300))
    request.cancel()
    do {
      _ = try await request.value
      XCTFail("Expected cancellation")
    } catch {}
    let text = await collector.text
    XCTAssertFalse(text.isEmpty)
    XCTAssertLessThan(text.count, 103)
  }
  func testRedirectIsNotFollowed() async {
    config.baseURL = config.baseURL.replacingOccurrences(of: "/v1", with: "/redirect")
    do {
      _ = try await ModelAPIClient().test(config: config, key: "fixture-placeholder")
      XCTFail("Redirect should fail")
    } catch { XCTAssertTrue(error.localizedDescription.contains("302")) }
  }
}
