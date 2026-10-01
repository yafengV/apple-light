import XCTest

@testable import ShipiOS

final class TaskWindowTests: XCTestCase {
  @MainActor func testTaskWindowKeepsItsOwnRunOrderAndDraft() {
    let store = WorkspaceStore()
    let first = AgentRun(
      id: "first", kind: "chat", project: "/project", status: "succeeded",
      createdAt: 1, updatedAt: 1, request: .null,
      result: .object(["response": .string("one")]))
    let second = AgentRun(
      id: "second", kind: "chat", project: "/project", status: "succeeded",
      createdAt: 2, updatedAt: 2, request: .null,
      result: .object(["response": .string("two")]))
    store.library.tasks = [
      .init(id: "task", project: "/project", title: "Task", runIDs: [first.id, second.id]),
      .init(id: "other", project: "/project", title: "Other", runIDs: []),
    ]
    store.runs = [second]
    store.library.chatRuns = [first]
    store.library.drafts["other"] = "other draft"

    store.setTaskWindowDraft("window draft", taskID: "task")

    XCTAssertEqual(store.taskWindowRuns("task").map(\.id), ["first", "second"])
    XCTAssertEqual(store.taskWindowDraft("task"), "window draft")
    XCTAssertEqual(store.library.drafts["other"], "other draft")
  }

  @MainActor func testPromptHistoryRestoresOnlyTheExactTaskAndSkipsEmptyNotes() {
    let store = WorkspaceStore()
    store.library.tasks = [
      .init(id: "task", project: "/project", title: "Task", runIDs: ["first", "empty"]),
      .init(id: "other", project: "/project", title: "Other", runIDs: ["other-run"]),
    ]
    store.library.notes = [
      "first": "previous task prompt",
      "empty": "  \n",
      "other-run": "other prompt",
    ]
    store.library.drafts["task"] = ""
    store.library.drafts["other"] = "other draft"

    store.restoreTaskWindowPrompt("task")

    XCTAssertEqual(store.taskWindowDraft("task"), "previous task prompt")
    XCTAssertEqual(store.taskWindowDraft("other"), "other draft")
    store.restoreTaskWindowPrompt("missing")
    XCTAssertNil(store.library.drafts["missing"])
  }

  @MainActor func testPromptHistoryDoesNotReplaceExistingTaskWindowDraft() {
    let store = WorkspaceStore()
    store.library.tasks = [
      .init(id: "task", project: "/project", title: "Task", runIDs: ["run"])
    ]
    store.library.notes["run"] = "previous prompt"
    store.library.drafts["task"] = "current draft"

    store.restoreTaskWindowPrompt("task")

    XCTAssertEqual(store.taskWindowDraft("task"), "current draft")
  }

  @MainActor func testTaskWindowModelSessionDoesNotRequireMainProjectSelection() {
    let store = WorkspaceStore()
    store.library.tasks = [
      .init(id: "task", project: "/other", title: "Task", runIDs: [])
    ]
    store.setTaskWindowDraft("keep me", taskID: "task")

    XCTAssertNotEqual(store.currentProjectKey, "/other")
    XCTAssertTrue(store.canStartChat(taskID: "task"))
    XCTAssertEqual(store.taskWindowDraft("task"), "keep me")
    XCTAssertNil(store.error)
  }

  @MainActor func testTaskWindowSearchIndexesOnlyItsVisibleConversation() {
    let store = WorkspaceStore()
    let first = AgentRun(
      id: "first", kind: "chat", project: "/project", status: "succeeded",
      createdAt: 1, updatedAt: 1, request: .null,
      result: .object(["response": .string("needle in the selected answer")]))
    let other = AgentRun(
      id: "other-run", kind: "chat", project: "/project", status: "succeeded",
      createdAt: 2, updatedAt: 2, request: .null,
      result: .object(["response": .string("needle in another task")]))
    store.library.chatRuns = [first, other]
    store.library.notes = [first.id: "selected prompt", other.id: "other prompt"]
    store.library.tasks = [
      .init(id: "task", project: "/project", title: "Task", runIDs: [first.id]),
      .init(id: "other", project: "/project", title: "Other", runIDs: [other.id]),
    ]

    let inputs = ConversationSearch.inputs(store.taskWindowRuns("task"), library: store.library)
    let matches = ConversationSearch.find(inputs, query: "needle")

    XCTAssertEqual(inputs.map(\.run), ["first"])
    XCTAssertEqual(Set(matches.map(\.textID.run)), ["first"])
    XCTAssertEqual(matches.count, 1)
  }

