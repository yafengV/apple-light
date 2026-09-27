import XCTest
@testable import ShipiOS

@MainActor final class CodexConversationPathTests: XCTestCase {
  private func fixture() throws -> (root: URL, task: WorkspaceTask, home: URL, rollout: URL) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    let taskID = UUID().uuidString.lowercased()
    let threadID = UUID().uuidString.lowercased()
    let home = root.appendingPathComponent("Codex/Tasks/\(taskID)", isDirectory: true)
    let rollout = home.appendingPathComponent("sessions/rollout.jsonl")
    try FileManager.default.createDirectory(at: rollout.deletingLastPathComponent(),
      withIntermediateDirectories: true)
    try Data("{}\n".utf8).write(to: rollout)
    let reference: [String: String] = ["thread_id": threadID, "rollout_path": rollout.path]
    try JSONSerialization.data(withJSONObject: reference).write(to: home.appendingPathComponent("thread.json"))
    var task = WorkspaceTask(id: taskID, project: "", title: "Codex task", runIDs: [])
    task.codexThreadID = threadID
    return (root, task, home, rollout)
  }

  func testExistingPrivateRolloutCanBeCopiedFromTask() throws {
    let value = try fixture()
    let store = WorkspaceStore(dataRoot: value.root)
    store.libraryLoaded = true
    store.library.tasks = [value.task]
    store.selection = value.task.id
    XCTAssertTrue(store.commandEnabled("copy-conversation-path"))
    let resolved = value.rollout.resolvingSymlinksInPath().standardizedFileURL
    XCTAssertEqual(store.codexConversationPath(for: value.task), resolved)
    store.openSettings(.general)
    XCTAssertFalse(store.commandEnabled("copy-conversation-path"))
  }

  func testMissingMismatchAndEscapedRolloutAreUnavailable() throws {
    let value = try fixture()
    XCTAssertNotNil(CodexConversationPath.existingPath(task: value.task, dataRoot: value.root))
    var wrong = value.task
    wrong.codexThreadID = UUID().uuidString
    XCTAssertNil(CodexConversationPath.existingPath(task: wrong, dataRoot: value.root))
    wrong = value.task
    wrong.id = UUID().uuidString
    XCTAssertNil(CodexConversationPath.existingPath(task: wrong, dataRoot: value.root))

    let outside = value.root.appendingPathComponent("outside.jsonl")
    try Data("{}\n".utf8).write(to: outside)
    let escaped = value.home.appendingPathComponent("sessions/escaped.jsonl")
    try FileManager.default.createSymbolicLink(at: escaped, withDestinationURL: outside)
    let reference: [String: String] = ["thread_id": value.task.codexThreadID!,
      "rollout_path": escaped.path]
    try JSONSerialization.data(withJSONObject: reference)
      .write(to: value.home.appendingPathComponent("thread.json"))
    XCTAssertNil(CodexConversationPath.existingPath(task: value.task, dataRoot: value.root))
    try FileManager.default.removeItem(at: escaped)
    try FileManager.default.removeItem(at: value.rollout)
    XCTAssertNil(CodexConversationPath.existingPath(task: value.task, dataRoot: value.root))

    try Data("{}\n".utf8).write(to: value.rollout)
    let outsideReference = value.root.appendingPathComponent("outside-thread.json")
    let valid: [String: String] = ["thread_id": value.task.codexThreadID!,
      "rollout_path": value.rollout.path]
    try JSONSerialization.data(withJSONObject: valid).write(to: outsideReference)
    let insideReference = value.home.appendingPathComponent("thread.json")
    try FileManager.default.removeItem(at: insideReference)
    try FileManager.default.createSymbolicLink(at: insideReference, withDestinationURL: outsideReference)
    XCTAssertNil(CodexConversationPath.existingPath(task: value.task, dataRoot: value.root))
  }
}
