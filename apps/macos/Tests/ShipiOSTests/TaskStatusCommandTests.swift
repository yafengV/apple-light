import XCTest
@testable import ShipiOS

final class TaskStatusCommandTests: XCTestCase {
  @MainActor func testStatusCommandOpensCurrentTaskWithoutModelConfiguration() {
    let store = WorkspaceStore()
    store.library.tasks = [.init(id: "first", project: "", title: "First", runIDs: []),
      .init(id: "second", project: "", title: "Second", runIDs: [])]
    store.selection = "second"
    store.draft = "/status"
    var selection = ComposerCommandSelection()
    selection.update(draft: "/sta", enabled: store.enabledComposerCommands)

    XCTAssertEqual(selection.matches, [.status])
    XCTAssertEqual(DesktopCommand.all.first(where: { $0.id == "status" })?.group, .chat)
    XCTAssertTrue(TaskWindowCommandContext.owns("status"))
    XCTAssertTrue(store.canSend)
    XCTAssertTrue(store.handleComposerCommand())
    XCTAssertTrue(store.showingTaskStatus)
    XCTAssertEqual(store.selectedTask?.id, "second")
    XCTAssertEqual(store.draft, "")
  }

  func testStatusSnapshotUsesOnlyItsOwnTaskUsageAndActualThreadID() {
    let task = WorkspaceTask(id: "second", project: "", title: "Second", runIDs: [],
      codexThreadID: "48F5D199-9809-4146-8FDB-87CBCA0EC210")
    let records = [record(taskID: "first", input: 100, output: 30),
      record(taskID: "second", input: 20, output: 5),
      record(taskID: "second", input: 35, output: 7)]
    let snapshot = TaskStatusSnapshot(task: task, records: records,
      recentContextInputTokens: 35)

    XCTAssertEqual(snapshot.taskID, "second")
    XCTAssertEqual(snapshot.codexThreadID, task.codexThreadID)
    XCTAssertEqual(snapshot.recentContextInputTokens, 35)
    XCTAssertEqual(snapshot.recordedUsage?.inputTokens, 55)
    XCTAssertEqual(snapshot.recordedUsage?.outputTokens, 12)
    XCTAssertEqual(snapshot.recordedUsage?.totalTokens, 67)
  }

  private func record(taskID: String, input: Int, output: Int) -> ModelUsageRecord {
    ModelUsageRecord(runID: UUID().uuidString, taskID: taskID,
      taskTitle: taskID, projectTitle: "", model: "test", reasoning: "",
      date: .now, duration: 1,
      usage: ModelTokenUsage(inputTokens: input, outputTokens: output))
  }
}
