import XCTest
@testable import ShipiOS

@MainActor final class WorkspaceAttachedFileTests: XCTestCase {
  private func fixture() throws -> (URL, URL, URL) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      .resolvingSymlinksInPath().standardizedFileURL
    let primary = root.appendingPathComponent("App", isDirectory: true), attached = root.appendingPathComponent("Docs", isDirectory: true)
    for folder in [primary, attached] {
      try FileManager.default.createDirectory(at: folder.appendingPathComponent("Sources"), withIntermediateDirectories: true)
      try folder.lastPathComponent.write(to: folder.appendingPathComponent("Sources/Same.swift"), atomically: true, encoding: .utf8)
    }
    return (root.resolvingSymlinksInPath(), primary.resolvingSymlinksInPath(), attached.resolvingSymlinksInPath())
  }

  func testTreeAndTabsKeepSameNamedFilesSeparateAndRemovalRevokesOnlyAttachedScope() async throws {
    let (root, primary, attached) = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let workspace = DeveloperWorkspace()
    workspace.root = primary
    workspace.setAdditionalFileRoots([attached, attached, primary])
    await workspace.refreshFiles()
    let path = attached.appendingPathComponent("Sources/Same.swift").path
    XCTAssertEqual(workspace.fileRoots, [primary, attached])
    XCTAssertEqual(Set(workspace.files), ["Sources/Same.swift", path])
    XCTAssertEqual(workspace.fileGroups.map(\.paths), [["Sources/Same.swift"], ["Sources/Same.swift"]])
    let nodes = WorkspaceFileNode.tree(workspace.fileGroups[1].paths, root: attached)
    XCTAssertEqual(nodes.first?.children?.first?.path, path)
    await workspace.openFile("Sources/Same.swift")
    XCTAssertEqual(workspace.fileText, "App")
    await workspace.openFile(path)
    XCTAssertEqual(workspace.fileText, "Docs")
    XCTAssertEqual(workspace.openFiles, ["Sources/Same.swift", path])
    let reviewRoot = workspace.root
    workspace.setAdditionalFileRoots([])
    await workspace.openFile("Sources/Same.swift")
    XCTAssertEqual(workspace.root, reviewRoot)
    XCTAssertEqual(workspace.openFiles, ["Sources/Same.swift"])
    XCTAssertEqual(workspace.fileText, "App")
    XCTAssertThrowsError(try workspace.fileLocation(path))
    XCTAssertThrowsError(try workspace.fileLocation("../Docs/Sources/Same.swift"))
    workspace.setProject(nil)
  }

  func testNestedFoldersDeduplicateAndSymlinkEscapesRequireAttachedDestination() async throws {
    let (root, primary, attached) = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let link = primary.appendingPathComponent("DocsLink")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: attached)
    let workspace = DeveloperWorkspace()
    workspace.root = primary
    await workspace.openFile("DocsLink/Sources/Same.swift")
    XCTAssertNotNil(workspace.fileError)
    workspace.setAdditionalFileRoots([attached, primary.appendingPathComponent("Sources")])
    await workspace.refreshFiles()
    XCTAssertEqual(workspace.files.filter { $0 == "Sources/Same.swift" }.count, 1)
    XCTAssertEqual(try workspace.fileLocation("DocsLink/Sources/Same.swift").root, attached)
    await workspace.openFile(attached.appendingPathComponent("Sources/Same.swift").path)
    XCTAssertEqual(workspace.fileText, "Docs")
    try FileManager.default.removeItem(at: attached)
    await workspace.refreshFiles()
    XCTAssertNotNil(workspace.filesError)
    XCTAssertTrue(workspace.files.contains("Sources/Same.swift"))
    workspace.setProject(nil)
  }

  func testProjectEditsRefreshMainAndIndependentTaskFoldersWithoutChangingTheirExecutionRoots() async throws {
    let (root, primary, attached) = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root.appendingPathComponent("Data"))
    store.project = primary; store.workspace.root = primary
    store.libraryLoaded = true; store.restoringLibrary = false
    store.library.projects = [primary.path]
    let task = WorkspaceTask(id: "task", project: primary.path, title: "task", runIDs: [], createdAt: Date(), updatedAt: Date())
    store.library.tasks = [task]
    let resources = TaskWindowResources()
    resources.prepare(task.id, store: store)
    let other = try XCTUnwrap(resources.panels.tasks[task.id]?.workspace)
    let detached = DetachedReviewSession()
    detached.configure(store: store, owner: task.id)
    store.beginEditingProject(primary.path)
    let edit = try XCTUnwrap(store.editingProject)
    try store.saveProjectEdit(edit, title: edit.title, folders: [attached.path])
    XCTAssertEqual(store.workspace.fileRoots, [primary, attached])
    XCTAssertEqual(other.fileRoots, [primary, attached])
    detached.configure(store: store, owner: task.id)
    XCTAssertEqual(detached.workspace.fileRoots, [primary, attached])
    XCTAssertThrowsError(try store.saveProjectEdit(edit, title: edit.title, folders: [], primary: attached.path))
    store.editingProject = nil
    store.beginEditingProject(primary.path)
    let next = try XCTUnwrap(store.editingProject)
    try store.saveProjectEdit(next, title: next.title, folders: [primary.path], primary: attached.path)
    XCTAssertEqual(store.workspace.root, primary)
    XCTAssertEqual(other.root, primary)
    XCTAssertEqual(store.library.tasks.first?.project, primary.path)
    XCTAssertEqual(other.fileRoots, [primary, attached])
    resources.shutdown()
    detached.shutdown()
    await store.shutdown()
  }

  func testRealSearchReturnsDistinctRootsAndReadsTheSelectedAttachedResult() async throws {
    let (root, primary, attached) = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let agent = try XCTUnwrap(ProcessInfo.processInfo.environment["SHIPIOS_TEST_AGENT"])
    let request = WorkspaceFileSearchRequest(root: primary, query: "same", executable: URL(fileURLWithPath: agent), additionalRoots: [attached])
    let catalog = WorkspaceFileSearchCatalog()
    await catalog.search(request)
    defer { catalog.close() }
    XCTAssertNil(catalog.error)
    let results = catalog.results(for: request)
    XCTAssertEqual(results.count, 2)
    XCTAssertEqual(Set(results.map(\.id)).count, 2)
    let secondary = try XCTUnwrap(results.first { $0.sourceRoot?.path == attached.path }, "\(results)")
    XCTAssertEqual(secondary.displayDirectory, "Docs/Sources")
    let workspace = DeveloperWorkspace()
    workspace.root = primary
    workspace.setAdditionalFileRoots([attached])
    await workspace.openFile(secondary.workspacePath)
    XCTAssertEqual(workspace.fileText, "Docs")
    await workspace.openFile(attached.appendingPathComponent("Sources/../Sources/Same.swift").path)
    XCTAssertEqual(workspace.openFiles, [secondary.workspacePath])
    var changed = request; changed.additionalRoots = []
    await catalog.search(changed)
    XCTAssertEqual(catalog.results(for: changed).count, 1)
    XCTAssertTrue(catalog.results(for: request).isEmpty)
    workspace.setProject(nil)
  }

  @MainActor private final class PendingRead {
    var pending: CheckedContinuation<String, Never>?
    func read() async -> String { await withCheckedContinuation { pending = $0 } }
  }

  func testRemovingFolderDuringReadCannotRestoreItsTabOrText() async throws {
    let (root, primary, attached) = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let reader = PendingRead()
    let workspace = DeveloperWorkspace(fileReader: { _, _ in await reader.read() })
    workspace.root = primary
    workspace.setAdditionalFileRoots([attached])
    let read = workspace.selectFile(attached.appendingPathComponent("Sources/Same.swift").path)
    for _ in 0..<1000 {
      if reader.pending != nil { break }
      await Task.yield()
    }
    XCTAssertNotNil(reader.pending)
    workspace.setAdditionalFileRoots([])
    reader.pending?.resume(returning: "late attached content")
    await read?.value
    XCTAssertNil(workspace.selectedFile)
    XCTAssertTrue(workspace.openFiles.isEmpty)
    XCTAssertEqual(workspace.fileText, "")
    XCTAssertFalse(workspace.fileLoading)
    workspace.setProject(nil)
  }
}
