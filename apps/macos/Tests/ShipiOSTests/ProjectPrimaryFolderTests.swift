import XCTest
@testable import ShipiOS

final class ProjectPrimaryFolderTests: XCTestCase {
  private func fixture() throws -> (URL, URL, URL, URL) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("primary-folder-\(UUID())")
      .resolvingSymlinksInPath().standardizedFileURL
    let paths = ["App", "Backend", "Docs"].map { root.appendingPathComponent($0) }
    for path in paths { try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true) }
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    return (root, paths[0], paths[1], paths[2])
  }

  @MainActor private func store(root: URL, project: URL) -> WorkspaceStore {
    let store = WorkspaceStore(dataRoot: root.appendingPathComponent("Data"))
    store.libraryLoaded = true
    store.library.projects = [project.path]
    store.project = project
    return store
  }

  @MainActor func testPrimaryChangesKeepProjectRowsPinsTasksAndDraftIdentity() throws {
    let (root, original, primary, docs) = try fixture()
    let store = store(root: root, project: original)
    store.library.projectAdditionalFolders[original.path] = [primary.path, docs.path]
    store.library.tasks = [WorkspaceTask(id: "old", project: original.path, title: "Old", runIDs: [])]
    store.library.pinnedProjects = [original.path]
    store.library.sidebar.groups = [SidebarGroup(id: "group", name: "Work")]
    store.library.sidebar.placement[SidebarItem.project(original.path).id] = "group"
    store.library.sidebar.order["group"] = [SidebarItem.project(original.path).id]
    store.selection = "old"
    store.draft = "old task draft"
    store.beginEditingProject(original.path)
    let edit = try XCTUnwrap(store.editingProject)
    try store.saveProjectEdit(edit, title: "My project", folders: [original.path, docs.path], primary: primary.path)
    XCTAssertEqual(store.currentProjectKey, original.path)
    XCTAssertEqual(store.selection, "old")
    XCTAssertEqual(store.draft, "old task draft")
    XCTAssertEqual(store.library.projects, [original.path])
    XCTAssertEqual(store.library.orderedProjects, [original.path])
    XCTAssertEqual(store.library.pinnedProjects, [original.path])
    XCTAssertEqual(store.library.sidebarItems(in: "group"), [.project(original.path)])
    XCTAssertEqual(store.library.projectTitle(primary.path), "My project")
    XCTAssertEqual(store.library.configuredFolders(for: original.path), [primary.path, original.path, docs.path])
    XCTAssertEqual(store.library.folderPaths(for: original.path), [original.path, primary.path, docs.path])
    XCTAssertEqual(store.library.folderPaths(for: primary.path), [primary.path, original.path, docs.path])
    let new = WorkspaceTask(id: "new", project: primary.path, title: "New", runIDs: [])
    XCTAssertEqual(store.library.sidebarProject(for: new), original.path)
    store.project = primary
    store.selection = nil
    store.draft = "new draft"
    XCTAssertEqual(store.draftKey, "new:" + original.path)
    store.project = original
    XCTAssertEqual(store.draft, "new draft", "Unsubmitted drafts use the stable project identity")
  }

  @MainActor func testRepeatedPrimaryChangesPersistHistoricalScopeAndDoNotDuplicateProjects() throws {
    let (root, original, second, third) = try fixture()
    let store = store(root: root, project: original)
    for next in [second, third, original] {
      store.beginEditingProject(original.path)
      let edit = try XCTUnwrap(store.editingProject)
      try store.saveProjectEdit(edit, title: "Project", folders: [original.path, second.path, third.path], primary: next.path)
      store.editingProject = nil
    }
    var saved = try WorkspaceLibrary.load(from: store.dataRoot.appendingPathComponent("workspace.json"))
    XCTAssertEqual(saved.primaryFolder(for: original.path), original.path)
    XCTAssertEqual(saved.projectOwner(for: second.path), original.path)
    XCTAssertEqual(saved.projectOwner(for: third.path), original.path)
    saved.visit(second.path)
    saved.visit(third.path)
    XCTAssertEqual(saved.projects, [original.path])
    XCTAssertTrue(saved.isKnownProjectScope(second.path))
    XCTAssertEqual(ProjectPickerOption.options(in: saved, query: "Backend"), [.project(original.path), .addFolder])
  }

  @MainActor func testPrimarySaveFailureAndConflictingProjectRetainBothProjects() throws {
    let (root, original, primary, _) = try fixture()
    let store = store(root: root, project: original)
    store.library.projects.append(primary.path)
    store.beginEditingProject(original.path)
    let edit = try XCTUnwrap(store.editingProject)
    XCTAssertThrowsError(try store.saveProjectEdit(edit, title: "Changed", folders: [original.path], primary: primary.path))
    XCTAssertEqual(store.library.projects, [original.path, primary.path])
    XCTAssertTrue(store.library.projectPrimaryFolders.isEmpty)
    store.library.projects = [original.path]
    try FileManager.default.createDirectory(at: store.dataRoot.appendingPathComponent("workspace.json"),
      withIntermediateDirectories: true)
    XCTAssertThrowsError(try store.saveProjectEdit(edit, title: "Changed", folders: [original.path], primary: primary.path))
    XCTAssertTrue(store.library.projectPrimaryFolders.isEmpty)
    XCTAssertTrue(store.library.projectScopeOwners.isEmpty)
    XCTAssertEqual(store.library.projectTitle(original.path), "App")
    try FileManager.default.removeItem(at: store.dataRoot.appendingPathComponent("workspace.json"))
    try store.saveProjectEdit(edit, title: "Changed", folders: [original.path], primary: primary.path)
    XCTAssertEqual(store.library.primaryFolder(for: original.path), primary.path)
  }

  @MainActor func testPendingWorktreeAndStalePrimaryCannotBeOverwritten() throws {
    let (root, original, primary, _) = try fixture()
    let store = store(root: root, project: original)
    store.beginEditingProject(original.path)
    let edit = try XCTUnwrap(store.editingProject)
    store.library.pendingManagedDraftTaskIDs[original.path] = "pending"
    XCTAssertThrowsError(try store.saveProjectEdit(edit, title: edit.title, folders: [original.path], primary: primary.path))
    XCTAssertEqual(store.library.pendingManagedDraftTaskIDs[original.path], "pending")
    store.library.pendingManagedDraftTaskIDs = [:]
    store.library.projectPrimaryFolders[original.path] = primary.path
    XCTAssertThrowsError(try store.saveProjectEdit(edit, title: edit.title, folders: [original.path], primary: original.path))
    XCTAssertEqual(store.library.primaryFolder(for: original.path), primary.path)
  }

  @MainActor func testPopoutAndProjectWorktreeUsePrimaryWhileOriginalTaskScopeRemainsKnown() throws {
    let (root, original, primary, _) = try fixture()
    let store = store(root: root, project: original)
    store.beginEditingProject(original.path)
    try store.saveProjectEdit(try XCTUnwrap(store.editingProject), title: "Project",
      folders: [original.path], primary: primary.path)
    store.editingProject = nil
    let popout = try XCTUnwrap(store.createPopoutTask())
    XCTAssertEqual(popout.project, primary.path)
    XCTAssertTrue(store.canHandOffToWorktree(popout) == false, "An unsubmitted popout retains transient protection")
    store.beginWorktreeCreation(from: original.path)
    XCTAssertEqual(store.worktreeSource, primary.path)
    XCTAssertTrue(store.library.projectScopePaths.contains(primary.path))
    var library = store.library
    let checkout = PermanentWorktree(id: UUID(), source: original.path, path: "/checkout",
      commonDirectory: "/git", startingCommit: "hash", startingName: "main", createdAt: Date(), title: "Tree", ready: true)
    library.managedWorktrees = [ManagedWorktree(taskID: "old", checkout: checkout)]
    XCTAssertEqual(library.folderPaths(for: checkout.path), [checkout.path, primary.path])
  }
}