  @MainActor func testTaskWindowDeveloperWorkspaceDoesNotReplaceMainProjectScope() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let mainRoot = root.appendingPathComponent("main", isDirectory: true)
    let taskRoot = root.appendingPathComponent("task", isDirectory: true)
    try FileManager.default.createDirectory(at: mainRoot, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: taskRoot, withIntermediateDirectories: true)
    try Data("main".utf8).write(to: mainRoot.appendingPathComponent("Main.swift"))
    try Data("task".utf8).write(to: taskRoot.appendingPathComponent("Task.swift"))
    let store = WorkspaceStore()
    let taskWorkspace = DeveloperWorkspace()
    store.workspace.setProject(mainRoot)
    taskWorkspace.setProject(taskRoot)
    await store.workspace.refreshFiles()
    await taskWorkspace.refreshFiles()
    await taskWorkspace.openFile("Task.swift")

    XCTAssertEqual(store.workspace.root, mainRoot)
    XCTAssertEqual(store.workspace.files, ["Main.swift"])
    XCTAssertNil(store.workspace.selectedFile)
    XCTAssertEqual(taskWorkspace.root, taskRoot)
    XCTAssertEqual(taskWorkspace.files, ["Task.swift"])
    XCTAssertEqual(taskWorkspace.selectedFile, "Task.swift")
    XCTAssertEqual(taskWorkspace.fileText, "task")
  }

  @MainActor func testTaskWindowAttachmentStorageUsesExactTaskDraft() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root.appendingPathComponent("Data"))
    await store.restore()
    store.library.tasks = [
      .init(id: "task", project: "", title: "Task", runIDs: []),
      .init(id: "other", project: "", title: "Other", runIDs: []),
    ]
    let source = root.appendingPathComponent("context.txt")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try Data("task window attachment".utf8).write(to: source)
    let importedFile = await store.importFiles([source], draft: "task")
    let importedImage = await store.importImages(
      [.bytes(try AttachmentFixture.png(), name: "window.png")], draft: "task")
    XCTAssertTrue(importedFile)
    XCTAssertTrue(importedImage)

    XCTAssertEqual(store.taskWindowFiles("task").map(\.name), ["context.txt"])
    XCTAssertEqual(store.taskWindowImages("task").map(\.name), ["window.png"])
    XCTAssertTrue(store.taskWindowFiles("other").isEmpty)
    XCTAssertTrue(store.taskWindowImages("other").isEmpty)

    store.removeDraftFile(try XCTUnwrap(store.taskWindowFiles("task").first), draft: "task")
    store.removeDraftImage(try XCTUnwrap(store.taskWindowImages("task").first), draft: "task")
    XCTAssertTrue(store.taskWindowFiles("task").isEmpty)
    XCTAssertTrue(store.taskWindowImages("task").isEmpty)
    await store.shutdown()
  }

  @MainActor func testEditingPopoutQueueRestoresOnlyItsTaskDraft() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root)
    store.library.tasks = [
      .init(id: "popout", project: "", title: "Popout", runIDs: []),
      .init(id: "other", project: "", title: "Other", runIDs: []),
    ]
    store.library.drafts["other"] = "keep other draft"
    let popoutMessage = QueuedMessage(taskID: "popout", text: "queued popout")
    let otherMessage = QueuedMessage(taskID: "other", text: "queued other")
    store.library.queuedMessages = [popoutMessage, otherMessage]
    XCTAssertNotEqual(store.selectedTask?.id, "popout")

    store.editQueuedMessage(popoutMessage, taskID: "popout")

    XCTAssertEqual(store.taskWindowDraft("popout"), "queued popout")
    XCTAssertEqual(store.taskWindowDraft("other"), "keep other draft")
    XCTAssertEqual(store.library.queuedMessages, [otherMessage])
    XCTAssertNil(store.error)
  }

  @MainActor func testEditingPopoutQueuePreservesExistingDraftAndMessage() {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root)
    store.library.tasks = [.init(id: "popout", project: "", title: "Popout", runIDs: [])]
    let message = QueuedMessage(taskID: "popout", text: "queued")
    store.library.queuedMessages = [message]
    store.library.drafts["popout"] = "unsent text"

    store.editQueuedMessage(message, taskID: "popout")

    XCTAssertEqual(store.taskWindowDraft("popout"), "unsent text")
    XCTAssertEqual(store.library.queuedMessages, [message])
    XCTAssertNotNil(store.error)
  }

  @MainActor func testSendingPopoutFollowUpQueuesOnlyItsTaskWhileRunning() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root)
    store.library.tasks = [
      .init(id: "popout", project: "", title: "Popout", runIDs: ["active"]),
      .init(id: "other", project: "", title: "Other", runIDs: []),
    ]
    store.runs = [AgentRun(id: "active", kind: "chat", project: "", status: "running",
      createdAt: 1, updatedAt: 1, request: .null, result: nil)]
    store.library.drafts["other"] = "untouched main draft"
    store.setTaskWindowDraft("follow up from popout", taskID: "popout")
    XCTAssertNotEqual(store.selectedTask?.id, "popout")

    await store.sendTaskWindowDraft("popout", mode: .standard)

    XCTAssertEqual(store.library.queuedMessages.map(\.taskID), ["popout"])
    XCTAssertEqual(store.library.queuedMessages.first?.text, "follow up from popout")
    XCTAssertEqual(store.taskWindowDraft("popout"), "")
    XCTAssertEqual(store.taskWindowDraft("other"), "untouched main draft")
    XCTAssertNil(store.error)
  }

  @MainActor func testTaskWindowQueueOverrideDoesNotChangeSavedSteerPreference() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root)
    store.libraryLoaded = true
    store.library.tasks = [.init(id: "popout", project: "", title: "Popout", runIDs: ["active"])]
    store.runs = [AgentRun(id: "active", kind: "chat", project: "", status: "running",
      createdAt: 1, updatedAt: 1, request: .null, result: nil)]
    store.followUpBehavior = .steer
    store.setTaskWindowDraft("Queue from this window", taskID: "popout")

    await store.sendTaskWindowDraft("popout", mode: .standard, followUpOverride: .queue)

    XCTAssertEqual(store.library.queuedMessages.map(\.text), ["Queue from this window"])
    XCTAssertEqual(store.followUpBehavior, .steer)
    XCTAssertEqual(store.taskWindowDraft("popout"), "")
    XCTAssertNil(store.error)
  }

  @MainActor func testPopoutPlanContinueTargetsItsTaskWithoutChangingMainDraft() {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root)
    let plan = AgentRun(id: "plan", kind: "chat", project: "", status: "succeeded",
      createdAt: 1, updatedAt: 2,
      request: .object(["mode": .string(ChatMode.plan.rawValue)]), result: nil)
    store.library.tasks = [
      .init(id: "popout", project: "", title: "Popout", runIDs: [plan.id]),
      .init(id: "other", project: "", title: "Other", runIDs: []),
    ]
    store.library.drafts["other"] = "main draft"
    XCTAssertNotEqual(store.selectedTask?.id, "popout")

    store.continueFromPlan(plan, taskID: "popout")

    XCTAssertEqual(store.taskWindowDraft("popout"),
      "按照上面的计划开始实现。完成后运行相关验证并报告结果。")
    XCTAssertEqual(store.taskWindowDraft("other"), "main draft")
    XCTAssertNil(store.error)
  }

  @MainActor func testPopoutRunActionsRejectRunOwnedByAnotherTask() {
    let store = WorkspaceStore()
    let run = AgentRun(id: "finished", kind: "chat", project: "", status: "succeeded",
      createdAt: 1, updatedAt: 2, request: .object(["mode": .string(ChatMode.plan.rawValue)]),
      result: .object(["response": .string("done")]))
    store.library.tasks = [
      .init(id: "popout", project: "", title: "Popout", runIDs: []),
      .init(id: "other", project: "", title: "Other", runIDs: [run.id]),
    ]
    store.library.chatRuns = [run]

    XCTAssertFalse(store.canRerunTaskWindowChat(run, taskID: "popout"))
    XCTAssertTrue(store.canRerunTaskWindowChat(run, taskID: "other"))
    store.continueFromPlan(run, taskID: "popout")
    XCTAssertTrue(store.taskWindowDraft("popout").isEmpty)
  }
}
