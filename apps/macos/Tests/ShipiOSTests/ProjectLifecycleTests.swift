import XCTest
@testable import ShipiOS

@MainActor final class ProjectLifecycleTests: XCTestCase {
  private func fixture() async throws -> (WorkspaceStore, URL, URL) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("project lifecycle \(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    let source = root.resolvingSymlinksInPath().appendingPathComponent("source")
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    let helper = try XCTUnwrap(ProcessInfo.processInfo.environment["SHIPIOS_TEST_AGENT"])
    let store = WorkspaceStore(dataRoot: root.appendingPathComponent("data"), agentExecutable: URL(fileURLWithPath: helper))
    await store.restore()
    await store.open(source)
    XCTAssertTrue(store.connected)
    store.library.tasks = [.init(id: "source-task", project: source.path, title: "Source", runIDs: [])]
    store.selectTask(store.library.tasks[0])
    store.draft = "source draft"
    return (store, source, root.resolvingSymlinksInPath())
  }

  func testMissingOrFileScopePreservesConnectedWorkspaceAndRetryOpensOnlyRecoveredTarget() async throws {
    let (store, source, root) = try await fixture()
    let target = root.appendingPathComponent("target")
    try Data("not a directory".utf8).write(to: target)
    store.showingInspector = true
    store.showingTerminal = true
    store.workspace.fileText = "source preview"
    let session = store.session
    await store.open(target)
    XCTAssertTrue(store.connected)
    XCTAssertEqual(store.session, session)
    XCTAssertEqual(store.project?.path, source.path)
    XCTAssertEqual(store.selectedTask?.id, "source-task")
    XCTAssertEqual(store.draft, "source draft")
    XCTAssertEqual(store.workspace.fileText, "source preview")
    XCTAssertTrue(store.showingInspector)
    XCTAssertTrue(store.showingTerminal)
    XCTAssertEqual(store.projectRecoveryPath, target.path)
    XCTAssertFalse(store.busy)
    try FileManager.default.removeItem(at: target)
    await store.retryProjectOpen()
    XCTAssertEqual(store.projectRecoveryPath, target.path)
    XCTAssertEqual(store.project?.path, source.path)
    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
    await store.retryProjectOpen()
    XCTAssertTrue(store.connected)
    XCTAssertEqual(store.project?.path, target.path)
    XCTAssertNil(store.projectRecoveryPath)
    XCTAssertEqual(store.library.drafts["source-task"], "source draft")
    await store.shutdown()
  }

  func testRemoveCurrentProjectPersistsNavigationChangeAndReimportRestoresHistoryAndDraft() async throws {
    let (store, source, _) = try await fixture()
    let file = source.appendingPathComponent("original.txt")
    try Data("keep file".utf8).write(to: file)
    store.library.projectNames[source.path] = "Custom name"
    store.toggleProjectPin(source.path)
    let removed = await store.removeProject(source.path)
    XCTAssertTrue(removed)
    XCTAssertNil(store.project)
    XCTAssertFalse(store.connected)
    XCTAssertEqual(store.library.lastWorkspace, "")
    XCTAssertFalse(store.library.projects.contains(source.path))
    XCTAssertFalse(store.library.pinnedProjects.contains(source.path))
    XCTAssertEqual(store.library.tasks.map(\.id), ["source-task"])
    XCTAssertEqual(store.library.drafts["source-task"], "source draft")
    XCTAssertEqual(try String(contentsOf: file), "keep file")
    let saved = try WorkspaceLibrary.load(from: store.dataRoot.appendingPathComponent("workspace.json"))
    XCTAssertFalse(saved.projects.contains(source.path))
    XCTAssertEqual(saved.lastWorkspace, "")
    XCTAssertEqual(saved.drafts["source-task"], "source draft")
    await store.open(source)
    XCTAssertTrue(store.connected)
    XCTAssertEqual(store.selectedTask?.id, "source-task")
    XCTAssertEqual(store.draft, "source draft")
    XCTAssertEqual(store.library.projectTitle(source.path), "Custom name")
    XCTAssertTrue(store.library.projects.contains(source.path))
    XCTAssertEqual(try String(contentsOf: file), "keep file")
    await store.shutdown()
  }

  func testRemoveSaveFailureKeepsLiveScopeAndRetryUsesLatestLibrary() async throws {
    let (store, source, _) = try await fixture()
    store.toggleProjectPin(source.path)
    let file = store.dataRoot.appendingPathComponent("workspace.json")
    try FileManager.default.removeItem(at: file)
    try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
    let removed = await store.removeProject(source.path)
    XCTAssertFalse(removed)
    XCTAssertTrue(store.connected)
    XCTAssertEqual(store.project?.path, source.path)
    XCTAssertTrue(store.library.projects.contains(source.path))
    XCTAssertTrue(store.library.pinnedProjects.contains(source.path))
    XCTAssertEqual(store.selectedTask?.id, "source-task")
    XCTAssertEqual(store.draft, "source draft")
    XCTAssertTrue(store.error?.contains("无法移除项目") == true)
    try FileManager.default.removeItem(at: file)
    store.library.tasks.append(.init(id: "later", project: "", title: "Later", runIDs: []))
    let retried = await store.removeProject(source.path)
    XCTAssertTrue(retried)
    XCTAssertEqual(Set(store.library.tasks.map(\.id)), ["source-task", "later"])
    XCTAssertNil(store.project)
    await store.shutdown()
  }

  func testRemovingInactiveProjectKeepsCurrentDraftAndOtherSidebarPlacement() async throws {
    let (store, source, root) = try await fixture()
    let other = root.appendingPathComponent("other")
    store.library.projects.append(other.path)
    store.library.tasks.append(.init(id: "other-task", project: other.path, title: "Other", runIDs: []))
    store.library.drafts["other-task"] = "other draft"
    let group = SidebarGroup(name: "Keep group")
    store.library.sidebar.groups = [group]
    XCTAssertTrue(store.moveSidebarItem(.project(source.path), to: group.id))
    let removed = await store.removeProject(other.path)
    XCTAssertTrue(removed)
    XCTAssertTrue(store.connected)
    XCTAssertEqual(store.project?.path, source.path)
    XCTAssertEqual(store.draft, "source draft")
    XCTAssertEqual(store.library.sidebarSection(for: .project(source.path)), group.id)
    XCTAssertEqual(store.library.drafts["other-task"], "other draft")
    XCTAssertNotNil(store.library.tasks.first { $0.id == "other-task" })
    await store.shutdown()
  }
}
