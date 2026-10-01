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

  func testContextPercentageRequiresMatchingModelAndUsage() {
    let task = WorkspaceTask(id: "second", project: "", title: "Second", runIDs: [])
    let usage = record(taskID: task.id, input: 200, output: 5)
    let matched = TaskStatusSnapshot(task: task, records: [usage],
      recentContextInputTokens: 200, currentModel: "test", contextWindow: 1_000)
    XCTAssertEqual(matched.contextFraction, 0.2)
    XCTAssertEqual(matched.contextWindow, 1_000)
    XCTAssertNil(TaskStatusSnapshot(task: task, records: [usage],
      recentContextInputTokens: 200, currentModel: "new-model", contextWindow: 1_000).contextFraction)
    XCTAssertNil(TaskStatusSnapshot(task: task, records: [usage],
      recentContextInputTokens: 201, currentModel: "test", contextWindow: 1_000).contextFraction)
    XCTAssertNil(TaskStatusSnapshot(task: task, records: [usage],
      recentContextInputTokens: 200, currentModel: "test", contextWindow: nil).contextFraction)
  }

  @MainActor func testTaskContextWindowUsesOnlyCurrentServiceAndModel() {
    let store = WorkspaceStore()
    var config = ModelConfiguration()
    config.baseURL = "https://example.com/v1"
    config.model = "selected"
    store.modelConfiguration = config
    let source = ModelCatalogSource(config)
    store.skillModelCatalogs[source] = [
      "selected": ModelCatalogEntry(id: "selected", contextWindow: 8_000),
      "other": ModelCatalogEntry(id: "other", contextWindow: 16_000),
    ]
    XCTAssertEqual(store.contextWindow(for: nil), 8_000)
    config.model = "missing"
    store.modelConfiguration = config
    XCTAssertNil(store.contextWindow(for: nil))
    config.baseURL = "https://another.example.com/v1"
    config.model = "selected"
    store.modelConfiguration = config
    XCTAssertNil(store.contextWindow(for: nil))
  }

  @MainActor func testTaskStatusLoadsMissingContextWindowOnceFromSelectedService() async {
    let store = WorkspaceStore()
    var config = ModelConfiguration()
    config.baseURL = "https://example.com/v1"
    config.model = "selected"
    store.modelConfiguration = config
    var fetches = 0
    let first = await store.loadContextWindow(for: nil) { requested in
      fetches += 1
      XCTAssertEqual(requested.credentialAccount, "https://example.com/v1")
      return [ModelCatalogEntry(id: "selected", contextWindow: 8_000)]
    }
    XCTAssertEqual(first, 8_000)
    let second = await store.loadContextWindow(for: nil) { _ in
      fetches += 1
      return []
    }
    XCTAssertEqual(second, 8_000)
    XCTAssertEqual(fetches, 1)
    config.model = "unknown"
    store.modelConfiguration = config
    let unknown = await store.loadContextWindow(for: nil) { _ in
      fetches += 1
      return []
    }
    XCTAssertNil(unknown)
    XCTAssertEqual(fetches, 1)
  }

  @MainActor func testTaskStatusKeepsUsageWhenModelCatalogFails() async {
    let store = WorkspaceStore()
    var config = ModelConfiguration()
    config.baseURL = "https://example.com/v1"
    config.model = "selected"
    store.modelConfiguration = config
    let window = await store.loadContextWindow(for: nil) { _ in
      throw AgentFailure(message: "Service unavailable")
    }
    XCTAssertNil(window)
    XCTAssertNil(store.contextWindow(for: nil))
  }

  private func record(taskID: String, input: Int, output: Int) -> ModelUsageRecord {
    ModelUsageRecord(runID: UUID().uuidString, taskID: taskID,
      taskTitle: taskID, projectTitle: "", model: "test", reasoning: "",
      date: .now, duration: 1,
      usage: ModelTokenUsage(inputTokens: input, outputTokens: output))
  }
}
