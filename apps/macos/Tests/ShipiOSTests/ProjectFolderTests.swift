import XCTest
@testable import ShipiOS

final class ProjectFolderTests: XCTestCase {
  private func fixture() throws -> (URL, URL, URL) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("project-folders-\(UUID())")
      .resolvingSymlinksInPath().standardizedFileURL
    let primary = root.appendingPathComponent("App")
    let attached = root.appendingPathComponent("Docs")
    try FileManager.default.createDirectory(at: primary, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: attached, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    return (root, primary, attached)
  }

  func testLegacyProjectsRemainSingleFolderAndAdditionalFoldersPersist() throws {
    let legacy = try JSONDecoder().decode(WorkspaceLibrary.self,
      from: Data(#"{"projects":["/project"]}"#.utf8))
    XCTAssertEqual(legacy.folderPaths(for: "/project"), ["/project"])
    XCTAssertTrue(legacy.folderPaths(for: "").isEmpty)
    var library = legacy
    library.projectAdditionalFolders["/project"] = ["/docs", "/backend"]
    let restored = try JSONDecoder().decode(WorkspaceLibrary.self, from: JSONEncoder().encode(library))
    XCTAssertEqual(restored.folderPaths(for: "/project"), ["/project", "/docs", "/backend"])
    XCTAssertEqual(restored.folderPaths(for: "/other"), ["/other"])
  }

  func testFolderAliasesDeduplicateWithoutCollapsingNestedRoots() throws {
    let (root, primary, attached) = try fixture()
    let nested = attached.appendingPathComponent("Nested")
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    let alias = root.appendingPathComponent("Alias")
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: attached)
    XCTAssertEqual(try ProjectFolders.canonical([primary.path, attached.path, alias.path,
      nested.path, primary.path]), [primary.path, attached.path, nested.path])
    XCTAssertThrowsError(try ProjectFolders.canonical(["relative"]))
    XCTAssertThrowsError(try ProjectFolders.canonical([root.appendingPathComponent("Missing").path]))
    let file = root.appendingPathComponent("file.txt")
    try Data("data".utf8).write(to: file)
    XCTAssertThrowsError(try ProjectFolders.canonical([file.path]))
  }

  @MainActor func testEditorSavesAtomicallyWithoutChangingTaskDraftOrWorkspace() throws {
    let (root, primary, attached) = try fixture()
    let store = WorkspaceStore(dataRoot: root.appendingPathComponent("Data"))
    store.libraryLoaded = true
    store.library.projects = [primary.path]
    store.library.tasks = [WorkspaceTask(id: "task", project: primary.path, title: "Task", runIDs: [])]
    store.project = primary
    store.selection = "task"
    store.draft = "keep draft"
    XCTAssertTrue(store.commandEnabled("activity"))
    store.beginEditingProject(primary.path)
    let request = try XCTUnwrap(store.editingProject)
    XCTAssertFalse(store.commandEnabled("activity"))
    try store.saveProjectEdit(request, title: "App and docs", folders: [attached.path, primary.path])
    XCTAssertEqual(store.project, primary)
    XCTAssertEqual(store.selection, "task")
    XCTAssertEqual(store.draft, "keep draft")
    let saved = try WorkspaceLibrary.load(from: store.dataRoot.appendingPathComponent("workspace.json"))
    XCTAssertEqual(saved.projectTitle(primary.path), "App and docs")
    XCTAssertEqual(saved.folderPaths(for: primary.path), [primary.path, attached.path])
    XCTAssertEqual(saved.tasks.first?.project, primary.path)
    store.editingProject = nil
    store.beginEditingProject(primary.path)
    try store.saveProjectEdit(try XCTUnwrap(store.editingProject), title: "App and docs", folders: [])
    XCTAssertEqual(store.library.folderPaths(for: primary.path), [primary.path])
    XCTAssertTrue(FileManager.default.fileExists(atPath: attached.path), "Detaching keeps actual files")
  }

  @MainActor func testSaveFailureRetainsNameFoldersAndEditorForRetry() throws {
    let (root, primary, attached) = try fixture()
    let data = root.appendingPathComponent("Data")
    try FileManager.default.createDirectory(at: data.appendingPathComponent("workspace.json"),
      withIntermediateDirectories: true)
    let store = WorkspaceStore(dataRoot: data)
    store.libraryLoaded = true
    store.library.projects = [primary.path]
    store.beginEditingProject(primary.path)
    let request = try XCTUnwrap(store.editingProject)
    XCTAssertThrowsError(try store.saveProjectEdit(request, title: "Changed", folders: [attached.path]))
    XCTAssertEqual(store.library.projectTitle(primary.path), "App")
    XCTAssertEqual(store.library.folderPaths(for: primary.path), [primary.path])
    XCTAssertEqual(store.editingProject?.id, request.id)
    try FileManager.default.removeItem(at: data.appendingPathComponent("workspace.json"))
    try store.saveProjectEdit(request, title: "Changed", folders: [attached.path])
    XCTAssertEqual(store.library.projectTitle(primary.path), "Changed")
  }

  @MainActor func testStaleEditorAndExternallyChangedProjectCannotOverwrite() throws {
    let (root, primary, attached) = try fixture()
    let store = WorkspaceStore(dataRoot: root.appendingPathComponent("Data"))
    store.libraryLoaded = true
    store.library.projects = [primary.path]
    store.beginEditingProject(primary.path)
    let request = try XCTUnwrap(store.editingProject)
    store.editingProject = nil
    store.beginEditingProject(primary.path)
    XCTAssertThrowsError(try store.saveProjectEdit(request, title: "Old", folders: [attached.path]))
    let current = try XCTUnwrap(store.editingProject)
    store.library.projectNames[primary.path] = "External"
    XCTAssertThrowsError(try store.saveProjectEdit(current, title: "Old", folders: [attached.path]))
    XCTAssertEqual(store.library.projectTitle(primary.path), "External")
    XCTAssertTrue(store.library.additionalFolders(for: primary.path).isEmpty)
  }

  func testWorktreesKeepAttachedFoldersWhileReplacingPrimaryCheckout() {
    var library = WorkspaceLibrary()
    library.projectAdditionalFolders["/source"] = ["/docs", "/backend"]
    let checkout = PermanentWorktree(id: UUID(), source: "/source", path: "/checkout",
      commonDirectory: "/source/.git", startingCommit: "hash", startingName: "main",
      createdAt: Date(), title: "Tree", ready: true)
    library.managedWorktrees = [ManagedWorktree(taskID: "task", checkout: checkout)]
    XCTAssertEqual(library.folderPaths(for: "/checkout"), ["/checkout", "/docs", "/backend"])
    library.projectAdditionalFolders["/checkout"] = []
    XCTAssertEqual(library.folderPaths(for: "/checkout"), ["/checkout"], "An explicit empty override detaches")
    library.projectAdditionalFolders["/checkout"] = nil
    library.managedWorktrees = []
    library.permanentWorktrees = [checkout]
    XCTAssertEqual(library.folderPaths(for: "/checkout"), ["/checkout", "/docs", "/backend"])
  }
}
