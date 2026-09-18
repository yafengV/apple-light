import XCTest
@testable import ShipiOS

final class SkillTrialTests: XCTestCase {
  @MainActor private func store(at root: URL) async throws -> WorkspaceStore {
    let source = root.appendingPathComponent("Source")
    let manifest = source.appendingPathComponent(".codex-plugin/plugin.json")
    try FileManager.default.createDirectory(at: manifest.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(#"{"id":"example","name":"Example"}"#.utf8).write(to: manifest)
    let skill = source.appendingPathComponent("skills/review/SKILL.md")
    try FileManager.default.createDirectory(at: skill.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("# Review\nReview the project".utf8).write(to: skill)
    let store = WorkspaceStore(dataRoot: root.appendingPathComponent("Data"))
    store.libraryLoaded = true
    store.restoringLibrary = false
    store.scopeLoaded = true
    await store.loadPlugins()
    XCTAssertTrue(store.installPlugin(from: source))
    return store
  }

  @MainActor func testTryCreatesSeparatePersistentDraftWithoutSendingOrOverwritingAttachments() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try await store(at: root)
    store.draft = "保留通用草稿"
    let file = FileAttachment(id: UUID(), name: "notes.txt", byteCount: 12, sha256: "test", isPDF: false)
    store.library.draftFiles["new:none"] = [file]
    store.openSettings(.skills)
    XCTAssertTrue(store.trySkill("example/review"))
    let task = try XCTUnwrap(store.selectedTask)
    XCTAssertTrue(task.runIDs.isEmpty)
    XCTAssertFalse(task.isPopoutDraft)
    XCTAssertEqual(store.destination, .workspace)
    XCTAssertEqual(store.draft, "$example/review ")
    XCTAssertTrue(store.draftFiles.isEmpty)
    XCTAssertEqual(store.library.drafts["new:none"], "保留通用草稿")
    XCTAssertEqual(store.library.draftFiles["new:none"], [file])
    XCTAssertTrue(store.library.chatRuns.isEmpty)
    XCTAssertNil(store.modelTask)
    XCTAssertTrue(store.library.visible(project: "", query: "", archived: false).contains { $0.id == task.id })
    let loaded = try WorkspaceLibrary.load(from: store.dataRoot.appendingPathComponent("workspace.json"))
    XCTAssertEqual(loaded.rememberedSelection(project: ""), task.id)
    XCTAssertEqual(loaded.task(containing: task.id)?.id, task.id)
    XCTAssertEqual(loaded.drafts[task.id], "$example/review ")
    store.newTask()
    XCTAssertEqual(store.draft, "保留通用草稿")
    store.selectTask(task)
    XCTAssertEqual(store.draft, "$example/review ")
  }

  @MainActor func testRepeatedTrialsStayIndependentAndUseCurrentProject() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try await store(at: root)
    store.project = root.appendingPathComponent("Project")
    store.connected = true
    XCTAssertTrue(store.trySkill("example/review"))
    let first = try XCTUnwrap(store.selectedTask)
    store.draft += "第一份草稿"
    XCTAssertTrue(store.trySkill("example/review"))
    let second = try XCTUnwrap(store.selectedTask)
    XCTAssertNotEqual(first.id, second.id)
    XCTAssertEqual(second.project, store.project?.path)
    XCTAssertEqual(store.library.drafts[first.id], "$example/review 第一份草稿")
    XCTAssertEqual(store.library.drafts[second.id], "$example/review ")
    XCTAssertEqual(store.library.tasks.count, 2)
  }

  @MainActor func testUnavailableAndStaleSkillsLeaveNavigationAndDraftsUntouched() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try await store(at: root)
    store.draft = "保留"
    store.openSettings(.skills)
    XCTAssertFalse(store.trySkill("unknown/review"))
    store.busy = true
    XCTAssertFalse(store.canTrySkill("example/review"))
    XCTAssertFalse(store.trySkill("example/review"))
    store.busy = false
    _ = try PluginStorage.setSkillEnabled(false, id: "example/review", root: store.dataRoot)
    XCTAssertFalse(store.trySkill("example/review"), "A stale preview must recheck the saved skill state")
    XCTAssertEqual(store.destination, .settings)
    XCTAssertTrue(store.library.tasks.isEmpty)
    XCTAssertEqual(store.draft, "保留")
    XCTAssertTrue(store.navigationBack.isEmpty)
    XCTAssertNil(store.modelTask)
  }

  @MainActor func testFailedSaveDoesNotCreateTaskOrNavigate() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try await store(at: root)
    store.openSettings(.skills)
    let blocker = store.dataRoot.appendingPathComponent("workspace.json")
    try FileManager.default.createDirectory(at: blocker, withIntermediateDirectories: false)
    XCTAssertFalse(store.trySkill("example/review"))
    XCTAssertEqual(store.destination, .settings)
    XCTAssertTrue(store.library.tasks.isEmpty)
    XCTAssertTrue(store.navigationBack.isEmpty)
  }

  @MainActor func testDeletingArchivedUnsentTaskClearsSelectionAndNavigation() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try await store(at: root)
    XCTAssertTrue(store.trySkill("example/review"))
    let id = try XCTUnwrap(store.selectedTask?.id)
    store.library.tasks[0].archived = true
    store.recordNavigation()
    store.navigationForward = store.navigationBack
    store.deleteArchivedTask(id)
    XCTAssertNil(store.selection)
    XCTAssertFalse(store.navigationBack.contains { $0.run == id })
    XCTAssertFalse(store.navigationForward.contains { $0.run == id })
    XCTAssertNil(store.library.drafts[id])
    XCTAssertFalse(store.library.tasks.contains { $0.id == id })
  }
}
