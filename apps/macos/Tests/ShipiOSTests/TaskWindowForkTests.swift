import XCTest
@testable import ShipiOS

@MainActor final class TaskWindowForkTests: XCTestCase {
  private func setup() async -> (WorkspaceStore, URL) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = WorkspaceStore(dataRoot: root)
    await store.restore()
    let sourceRuns = ["first", "middle", "last"].map { id in
      AgentRun(id: id, kind: "chat", project: "/another-project", status: "succeeded", createdAt: 0,
        updatedAt: 1, request: .object(["model": .string("source-model")]),
        result: .object(["response": .string("Reply " + id)]))
    }
    store.library.tasks = [.init(id: "main", project: "", title: "Main", runIDs: []),
      .init(id: "source", project: "/another-project", title: "Source", runIDs: sourceRuns.map(\.id))]
    store.library.chatRuns = sourceRuns
    store.library.notes = ["first": "First prompt", "middle": "Middle prompt", "last": "Last prompt"]
    store.library.drafts = ["main": "Main draft", "source": "Source draft"]
    store.selectTask(store.library.tasks[0])
    return (store, root)
  }

  func testCrossProjectForkCopiesPrefixAndLeavesMainStateUnchanged() async throws {
    let (store, root) = await setup()
    defer { try? FileManager.default.removeItem(at: root) }
    store.library.tasks[1].modelSelection = .init(model: "source-model", reasoning: "high", providerAccount: "provider")
    let image = try ImageAttachmentStorage.importData(AttachmentFixture.png(), name: "source.png", root: root)
    store.library.runImages["first"] = [image]
    let selection = store.selection, mainRuns = store.runs, navigation = store.navigationBack
    let projectSelections = store.library.projectSelections
    XCTAssertTrue(store.canForkTaskWindow("source", through: "middle"))
    let fork = try store.forkTaskWindowConversation("source", through: "middle")
    XCTAssertEqual(store.selection, selection)
    XCTAssertEqual(store.runs, mainRuns)
    XCTAssertEqual(store.navigationBack, navigation)
    XCTAssertEqual(store.library.projectSelections, projectSelections)
    XCTAssertEqual(fork.project, "/another-project")
    XCTAssertEqual(fork.runIDs.count, 2)
    XCTAssertEqual(fork.modelSelection?.model, "source-model")
    XCTAssertEqual(store.library.runImages[fork.runIDs[0]], [image])
    XCTAssertEqual(store.taskWindowRuns(fork.id).map(\.result), Array(store.library.chatRuns.prefix(2)).map(\.result))
    XCTAssertEqual(store.library.drafts["source"], "Source draft")
    XCTAssertEqual(store.library.drafts["main"], "Main draft")
    XCTAssertEqual(store.library.chatContext(taskID: fork.id).map(\.content),
      ["First prompt", "Reply first", "Middle prompt", "Reply middle"])
    let restored = WorkspaceStore(dataRoot: root)
    await restored.restore()
    XCTAssertEqual(restored.taskWindowRuns(fork.id).count, 2)
    XCTAssertEqual(restored.library.tasks.first { $0.id == fork.id }?.forkOrigin?.runID, "middle")
    await store.shutdown(); await restored.shutdown()
  }

  func testSlashForkConsumesOnlySourceCommandAfterSuccessfulWrite() async throws {
    let (store, root) = await setup()
    defer { try? FileManager.default.removeItem(at: root) }
    store.setTaskWindowDraft("/fork", taskID: "source")
    let file = root.appendingPathComponent("workspace.json")
    try FileManager.default.removeItem(at: file)
    try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
    XCTAssertThrowsError(try store.forkTaskWindowConversation("source", consumeCommand: true))
    XCTAssertEqual(store.library.tasks.count, 2)
    XCTAssertTrue(store.library.forkRuns.isEmpty)
    XCTAssertEqual(store.taskWindowDraft("source"), "/fork")
    try FileManager.default.removeItem(at: file)
    let fork = try store.forkTaskWindowConversation("source", consumeCommand: true)
    XCTAssertEqual(store.taskWindowDraft("source"), "")
    XCTAssertEqual(store.taskWindowDraft("main"), "Main draft")
    XCTAssertEqual(store.selectedTask?.id, "main")
    XCTAssertEqual(fork.runIDs.count, 3)
    await store.shutdown()
  }

  func testIncompleteHistoryAndActiveTurnsCannotBeExplicitForkPoints() async throws {
    let (store, root) = await setup()
    defer { try? FileManager.default.removeItem(at: root) }
    let last = store.library.chatRuns[2]
    store.library.chatRuns[2] = AgentRun(id: last.id, kind: last.kind, project: last.project,
      status: "running", createdAt: last.createdAt, updatedAt: last.updatedAt,
      request: last.request, result: last.result)
    XCTAssertTrue(store.canForkTaskWindow("source"))
    XCTAssertFalse(store.canForkTaskWindow("source", through: "last"))
    let fork = try store.forkTaskWindowConversation("source")
    XCTAssertEqual(fork.runIDs.count, 2)
    store.library.chatRuns.removeAll { $0.id == "middle" }
    XCTAssertFalse(store.canForkTaskWindow("source"))
    XCTAssertFalse(store.canForkTaskWindow("source", through: "middle"))
    XCTAssertTrue(store.canForkTaskWindow("source", through: "first"))
    XCTAssertFalse(store.canForkTaskWindow("main"))
    XCTAssertThrowsError(try store.forkTaskWindowConversation("missing"))
    XCTAssertThrowsError(try store.forkTaskWindowConversation("source", through: "missing"))
    await store.shutdown()
  }

  func testNestedForkKeepsOriginalRunOriginsAndCanContinueIndependently() async throws {
    let (store, root) = await setup()
    defer { try? FileManager.default.removeItem(at: root) }
    let first = try store.forkTaskWindowConversation("source", through: "first")
    let second = try store.forkTaskWindowConversation(first.id)
    XCTAssertEqual(store.library.forkRunOrigins[second.runIDs[0]], "first")
    XCTAssertEqual(second.forkOrigin?.taskID, first.id)
    store.setTaskWindowDraft("Follow up", taskID: second.id)
    XCTAssertEqual(store.taskWindowDraft(first.id), "")
    XCTAssertEqual(store.taskWindowDraft("source"), "Source draft")
    XCTAssertEqual(store.selectedTask?.id, "main")
    await store.shutdown()
  }
}
