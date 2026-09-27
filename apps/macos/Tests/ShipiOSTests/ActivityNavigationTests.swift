import XCTest
@testable import ShipiOS

@MainActor final class ActivityNavigationTests: XCTestCase {
  private func store(withMissingAgent: Bool = false) async -> WorkspaceStore {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("activity-\(UUID())")
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root,
      agentExecutable: withMissingAgent ? root.appendingPathComponent("missing-agent") : nil)
    await store.restore()
    return store
  }

  private func run(_ id: String, status: String) -> AgentRun {
    AgentRun(id: id, kind: "chat", project: "", status: status,
      createdAt: 1, updatedAt: 2, request: .null, result: nil)
  }

  func testActivityOrdersPendingRunningAndUnreadAndFiltersIndependently() async {
    let store = await store()
    store.library.tasks = ["unread", "running", "pending", "archived"].map {
      .init(id: $0, project: "", title: $0, runIDs: [$0])
    }
    store.library.tasks[3].archived = true
    store.runs = [run("unread", status: "succeeded"), run("running", status: "running"),
      run("pending", status: "running"), run("archived", status: "succeeded")]
    store.library.unreadTasks = ["unread", "pending", "archived"]
    let execution = MCPToolExecution(callID: "call", serverID: UUID(), serverName: "server",
      toolName: "tool", arguments: "{}")
    store.mcpPendingApprovals[execution.id] = MCPApprovalContext(runID: "pending", execution: execution)

    let items = store.activityEntries
    XCTAssertEqual(items.map(\.id), ["pending", "running", "unread"])
    XCTAssertEqual(items.map(\.statusTitle), ["等待工具批准", "正在运行", "未读活动"])
    XCTAssertEqual(items.filter(ActivityFilter.needsAction.includes).map(\.id), ["pending"])
    XCTAssertEqual(items.filter(ActivityFilter.running.includes).map(\.id), ["pending", "running"])
    XCTAssertEqual(items.filter(ActivityFilter.unread.includes).map(\.id), ["pending", "unread"])
    XCTAssertEqual(store.activityBadgeCount, 2)
    store.clearUnreadTasks()
    XCTAssertEqual(store.activityEntries.map(\.id), ["pending", "running"])
    XCTAssertEqual(store.activityBadgeCount, 1)
    await store.shutdown()
  }

  func testActivityNavigationKeepsSettingsReturnAndOpeningConsumesUnread() async {
    let store = await store()
    store.library.tasks = [.init(id: "target", project: "", title: "Target", runIDs: ["run"])]
    store.runs = [run("run", status: "succeeded")]
    store.library.unreadTasks = ["target"]
    XCTAssertTrue(store.commandEnabled("activity"))
    XCTAssertEqual(store.shortcuts.binding("activity"), ShortcutBinding("⌘⌥U"))
    store.executeCommand("activity")
    XCTAssertEqual(store.destination, .activity)
    XCTAssertTrue(store.retainsActivityPage)
    store.openSettings(.notifications)
    store.closeSettings()
    XCTAssertEqual(store.destination, .activity)
    let opened = await store.openActivityTask("target")
    XCTAssertTrue(opened)
    XCTAssertEqual(store.destination, .workspace)
    XCTAssertEqual(store.selectedTask?.id, "target")
    XCTAssertFalse(store.library.unreadTasks.contains("target"))
    XCTAssertTrue(store.activityEntries.isEmpty)
    store.executeCommand("activity")
    XCTAssertEqual(store.destination, .activity)
    store.executeCommand("activity")
    XCTAssertEqual(store.destination, .workspace)
    await store.shutdown()
  }

  func testFailedCrossProjectOpenReturnsToActivityWithoutConsumingUnread() async throws {
    let store = await store(withMissingAgent: true)
    let project = store.dataRoot.appendingPathComponent("project")
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    let path = project.resolvingSymlinksInPath().standardizedFileURL.path
    store.library.tasks = [.init(id: "target", project: path, title: "Target", runIDs: ["run"])]
    store.library.unreadTasks = ["target"]
    store.toggleActivity()
    let opened = await store.openActivityTask("target")
    XCTAssertFalse(opened)
    XCTAssertEqual(store.destination, .activity)
    XCTAssertTrue(store.library.unreadTasks.contains("target"))
    XCTAssertNotNil(store.activityError)
    await store.shutdown()
  }
}
