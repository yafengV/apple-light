import XCTest
@testable import ShipiOS

@MainActor final class TaskArchiveAgentTests: XCTestCase {
  func testArchiveStopsRealLocalAgentJobAndPersistsOnlyItsTask() async throws {
    let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent()
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("archive-local-agent-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root,
      agentExecutable: repository.appendingPathComponent("target/debug/shipios-agent"))
    await store.restore()
    store.notificationPreferences = .init(timing: .never)
    await store.open(repository.appendingPathComponent("fixtures/HelloShipiOS"))
    XCTAssertTrue(store.connected, store.error ?? "No real local Agent")
    let run = try await store.client.request("run.start", ["kind": .string("build"),
      "container": .string("HelloShipiOS.xcodeproj"), "scheme": .string("HelloShipiOS")])
      .decode(AgentRun.self)
    XCTAssertTrue(run.isActive)
    store.library.attach(run, to: nil, note: "local build to archive")
    store.runs.append(run)
    store.selection = run.id
    let target = try XCTUnwrap(store.selectedTask)
    let other = WorkspaceTask(id: "other", project: target.project, title: "Other", runIDs: [])
    store.library.tasks.append(other)
    store.draft = "unsent local draft"
    XCTAssertTrue(store.commandEnabled("archive"))
    await store.archiveTask(target.id)
    XCTAssertTrue(store.activityArchiveNeedsStop)
    XCTAssertEqual(store.archiveConfirmation()?.taskIDs, [target.id])
    await store.confirmTaskArchive()
    let completed = try await store.client.request("run.get", ["runId": .string(run.id)]).decode(AgentRun.self)
    XCTAssertEqual(completed.status, "cancelled")
    XCTAssertNil(store.activeRun(taskID: target.id))
    XCTAssertEqual(store.activityArchiveResult?.archivedIDs, [target.id])
    XCTAssertEqual(store.activityArchiveResult?.failures.count, 0, store.error ?? "")
    XCTAssertEqual(store.library.drafts[target.id], "unsent local draft")
    XCTAssertFalse(store.library.tasks.first(where: { $0.id == other.id })?.archived ?? true)
    XCTAssertNil(store.selectedTask)
    XCTAssertEqual(try WorkspaceLibrary.load(from: root.appendingPathComponent("workspace.json"))
      .tasks.filter(\.archived).map(\.id), [target.id])
    await store.shutdown()
  }
}
